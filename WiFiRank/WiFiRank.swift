// WiFi Rank: nearby Wi-Fi networks ranked best first, in the menu bar, in a
// window, and (through `--json`) for the `wifirank` terminal command.
import AppKit
import CoreLocation
import CoreWLAN
import ServiceManagement

struct Net {
    let ssid: String, bssid: String, rssi: Int, noise: Int, channel: Int, band: String, security: String
    var current: Bool
    var saved = false
    /// Share of the channel's airtime already in use, as the router reports it (not all do).
    var busyPercent: Int? = nil
    /// Devices connected, as the router reports it.
    var devices: Int? = nil
    /// Other access points heard on the same channel.
    var sameChannel = 0
    /// How wide a slice of airwaves the network uses, in MHz.
    var width: Int? = nil
    /// Wi-Fi generation the router advertises: "4", "5", "6", "6E", "7", or "old".
    var generation: String? = nil
    var snr: Int? { noise == 0 ? nil : rssi - noise }
}

/// How usable a signal is, from its SNR (the same thresholds the README explains).
func snrLevel(_ snr: Int) -> (word: String, color: NSColor) {
    switch snr {
    case 25...: return ("Good: enough for full speed", .systemGreen)
    case 10...: return ("Fair: works, but may slow down", .systemOrange)
    default: return ("Poor: will struggle", .systemRed)
    }
}

/// The SNR hover: the signal and noise behind the number, and why a weak one is weak.
func snrExplanation(_ n: Net) -> String? {
    guard let snr = n.snr else { return "Signal \(n.rssi) dBm; this network didn't report its noise level." }
    var s = "\(snrLevel(snr).word). Signal \(n.rssi) dBm, noise \(n.noise) dBm."
    if snr < 25 {
        s += n.rssi >= -67
            ? " Strong signal but a noisy channel: interference, not distance. Its 5G version or another network may do better."
            : " Weak signal: distance is the problem. A closer access point would help."
    }
    return s
}

/// Only risky security gets a colour; normal encryption stays neutral.
func securityWarning(_ security: String) -> (word: String, color: NSColor)? {
    switch security {
    case "open": return ("No password and no encryption: others nearby can see unencrypted traffic.", .systemOrange)
    case "wep": return ("WEP encryption is broken and easy to crack.", .systemRed)
    default: return nil
    }
}

/// How crowded a channel is, from the share of airtime in use (a common rule of thumb).
func busyLevel(_ percent: Int) -> (word: String, color: NSColor) {
    switch percent {
    case ..<30: return ("Comfortable", .systemGreen)
    case ..<60: return ("Getting crowded", .systemOrange)
    default: return ("Crowded", .systemRed)
    }
}

/// Networks broadcast by one cluster (same router or system), for the window's "Group into Clusters" view.
/// The rules match `same_box()` / `family()` in cli/wifirank; keep the two in step.
struct RouterGroup {
    let id: Int
    let names: [String]
    let accessPoints: Int
    let radios: Int

    /// "Office" when every name is one network on different bands, otherwise "6 names".
    var label: String {
        let bases = Set(names.map(bandless))
        return bases.count == 1 ? baseName(names.min { $0.count < $1.count } ?? "") : "\(names.count) names"
    }
}

private let bandMarker = #"[-_ ]?(2\.4|2|5|6)\s*g(hz)?(?![a-z0-9])|[-_ ](2\.4|5)$"#

/// Name with any band marker removed, lowercased, for matching "Office" with "Office 5G".
func bandless(_ ssid: String) -> String {
    ssid.lowercased()
        .replacingOccurrences(of: bandMarker, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"[-_ ]+"#, with: "_", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
}

/// Name with any band marker removed, keeping its capitals.
func baseName(_ ssid: String) -> String {
    let s = ssid.replacingOccurrences(of: bandMarker, with: "", options: [.regularExpression, .caseInsensitive])
        .trimmingCharacters(in: CharacterSet(charactersIn: " _-"))
    return s.isEmpty ? ssid : s
}

private func addressBytes(_ bssid: String) -> [Int]? {
    let parts = bssid.split(separator: ":").compactMap { Int($0, radix: 16) }
    return parts.count == 6 ? parts : nil
}

/// Radios in one box share the 4th and 5th address bytes and have last bytes close together
/// (…:b2/…:b3); separate boxes jump further (…:ac/…:75).
private func sameBox(_ a: [Int], _ b: [Int]) -> Bool { a[3] == b[3] && a[4] == b[4] && abs(a[5] - b[5]) <= 16 }

/// Groups every radio in a scan by router: same first five address bytes, same box, or the
/// same name once band markers are removed. Returns each visible network name's group.
func routerGroups(_ all: [Net]) -> [String: RouterGroup] {
    var parent = Array(all.indices), boxParent = Array(all.indices)
    func find(_ x: Int, _ p: inout [Int]) -> Int {
        var x = x
        while p[x] != x { p[x] = p[p[x]]; x = p[x] }
        return x
    }
    func union(_ a: Int, _ b: Int, _ p: inout [Int]) {
        let ra = find(a, &p), rb = find(b, &p)
        if ra != rb { p[ra] = rb }
    }
    let addr = all.map { addressBytes($0.bssid) }
    let family = all.map { $0.ssid == "(hidden)" ? "" : bandless($0.ssid) }
    for i in all.indices {
        for j in all.indices where j > i {
            if let a = addr[i], let b = addr[j] {
                if sameBox(a, b) {
                    union(i, j, &parent)
                    union(i, j, &boxParent)
                    continue
                }
                if a[0..<5] == b[0..<5] { union(i, j, &parent); continue }
            }
            if !family[i].isEmpty, family[i] == family[j] { union(i, j, &parent) }
        }
    }
    var members: [Int: [Int]] = [:]
    for i in all.indices { members[find(i, &parent), default: []].append(i) }
    var out: [String: RouterGroup] = [:]
    for (root, idx) in members {
        let names = Array(Set(idx.map { all[$0].ssid }.filter { $0 != "(hidden)" })).sorted { $0.lowercased() < $1.lowercased() }
        let withAddr = idx.filter { addr[$0] != nil }
        let boxes = Set(withAddr.map { find($0, &boxParent) }).count
        let radios = Set(withAddr.map { all[$0].bssid }).count
        let g = RouterGroup(id: root, names: names, accessPoints: max(boxes, 1), radios: max(radios, idx.count))
        for n in names { out[n] = g }
    }
    return out
}

/// The Wi-Fi generation a beacon advertises, from which capability elements it carries:
/// HT (45) = Wi-Fi 4, VHT (191) = Wi-Fi 5, HE (255/35) = Wi-Fi 6, EHT (255/108) = Wi-Fi 7.
func wifiGeneration(_ ie: Data?, band: String) -> String? {
    guard let ie else { return nil }
    let b = [UInt8](ie)
    var ht = false, vht = false, he = false, eht = false
    var i = 0
    while i + 2 <= b.count {
        let id = b[i], len = Int(b[i + 1])
        guard i + 2 + len <= b.count else { break }
        switch id {
        case 45: ht = true
        case 191: vht = true
        case 255 where len >= 1:
            if b[i + 2] == 35 { he = true }
            if b[i + 2] == 108 { eht = true }
        default: break
        }
        i += 2 + len
    }
    if eht { return "7" }
    if he { return band == "6G" ? "6E" : "6" }
    if vht && band == "5G" { return "5" }   // Wi-Fi 5 is 5G-only; some 2.4G routers carry the element anyway
    if ht { return "4" }
    return "old"
}

/// Plain-English description of a generation, and a colour if it holds speed back.
func generationInfo(_ g: String) -> (text: String, color: NSColor?) {
    switch g {
    case "7": return ("Wi-Fi 7 (2024): the newest.", nil)
    case "6E": return ("Wi-Fi 6E (2021): Wi-Fi 6 on the uncrowded 6 GHz band.", nil)
    case "6": return ("Wi-Fi 6 (2019): fast, and copes well with many devices.", nil)
    case "5": return ("Wi-Fi 5 (2014): fast, but slows down more with many devices.", nil)
    case "4": return ("Wi-Fi 4 (2009): older and slower; caps your speed even with a good signal.", .systemOrange)
    default: return ("Older than Wi-Fi 4: very slow.", .systemRed)
    }
}

/// Reads the "BSS Load" element (id 11) from a beacon: devices connected and channel use.
func bssLoad(_ ie: Data?) -> (devices: Int, busy: Int)? {
    guard let ie else { return nil }
    let b = [UInt8](ie)
    var i = 0
    while i + 2 <= b.count {
        let id = b[i], len = Int(b[i + 1])
        if id == 11, len >= 5, i + 2 + len <= b.count {
            return (Int(b[i + 2]) | Int(b[i + 3]) << 8, Int((Double(b[i + 4]) / 255 * 100).rounded()))
        }
        i += 2 + len
    }
    return nil
}

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

/// macOS shows real network names only to an app with Location Services permission,
/// so every scan waits for this first.
final class Location: NSObject, CLLocationManagerDelegate {
    static let shared = Location()
    private let manager = CLLocationManager()
    private var waiting: [(Bool) -> Void] = []
    private var heard = false   // macOS reports the real status shortly after start-up
    private var asked = false

    override init() {
        super.init()
        manager.delegate = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.heard else { return }
            self.heard = true
            self.settle()
        }
    }

    /// Calls `done(true)` once access is granted, asking first only if macOS has never asked.
    func whenAuthorized(_ done: @escaping (Bool) -> Void) {
        waiting.append(done)
        if heard { settle() }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        heard = true
        settle()
    }

    private func settle() {
        guard !waiting.isEmpty else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            if !asked {
                asked = true
                err("WiFi Rank is asking for location access — click Allow.")
                manager.requestWhenInUseAuthorization()
            }
        case .denied, .restricted:
            finish(false)
        default:
            finish(true)
        }
    }

    private func finish(_ ok: Bool) {
        let calls = waiting
        waiting = []
        calls.forEach { $0(ok) }
    }
}

let locationOffMessage = "Location access is off for WiFi Rank, so network names are hidden. "
    + "Turn it on in System Settings → Privacy & Security → Location Services."

func band(_ n: CWNetwork) -> String {
    switch n.wlanChannel?.channelBand {
    case .band2GHz: return "2.4G"
    case .band5GHz: return "5G"
    case .band6GHz: return "6G"
    default: return "?"
    }
}

/// Approximate: CoreWLAN reports most mixed networks as WPA3 transition.
func security(_ n: CWNetwork) -> String {
    if n.supportsSecurity(.none) { return "open" }
    if n.supportsSecurity(.wpa3Personal) { return "wpa3" }
    if n.supportsSecurity(.wpa3Transition) { return "wpa3 transition" }
    if n.supportsSecurity(.wpa3Enterprise) { return "wpa3 enterprise" }
    if n.supportsSecurity(.wpa2Personal) { return "wpa2" }
    if n.supportsSecurity(.wpa2Enterprise) { return "wpa2 enterprise" }
    if n.supportsSecurity(.personal) { return "wpa" }
    if n.supportsSecurity(.WEP) { return "wep" }
    return "other"
}

/// Every access point in range, unranked: hidden networks and duplicates included.
/// Blocks for a few seconds, so call it off the main thread.
func scanAll() -> (nets: [Net], error: String?) {
    guard let iface = CWWiFiClient.shared().interface() else { return ([], "No Wi-Fi hardware found.") }
    let found: Set<CWNetwork>
    do { found = try iface.scanForNetworks(withSSID: nil) }
    catch { return ([], "Scan failed: \(error.localizedDescription)") }
    if found.isEmpty { return ([], "No networks found. Is Wi-Fi on?") }
    let current = iface.ssid()
    let known = savedNetworks()
    let nets = found.map { n -> Net in
        let ssid = n.ssid ?? "(hidden)"
        var net = Net(ssid: ssid, bssid: n.bssid ?? "", rssi: n.rssiValue, noise: n.noiseMeasurement,
                      channel: n.wlanChannel?.channelNumber ?? 0, band: band(n), security: security(n),
                      current: n.ssid != nil && n.ssid == current)
        net.saved = known.contains(ssid)
        if let load = bssLoad(n.informationElementData) {
            net.devices = load.devices
            net.busyPercent = load.busy
        }
        let ch = n.wlanChannel?.channelNumber
        net.sameChannel = found.filter { $0.wlanChannel?.channelNumber == ch }.count - 1
        net.width = [1: 20, 2: 40, 3: 80, 4: 160][n.wlanChannel?.channelWidth.rawValue ?? 0]
        net.generation = wifiGeneration(n.informationElementData, band: net.band)
        return net
    }
    return (nets, nil)
}

/// A cautious ceiling for the Wi-Fi link a network allows, in Mbps, from its SNR, channel width
/// and Wi-Fi generation, assuming a two-stream Mac (the Wi-Fi 6 rate table). Real links usually
/// run lower; it exists to rank networks, so SNR alone can't put a narrow 20 MHz network above
/// a wide 80 MHz one.
func estimatedSpeed(_ n: Net, snr override: Int? = nil) -> Double? {
    guard let snr = override ?? n.snr else { return nil }
    // SNR needed for each rate step (MCS 0–11), with a margin for real-world conditions.
    let needed = [8, 11, 14, 17, 21, 25, 27, 29, 33, 35, 38, 41]
    let perStream20MHz = [8.6, 17.2, 25.8, 34.4, 51.6, 68.8, 77.4, 86.0, 103.2, 114.7, 129.0, 143.4]
    guard let step = needed.lastIndex(where: { snr >= $0 }) else { return 0 }
    let topStep = ["4": 7, "5": 9, "old": 3][n.generation ?? ""] ?? 11
    var widthFactor = [20: 1.0, 40: 2.0, 80: 4.19, 160: 8.38][n.width ?? 20] ?? 1.0
    if n.generation == "4" { widthFactor = min(widthFactor, 2.0) }
    return perStream20MHz[min(step, topStep)] * widthFactor * 2
}

func formatEstimate(_ v: Double?) -> String {
    guard let v else { return "–" }
    return v < 10 ? "<10 Mbps" : "~\(Int((v / 10).rounded()) * 10) Mbps"
}

/// One row per network name (its strongest transmitter), hidden networks dropped,
/// best first: highest SNR, then stronger signal.
func ranked(_ all: [Net]) -> [Net] {
    var best: [String: Net] = [:]
    for n in all where n.ssid != "(hidden)" {
        if let e = best[n.ssid] {
            var keep = n.rssi > e.rssi ? n : e
            keep.current = e.current || n.current
            best[n.ssid] = keep
        } else {
            best[n.ssid] = n
        }
    }
    return best.values.sorted {
        (estimatedSpeed($0) ?? -1, $0.snr ?? -999, $0.rssi) > (estimatedSpeed($1) ?? -1, $1.snr ?? -999, $1.rssi)
    }
}

func run(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try? p.run()
    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

func savedNetworks() -> Set<String> {
    let lines = run(["-listpreferredwirelessnetworks", "en0"]).split(separator: "\n").dropFirst()
    return Set(lines.map { $0.trimmingCharacters(in: .whitespaces) })
}

func pad(_ s: String, _ w: Int, right: Bool = false) -> String {
    let gap = String(repeating: " ", count: max(0, w - s.count))
    return right ? gap + s : s + gap
}

func bars(_ n: Net) -> Character { Array("▂▄▆█")[min(3, max(0, (n.rssi + 90) / 12))] }

func shortName(_ n: Net) -> String { n.ssid.count > 24 ? String(n.ssid.prefix(23)) + "…" : n.ssid }

/// The everyday row: bars, name, band.
func compactLine(_ n: Net) -> String { "\(bars(n))  \(pad(shortName(n), 24))  \(n.band)" }

/// The detailed row shown while Option is held.
func line(_ n: Net) -> String {
    let bar = bars(n)
    let name = shortName(n)
    let snr = n.snr.map(String.init) ?? "-"
    return "\(bar)  \(pad(name, 24))  SNR \(pad(snr, 3, right: true))  \(pad(String(n.rssi), 4, right: true)) dBm  \(pad(n.band, 4))  ch \(n.channel)"
}

// Every row is drawn on this one grid so ticks, icons, names and the grey
// right-hand details line up across all sections.
enum Grid {
    static let check: CGFloat = 12      // tick column
    static let icon: CGFloat = 30       // icon column; section titles start here too
    static let text: CGFloat = 54       // name column
    static let right: CGFloat = 14      // right margin
    static let colGap: CGFloat = 12     // gap between right-hand columns
    static let row: CGFloat = 24
    static let iconBox: CGFloat = 18
}

final class RowView: NSView {
    enum Kind { case item, header, note }
    let kind: Kind
    let title: String
    let columns: [String]
    let colWidths: [CGFloat]
    let iconName: String?
    let iconValue: Double?
    let checked: Bool
    /// Short text drawn in its own column before the title (the band, for networks).
    var lead: String?
    var leadWidth: CGFloat = 0
    /// Optional colour per right-hand column; nil means the usual grey.
    var colColors: [NSColor?] = []
    var action: (() -> Void)?
    var keepsMenuOpen = false    // run the action without closing the menu
    var interactive = true       // false = shown only, never highlighted or clicked
    var forceHighlight = false   // used by the off-screen preview

    init(kind: Kind, title: String, width: CGFloat, columns: [String] = [], colWidths: [CGFloat] = [],
         iconName: String? = nil, iconValue: Double? = nil, checked: Bool = false) {
        self.kind = kind
        self.title = title
        self.columns = columns
        self.colWidths = colWidths
        self.iconName = iconName
        self.iconValue = iconValue
        self.checked = checked
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Grid.row))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var lit: Bool { forceHighlight || (kind == .item && enclosingMenuItem?.isHighlighted == true) }

    override func draw(_ dirtyRect: NSRect) {
        let on = lit
        if on {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 6, yRadius: 6).fill()
        }
        let primary: NSColor = on ? .white : .labelColor
        let secondary: NSColor = on ? NSColor.white.withAlphaComponent(0.75) : .secondaryLabelColor
        let font = NSFont.menuFont(ofSize: 0)
        let edge = bounds.width - Grid.right

        switch kind {
        case .header:
            text(title, x: Grid.icon, maxX: edge, font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor)
        case .note:
            text(title, x: Grid.icon, maxX: edge, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        case .item:
            if checked {
                symbol("checkmark", value: nil, x: Grid.check, box: 14, size: 11, weight: .bold, color: primary)
            }
            if let iconName {
                symbol(iconName, value: iconValue, x: Grid.icon, box: Grid.iconBox, size: 13, weight: .regular, color: primary)
            }
            let digits = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
            var right = edge
            for (i, (col, w)) in zip(columns, colWidths).enumerated().reversed() {
                let color = on ? secondary : ((i < colColors.count ? colColors[i] : nil) ?? secondary)
                text(col, x: right - w, maxX: right, font: digits, color: color, alignment: .right)
                right -= w + Grid.colGap
            }
            var x = Grid.text
            if let lead {
                text(lead, x: x, maxX: x + leadWidth, font: digits, color: secondary, alignment: .right)
                x += leadWidth + Grid.colGap
            }
            text(title, x: x, maxX: right, font: font, color: primary)
        }
    }

    func text(_ s: String, x: CGFloat, maxX: CGFloat, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        p.alignment = alignment
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
        let h = ceil(a.size().height)
        a.draw(with: NSRect(x: x, y: (bounds.height - h) / 2, width: max(0, maxX - x), height: h),
               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    func symbol(_ name: String, value: Double?, x: CGFloat, box: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let base: NSImage? = value != nil
            ? NSImage(systemSymbolName: name, variableValue: value!, accessibilityDescription: nil)
            : NSImage(systemSymbolName: name, accessibilityDescription: nil)
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(hierarchicalColor: color))
        guard let img = base?.withSymbolConfiguration(cfg) else { return }
        let s = img.size
        img.draw(in: NSRect(x: x + (box - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func mouseUp(with event: NSEvent) {
        guard kind == .item, let item = enclosingMenuItem else { return }
        let act = action
        if keepsMenuOpen {
            act?()
            return
        }
        item.menu?.cancelTracking()
        DispatchQueue.main.async { act?() }
    }
}

/// Builds the whole menu. Shared by the live menu and the off-screen preview.
func buildItems(nets: [Net], error: String?, scanning: Bool, updated: Date?, detailed: Bool,
                app: App?) -> [NSMenuItem] {
    let font = NSFont.menuFont(ofSize: 0)
    let small = NSFont.systemFont(ofSize: 11)
    let digits = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
    func w(_ t: String, _ f: NSFont) -> CGFloat { ceil((t as NSString).size(withAttributes: [.font: f]).width) }
    func span(_ cols: [CGFloat]) -> CGFloat { cols.reduce(0, +) + CGFloat(max(0, cols.count - 1)) * Grid.colGap }

    let bandWidth = w("2.4G", digits)
    let netCols = (detailed ? ["SNR 100", "100% busy", "-100 dBm", "ch 165"] : []).map { w($0, digits) }
    let keyCols = [w("⌘R", digits)]
    let f = DateFormatter()
    f.dateFormat = "h:mm a"
    let status = scanning ? "Scanning…"
        : updated.map { "Updated \(f.string(from: $0))  ·  \(nets.count) networks" } ?? "Click to scan"

    let longestName = min(nets.map { w($0.ssid, font) }.max() ?? 0, 260)
    let width = ceil(max(Grid.text + bandWidth + Grid.colGap + longestName + 24 + span(netCols) + Grid.right,
                         Grid.text + w("Rescan", font) + 24 + span(keyCols) + Grid.right,
                         Grid.icon + w(status, small) + Grid.right,
                         240))

    var items: [NSMenuItem] = []
    func add(_ v: RowView, key: String = "", action: Selector? = nil, target: AnyObject? = nil) {
        let m = NSMenuItem(title: v.title, action: action, keyEquivalent: key)
        m.target = target
        m.view = v
        m.isEnabled = v.kind == .item && v.interactive
        items.append(m)
    }

    add(RowView(kind: .note, title: status, width: width))
    if let error, nets.isEmpty { add(RowView(kind: .note, title: error, width: width)) }

    func addNetwork(_ n: Net) {
        let snr = n.snr.map(String.init) ?? "-"
        let busy = n.busyPercent.map { "\($0)% busy" } ?? "–"
        let cols = detailed ? ["SNR \(snr)", busy, "\(n.rssi) dBm", "ch \(n.channel)"] : []
        let v = RowView(kind: .item, title: n.ssid, width: width, columns: cols, colWidths: netCols,
                        iconName: "wifi", iconValue: min(1, max(0, Double(n.rssi + 90) / 40)), checked: n.current)
        v.lead = n.band
        v.leadWidth = bandWidth
        if detailed { v.colColors = [n.snr.map { snrLevel($0).color }, n.busyPercent.map { busyLevel($0).color }] }
        v.interactive = false
        add(v)
    }

    // Networks this Mac has joined before, then the rest; each strongest first.
    let known = nets.filter { $0.saved }, others = nets.filter { !$0.saved }
    if !known.isEmpty {
        items.append(.separator())
        add(RowView(kind: .header, title: "Known Networks", width: width))
        known.forEach(addNetwork)
    }
    if !others.isEmpty {
        items.append(.separator())
        add(RowView(kind: .header, title: "Other Networks", width: width))
        others.forEach(addNetwork)
    }

    items.append(.separator())
    let rescan = RowView(kind: .item, title: "Rescan", width: width, columns: ["⌘R"], colWidths: keyCols,
                         iconName: "arrow.clockwise")
    rescan.action = { [weak app] in app?.startScan() }
    rescan.keepsMenuOpen = true
    add(rescan, key: "r", action: #selector(App.startScan), target: app)
    return items
}

func prettySecurity(_ s: String) -> String {
    switch s {
    case "open": return "Open"
    case "wpa3 transition": return "WPA2/WPA3"
    case "wpa3": return "WPA3"
    case "wpa2": return "WPA2"
    case "wpa": return "WPA"
    case "wep": return "WEP"
    case "wpa3 enterprise": return "WPA3 Enterprise"
    case "wpa2 enterprise": return "WPA2 Enterprise"
    default: return s.capitalized
    }
}

final class BackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

/// A read-only table of nearby networks, opened from the right-click menu.
final class NetworksWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    enum Row { case header(String), net(Net) }

    let window: NSWindow
    let table = NSTableView()
    let status = NSTextField(labelWithString: "")
    let rescanButton: NSButton
    let groupBox = NSButton(checkboxWithTitle: "Group into Clusters", target: nil, action: nil)
    var groups: [String: RouterGroup] = [:]
    let tabs = NSSegmentedControl(labels: ["Networks", "Speed"], trackingMode: .selectOne, target: nil, action: nil)
    let networksView = NSView()
    let speedTab: SpeedTab
    var nets: [Net] = []
    var rows: [Row] = []

    // id, title, width, default sort (nil = not sortable), header tooltip
    static let columns: [(String, String, CGFloat, NSSortDescriptor?, String)] = [
        ("icon", "", 44, nil, ""),
        ("band", "Band", 50, NSSortDescriptor(key: "band", ascending: true),
         "2.4G reaches further but is slower and more crowded. 5G is faster but weaker through walls."),
        ("name", "Network", 150, NSSortDescriptor(key: "name", ascending: true),
         "The network's name. A tick means you're connected to it."),
        ("speed", "Est. Speed", 84, NSSortDescriptor(key: "speed", ascending: false),
         "A cautious estimate of the fastest Wi-Fi link this network allows, from its SNR, width and Wi-Fi generation. "
            + "The list is ranked by it. Real links usually run lower, and it isn't your internet speed."),
        ("snr", "SNR", 44, NSSortDescriptor(key: "snr", ascending: false),
         "How far the signal stands out above background noise. The best guide to real speed: green 25 and above is good, "
            + "orange 10–24 works but may slow, red under 10 will struggle. Hover a value to see the signal and noise behind it."),
        ("busy", "Busy", 54, NSSortDescriptor(key: "busy", ascending: true),
         "How much of the channel's airtime is already in use, as the router reports it. Lower is better: "
            + "green under 30% is comfortable, orange 30–59% is getting crowded, red 60% and over is crowded. "
            + "Not every router reports it; hover a value for details."),
        ("width", "Width", 62, NSSortDescriptor(key: "width", ascending: false),
         "How wide a slice of airwaves the network uses. Wider carries more at once: 80 MHz is roughly four times "
            + "20 MHz. Usually 20 or 40 on 2.4G, 80 or 160 on 5G."),
        ("wifi", "Wi-Fi", 50, NSSortDescriptor(key: "wifi", ascending: false),
         "The Wi-Fi generation the router supports: 4, 5, 6, 6E or 7. Newer is faster and copes better with crowds. "
            + "Orange 4 or older holds your speed back even with a good signal."),
        ("channel", "Channel", 62, NSSortDescriptor(key: "channel", ascending: true),
         "Which lane in the band the network uses. Networks on the same channel slow each other down."),
        ("security", "Security", 88, nil,
         "The encryption the network offers (approximate). Orange Open means no password and no encryption; "
            + "red WEP is easy to crack."),
    ]

    var onClose: () -> Void = {}

    enum Tab: Int { case networks, speed }

    init(onRescan: @escaping () -> Void, currentNet: @escaping () -> Net?) {
        self.onRescan = onRescan
        speedTab = SpeedTab(currentNet: currentNet)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 480),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        rescanButton = NSButton(title: "Rescan", image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)!,
                                target: nil, action: nil)
        super.init()
        window.title = "WiFi Rank"
        window.delegate = self
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.collectionBehavior.insert(.fullScreenNone)
        window.isReleasedWhenClosed = false
        // Fixed size; only the position is remembered between openings.
        if window.setFrameUsingName("WiFiRankNetworks") {
            window.setContentSize(NSSize(width: 850, height: 480))
        } else {
            window.center()
        }
        window.setFrameAutosaveName("WiFiRankNetworks")

        for (id, title, width, sort, tip) in Self.columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            // Wide enough for the title in bold plus the sort arrow, so sorting never squashes it.
            let headerFont = NSFont.boldSystemFont(ofSize: c.headerCell.font?.pointSize ?? NSFont.smallSystemFontSize)
            let fit = sort == nil ? 0 : ceil((title as NSString).size(withAttributes: [.font: headerFont]).width) + 34
            c.width = max(width, fit)
            c.minWidth = id == "name" ? 110 : c.width
            c.resizingMask = id == "name" ? .autoresizingMask : []
            c.headerCell.alignment = id == "name" ? .left : .center
            c.sortDescriptorPrototype = sort
            c.headerToolTip = tip.isEmpty ? nil : tip
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.style = .fullWidth
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.usesAlternatingRowBackgroundColors = true
        table.selectionHighlightStyle = .none
        table.allowsColumnReordering = false
        table.floatsGroupRows = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.sortDescriptors = [NSSortDescriptor(key: "speed", ascending: false)]

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        rescanButton.imagePosition = .imageLeading
        rescanButton.target = self
        rescanButton.action = #selector(rescan)
        rescanButton.keyEquivalent = "r"
        rescanButton.keyEquivalentModifierMask = .command
        // A long status trims with "…" rather than widening the window.
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        groupBox.target = self
        groupBox.action = #selector(groupChanged)
        groupBox.state = UserDefaults.standard.bool(forKey: "groupByRouter") ? .on : .off
        groupBox.toolTip = "Show related networks together in clusters: one router broadcasting several names, "
            + "or an office's access points sharing a name. Off shows Known and Other networks."
        tabs.selectedSegment = Tab.networks.rawValue
        tabs.target = self
        tabs.action = #selector(tabChanged)
        let hint = NSTextField(labelWithString: "Best pick: the top of the list (ranked by estimated speed), ideally with green Busy. Hover anything for what it means.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail

        let content = BackgroundView()
        window.contentView = content
        for v in [tabs, networksView, speedTab] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        for v in [status, groupBox, rescanButton, scroll, hint] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            networksView.addSubview(v)
        }
        let n = networksView
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            n.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 6),
            n.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            n.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            n.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            speedTab.topAnchor.constraint(equalTo: n.topAnchor),
            speedTab.leadingAnchor.constraint(equalTo: n.leadingAnchor),
            speedTab.trailingAnchor.constraint(equalTo: n.trailingAnchor),
            speedTab.bottomAnchor.constraint(equalTo: n.bottomAnchor),

            rescanButton.topAnchor.constraint(equalTo: n.topAnchor, constant: 8),
            rescanButton.trailingAnchor.constraint(equalTo: n.trailingAnchor, constant: -16),
            status.leadingAnchor.constraint(equalTo: n.leadingAnchor, constant: 16),
            status.centerYAnchor.constraint(equalTo: rescanButton.centerYAnchor),
            groupBox.trailingAnchor.constraint(equalTo: rescanButton.leadingAnchor, constant: -16),
            groupBox.centerYAnchor.constraint(equalTo: rescanButton.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: groupBox.leadingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: rescanButton.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: n.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: n.trailingAnchor),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: n.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: n.trailingAnchor, constant: -16),
            hint.bottomAnchor.constraint(equalTo: n.bottomAnchor, constant: -10),
        ])
        select(.networks)
    }

    var selectedTab: Tab { Tab(rawValue: tabs.selectedSegment) ?? .networks }

    func select(_ tab: Tab) {
        tabs.selectedSegment = tab.rawValue
        networksView.isHidden = tab != .networks
        speedTab.isHidden = tab != .speed
    }

    @objc func tabChanged() { select(selectedTab) }

    let onRescan: () -> Void
    @objc func rescan() { onRescan() }

    func windowWillClose(_ notification: Notification) { onClose() }

    @objc func groupChanged() {
        UserDefaults.standard.set(groupBox.state == .on, forKey: "groupByRouter")
        rebuildRows()
    }

    func update(nets: [Net], error: String?, scanning: Bool, updated: Date?, groups: [String: RouterGroup]? = nil) {
        if let groups { self.groups = groups }
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        status.stringValue = scanning ? "Scanning…"
            : (nets.isEmpty ? error : nil) ?? updated.map { "Updated \(f.string(from: $0))  ·  \(nets.count) networks" } ?? ""
        rescanButton.isEnabled = !scanning
        self.nets = nets
        rebuildRows()
        if !scanning { speedTab.panel.refresh() }
    }

    func less(_ a: Net, _ b: Net, _ key: String) -> Bool {
        switch key {
        case "name": return a.ssid.localizedCaseInsensitiveCompare(b.ssid) == .orderedAscending
        case "band": return a.band < b.band
        case "snr": return (a.snr ?? -999, a.rssi) < (b.snr ?? -999, b.rssi)
        case "speed": return (estimatedSpeed(a) ?? -1, a.snr ?? -999) < (estimatedSpeed(b) ?? -1, b.snr ?? -999)
        case "channel": return a.channel < b.channel
        case "busy": return (a.busyPercent ?? 999) < (b.busyPercent ?? 999)
        case "width": return (a.width ?? 0, a.snr ?? -999) < (b.width ?? 0, b.snr ?? -999)
        case "wifi":
            let rank = ["old": 1, "4": 4, "5": 5, "6": 6, "6E": 6, "7": 7]
            return (rank[a.generation ?? ""] ?? 0, a.snr ?? -999) < (rank[b.generation ?? ""] ?? 0, b.snr ?? -999)
        default: return a.rssi < b.rssi
        }
    }

    /// Known networks first, then the rest, each sorted by the chosen column.
    func rebuildRows() {
        let sd = table.sortDescriptors.first
        let key = sd?.key ?? "speed", asc = sd?.ascending ?? false
        let order: (Net, Net) -> Bool = { a, b in
            // Routers that don't report how busy they are go last, whichever way it's sorted.
            if key == "busy", (a.busyPercent == nil) != (b.busyPercent == nil) { return b.busyPercent == nil }
            return asc ? self.less(a, b, key) : self.less(b, a, key)
        }
        rows = []
        if groupBox.state == .on {
            // Routers broadcasting two or more of the visible names, then everything else.
            let byRouter = Dictionary(grouping: nets) { groups[$0.ssid]?.id ?? -1 }
            var routers: [[Net]] = [], alone: [Net] = []
            for (id, members) in byRouter {
                if id != -1, members.count > 1 { routers.append(members.sorted(by: order)) } else { alone += members }
            }
            routers.sort { order($0[0], $1[0]) }
            for members in routers {
                guard let g = groups[members[0].ssid] else { continue }
                let aps = g.accessPoints == 1 ? "1 access point" : "\(g.accessPoints) access points"
                rows.append(.header("In one cluster  ·  \(g.label)  ·  \(aps)"))
                rows += members.map { .net($0) }
            }
            if !alone.isEmpty {
                rows.append(.header(routers.isEmpty ? "Networks" : "On their own"))
                rows += alone.sorted(by: order).map { .net($0) }
            }
        } else {
            let known = nets.filter { $0.saved }.sorted(by: order)
            let others = nets.filter { !$0.saved }.sorted(by: order)
            if !known.isEmpty { rows.append(.header("Known Networks")); rows += known.map { .net($0) } }
            if !others.isEmpty { rows.append(.header("Other Networks")); rows += others.map { .net($0) } }
        }
        table.reloadData()
    }

    func tableView(_ t: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) { rebuildRows() }

    func numberOfRows(in t: NSTableView) -> Int { rows.count }

    func tableView(_ t: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            return label(title, font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor, align: .left, inset: 8)
        case .net(let n):
            let font = NSFont.systemFont(ofSize: 13)
            let digits = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            switch col?.identifier.rawValue {
            case "icon": return signalCell(n)
            case "name": return label(n.ssid, font: font, color: .labelColor, align: .left)
            case "band": return label(n.band, font: digits, color: .secondaryLabelColor, align: .center)
            case "speed":
                let cell = label(formatEstimate(estimatedSpeed(n)), font: digits, color: .labelColor, align: .center)
                cell.toolTip = "Rough ceiling: SNR \(n.snr.map(String.init) ?? "–"), \(n.width.map { "\($0) MHz" } ?? "unknown width")"
                    + "\(n.generation.map { ", Wi-Fi \($0)" } ?? ""). Real links usually run lower."
                return cell
            case "snr":
                let level = n.snr.map(snrLevel)
                let cell = label(n.snr.map(String.init) ?? "–", font: digits, color: level?.color ?? .secondaryLabelColor, align: .center)
                cell.toolTip = snrExplanation(n)
                return cell
            case "rssi": return label("\(n.rssi) dBm", font: digits, color: .secondaryLabelColor, align: .center)
            case "width": return label(n.width.map { "\($0) MHz" } ?? "–", font: digits, color: .secondaryLabelColor, align: .center)
            case "wifi":
                let info = n.generation.map(generationInfo)
                let cell = label(n.generation.map { $0 == "old" ? "≤3" : $0 } ?? "–", font: digits,
                                 color: info?.color ?? .secondaryLabelColor, align: .center)
                cell.toolTip = info?.text
                return cell
            case "channel": return label(String(n.channel), font: digits, color: .secondaryLabelColor, align: .center)
            case "busy":
                let level = n.busyPercent.map(busyLevel)
                let cell = label(n.busyPercent.map { "\($0)%" } ?? "–", font: digits,
                                 color: level?.color ?? .secondaryLabelColor, align: .center)
                let others = n.sameChannel == 1 ? "1 other network" : "\(n.sameChannel) other networks"
                cell.toolTip = n.busyPercent.map { "\(level!.word): channel \($0)% busy · \(n.devices ?? 0) devices connected · "
                    + "\(others) on channel \(n.channel)" } ?? "This router doesn't report how busy it is. \(others) share channel \(n.channel)."
                return cell
            case "security":
                let warning = securityWarning(n.security)
                let cell = label(prettySecurity(n.security), font: font, color: warning?.color ?? .secondaryLabelColor, align: .center)
                cell.toolTip = warning?.word
                return cell
            default: return nil
            }
        }
    }

    func label(_ text: String, font: NSFont, color: NSColor, align: NSTextAlignment, inset: CGFloat = 2) -> NSView {
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: text)
        tf.font = font
        tf.textColor = color
        tf.alignment = align
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: inset),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// Tick (if connected) and the signal-strength icon, side by side in one cell.
    func signalCell(_ n: Net) -> NSView {
        let cell = NSTableCellView()
        let pairs: [(NSImage?, CGFloat, NSFont.Weight, CGFloat)] = [
            (n.current ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: "connected") : nil, 11, .bold, 10),
            (NSImage(systemSymbolName: "wifi", variableValue: min(1, max(0, Double(n.rssi + 90) / 40)),
                     accessibilityDescription: "signal"), 13, .regular, 32),
        ]
        for (img, size, weight, centerX) in pairs {
            guard let img else { continue }
            let iv = NSImageView()
            iv.image = img.withSymbolConfiguration(.init(pointSize: size, weight: weight))
            iv.contentTintColor = .labelColor
            iv.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(iv)
            NSLayoutConstraint.activate([
                iv.centerXAnchor.constraint(equalTo: cell.leadingAnchor, constant: centerX),
                iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }

    func symbol(_ image: NSImage?, size: CGFloat, weight: NSFont.Weight) -> NSView {
        let iv = NSImageView()
        iv.image = image?.withSymbolConfiguration(.init(pointSize: size, weight: weight))
        iv.contentTintColor = .labelColor
        iv.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSTableCellView()
        cell.addSubview(iv)
        NSLayoutConstraint.activate([
            iv.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    var nets: [Net] = []
    var error: String?
    var scanning = false
    var updated: Date?
    var detailed = false   // menu was opened with Option held
    var networksWindow: NetworksWindow?
    var speedWindow: SpeedWindow?
    var groups: [String: RouterGroup] = [:]
    var launchedAtLogin = false
    var backgroundScans: Timer?
    /// How often to look for a better known network while the app runs.
    static let backgroundScanEvery: TimeInterval = 300

    var currentNet: Net? { nets.first { $0.current } }

    /// True when the speed view is what the user is looking at, so no notification is needed.
    var isWatchingSpeed: Bool {
        guard NSApp.isActive else { return false }
        if speedWindow?.window.isKeyWindow == true { return true }
        guard let w = networksWindow, w.window.isKeyWindow else { return false }
        return w.selectedTab == .speed
    }

    func applicationWillFinishLaunching(_ note: Notification) {
        let ev = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = ev?.eventID == AEEventID(kAEOpenApplication)
            && ev?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    /// Opening the app again (Dock, Spotlight, app list) shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showNetworksWindow()
        return false
    }

    @objc func toggleNetworksWindow() {
        if let w = networksWindow?.window, w.isVisible { w.performClose(nil) } else { showNetworksWindow() }
    }

    /// In the Dock while any window is open; menu bar only otherwise.
    func updateDockPresence() {
        let open = [networksWindow?.window, speedWindow?.window].contains { $0?.isVisible == true }
        NSApp.setActivationPolicy(open ? .regular : .accessory)
    }

    @objc func showSpeedTab() {
        showNetworksWindow()
        networksWindow?.select(.speed)
    }

    /// The small speed window starts a test straight away unless one is already running.
    @objc func testSpeedNow() {
        if speedWindow == nil {
            speedWindow = SpeedWindow(currentNet: { [weak self] in self?.currentNet })
            speedWindow?.onClose = { [weak self] in DispatchQueue.main.async { self?.updateDockPresence() } }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        speedWindow?.window.makeKeyAndOrderFront(nil)
        speedWindow?.panel.refresh()
        SpeedController.shared.start(on: currentNet)
    }

    @objc func toggleBetterAlerts() { Notifier.shared.betterAlertsOn.toggle() }

    func applicationDidFinishLaunching(_ note: Notification) {
        item.button?.image = makeMenuBarIcon()
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menu.delegate = self
        // Hidden main menu so ⌘W closes the networks window.
        let mainMenu = NSMenu(), appItem = NSMenuItem(), appSub = NSMenu()
        appSub.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appSub.addItem(.separator())
        appSub.addItem(withTitle: "Quit WiFi Rank", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appSub
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu

        Notifier.shared.setUp()
        Notifier.shared.onOpenSpeed = { [weak self] in self?.showSpeedTab() }
        Notifier.shared.onOpenNetworks = { [weak self] in
            self?.showNetworksWindow()
            self?.networksWindow?.select(.networks)
        }
        SpeedController.shared.onFinished = { [weak self] sample in
            Notifier.shared.speedFinished(sample, userIsWatching: self?.isWatchingSpeed ?? false)
        }
        // Quiet scans so a clearly better known network can be suggested.
        let t = Timer(timeInterval: Self.backgroundScanEvery, repeats: true) { [weak self] _ in
            if Notifier.shared.betterAlertsOn { self?.startScan() }
        }
        RunLoop.main.add(t, forMode: .common)
        backgroundScans = t
        rebuild()
        startScan()
        // Opened by hand (not at login): show the window straight away.
        if !launchedAtLogin { DispatchQueue.main.async { self.showNetworksWindow() } }
    }

    @objc func showNetworksWindow() {
        if networksWindow == nil {
            networksWindow = NetworksWindow(onRescan: { [weak self] in self?.startScan() },
                                            currentNet: { [weak self] in self?.currentNet })
            networksWindow?.onClose = { [weak self] in DispatchQueue.main.async { self?.updateDockPresence() } }
        }
        networksWindow?.update(nets: nets, error: error, scanning: scanning, updated: updated, groups: groups)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        networksWindow?.window.makeKeyAndOrderFront(nil)
        startScan()
    }

    /// Click = network list, Shift-click = networks window, right/Control-click = app menu.
    @objc func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .leftMouseUp, event?.modifierFlags.contains(.shift) == true {
            showNetworksWindow()
            return
        }
        let right = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        show(right ? appMenu() : menu)
    }

    /// Attaches a menu just long enough to pop it from the icon.
    func show(_ m: NSMenu) {
        item.menu = m
        item.button?.performClick(nil)
        item.menu = nil
    }

    func appMenu() -> NSMenu {
        let m = NSMenu()
        let open = networksWindow?.window.isVisible == true
        let show = NSMenuItem(title: open ? "Hide Networks Window" : "Show Networks Window",
                              action: #selector(toggleNetworksWindow), keyEquivalent: "")
        show.target = self
        show.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        show.toolTip = "Shortcut: Shift-click the menu bar icon"
        m.addItem(show)
        let speed = NSMenuItem(title: SpeedController.shared.isTesting ? "Testing Internet Speed…" : "Test Internet Speed…",
                               action: #selector(testSpeedNow), keyEquivalent: "")
        speed.target = self
        speed.image = NSImage(systemSymbolName: "speedometer", accessibilityDescription: nil)
        speed.toolTip = "Measures the internet speed of the network you're on. About 20 seconds; uses some data."
        m.addItem(speed)
        m.addItem(.separator())
        let alerts = NSMenuItem(title: "Better Network Alerts", action: #selector(toggleBetterAlerts), keyEquivalent: "")
        alerts.target = self
        alerts.state = Notifier.shared.betterAlertsOn ? .on : .off
        alerts.image = NSImage(systemSymbolName: "bell", accessibilityDescription: nil)
        alerts.toolTip = "Notifies you when one of your known networks is clearly better than the one you're on. "
            + "Checks every 5 minutes; one alert at a time."
        m.addItem(alerts)
        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        m.addItem(login)
        m.addItem(.separator())
        let quit = NSMenuItem(title: "Quit WiFi Rank", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "xmark.square", accessibilityDescription: nil)
        m.addItem(quit)
        return m
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        detailed = NSEvent.modifierFlags.contains(.option)
        startScan()
    }

    @objc func startScan() {
        guard !scanning else { return }
        scanning = true
        rebuild()
        Location.shared.whenAuthorized { ok in
            DispatchQueue.global().async {
                let r = scanAll()
                DispatchQueue.main.async {
                    self.nets = ranked(r.nets)
                    self.groups = routerGroups(r.nets)
                    self.error = ok ? r.error : locationOffMessage
                    self.updated = Date()
                    self.scanning = false
                    self.rebuild()
                    self.speedWindow?.panel.refresh()
                    Notifier.shared.scanned(self.nets)
                }
            }
        }
    }

    func rebuild() {
        menu.removeAllItems()
        buildItems(nets: nets, error: error, scanning: scanning, updated: updated, detailed: detailed,
                   app: self).forEach(menu.addItem)
        networksWindow?.update(nets: nets, error: error, scanning: scanning, updated: updated, groups: groups)
    }

    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        if s.status == .enabled { try? s.unregister() } else { try? s.register() }
    }
}

/// Runs one scan inside a normal app run loop (macOS hides network names otherwise),
/// hands the result to `body`, then exits. Used by every command-line mode.
final class Headless: NSObject, NSApplicationDelegate {
    let body: ([Net], String?) -> Void
    init(_ body: @escaping ([Net], String?) -> Void) { self.body = body }

    func applicationDidFinishLaunching(_ note: Notification) {
        Location.shared.whenAuthorized { ok in
            DispatchQueue.global().async {
                let r = scanAll()
                DispatchQueue.main.async {
                    self.body(r.nets, ok ? r.error : locationOffMessage)
                    exit(0)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            err("Timed out waiting for location access.")
            exit(2)
        }
    }
}

func runHeadless(_ body: @escaping ([Net], String?) -> Void) -> Never {
    let app = NSApplication.shared
    let d = Headless(body)
    app.delegate = d
    app.setActivationPolicy(.accessory)
    app.run()
    exit(0)
}

// Menu bar list of nearby Wi-Fi networks, strongest first.
// The scan itself is done by WiFiScanHelper.app, which holds the location
// permission macOS requires before it will reveal network names.
import AppKit
import ServiceManagement

let helperPath = NSString(string: "~/.local/libexec/WiFiScanHelper.app/Contents/MacOS/wifiscanhelper").expandingTildeInPath

struct Net {
    let ssid: String, rssi: Int, noise: Int, channel: Int, band: String, security: String
    var current: Bool
    var saved = false
    var snr: Int? { noise == 0 ? nil : rssi - noise }
}

func scan() -> (nets: [Net], error: String?) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: helperPath)
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    do { try p.run() } catch { return ([], "Scan helper not found.") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !rows.isEmpty else {
        return ([], errText.isEmpty ? "No networks found. Is Wi-Fi on?" : errText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    // One entry per name: keep the strongest transmitter.
    var best: [String: Net] = [:]
    for r in rows {
        let n = Net(ssid: r["ssid"] as? String ?? "?", rssi: r["rssi"] as? Int ?? -999,
                    noise: r["noise"] as? Int ?? 0, channel: r["channel"] as? Int ?? 0,
                    band: r["band"] as? String ?? "?", security: r["security"] as? String ?? "",
                    current: r["current"] as? Bool ?? false)
        if n.ssid == "(hidden)" { continue }
        if var e = best[n.ssid] {
            e.current = e.current || n.current
            best[n.ssid] = n.rssi > e.rssi ? Net(ssid: n.ssid, rssi: n.rssi, noise: n.noise, channel: n.channel,
                                                  band: n.band, security: n.security, current: e.current) : e
        } else {
            best[n.ssid] = n
        }
    }
    let known = savedNetworks()
    let nets = best.values.map { n -> Net in var n = n; n.saved = known.contains(n.ssid); return n }
    return (nets.sorted { ($0.snr ?? -999, $0.rssi) > ($1.snr ?? -999, $1.rssi) }, nil)
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
            for (col, w) in zip(columns, colWidths).reversed() {
                text(col, x: right - w, maxX: right, font: digits, color: secondary, alignment: .right)
                right -= w + Grid.colGap
            }
            text(title, x: Grid.text, maxX: right, font: font, color: primary)
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

    let netCols = (detailed ? ["2.4G", "SNR 100", "-100 dBm", "ch 165"] : ["2.4G"]).map { w($0, digits) }
    let keyCols = [w("⌘R", digits)]
    let f = DateFormatter()
    f.dateFormat = "h:mm a"
    let status = scanning ? "Scanning…"
        : updated.map { "Updated \(f.string(from: $0))  ·  \(nets.count) networks" } ?? "Click to scan"

    let longestName = min(nets.map { w($0.ssid, font) }.max() ?? 0, 260)
    let width = ceil(max(Grid.text + longestName + 24 + span(netCols) + Grid.right,
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
        let cols = detailed ? [n.band, "SNR \(snr)", "\(n.rssi) dBm", "ch \(n.channel)"] : [n.band]
        let v = RowView(kind: .item, title: n.ssid, width: width, columns: cols, colWidths: netCols,
                        iconName: "wifi", iconValue: min(1, max(0, Double(n.rssi + 90) / 40)), checked: n.current)
        v.toolTip = "Security: \(n.security)\(n.saved ? "  ·  known network" : "")"
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
    var nets: [Net] = []
    var rows: [Row] = []

    // id, title, width, default sort (nil = not sortable), header tooltip
    static let columns: [(String, String, CGFloat, NSSortDescriptor?, String)] = [
        ("icon", "", 44, nil, ""),
        ("name", "Network", 170, NSSortDescriptor(key: "name", ascending: true),
         "The network's name. A tick means you're connected to it."),
        ("band", "Band", 50, NSSortDescriptor(key: "band", ascending: true),
         "2.4G reaches further but is slower and more crowded. 5G is faster but weaker through walls."),
        ("snr", "SNR", 44, NSSortDescriptor(key: "snr", ascending: false),
         "How far the signal stands out above background noise. The best guide to real speed: above 25 is comfortable, under 10 will struggle."),
        ("rssi", "Signal", 72, NSSortDescriptor(key: "rssi", ascending: false),
         "Raw signal strength. Closer to zero is stronger: -50 excellent, -65 good, -75 weak, -85 barely usable."),
        ("channel", "Channel", 62, NSSortDescriptor(key: "channel", ascending: true),
         "Which lane in the band the network uses. Networks on the same channel slow each other down."),
        ("security", "Security", 110, nil,
         "The encryption the network offers (approximate). Open means no password and no encryption."),
    ]

    var onClose: () -> Void = {}

    init(onRescan: @escaping () -> Void) {
        self.onRescan = onRescan
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 440),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        rescanButton = NSButton(title: "Rescan", image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)!,
                                target: nil, action: nil)
        super.init()
        window.title = "WiFi Rank"
        window.delegate = self
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.collectionBehavior.insert(.fullScreenNone)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 260)
        if !window.setFrameUsingName("WiFiRankNetworks") { window.center() }
        window.setFrameAutosaveName("WiFiRankNetworks")

        for (id, title, width, sort, tip) in Self.columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            // Wide enough for the title in bold plus the sort arrow, so sorting never squashes it.
            let headerFont = NSFont.boldSystemFont(ofSize: c.headerCell.font?.pointSize ?? NSFont.smallSystemFontSize)
            let fit = sort == nil ? 0 : ceil((title as NSString).size(withAttributes: [.font: headerFont]).width) + 34
            c.width = max(width, fit)
            c.minWidth = id == "name" ? 120 : c.width
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
        table.intercellSpacing = NSSize(width: 10, height: 0)
        table.usesAlternatingRowBackgroundColors = true
        table.selectionHighlightStyle = .none
        table.allowsColumnReordering = false
        table.floatsGroupRows = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.sortDescriptors = [NSSortDescriptor(key: "snr", ascending: false)]

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
        let hint = NSTextField(labelWithString: "Best pick: highest SNR. Hover a column title to see what it means; click one to sort.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail

        let content = BackgroundView()
        window.contentView = content
        for v in [status, rescanButton, scroll, hint] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            rescanButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            rescanButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            status.centerYAnchor.constraint(equalTo: rescanButton.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: rescanButton.leadingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: rescanButton.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
    }

    let onRescan: () -> Void
    @objc func rescan() { onRescan() }

    func windowWillClose(_ notification: Notification) { onClose() }

    func update(nets: [Net], error: String?, scanning: Bool, updated: Date?) {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        status.stringValue = scanning ? "Scanning…"
            : (nets.isEmpty ? error : nil) ?? updated.map { "Updated \(f.string(from: $0))  ·  \(nets.count) networks" } ?? ""
        rescanButton.isEnabled = !scanning
        self.nets = nets
        rebuildRows()
    }

    func less(_ a: Net, _ b: Net, _ key: String) -> Bool {
        switch key {
        case "name": return a.ssid.localizedCaseInsensitiveCompare(b.ssid) == .orderedAscending
        case "band": return a.band < b.band
        case "snr": return (a.snr ?? -999, a.rssi) < (b.snr ?? -999, b.rssi)
        case "channel": return a.channel < b.channel
        default: return a.rssi < b.rssi
        }
    }

    /// Known networks first, then the rest, each sorted by the chosen column.
    func rebuildRows() {
        let sd = table.sortDescriptors.first
        let key = sd?.key ?? "snr", asc = sd?.ascending ?? false
        let order: (Net, Net) -> Bool = { asc ? self.less($0, $1, key) : self.less($1, $0, key) }
        rows = []
        let known = nets.filter { $0.saved }.sorted(by: order)
        let others = nets.filter { !$0.saved }.sorted(by: order)
        if !known.isEmpty { rows.append(.header("Known Networks")); rows += known.map { .net($0) } }
        if !others.isEmpty { rows.append(.header("Other Networks")); rows += others.map { .net($0) } }
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
            case "snr": return label(n.snr.map(String.init) ?? "–", font: digits, color: .secondaryLabelColor, align: .center)
            case "rssi": return label("\(n.rssi) dBm", font: digits, color: .secondaryLabelColor, align: .center)
            case "channel": return label(String(n.channel), font: digits, color: .secondaryLabelColor, align: .center)
            case "security": return label(prettySecurity(n.security), font: font, color: .secondaryLabelColor, align: .center)
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

/// The app's icon: a white Wi-Fi symbol on a blue rounded square.
func makeAppIcon() -> NSImage {
    NSImage(size: NSSize(width: 512, height: 512), flipped: false) { r in
        let tile = NSBezierPath(roundedRect: r.insetBy(dx: 50, dy: 50), xRadius: 92, yRadius: 92)
        NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.56, blue: 1.0, alpha: 1),
                   ending: NSColor(srgbRed: 0.04, green: 0.36, blue: 0.86, alpha: 1))?.draw(in: tile, angle: -90)
        let cfg = NSImage.SymbolConfiguration(pointSize: 210, weight: .semibold).applying(.init(paletteColors: [.white]))
        if let sym = NSImage(systemSymbolName: "wifi", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let s = sym.size
            sym.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
        }
        return true
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
    var launchedAtLogin = false

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

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.applicationIconImage = makeAppIcon()
        let img = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "WiFi Rank")
        img?.isTemplate = true
        item.button?.image = img
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
        rebuild()
        // Opened by hand (not at login): show the window straight away.
        if !launchedAtLogin { DispatchQueue.main.async { self.showNetworksWindow() } }
    }

    @objc func showNetworksWindow() {
        if networksWindow == nil {
            networksWindow = NetworksWindow(onRescan: { [weak self] in self?.startScan() })
            // Leave the Dock again once the window is closed.
            networksWindow?.onClose = { NSApp.setActivationPolicy(.accessory) }
        }
        networksWindow?.update(nets: nets, error: error, scanning: scanning, updated: updated)
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
        m.addItem(.separator())
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
        DispatchQueue.global().async {
            let r = scan()
            DispatchQueue.main.async {
                self.nets = r.nets
                self.error = r.error
                self.updated = Date()
                self.scanning = false
                self.rebuild()
            }
        }
    }

    func rebuild() {
        menu.removeAllItems()
        buildItems(nets: nets, error: error, scanning: scanning, updated: updated, detailed: detailed,
                   app: self).forEach(menu.addItem)
        networksWindow?.update(nets: nets, error: error, scanning: scanning, updated: updated)
    }

    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        if s.status == .enabled { try? s.unregister() } else { try? s.register() }
    }
}

// `wifirank --render out.png [--dark] [--detailed]` draws the menu to a picture
// without showing anything on screen, for checking the layout.
if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    let r = scan()
    let items = buildItems(nets: r.nets, error: r.error, scanning: false, updated: Date(),
                           detailed: CommandLine.arguments.contains("--detailed"), app: nil)
    let appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)!
    var y: CGFloat = 5
    var placed: [(RowView, CGFloat)] = []
    var seps: [CGFloat] = []
    for it in items {
        if it.isSeparatorItem { seps.append(y + 5); y += 11; continue }
        guard let v = it.view as? RowView else { continue }
        placed.append((v, y))
        y += v.frame.height
    }
    let size = NSSize(width: placed.first?.0.frame.width ?? 300, height: y + 5)
    // Show the hover state on the first row that can actually be clicked.
    placed.map(\.0).first { $0.kind == .item && $0.interactive }?.forceHighlight = true
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    // Rows are laid out top-down, so draw into a top-down (flipped) context.
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    appearance.performAsCurrentDrawingAppearance {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 10, yRadius: 10).fill()
        NSColor.separatorColor.setFill()
        for sy in seps { NSRect(x: 12, y: sy, width: size.width - 24, height: 1).fill() }
        for (v, vy) in placed {
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: 0, yBy: vy)
            t.concat()
            v.appearance = appearance
            v.draw(v.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

// `wifirank --render-icon out.png` draws the app icon.
if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    let icon = makeAppIcon()
    let rep = NSBitmapImageRep(data: icon.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

// `wifirank --render-window out.png [--dark]` draws the networks window off-screen.
if let i = CommandLine.arguments.firstIndex(of: "--render-window"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    let r = scan()
    let w = NetworksWindow(onRescan: {})
    let appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)!
    w.window.appearance = appearance
    w.window.setContentSize(NSSize(width: 700, height: 440))
    if let k = CommandLine.arguments.firstIndex(of: "--sort"), k + 1 < CommandLine.arguments.count {
        let key = CommandLine.arguments[k + 1]
        w.table.sortDescriptors = [NSSortDescriptor(key: key, ascending: key == "name" || key == "band" || key == "channel")]
    }
    w.update(nets: r.nets, error: r.error, scanning: false, updated: Date())
    let v = w.window.contentView!
    v.layoutSubtreeIfNeeded()
    w.table.layoutSubtreeIfNeeded()
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    appearance.performAsCurrentDrawingAppearance { v.cacheDisplay(in: v.bounds, to: rep) }
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

// `wifirank --print` runs one scan and prints it, for checking without the menu bar.
if CommandLine.arguments.contains("--print") {
    let r = scan()
    if let e = r.error { print("error:", e) }
    r.nets.forEach { print(($0.current ? "✓ " : "  ") + line($0) + ($0.saved ? "   [known]" : "")) }
    exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

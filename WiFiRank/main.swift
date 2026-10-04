// Entry point: command-line modes first, otherwise the menu bar app.
import AppKit
import CoreWLAN

/// Draws an image into a PNG of exactly `pixels` wide and high.
func writeIconPNG(_ image: NSImage, pixels: Int, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// `wifirank --render-icon out.png` draws the app icon at 1024 pixels.
if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    writeIconPNG(makeAppIcon(size: 1024), pixels: 1024, to: CommandLine.arguments[i + 1])
    exit(0)
}

// `wifirank --render-iconset DIR` writes every size macOS wants; build.sh turns it into AppIcon.icns.
if let i = CommandLine.arguments.firstIndex(of: "--render-iconset"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    let dir = CommandLine.arguments[i + 1]
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = points * scale
            // Each size is drawn fresh, so small sizes drop the detail they can't show.
            writeIconPNG(makeAppIcon(size: CGFloat(px)), pixels: px,
                         to: "\(dir)/icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png")
        }
    }
    exit(0)
}

// `wifirank --render-menubar-icon out.png` shows the menu bar icon on light and dark bars, 4x size.
if let i = CommandLine.arguments.firstIndex(of: "--render-menubar-icon"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    let icon = makeMenuBarIcon()
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    for (k, dark) in [false, true].enumerated() {
        let bar = NSRect(x: 0, y: CGFloat(k) * 100, width: 320, height: 100)
        (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
        bar.fill()
        // Tint the template the way macOS does: black on light bars, white on dark.
        let tinted = NSImage(size: icon.size, flipped: false) { r in
            icon.draw(in: r)
            (dark ? NSColor.white : NSColor.black).set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: 124, y: bar.minY + 14, width: 72, height: 72))   // 18 pt at 4x
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

// `wifirank --speed-test` runs one real speed test and prints the live readings, for checking the engine.
if CommandLine.arguments.contains("--speed-test") {
    let test = SpeedTest()
    var count = 0
    test.start(onLive: { r in
        count += 1
        if count % 10 == 1 { print("live  down \(formatMbps(r.down))  up \(formatMbps(r.up))") }
    }, onDone: { outcome in
        switch outcome {
        case .finished(let d, let u, let delay, let resp):
            print("done  down \(formatMbps(d))  up \(formatMbps(u))  delay \(Int(delay.rounded())) ms  responsiveness \(resp)  (\(count) live readings)")
        case .cancelled: print("cancelled")
        case .failed(let why): print("failed: \(why)")
        }
        exit(0)
    })
    RunLoop.main.run()
}

// `wifirank --check-better-rule` runs the better-network rule against made-up scans.
if CommandLine.arguments.contains("--check-better-rule") {
    func net(_ ssid: String, snr: Int, current: Bool = false, saved: Bool = true) -> Net {
        Net(ssid: ssid, bssid: "", rssi: -90 + snr, noise: -90, channel: 1, band: "5G", security: "wpa3", current: current, saved: saved)
    }
    let cases: [(String, [Net], String?)] = [
        ("known network 6 points better", [net("Here", snr: 15, current: true), net("Better", snr: 21)], "Better"),
        ("only 4 points better", [net("Here", snr: 18, current: true), net("Close", snr: 22)], nil),
        ("better but not known", [net("Here", snr: 15, current: true), net("Stranger", snr: 40, saved: false)], nil),
        ("5 better but below 20 overall", [net("Here", snr: 10, current: true), net("Weak", snr: 15)], nil),
        ("picks the best of two", [net("Here", snr: 10, current: true), net("Good", snr: 25), net("Best", snr: 35)], "Best"),
        ("not connected", [net("Elsewhere", snr: 40)], nil),
    ]
    var ok = true
    for (name, nets, want) in cases {
        let got = Notifier.clearlyBetter(nets)?.ssid
        let pass = got == want
        ok = ok && pass
        print("\(pass ? "pass" : "FAIL")  \(name): got \(got ?? "none"), expected \(want ?? "none")")
    }
    exit(ok ? 0 : 1)
}

// `wifirank --check-load` shows, per access point, how many share its channel and whether
// it broadcasts how busy it is (the "BSS Load" part of its beacon: devices connected, airtime used).
if CommandLine.arguments.contains("--check-load") {
    runHeadless { all, _ in
        guard let iface = CWWiFiClient.shared().interface(),
              let found = try? iface.scanForNetworks(withSSID: nil) else { print("scan failed"); return }
        var withLoad = 0
        for n in found.sorted(by: { $0.rssiValue > $1.rssiValue }) {
            let ch = n.wlanChannel?.channelNumber ?? 0
            let sameChannel = found.filter { $0.wlanChannel?.channelNumber == ch }.count - 1
            var load = "no busy info"
            if let ie = n.informationElementData {
                let b = [UInt8](ie)
                var i = 0
                while i + 2 <= b.count {
                    let id = b[i], len = Int(b[i + 1])
                    if id == 11, len >= 5, i + 2 + len <= b.count {
                        let stations = Int(b[i + 2]) | Int(b[i + 3]) << 8
                        let busy = Int((Double(b[i + 4]) / 255 * 100).rounded())
                        load = "\(stations) devices, channel \(busy)% busy"
                        withLoad += 1
                        break
                    }
                    i += 2 + len
                }
            } else {
                load = "no beacon data"
            }
            let name = (n.ssid ?? "(hidden)").padding(toLength: 26, withPad: " ", startingAt: 0)
            print("\(name) ch \(String(ch).padding(toLength: 4, withPad: " ", startingAt: 0)) \(sameChannel) others on channel   \(load)")
        }
        print("--- \(withLoad) of \(found.count) access points broadcast busy info")
    }
}

// `wifirank --check-details` shows, per access point, the Wi-Fi generation its beacon
// advertises and its channel width, plus the current connection's link rate.
if CommandLine.arguments.contains("--check-details") {
    runHeadless { _, _ in
        guard let iface = CWWiFiClient.shared().interface(),
              let found = try? iface.scanForNetworks(withSSID: nil) else { print("scan failed"); return }
        func generation(_ ie: Data?, band: String) -> String {
            guard let ie else { return "no beacon data" }
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
            if eht { return "Wi-Fi 7" }
            if he { return band == "6G" ? "Wi-Fi 6E" : "Wi-Fi 6" }
            if vht && band == "5G" { return "Wi-Fi 5" }
            if ht { return "Wi-Fi 4" }
            return "older"
        }
        var counts: [String: Int] = [:]
        for n in found.sorted(by: { $0.rssiValue > $1.rssiValue }) {
            let net = Net(ssid: n.ssid ?? "(hidden)", bssid: "", rssi: 0, noise: 0, channel: 0, band: band(n), security: "", current: false)
            let g = generation(n.informationElementData, band: net.band)
            counts[g, default: 0] += 1
            let w: String
            switch n.wlanChannel?.channelWidth.rawValue ?? 0 {
            case 1: w = "20 MHz"; case 2: w = "40 MHz"; case 3: w = "80 MHz"; case 4: w = "160 MHz"; default: w = "unknown"
            }
            let name = net.ssid.padding(toLength: 26, withPad: " ", startingAt: 0)
            print("\(name) \(net.band.padding(toLength: 5, withPad: " ", startingAt: 0)) \(g.padding(toLength: 9, withPad: " ", startingAt: 0)) \(w)")
        }
        print("--- generations: \(counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
        print("--- connected: link rate \(Int(iface.transmitRate())) Mbps, mode raw \(iface.activePHYMode().rawValue) (6 = Wi-Fi 6, 7 = Wi-Fi 7)")
    }
}

// `wifirank --json` prints every access point in range; the terminal command uses this.
if CommandLine.arguments.contains("--json") {
    runHeadless { all, error in
        if let error, all.isEmpty { err(error) }
        let rows: [[String: Any]] = all.map {
            ["ssid": $0.ssid, "bssid": $0.bssid, "rssi": $0.rssi, "noise": $0.noise, "channel": $0.channel,
             "band": $0.band, "security": $0.security, "current": $0.current, "known": $0.saved]
        }
        let data = (try? JSONSerialization.data(withJSONObject: rows)) ?? Data("[]".utf8)
        FileHandle.standardOutput.write(data)
    }
}

// `wifirank --print` runs one scan and prints it, for checking without the menu bar.
if CommandLine.arguments.contains("--print") {
    runHeadless { all, error in
        if let error { print("error:", error) }
        ranked(all).forEach { print(($0.current ? "✓ " : "  ") + line($0) + ($0.saved ? "   [known]" : "")) }
    }
}

// `wifirank --render out.png [--dark] [--detailed]` draws the menu to a picture
// without showing anything on screen, for checking the layout.
if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
    runHeadless { all, error in
        let items = buildItems(nets: ranked(all), error: error, scanning: false, updated: Date(),
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
    }
}

/// Sample results for off-screen previews: two weeks on the current network, a few on others,
/// and a multi-network session earlier today. Never saved.
func previewHistory(current: String) -> [SpeedSample] {
    let now = Date()
    var out: [SpeedSample] = []
    let downs: [Double] = [62, 70, 81, 55, 38, 41, 74, 79, 83, 60, 35, 44, 77]
    for (i, d) in downs.enumerated() {
        let date = now.addingTimeInterval(-Double(downs.count - i) * 26 * 3600)
        out.append(SpeedSample(date: date, ssid: current, band: "5G", snr: 30, down: d, up: d * 0.27,
                               delay: 38, responsiveness: "Medium"))
    }
    let session: [(String, Double, Double)] = [("SCM DEPT AP 2", 142, 38), ("SCM DEPT AP 1", 64, 21),
                                               ("GUEST KL", 23, 9), ("SCM DEPT AP 2", 128, 35)]
    for (i, x) in session.enumerated() {
        out.append(SpeedSample(date: now.addingTimeInterval(-5 * 3600 + Double(i) * 1500), ssid: x.0, band: "5G", snr: 28,
                               down: x.1, up: x.2, delay: 30, responsiveness: "High"))
    }
    out.append(SpeedSample(date: now.addingTimeInterval(-600), ssid: current, band: "5G", snr: 31, down: 81.5, up: 21.7,
                           delay: 41, responsiveness: "Medium"))
    return out.sorted { $0.date < $1.date }
}

/// Sample networks for previews, covering every Busy level and the unknown case.
func previewNetworks() -> [Net] {
    func n(_ ssid: String, _ snr: Int, _ band: String, _ ch: Int, busy: Int?, devices: Int? = nil, others: Int = 0,
           current: Bool = false, saved: Bool = false, security: String = "wpa3 transition", bssid: String = "") -> Net {
        var x = Net(ssid: ssid, bssid: bssid, rssi: -92 + snr, noise: -92, channel: ch, band: band, security: security,
                    current: current, saved: saved)
        x.busyPercent = busy
        x.width = band == "5G" ? 80 : 20
        x.generation = ssid == "Old Printer" ? "4" : (band == "5G" ? "6" : "5")
        x.devices = devices
        x.sameChannel = others
        return x
    }
    var sample = [n("Office", 34, "5G", 44, busy: 12, devices: 9, others: 1, current: true, saved: true, bssid: "aa:11:22:33:44:10"),
            n("Office-2.4", 30, "2.4G", 1, busy: 63, devices: 21, others: 5, saved: true, bssid: "aa:11:22:33:44:11"),
            n("Cafe Guest", 28, "2.4G", 6, busy: 41, devices: 6, others: 2, security: "open"),
            n("Neighbour_5G", 22, "5G", 36, busy: 3, devices: 1),
            n("Phone hotspot", 18, "5G", 149, busy: nil),
            n("Shop WiFi", 12, "2.4G", 11, busy: 58, devices: 4, others: 3),
            n("Old Printer", 6, "2.4G", 3, busy: nil, security: "wep")]
    // A company router broadcasting three names from two access points (the FM pattern seen 2026-10-04).
    for (name, first) in [("DeliveryMFM", "ee"), ("DeviceNet", "f2"), ("FM_Access", "e2")] {
        sample.append(n(name, 33, "2.4G", 1, busy: 58, devices: 0, others: 5, bssid: "\(first):55:a8:e6:50:ac"))
        sample.append(n(name, 27, "2.4G", 11, busy: 22, devices: 0, others: 5, bssid: "\(first):55:a8:e6:50:75"))
    }
    return sample
}

/// Puts the speed views into a preview state from `--speed-state testing|failed`.
func applyPreviewSpeedState(_ net: Net?) {
    guard let k = CommandLine.arguments.firstIndex(of: "--speed-state"), k + 1 < CommandLine.arguments.count else { return }
    switch CommandLine.arguments[k + 1] {
    case "testing":
        SpeedController.shared.preview(.testing(started: Date().addingTimeInterval(-12),
                                                reading: SpeedReading(down: 27.3, up: 18.9)), on: net)
    case "failed":
        SpeedController.shared.preview(.failed("no result. Check that you're connected to the internet."), on: net)
    default: break
    }
}

func writePNG(_ v: NSView, appearance: NSAppearance, to path: String) {
    v.layoutSubtreeIfNeeded()
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    appearance.performAsCurrentDrawingAppearance { v.cacheDisplay(in: v.bounds, to: rep) }
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func argument(after flag: String) -> String? {
    guard let k = CommandLine.arguments.firstIndex(of: flag), k + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[k + 1]
}

// `wifirank --render-window out.png [--dark] [--sort KEY] [--tab speed] [--history MODE] [--speed-state STATE]
// [--sample-history]` draws the main window off-screen. MODE is network or session.
if let path = argument(after: "--render-window") {
    runHeadless { all, error in
        let scan = CommandLine.arguments.contains("--sample-networks") ? previewNetworks() : all
        let nets = ranked(scan)
        let current = nets.first { $0.current }
        if CommandLine.arguments.contains("--sample-history") {
            SpeedHistory.shared.useForPreview(previewHistory(current: current?.ssid ?? "SCM DEPT AP 2"))
        }
        applyPreviewSpeedState(current)
        let w = NetworksWindow(onRescan: {}, currentNet: { current })
        let appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)!
        w.window.appearance = appearance
        w.window.setContentSize(NSSize(width: 760, height: 480))
        if let key = argument(after: "--sort") {
            w.table.sortDescriptors = [NSSortDescriptor(key: key, ascending: ["name", "band", "channel", "busy"].contains(key))]
        }
        w.groupBox.state = CommandLine.arguments.contains("--group") ? .on : .off
        w.update(nets: nets, error: error, scanning: false, updated: Date(), groups: routerGroups(scan))
        if argument(after: "--tab") == "speed" { w.select(.speed) }
        if argument(after: "--history") == "session" {
            w.speedTab.history.modeControl.selectedSegment = 1
            w.speedTab.history.reload()
            if let i = argument(after: "--session-index").flatMap(Int.init) {
                w.speedTab.history.picker.selectItem(at: i)
                w.speedTab.history.picked()
            }
        }
        w.speedTab.refresh()
        writePNG(w.window.contentView!, appearance: appearance, to: path)
    }
}

// `wifirank --render-speed-window out.png [--dark] [--speed-state STATE] [--sample-history]` draws the small window.
if let path = argument(after: "--render-speed-window") {
    runHeadless { all, _ in
        let current = ranked(all).first { $0.current }
        if CommandLine.arguments.contains("--sample-history") {
            SpeedHistory.shared.useForPreview(previewHistory(current: current?.ssid ?? "SCM DEPT AP 2"))
        }
        applyPreviewSpeedState(current)
        let w = SpeedWindow(currentNet: { current })
        let appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)!
        w.window.appearance = appearance
        w.panel.refresh()
        writePNG(w.window.contentView!, appearance: appearance, to: path)
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

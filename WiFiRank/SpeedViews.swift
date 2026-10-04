// The speed test UI: the dial panel (Speed tab and the small speed window share it)
// and the history chart.
import AppKit

/// Speedometer dial. The scale is stretched at the low end, like Ookla's, so everyday
/// speeds use most of the arc.
final class DialView: NSView {
    static let ticks: [Double] = [0, 5, 10, 25, 50, 100, 250, 500, 1000]

    var value: Double = 0 { didSet { needsDisplay = true } }
    var live = false { didSet { needsDisplay = true } }

    /// Where a speed sits along the arc, from 0 (left end) to 1 (right end).
    static func position(_ v: Double) -> CGFloat {
        guard v > 0 else { return 0 }
        for i in 1..<ticks.count where v <= ticks[i] {
            let f = (v - ticks[i - 1]) / (ticks[i] - ticks[i - 1])
            return CGFloat((Double(i - 1) + f) / Double(ticks.count - 1))
        }
        return 1
    }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: 16)
        let radius = min(bounds.width / 2 - 22, bounds.height - 28)
        func arc(to fraction: CGFloat) -> NSBezierPath {
            let p = NSBezierPath()
            p.appendArc(withCenter: center, radius: radius, startAngle: 180, endAngle: 180 - 180 * fraction, clockwise: true)
            p.lineWidth = 10
            p.lineCapStyle = .round
            return p
        }
        NSColor.quaternaryLabelColor.setStroke()
        arc(to: 1).stroke()
        if value > 0 {
            (live ? NSColor.controlAccentColor.withAlphaComponent(0.55) : NSColor.controlAccentColor).setStroke()
            arc(to: Self.position(value)).stroke()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]
        for t in Self.ticks {
            let a = (180 - 180 * Self.position(t)) * .pi / 180
            let label = NSAttributedString(string: t >= 1000 ? "1k" : String(Int(t)), attributes: attrs)
            let s = label.size()
            let p = NSPoint(x: center.x + (radius + 14) * cos(a), y: center.y + (radius + 14) * sin(a))
            label.draw(at: NSPoint(x: p.x - s.width / 2, y: p.y - s.height / 2))
        }
    }
}

private func label(_ size: CGFloat, _ weight: NSFont.Weight = .regular, secondary: Bool = true, digits: Bool = false) -> NSTextField {
    let l = NSTextField(labelWithString: "")
    l.font = digits ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    l.textColor = secondary ? .secondaryLabelColor : .labelColor
    l.alignment = .center
    l.lineBreakMode = .byTruncatingTail
    return l
}

private let dayAndTime: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    f.doesRelativeDateFormatting = true
    return f
}()

/// The dial, the numbers, and the Test button.
final class SpeedPanel: NSView {
    let networkLabel = label(12)
    let dial = DialView()
    let number = label(32, .semibold, secondary: false, digits: true)
    let caption = label(11.5)
    let details = label(12.5, secondary: false, digits: true)
    let quality = label(12)
    let statusLabel = label(11)
    let button = NSButton(title: "Test Speed", target: nil, action: nil)
    let currentNet: () -> Net?
    private var observer: NSObjectProtocol?

    init(currentNet: @escaping () -> Net?) {
        self.currentNet = currentNet
        super.init(frame: NSRect(x: 0, y: 0, width: 270, height: 380))
        quality.toolTip = "How much the delay grows when the connection is busy. High is best; it matters most for video calls and games."
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.target = self
        button.action = #selector(pressed)

        let stack = NSStackView(views: [networkLabel, dial, caption, details, quality, statusLabel, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(10, after: networkLabel)
        stack.setCustomSpacing(10, after: caption)
        stack.setCustomSpacing(12, after: statusLabel)
        for v in [stack, number] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -4),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
            networkLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            dial.widthAnchor.constraint(equalToConstant: 230),
            dial.heightAnchor.constraint(equalToConstant: 125),
            number.centerXAnchor.constraint(equalTo: dial.centerXAnchor),
            number.bottomAnchor.constraint(equalTo: dial.bottomAnchor, constant: -8),
        ])
        observer = NotificationCenter.default.addObserver(forName: .speedChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    @objc func pressed() {
        let c = SpeedController.shared
        if c.isTesting { c.cancel() } else { c.start(on: currentNet()) }
    }

    func refresh() {
        let c = SpeedController.shared
        let net = c.isTesting ? c.network : currentNet()
        networkLabel.stringValue = net.map { "Internet · \($0.ssid)" } ?? "Not connected to Wi-Fi"
        switch c.state {
        case .testing(let started, let reading):
            dial.live = true
            dial.value = reading?.down ?? 0
            number.stringValue = reading.map { formatMbps($0.down) } ?? "–"
            number.textColor = .secondaryLabelColor
            caption.stringValue = "Mbps down · live"
            details.stringValue = "Up \(reading.map { formatMbps($0.up) } ?? "–") Mbps"
            quality.stringValue = " "
            statusLabel.stringValue = "Testing… \(Int(Date().timeIntervalSince(started))) s"
            button.title = "Cancel"
            button.isEnabled = true
        case .idle, .failed:
            dial.live = false
            number.textColor = .labelColor
            caption.stringValue = "Mbps down"
            if let s = c.latest(for: net?.ssid) {
                dial.value = s.down
                number.stringValue = formatMbps(s.down)
                details.stringValue = "Up \(formatMbps(s.up)) Mbps  ·  \(Int(s.delay.rounded())) ms delay"
                let color: NSColor = ["High": .systemGreen, "Medium": .systemOrange, "Low": .systemRed][s.responsiveness]
                    ?? .secondaryLabelColor
                let q = NSMutableAttributedString(string: "Responsiveness: ", attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor, .font: quality.font!])
                q.append(NSAttributedString(string: s.responsiveness, attributes: [.foregroundColor: color, .font: quality.font!]))
                let centered = NSMutableParagraphStyle()
                centered.alignment = .center
                q.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: q.length))
                quality.attributedStringValue = q
                statusLabel.stringValue = "Tested \(dayAndTime.string(from: s.date))"
                button.title = "Test Again"
            } else {
                dial.value = 0
                number.stringValue = "–"
                number.textColor = .tertiaryLabelColor
                details.stringValue = " "
                quality.stringValue = " "
                statusLabel.stringValue = net == nil ? " " : "Not tested on this network yet"
                button.title = "Test Speed"
            }
            if case .failed(let why) = c.state { statusLabel.stringValue = "Speed test failed: \(why)" }
            button.isEnabled = net != nil
        }
        statusLabel.toolTip = statusLabel.stringValue
    }
}

/// Line chart of saved results: download and upload for one network, or download for a
/// session with each point coloured by network.
final class ChartView: NSView {
    enum Mode { case network, session }

    var samples: [SpeedSample] = [] { didSet { needsDisplay = true } }
    var mode: Mode = .network { didSet { needsDisplay = true } }
    var colors: [String: NSColor] = [:]

    static let down = NSColor.systemBlue
    static let up = NSColor.systemGreen

    /// A round top for the scale, comfortably above the highest value.
    static func niceMax(_ v: Double) -> Double {
        for n in [10.0, 25, 50, 100, 250, 500, 1000, 2500] where n >= v * 1.1 { return n }
        return (v * 1.2).rounded(.up)
    }

    override func draw(_ dirtyRect: NSRect) {
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        guard !samples.isEmpty else {
            let s = NSAttributedString(string: "No tests yet.\nResults appear here after each speed test.", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }()])
            let size = s.size()
            s.draw(in: NSRect(x: 0, y: bounds.midY - size.height / 2, width: bounds.width, height: size.height))
            return
        }
        let plot = NSRect(x: 34, y: 20, width: bounds.width - 42, height: bounds.height - 30)
        let sorted = samples.sorted { $0.date < $1.date }
        let values = mode == .network ? sorted.flatMap { [$0.down, $0.up] } : sorted.map(\.down)
        let top = Self.niceMax(values.max() ?? 10)

        for f in [0.0, 0.5, 1.0] {
            let y = plot.minY + plot.height * CGFloat(f)
            NSColor.separatorColor.setFill()
            NSRect(x: plot.minX, y: y, width: plot.width, height: 1).fill()
            let t = NSAttributedString(string: String(Int(top * f)), attributes: small)
            t.draw(at: NSPoint(x: plot.minX - 6 - t.size().width, y: y - t.size().height / 2))
        }

        let t0 = sorted.first!.date, t1 = sorted.last!.date
        let span = t1.timeIntervalSince(t0)
        func x(_ d: Date) -> CGFloat {
            span <= 0 ? plot.midX : plot.minX + plot.width * CGFloat(d.timeIntervalSince(t0) / span)
        }
        func y(_ v: Double) -> CGFloat { plot.minY + plot.height * CGFloat(min(v / top, 1)) }

        let f = DateFormatter()
        f.dateFormat = span < 20 * 3600 ? "h:mm a" : "d MMM"
        let start = NSAttributedString(string: f.string(from: t0), attributes: small)
        start.draw(at: NSPoint(x: plot.minX, y: 2))
        if span > 0 {
            let end = NSAttributedString(string: f.string(from: t1), attributes: small)
            end.draw(at: NSPoint(x: plot.maxX - end.size().width, y: 2))
        }

        func line(_ pts: [NSPoint], _ color: NSColor) {
            guard pts.count > 1 else { return }
            let p = NSBezierPath()
            p.move(to: pts[0])
            pts.dropFirst().forEach { p.line(to: $0) }
            p.lineWidth = 2
            p.lineJoinStyle = .round
            color.setStroke()
            p.stroke()
        }
        func dot(_ pt: NSPoint, _ color: NSColor) {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6)).fill()
        }

        let downPts = sorted.map { NSPoint(x: x($0.date), y: y($0.down)) }
        switch mode {
        case .network:
            let upPts = sorted.map { NSPoint(x: x($0.date), y: y($0.up)) }
            line(upPts, Self.up)
            line(downPts, Self.down)
            upPts.forEach { dot($0, Self.up) }
            downPts.forEach { dot($0, Self.down) }
        case .session:
            line(downPts, .tertiaryLabelColor)
            for (pt, s) in zip(downPts, sorted) { dot(pt, colors[s.ssid] ?? Self.down) }
        }
    }
}

/// The history side of the Speed tab: pick a network or a session, see its chart.
final class HistoryView: NSView {
    let modeControl = NSSegmentedControl(labels: ["By Network", "By Session"], trackingMode: .selectOne, target: nil, action: nil)
    let picker = NSPopUpButton()
    let legend = NSTextField(labelWithString: "")
    let chart = ChartView()
    let summary = NSTextField(wrappingLabelWithString: "")
    let currentSSID: () -> String?
    private var sessions: [[SpeedSample]] = []

    static let palette: [NSColor] = [.systemBlue, .systemOrange, .systemPurple, .systemTeal, .systemPink, .systemBrown]

    init(currentSSID: @escaping () -> String?) {
        self.currentSSID = currentSSID
        super.init(frame: .zero)
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.toolTip = "By Session shows tests that were less than 10 minutes apart, which may span several networks."
        picker.target = self
        picker.action = #selector(picked)
        legend.lineBreakMode = .byTruncatingTail
        legend.maximumNumberOfLines = 1
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        for v in [modeControl, picker, legend, chart, summary] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        legend.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            modeControl.topAnchor.constraint(equalTo: topAnchor),
            modeControl.leadingAnchor.constraint(equalTo: leadingAnchor),
            picker.centerYAnchor.constraint(equalTo: modeControl.centerYAnchor),
            picker.leadingAnchor.constraint(equalTo: modeControl.trailingAnchor, constant: 10),
            picker.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            picker.widthAnchor.constraint(lessThanOrEqualToConstant: 230),
            legend.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 12),
            legend.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            legend.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            chart.topAnchor.constraint(equalTo: legend.bottomAnchor, constant: 6),
            chart.leadingAnchor.constraint(equalTo: leadingAnchor),
            chart.trailingAnchor.constraint(equalTo: trailingAnchor),
            summary.topAnchor.constraint(equalTo: chart.bottomAnchor, constant: 8),
            summary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            summary.trailingAnchor.constraint(equalTo: trailingAnchor),
            summary.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    var byNetwork: Bool { modeControl.selectedSegment == 0 }

    @objc func modeChanged() { reload() }
    @objc func picked() { show() }

    /// Rebuilds the picker from the saved history, keeping the current choice where possible.
    func reload() {
        let history = SpeedHistory.shared
        let previous = picker.selectedItem?.representedObject as? String
        picker.removeAllItems()
        if byNetwork {
            for ssid in history.networks {
                picker.addItem(withTitle: ssid)
                picker.lastItem?.representedObject = ssid
            }
            let want = previous.flatMap { p in history.networks.contains(p) ? p : nil }
                ?? currentSSID().flatMap { c in history.networks.contains(c) ? c : nil }
            if let want, let i = picker.itemArray.firstIndex(where: { $0.representedObject as? String == want }) {
                picker.selectItem(at: i)
            }
        } else {
            sessions = history.sessions
            let time = DateFormatter()
            time.timeStyle = .short
            let day = DateFormatter()
            day.dateStyle = .medium
            day.doesRelativeDateFormatting = true
            for (i, s) in sessions.enumerated() {
                let networks = Set(s.map(\.ssid)).count
                var title = "\(day.string(from: s.first!.date)), \(time.string(from: s.first!.date))"
                if s.count > 1 { title += " – \(time.string(from: s.last!.date))" }
                title += networks > 1 ? "  ·  \(networks) networks" : "  ·  \(s.first!.ssid)"
                picker.addItem(withTitle: title)
                picker.lastItem?.representedObject = String(i)
            }
            if let p = previous.flatMap(Int.init), p < sessions.count { picker.selectItem(at: p) }
        }
        picker.isEnabled = picker.numberOfItems > 0
        if picker.numberOfItems == 0 { picker.addItem(withTitle: "No tests yet") }
        show()
    }

    private func show() {
        let dotted: (NSColor, String) -> NSAttributedString = { color, text in
            let s = NSMutableAttributedString(string: "●  ", attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 11)])
            s.append(NSAttributedString(string: text + "     ", attributes: [
                .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)]))
            return s
        }
        let history = SpeedHistory.shared
        let legendText = NSMutableAttributedString()
        var shown: [SpeedSample] = []
        if byNetwork {
            chart.mode = .network
            if let ssid = picker.selectedItem?.representedObject as? String { shown = history.samples(for: ssid) }
            legendText.append(dotted(ChartView.down, "Download"))
            legendText.append(dotted(ChartView.up, "Upload"))
        } else {
            chart.mode = .session
            if let i = (picker.selectedItem?.representedObject as? String).flatMap(Int.init), i < sessions.count {
                shown = sessions[i]
            }
            var colors: [String: NSColor] = [:]
            for s in shown where colors[s.ssid] == nil {
                colors[s.ssid] = Self.palette[colors.count % Self.palette.count]
                legendText.append(dotted(colors[s.ssid]!, s.ssid))
            }
            chart.colors = colors
        }
        if !shown.isEmpty && byNetwork {
            legendText.append(NSAttributedString(string: "Mbps", attributes: [
                .foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: 11)]))
        }
        legend.attributedStringValue = legendText
        legend.isHidden = shown.isEmpty
        chart.samples = shown

        if shown.isEmpty {
            summary.stringValue = " "
        } else {
            let n = shown.count
            let avgDown = shown.map(\.down).reduce(0, +) / Double(n)
            let avgUp = shown.map(\.up).reduce(0, +) / Double(n)
            let tests = n == 1 ? "1 test" : "\(n) tests"
            if byNetwork {
                summary.stringValue = "\(tests)  ·  average \(formatMbps(avgDown)) down, \(formatMbps(avgUp)) up  ·  "
                    + "best \(formatMbps(shown.map(\.down).max()!)) down"
            } else {
                let networks = Set(shown.map(\.ssid)).count
                summary.stringValue = "\(tests) on \(networks == 1 ? "1 network" : "\(networks) networks")  ·  "
                    + "average download \(formatMbps(avgDown)) Mbps. A session is tests less than 10 minutes apart."
            }
        }
    }
}

/// The Speed tab: dial panel on the left, history on the right.
final class SpeedTab: NSView {
    let panel: SpeedPanel
    let history: HistoryView
    private var observer: NSObjectProtocol?

    init(currentNet: @escaping () -> Net?) {
        panel = SpeedPanel(currentNet: currentNet)
        history = HistoryView(currentSSID: { currentNet()?.ssid })
        super.init(frame: .zero)
        let divider = NSBox()
        divider.boxType = .separator
        for v in [panel, divider, history] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.widthAnchor.constraint(equalToConstant: 270),
            divider.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            divider.leadingAnchor.constraint(equalTo: panel.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            history.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            history.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 18),
            history.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            history.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
        // A finished test adds a point to the chart.
        observer = NotificationCenter.default.addObserver(forName: .speedChanged, object: nil, queue: .main) { [weak self] _ in
            if case .idle = SpeedController.shared.state { self?.history.reload() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    func refresh() {
        panel.refresh()
        history.reload()
    }
}

/// The small "Internet Speed" window opened from the right-click menu.
final class SpeedWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let panel: SpeedPanel
    var onClose: () -> Void = {}

    init(currentNet: @escaping () -> Net?) {
        panel = SpeedPanel(currentNet: currentNet)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 360),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Internet Speed"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.collectionBehavior.insert(.fullScreenNone)
        if !window.setFrameUsingName("WiFiRankSpeed") { window.center() }
        window.setFrameAutosaveName("WiFiRankSpeed")
        let content = BackgroundView()
        window.contentView = content
        panel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: content.topAnchor),
            panel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}

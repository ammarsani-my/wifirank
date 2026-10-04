// Internet speed tests (macOS's networkQuality) and the history of their results.
import Foundation

/// One finished speed test, saved against the network it ran on.
struct SpeedSample: Codable, Equatable {
    let date: Date
    let ssid: String
    let band: String
    let snr: Int?
    let down: Double            // Mbps
    let up: Double              // Mbps
    let delay: Double           // ms, measured while the connection is idle
    let responsiveness: String  // "High", "Medium" or "Low", as macOS words it
}

struct SpeedReading {
    var down: Double
    var up: Double
}

/// "81.5" below 100 Mbps, "142" above.
func formatMbps(_ v: Double) -> String { String(format: v >= 100 ? "%.0f" : "%.1f", v) }

/// Runs `/usr/bin/networkQuality` on Wi-Fi. The tool only prints live readings when its output
/// is a terminal, so it runs inside a pseudo-terminal and its screen output is parsed.
final class SpeedTest {
    enum Outcome {
        case finished(down: Double, up: Double, delay: Double, responsiveness: String)
        case cancelled
        case failed(String)
    }

    private var process: Process?
    private var cancelled = false

    func start(onLive: @escaping (SpeedReading) -> Void, onDone: @escaping (Outcome) -> Void) {
        var master: Int32 = -1, slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            onDone(.failed("couldn't start the test."))
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
        p.arguments = ["-I", "en0", "-M", "20"]
        let tty = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        p.standardOutput = tty
        p.standardError = tty
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            close(master)
            close(slave)
            onDone(.failed("macOS's speed test tool wasn't found."))
            return
        }
        close(slave)
        process = p
        cancelled = false

        DispatchQueue.global().async { [weak self] in
            var text = "", pending = ""
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(master, &buf, buf.count)
                if n <= 0 { break }  // the terminal reports an error once the tool exits
                let chunk = String(decoding: buf[0..<n], as: UTF8.self)
                text += chunk
                pending += chunk
                // Live readings are rewritten in place, separated by carriage returns.
                let parts = pending.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
                pending = parts.last ?? ""
                for line in parts.dropLast() {
                    if let r = Self.live(line) { DispatchQueue.main.async { onLive(r) } }
                }
            }
            close(master)
            p.waitUntilExit()
            let outcome: Outcome = (self?.cancelled ?? false) ? .cancelled : Self.summary(text)
            DispatchQueue.main.async {
                self?.process = nil
                onDone(outcome)
            }
        }
    }

    func cancel() {
        cancelled = true
        process?.terminate()
    }

    static func strip(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    static func groups(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }

    static func mbps(_ value: String, _ unit: String) -> Double? {
        guard let v = Double(value) else { return nil }
        switch unit.lowercased() {
        case "gbps": return v * 1000
        case "kbps": return v / 1000
        default: return v
        }
    }

    /// Parses a live line: "Downlink: 27.284 Mbps, 327 RPM - Uplink: 61.659 Mbps, 327 RPM".
    static func live(_ raw: String) -> SpeedReading? {
        guard let g = groups(#"Downlink: ([\d.]+) (\w+),.*Uplink: ([\d.]+) (\w+)"#, strip(raw)),
              let down = mbps(g[0], g[1]), let up = mbps(g[2], g[3]) else { return nil }
        return SpeedReading(down: down, up: up)
    }

    /// Parses the block printed at the end:
    ///
    ///     Uplink capacity: 65.339 Mbps
    ///     Downlink capacity: 28.960 Mbps
    ///     Responsiveness: Medium (191.939 milliseconds | 312 RPM)
    ///     Idle Latency: 34.771 milliseconds | 1725 RPM
    static func summary(_ raw: String) -> Outcome {
        let s = strip(raw)
        guard let dn = groups(#"Downlink capacity: ([\d.]+) (\w+)"#, s),
              let up = groups(#"Uplink capacity: ([\d.]+) (\w+)"#, s),
              let down = mbps(dn[0], dn[1]), let upload = mbps(up[0], up[1]) else {
            return .failed("no result. Check that you're connected to the internet.")
        }
        let delay = groups(#"Idle Latency: ([\d.]+) milliseconds"#, s).flatMap { Double($0[0]) } ?? 0
        let responsiveness = groups(#"Responsiveness: (\w+)"#, s)?[0] ?? "Unknown"
        return .finished(down: down, up: upload, delay: delay, responsiveness: responsiveness)
    }
}

/// Every finished test, kept in ~/Library/Application Support/WiFi Rank/speed-history.json.
final class SpeedHistory {
    static let shared = SpeedHistory()
    /// Tests closer together than this belong to the same session.
    static let sessionGap: TimeInterval = 10 * 60

    private(set) var samples: [SpeedSample] = []
    private var persists = true
    private let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WiFi Rank/speed-history.json")

    init() {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: file), let s = try? d.decode([SpeedSample].self, from: data) { samples = s }
    }

    func add(_ s: SpeedSample) {
        samples = Array((samples + [s]).suffix(1000))
        save()
    }

    /// Off-screen previews show sample data and must never write it to disk.
    func useForPreview(_ s: [SpeedSample]) {
        persists = false
        samples = s
    }

    private func save() {
        guard persists else { return }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(samples) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Networks that have been tested, most recently tested first.
    var networks: [String] {
        var seen: [String] = []
        for s in samples.reversed() where !seen.contains(s.ssid) { seen.append(s.ssid) }
        return seen
    }

    func samples(for ssid: String) -> [SpeedSample] { samples.filter { $0.ssid == ssid } }

    /// Runs of tests with gaps shorter than `sessionGap`, newest session first.
    var sessions: [[SpeedSample]] {
        var out: [[SpeedSample]] = []
        for s in samples.sorted(by: { $0.date < $1.date }) {
            if let last = out.last?.last, s.date.timeIntervalSince(last.date) < Self.sessionGap {
                out[out.count - 1].append(s)
            } else {
                out.append([s])
            }
        }
        return out.reversed()
    }
}

extension Notification.Name {
    static let speedChanged = Notification.Name("WiFiRankSpeedChanged")
}

/// The one speed test that can run at a time, shared by the Speed tab and the small speed window.
final class SpeedController {
    static let shared = SpeedController()

    enum State {
        case idle
        case testing(started: Date, reading: SpeedReading?)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The network the running (or most recent) test is on.
    private(set) var network: Net?
    var onFinished: ((SpeedSample) -> Void)?

    private let test = SpeedTest()
    private var ticker: Timer?

    var isTesting: Bool {
        if case .testing = state { return true }
        return false
    }

    func start(on net: Net?) {
        guard !isTesting else { return }
        guard let net else {
            state = .failed("not connected to Wi-Fi.")
            post()
            return
        }
        network = net
        state = .testing(started: Date(), reading: nil)
        post()
        // Keeps "Testing… 12 s" counting, including while a menu is open.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.post() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        test.start(onLive: { [weak self] reading in
            guard let self, case .testing(let started, _) = self.state else { return }
            self.state = .testing(started: started, reading: reading)
            self.post()
        }, onDone: { [weak self] outcome in
            guard let self else { return }
            self.ticker?.invalidate()
            self.ticker = nil
            switch outcome {
            case .finished(let down, let up, let delay, let responsiveness):
                let s = SpeedSample(date: Date(), ssid: net.ssid, band: net.band, snr: net.snr, down: down, up: up,
                                    delay: delay, responsiveness: responsiveness)
                SpeedHistory.shared.add(s)
                self.state = .idle
                self.post()
                self.onFinished?(s)
            case .cancelled:
                self.state = .idle
                self.post()
            case .failed(let why):
                self.state = .failed(why)
                self.post()
            }
        })
    }

    func cancel() { test.cancel() }

    /// The newest saved result for a network.
    func latest(for ssid: String?) -> SpeedSample? {
        guard let ssid else { return nil }
        return SpeedHistory.shared.samples.last { $0.ssid == ssid }
    }

    /// Off-screen previews set a state directly.
    func preview(_ s: State, on net: Net?) {
        state = s
        network = net
    }

    private func post() { NotificationCenter.default.post(name: .speedChanged, object: nil) }
}

// macOS notifications: a finished speed test, and a clearly better known network nearby.
import Foundation
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    static let betterPrefix = "better-"
    /// How much higher a known network's SNR must be before it counts as clearly better.
    /// Compared on averages of recent scans, because SNR wobbles by about 6 on its own.
    static let snrMargin = 5
    static let averageOver = 3
    static let minSNR = 20
    static let repeatAfter: TimeInterval = 3600

    var onOpenSpeed: () -> Void = {}
    var onOpenNetworks: () -> Void = {}

    private let center = UNUserNotificationCenter.current()
    private var candidateLastScan: String?
    private var lastSuggested: [String: Date] = [:]
    /// Recent SNR readings per network, newest last.
    private var recent: [String: [Int]] = [:]

    var betterAlertsOn: Bool {
        get { UserDefaults.standard.object(forKey: "betterNetworkAlerts") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "betterNetworkAlerts") }
    }

    func setUp() { center.delegate = self }

    /// Asks for permission the first time; macOS remembers the answer after that.
    private func send(id: String, title: String, body: String) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            self.center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
        }
    }

    func speedFinished(_ s: SpeedSample, userIsWatching: Bool) {
        guard !userIsWatching else { return }
        send(id: "speed-\(Int(s.date.timeIntervalSince1970))", title: "Speed test finished",
             body: "\(s.ssid): \(formatMbps(s.down)) Mbps down · \(formatMbps(s.up)) up · \(Int(s.delay.rounded())) ms delay")
    }

    /// The known network that beats the current one by a clear margin, if any. `snr` gives the
    /// value to compare for each network (the app passes recent averages).
    static func clearlyBetter(_ nets: [Net], snr: (Net) -> Int? = { $0.snr }) -> Net? {
        guard let current = nets.first(where: { $0.current }), let currentSNR = snr(current) else { return nil }
        return nets
            .filter { $0.saved && !$0.current && (snr($0) ?? -999) >= max(currentSNR + snrMargin, minSNR) }
            .max { (snr($0) ?? -999) < (snr($1) ?? -999) }
    }

    private func remember(_ nets: [Net]) {
        for n in nets {
            guard let v = n.snr else { continue }
            recent[n.ssid] = Array(((recent[n.ssid] ?? []) + [v]).suffix(Self.averageOver))
        }
    }

    private func average(_ n: Net) -> Int? {
        guard let r = recent[n.ssid], !r.isEmpty else { return n.snr }
        return Int((Double(r.reduce(0, +)) / Double(r.count)).rounded())
    }

    /// Called after every scan. Suggests a known network only when it beats the current one
    /// clearly on two scans in a row, never while an earlier suggestion is still waiting in
    /// Notification Center, and not the same network again within `repeatAfter`.
    func scanned(_ nets: [Net]) {
        remember(nets)
        guard betterAlertsOn, let current = nets.first(where: { $0.current }), let currentSNR = average(current) else {
            candidateLastScan = nil
            return
        }
        guard let best = Self.clearlyBetter(nets, snr: average) else {
            candidateLastScan = nil
            return
        }
        let seenTwice = candidateLastScan == best.ssid
        candidateLastScan = best.ssid
        guard seenTwice else { return }
        if let t = lastSuggested[best.ssid], Date().timeIntervalSince(t) < Self.repeatAfter { return }
        center.getDeliveredNotifications { delivered in
            guard !delivered.contains(where: { $0.request.identifier.hasPrefix(Self.betterPrefix) }) else { return }
            DispatchQueue.main.async {
                self.lastSuggested[best.ssid] = Date()
                self.send(id: Self.betterPrefix + best.ssid, title: "A better network is nearby",
                          body: "\(best.ssid) is clearly stronger than \(current.ssid) "
                              + "(SNR \(self.average(best) ?? 0) vs \(currentSNR), averaged over recent scans). "
                              + "Switch from the Wi-Fi menu.")
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let better = response.notification.request.identifier.hasPrefix(Self.betterPrefix)
        DispatchQueue.main.async { better ? self.onOpenNetworks() : self.onOpenSpeed() }
        done()
    }
}

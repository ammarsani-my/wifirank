import AppKit
import CoreLocation
import CoreWLAN
import Foundation

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// Join mode: passwords the user types are kept in their login keychain under this service.
let keychainService = "local.ammarsani.wifirank"

func savedPassword(_ ssid: String) -> String? {
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: keychainService,
                            kSecAttrAccount as String: ssid,
                            kSecReturnData as String: true,
                            kSecMatchLimit as String: kSecMatchLimitOne]
    var out: AnyObject?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
    return String(data: d, encoding: .utf8)
}

func savePassword(_ ssid: String, _ password: String) {
    let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                               kSecAttrService as String: keychainService,
                               kSecAttrAccount as String: ssid]
    let data = Data(password.utf8)
    if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "WiFi Rank: \(ssid)"
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Exit codes: 0 joined, 1 failed, 3 needs a password, 4 the saved password failed.
/// A typed password arrives on stdin (`--password-stdin`) and is saved only after it works.
func join(_ ssid: String) -> Int32 {
    guard let iface = CWWiFiClient.shared().interface() else { err("No Wi-Fi interface."); return 1 }
    var typed: String? = nil
    if CommandLine.arguments.contains("--password-stdin") {
        let d = FileHandle.standardInput.readDataToEndOfFile()
        typed = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .newlines)
    }
    let nets: Set<CWNetwork>
    do { nets = try iface.scanForNetworks(withName: ssid) }
    catch { err("Scan failed: \(error.localizedDescription)"); return 1 }
    guard let target = nets.filter({ $0.ssid == ssid }).max(by: { $0.rssiValue < $1.rssiValue }) else {
        err("\u{201C}\(ssid)\u{201D} is out of range."); return 1
    }
    let open = target.supportsSecurity(.none)
    let saved = open ? nil : savedPassword(ssid)
    let password = open ? nil : (typed ?? saved)
    if !open && password == nil { return 3 }
    do { try iface.associate(to: target, password: password) }
    catch {
        err(error.localizedDescription)
        return typed == nil && saved != nil ? 4 : 1
    }
    if let typed { savePassword(ssid, typed) }
    return 0
}

final class Delegate: NSObject, NSApplicationDelegate, CLLocationManagerDelegate {
    let mgr = CLLocationManager()
    var started = false

    func applicationDidFinishLaunching(_ note: Notification) {
        mgr.delegate = self
        if mgr.authorizationStatus == .notDetermined {
            err("Requesting location access — click Allow in the dialog.")
            mgr.requestWhenInUseAuthorization()
        } else {
            proceed()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            err("Timed out waiting for location authorization.")
            exit(2)
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus != .notDetermined { proceed() }
    }

    func proceed() {
        guard !started else { return }
        started = true
        if let i = CommandLine.arguments.firstIndex(of: "--join"), i + 1 < CommandLine.arguments.count {
            let ssid = CommandLine.arguments[i + 1]
            DispatchQueue.global().async { exit(join(ssid)) }
            return
        }
        DispatchQueue.global().async {
            let json = self.scan()
            FileHandle.standardOutput.write(json.data(using: .utf8)!)
            exit(0)
        }
    }

    func band(_ n: CWNetwork) -> String {
        switch n.wlanChannel?.channelBand {
        case .band2GHz: return "2.4G"
        case .band5GHz: return "5G"
        case .band6GHz: return "6G"
        default: return "?"
        }
    }

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

    func scan() -> String {
        guard let iface = CWWiFiClient.shared().interface() else {
            err("No Wi-Fi interface."); return "[]"
        }
        let nets: Set<CWNetwork>
        do { nets = try iface.scanForNetworks(withSSID: nil) }
        catch { err("Scan failed: \(error.localizedDescription)"); return "[]" }
        let current = iface.ssid()
        let rows: [[String: Any]] = nets.map { n in
            [
                "ssid": n.ssid ?? "(hidden)",
                "bssid": n.bssid ?? "",
                "rssi": n.rssiValue,
                "noise": n.noiseMeasurement,
                "channel": n.wlanChannel?.channelNumber ?? 0,
                "band": band(n),
                "security": security(n),
                "current": (n.ssid != nil && n.ssid == current),
            ]
        }
        guard let d = try? JSONSerialization.data(withJSONObject: rows) else { return "[]" }
        return String(data: d, encoding: .utf8) ?? "[]"
    }
}

let app = NSApplication.shared
let del = Delegate()
app.delegate = del
app.setActivationPolicy(.accessory)
app.run()

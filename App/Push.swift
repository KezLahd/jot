#if os(macOS)
import AppKit
import CryptoKit
import Foundation
import JotCore
import Security
import UniformTypeIdentifiers

/// Pushes to your iPhone when the Mac finishes something (APNs, straight from this Mac; no server).
/// The phone leaves its push token in the library's Devices/ folder. The APNs key (.p8) lives in the
/// login keychain (service com.kezlahd.jot.apns, account = Key ID). Set up from the menu-bar window.
enum PhonePush {
    static let team = "8QPPD49JQ5"
    static let topic = "com.kezlahd.jot"
    private static let service = "com.kezlahd.jot.apns"

    static var keyID: String? {
        get { UserDefaults.standard.string(forKey: "apnsKeyID").flatMap { $0.isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue, forKey: "apnsKeyID") }
    }
    static var configured: Bool { keyID != nil }

    // MARK: Setup

    /// Asks for the AuthKey_<KEYID>.p8 file and keeps it in the keychain. Returns a line for the menu.
    @MainActor
    static func chooseKey() -> String? {
        let panel = NSOpenPanel()
        panel.message = "Choose your APNs key: AuthKey_XXXXXXXXXX.p8, from developer.apple.com › Keys (Apple Push Notifications service)."
        panel.allowedContentTypes = [UTType(filenameExtension: "p8") ?? .data]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("AuthKey_"), case let id = String(name.dropFirst(8)), id.count == 10 else {
            return "That isn't an AuthKey_XXXXXXXXXX.p8 file."
        }
        guard let pem = try? String(contentsOf: url, encoding: .utf8), (try? P256.Signing.PrivateKey(pemRepresentation: pem)) != nil else {
            return "Couldn't read a key from that file."
        }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(pem.utf8)
        add[kSecAttrLabel as String] = "Jot — APNs key"
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return "Couldn't save the key to the keychain." }
        keyID = id
        jwt = nil
        return nil
    }

    static func turnOff() {
        if let keyID {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: keyID] as CFDictionary)
        }
        keyID = nil
        jwt = nil
    }

    // MARK: Sending

    private struct Device: Decodable { var token: String; var sandbox: Bool; var name: String }

    /// Sends to every phone in Devices/. Returns how many took it.
    @discardableResult
    static func send(_ title: String, _ body: String, readID: String? = nil, library: Library) async -> Int {
        guard configured, let token = token() else { return 0 }
        let folder = library.root.appending(path: "Devices", directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var aps: [String: Any] = ["alert": ["title": title, "body": body], "sound": "default", "thread-id": "jot"]
        aps["interruption-level"] = "active"
        var payload: [String: Any] = ["aps": aps]
        if let readID { payload["read"] = readID }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return 0 }
        var sent = 0
        for file in files where file.pathExtension == "json" {
            guard let d = try? Data(contentsOf: file), let device = try? JSONDecoder().decode(Device.self, from: d) else { continue }
            switch await post(data, to: device.token, sandbox: device.sandbox, jwt: token) {
            case 200: sent += 1
            case 400:  // BadDeviceToken: the other APNs (a build signed the other way)
                if await post(data, to: device.token, sandbox: !device.sandbox, jwt: token) == 200 { sent += 1 }
            case 410: try? FileManager.default.removeItem(at: file)  // the app was deleted
            default: break
            }
        }
        return sent
    }

    private static func post(_ body: Data, to device: String, sandbox: Bool, jwt: String) async -> Int {
        let host = sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com"
        var req = URLRequest(url: URL(string: "https://\(host)/3/device/\(device)")!)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        req.setValue(topic, forHTTPHeaderField: "apns-topic")
        req.setValue("alert", forHTTPHeaderField: "apns-push-type")
        req.setValue("10", forHTTPHeaderField: "apns-priority")
        req.timeoutInterval = 20
        let response = try? await URLSession.shared.data(for: req).1
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// The provider token (ES256 over Team and Key ID). APNs wants it remade at most every hour, at least every 20 min apart.
    nonisolated(unsafe) private static var jwt: (value: String, made: Date)?

    private static func token() -> String? {
        if let jwt, Date.now.timeIntervalSince(jwt.made) < 45 * 60 { return jwt.value }
        guard let keyID else { return nil }
        var out: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: keyID, kSecReturnData as String: true]
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let key = try? P256.Signing.PrivateKey(pemRepresentation: String(decoding: data, as: UTF8.self)) else { return nil }
        func b64(_ d: Data) -> String {
            d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let head = b64(Data(#"{"alg":"ES256","kid":"\#(keyID)"}"#.utf8))
        let claims = b64(Data(#"{"iss":"\#(team)","iat":\#(Int(Date.now.timeIntervalSince1970))}"#.utf8))
        guard let sig = try? key.signature(for: Data("\(head).\(claims)".utf8)) else { return nil }
        let value = "\(head).\(claims).\(b64(sig.rawRepresentation))"
        jwt = (value, .now)
        return value
    }
}
#endif

import Foundation
import Security

/// What the share extension and the app share for cloud runs: the GitHub token (Keychain, App Group access
/// group), the repo, and this phone's push token (App Group defaults). Dependency-free, so the extension stays small.
public enum CloudShared {
    private static let service = "com.kezlahd.jot.cloud"
    public static let defaultRepo = "KezLahd/jot-fetcher"
    private static var defaults: UserDefaults { UserDefaults(suiteName: Inbox.appGroup) ?? .standard }

    public static var repo: String {
        get { defaults.string(forKey: "cloudRepo") ?? defaultRepo }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "cloudRepo") }
    }

    /// APNs token and environment, so the runner can tell this phone when it's done.
    public static var pushDevice: (token: String, sandbox: Bool)? {
        get { defaults.string(forKey: "pushToken").map { ($0, defaults.bool(forKey: "pushSandbox")) } }
        set {
            defaults.set(newValue?.token, forKey: "pushToken")
            defaults.set(newValue?.sandbox ?? false, forKey: "pushSandbox")
        }
    }

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccessGroup as String: Inbox.appGroup, kSecUseDataProtectionKeychain as String: true]
    }

    public static var token: String? {
        get {
            var q = base
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            SecItemDelete(base as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(newValue.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// Starts the jot-fetcher workflow. Used by the share extension (so a shared reel starts at once, even while
/// Jot is closed) and by the app.
public enum CloudDispatch {
    public enum Failure: Error { case refused(Int), noRun, network(Error) }

    /// Returns the run id. `transcribe` asks the runner to transcribe as well as fetch; `device` gets a push when done.
    public static func start(repo: String, token: String, link: String, runName: String, transcribe: Bool,
                             device: (token: String, sandbox: Bool)?, model: String? = nil, timeout: TimeInterval = 20) async throws -> Int {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/actions/workflows/fetch.yml/dispatches")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        var inputs = ["url": link, "id": runName, "transcribe": transcribe ? "true" : "false"]
        if let device { inputs["device"] = device.token; inputs["sandbox"] = device.sandbox ? "true" : "false" }
        if let model { inputs["model"] = model }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["ref": "main", "return_run_details": true, "inputs": inputs])
        // GitHub now and then answers a good token with a passing 404 or 5xx; nothing was started, so try again.
        var data = Data(), code = 0
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1.5 * Double(attempt))) }
            let response: URLResponse
            do { (data, response) = try await URLSession.shared.data(for: req) } catch { throw Failure.network(error) }
            code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code != 404, code < 500 { break }
        }
        guard (200..<300).contains(code) else { throw Failure.refused(code) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = json["workflow_run_id"] as? Int else {
            throw Failure.noRun
        }
        return id
    }
}

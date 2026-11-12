import Foundation
import JotCore
import JotInbox
import Security

/// The GitHub token for cloud fetch lives in the Keychain, never in source or defaults.
/// The repo name isn't secret and sits in UserDefaults.
enum CloudSettings {
    private static let service = "com.kezlahd.jot.cloud"
    static let defaultRepo = "KezLahd/jot-fetcher"

    static var repo: String {
        get { CloudShared.repo }
        set { CloudShared.repo = newValue }
    }

    /// Shared with the share extension (App Group keychain), so a shared link starts its cloud run at once.
    static var token: String? {
        get {
            if let t = CloudShared.token { return t }
            guard let old = legacyToken else { return nil }  // saved before the extension could see it: move it
            CloudShared.token = old
            if CloudShared.token != nil { legacyToken = nil }
            return old
        }
        set { CloudShared.token = newValue; legacyToken = nil }
    }

    /// The app's own access group, so these queries never touch the shared item.
    private static let legacyBase: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                                    kSecAttrAccessGroup as String: "8QPPD49JQ5.com.kezlahd.jot"]

    private static var legacyToken: String? {
        get {
            var item: CFTypeRef?
            var q = legacyBase
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            SecItemDelete(legacyBase as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var add = legacyBase
            add[kSecValueData as String] = Data(newValue.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static var fetcher: CloudFetcher? {
        guard let token, !token.isEmpty, repo.contains("/") else { return nil }
        return CloudFetcher(repo: repo, token: token)
    }
}

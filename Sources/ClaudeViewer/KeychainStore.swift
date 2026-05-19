import Foundation
import Security

/// File-based secret storage under ~/Library/Application Support/ClaudeViewer/.
///
/// We used to put the session key in the macOS Keychain, but that bound the
/// entry to the binary's code signature — every ad-hoc rebuild produced a
/// different CDHash, so macOS would prompt the user to re-authorize on each
/// launch. A 0600 file in the user's Application Support directory has the
/// same effective protection (only this user can read it) without the
/// per-rebuild friction.
enum SecretStore {
    private static let storeDir: String = {
        let base = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/ClaudeViewer")
        try? FileManager.default.createDirectory(
            atPath: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return base
    }()

    private static var storePath: String {
        (storeDir as NSString).appendingPathComponent("session-key")
    }

    static func save(_ key: String) throws {
        let data = Data(key.utf8)
        let url = URL(fileURLWithPath: storePath)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storePath
        )
    }

    static func load() -> String? {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: storePath)),
           let s = String(data: data, encoding: .utf8),
           !s.isEmpty {
            return s
        }
        // One-time migration from the previous Keychain-based store.
        if let legacy = loadLegacyKeychain() {
            try? save(legacy)
            deleteLegacyKeychain()
            return legacy
        }
        return nil
    }

    static func delete() {
        try? FileManager.default.removeItem(atPath: storePath)
        deleteLegacyKeychain()
    }

    // MARK: legacy keychain (only used for migration)

    private static let legacyService = "com.claudeviewer.session-key"
    private static let legacyAccount = "default"

    private static func loadLegacyKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: legacyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteLegacyKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: legacyAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Back-compat name; existing callers can keep `KeychainStore.x()`.
typealias KeychainStore = SecretStore

enum AppPreferences {
    private static let orgKey = "claudeOrgId"
    private static let lastBrowserKey = "claudeImportBrowser"

    static var orgId: String? {
        get { UserDefaults.standard.string(forKey: orgKey) }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: orgKey) }
            else { UserDefaults.standard.removeObject(forKey: orgKey) }
        }
    }

    /// Display name of the last browser used to import the session key, so
    /// "Reconnect" can offer a one-click redo without making the user
    /// re-pick the browser.
    static var lastImportBrowser: String? {
        get { UserDefaults.standard.string(forKey: lastBrowserKey) }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: lastBrowserKey) }
            else { UserDefaults.standard.removeObject(forKey: lastBrowserKey) }
        }
    }
}

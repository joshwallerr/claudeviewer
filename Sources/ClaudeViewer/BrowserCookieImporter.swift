import Foundation
import SQLite3
import CommonCrypto
import Security

enum BrowserCookieError: LocalizedError {
    case browserNotInstalled(String)
    case keychainAccessDenied
    case cookieDbMissing
    case cookieDbReadFailed(String)
    case sessionKeyNotFound
    case decryptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .browserNotInstalled(let name):
            return "\(name) cookies not found on this machine"
        case .keychainAccessDenied:
            return "Keychain access denied — you need to click Allow when macOS prompts"
        case .cookieDbMissing:
            return "Browser cookies database not found"
        case .cookieDbReadFailed(let s):
            return "Couldn't read cookies database: \(s)"
        case .sessionKeyNotFound:
            return "No claude.ai session in this browser — sign in there first, then retry"
        case .decryptionFailed(let s):
            return "Decryption failed: \(s)"
        }
    }
}

struct Browser {
    let displayName: String
    let cookiesPath: String
    let keychainService: String
    let keychainAccount: String

    static let brave = Browser(
        displayName: "Brave",
        cookiesPath: "~/Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies",
        keychainService: "Brave Safe Storage",
        keychainAccount: "Brave"
    )

    static let chrome = Browser(
        displayName: "Chrome",
        cookiesPath: "~/Library/Application Support/Google/Chrome/Default/Cookies",
        keychainService: "Chrome Safe Storage",
        keychainAccount: "Chrome"
    )

    static let arc = Browser(
        displayName: "Arc",
        cookiesPath: "~/Library/Application Support/Arc/User Data/Default/Cookies",
        keychainService: "Arc Safe Storage",
        keychainAccount: "Arc"
    )

    static let edge = Browser(
        displayName: "Microsoft Edge",
        cookiesPath: "~/Library/Application Support/Microsoft Edge/Default/Cookies",
        keychainService: "Microsoft Edge Safe Storage",
        keychainAccount: "Microsoft Edge"
    )

    var expandedCookiesPath: String {
        (cookiesPath as NSString).expandingTildeInPath
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: expandedCookiesPath)
    }
}

struct BrowserCookieImporter {
    let browser: Browser

    /// Reads the `sessionKey` cookie value for claude.ai out of the browser's
    /// encrypted cookies DB. Triggers a one-time macOS keychain prompt.
    func importSessionKey() throws -> String {
        guard browser.isInstalled else {
            throw BrowserCookieError.browserNotInstalled(browser.displayName)
        }
        let password = try readSafeStoragePassword()
        let key = deriveAESKey(from: password)
        let blob = try readEncryptedCookieBlob()
        return try decrypt(blob: blob, key: key)
    }

    private func readSafeStoragePassword() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: browser.keychainService,
            kSecAttrAccount as String: browser.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw BrowserCookieError.keychainAccessDenied }
            return data
        case errSecItemNotFound:
            throw BrowserCookieError.browserNotInstalled(browser.displayName)
        default:
            throw BrowserCookieError.keychainAccessDenied
        }
    }

    private func deriveAESKey(from password: Data) -> Data {
        // Chromium uses PBKDF2-HMAC-SHA1 with salt "saltysalt", 1003 iterations, 16-byte key.
        let salt = Data("saltysalt".utf8)
        var derived = Data(count: 16)
        let result = derived.withUnsafeMutableBytes { derivedPtr -> Int32 in
            password.withUnsafeBytes { passwordPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr.bindMemory(to: Int8.self).baseAddress, password.count,
                        saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        derivedPtr.bindMemory(to: UInt8.self).baseAddress, 16
                    )
                }
            }
        }
        precondition(result == kCCSuccess, "PBKDF2 failed")
        return derived
    }

    private func readEncryptedCookieBlob() throws -> Data {
        let src = browser.expandedCookiesPath
        // Copy to tmp to avoid contending with the live browser for the lock.
        let tmp = NSTemporaryDirectory() + "claudeviewer-cookies-\(UUID().uuidString).sqlite"
        defer {
            try? FileManager.default.removeItem(atPath: tmp)
            try? FileManager.default.removeItem(atPath: tmp + "-wal")
            try? FileManager.default.removeItem(atPath: tmp + "-shm")
            try? FileManager.default.removeItem(atPath: tmp + "-journal")
        }
        do {
            try FileManager.default.copyItem(atPath: src, toPath: tmp)
            for suffix in ["-wal", "-shm", "-journal"] {
                let from = src + suffix
                if FileManager.default.fileExists(atPath: from) {
                    try? FileManager.default.copyItem(atPath: from, toPath: tmp + suffix)
                }
            }
        } catch {
            throw BrowserCookieError.cookieDbReadFailed(error.localizedDescription)
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw BrowserCookieError.cookieDbReadFailed("sqlite3_open_v2 failed")
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT encrypted_value
            FROM cookies
            WHERE (host_key = 'claude.ai' OR host_key = '.claude.ai')
              AND name = 'sessionKey'
            ORDER BY expires_utc DESC
            LIMIT 1
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            throw BrowserCookieError.cookieDbReadFailed("prepare failed")
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw BrowserCookieError.sessionKeyNotFound
        }
        let bytes = sqlite3_column_bytes(stmt, 0)
        guard bytes > 0, let ptr = sqlite3_column_blob(stmt, 0) else {
            throw BrowserCookieError.sessionKeyNotFound
        }
        return Data(bytes: ptr, count: Int(bytes))
    }

    private func decrypt(blob: Data, key: Data) throws -> String {
        guard blob.count > 3 else {
            throw BrowserCookieError.decryptionFailed("blob too short (\(blob.count) bytes)")
        }
        // Chromium prefixes "v10" or "v11" then the ciphertext.
        let prefix = String(data: blob.prefix(3), encoding: .utf8)
        guard prefix == "v10" || prefix == "v11" else {
            throw BrowserCookieError.decryptionFailed("unknown ciphertext version \(prefix ?? "?")")
        }
        let ciphertext = Data(blob.dropFirst(3))
        let iv = Data(repeating: 0x20, count: 16)

        var out = Data(count: ciphertext.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var outMoved: size_t = 0
        let status = out.withUnsafeMutableBytes { outBuf -> Int32 in
            ciphertext.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, key.count,
                            ivBuf.baseAddress,
                            inBuf.baseAddress, ciphertext.count,
                            outBuf.baseAddress, outCapacity,
                            &outMoved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw BrowserCookieError.decryptionFailed("CCCrypt returned \(status)")
        }
        out = out.prefix(outMoved)

        // Modern Chromium (M118+ on some platforms) prepends a 32-byte SHA256
        // host hash to the plaintext to bind the cookie to its origin. If the
        // plaintext doesn't decode as ASCII, try stripping that prefix.
        if let s = ascii(out) { return s }
        if out.count > 32, let s = ascii(out.dropFirst(32)) { return s }
        throw BrowserCookieError.decryptionFailed("plaintext was not valid ASCII text")
    }

    private func ascii<T: DataProtocol>(_ data: T) -> String? {
        let bytes = Array(data)
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }
}

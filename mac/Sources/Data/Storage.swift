import Foundation
import Security

/// The app's own small state (accounts and notebook list), kept as one JSON file.
final class StateStore {
    private let file: URL
    private(set) var state: AppState

    init(file: URL) {
        self.file = file
        state = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(AppState.self, from: $0) } ?? AppState()
    }

    func update(_ transform: (inout AppState) -> Void) {
        var next = state
        transform(&next)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(next) { try? data.write(to: file, options: .atomic) }
        state = next
    }
}

/// Access tokens in the login Keychain, readable only by this app on this Mac.
/// Reading may show a Keychain prompt (e.g. after an update), so never call it on the main thread.
enum TokenVault {
    private static let service = "io.github.leonmason.jitnote"

    #if GN_DEBUG_HOOKS
    // Test builds keep tokens in a file next to their state, so automated runs never touch the real Keychain.
    private static var testFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jitnote/test-tokens.json")
    }

    private static var testTokens: [String: String] {
        get { (try? Data(contentsOf: testFile)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:] }
        set { try? JSONEncoder().encode(newValue).write(to: testFile) }
    }

    static func save(_ token: String, account: String) throws { testTokens[account] = token }
    static func load(account: String) throws -> String? { testTokens[account] }
    static func delete(account: String) { testTokens[account] = nil }
    #else

    static func save(_ token: String, account: String) throws {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(token.utf8),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw SyncError(.other, "无法把令牌保存到钥匙串（\(status)）") }
    }

    /// The token, or nil when none was saved. Throws when the Keychain refuses to hand it out.
    static func load(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        // E.g. the app was replaced while running, or the person clicked "Deny" in the Keychain prompt.
        guard status == errSecSuccess, let data = result as? Data else {
            throw SyncError(.auth, "钥匙串没有允许读取这个账号的令牌（错误码 \(status)）。请退出后重新打开 App 再试，系统询问时输入电脑密码并选「始终允许」；还不行的话，到「云端账号」里重新连接。")
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
    #endif
}

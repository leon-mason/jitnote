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
    private static let service = "io.github.leonmason.gitnotebook"

    #if GN_DEBUG_HOOKS
    // Test builds keep tokens in a file next to their state, so automated runs never touch the real Keychain.
    private static var testFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitNotebook/test-tokens.json")
    }

    private static var testTokens: [String: String] {
        get { (try? Data(contentsOf: testFile)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:] }
        set { try? JSONEncoder().encode(newValue).write(to: testFile) }
    }

    static func save(_ token: String, account: String) throws { testTokens[account] = token }
    static func load(account: String) -> String? { testTokens[account] }
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

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
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

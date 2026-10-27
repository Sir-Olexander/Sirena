import Foundation
import Security

/// Loads the Meta Model API key from the environment (MODEL_API_KEY or SIRENA_API_KEY) or the macOS Keychain.
/// The app (not the CLI) copies a key found in the environment into the Keychain so later launches from Finder work too.
public enum APIKeyStore {
    static let service = "ai.sirena.app"
    static let account = "MODEL_API_KEY"

    public static func environmentKey() -> String? {
        let env = ProcessInfo.processInfo.environment
        for name in ["MODEL_API_KEY", "SIRENA_API_KEY"] {
            if let key = env[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty { return key }
        }
        return nil
    }

    /// Environment first (no Keychain access at all in that case, so command-line tools never trigger a Keychain prompt).
    public static func load() -> String? {
        if let key = environmentKey() { return key }
        return readKeychain()
    }

    /// Called by the app at launch: persist a key that came from the environment.
    public static func persistEnvironmentKeyIfNeeded() {
        guard let key = environmentKey() else { return }
        if readKeychain() != key { save(key) }
    }

    @discardableResult
    public static func save(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Sirena – Meta Model API key"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }
}

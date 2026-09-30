import Foundation
import Security

/// Quick AI API Key 保存在登录钥匙串的通用密码项中，不落入 UserDefaults 明文。
@MainActor
final class KeychainQuickAIKeyStore: QuickAIKeyStoring {
    private let service: String
    private let account = "quickAI.apiKey"

    init(service: String = (Bundle.main.bundleIdentifier ?? "OI") + ".quickAI") {
        self.service = service
    }

    func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ apiKey: String?) {
        SecItemDelete(baseQuery as CFDictionary)
        let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

import Foundation
import Security

/// Quick AI API Key 保存在登录钥匙串的通用密码项中，不落入 UserDefaults 明文。
/// 读到的值缓存在内存里：本地签名的构建每次重新编译后访问钥匙串都可能弹授权框，
/// 缓存后每次运行最多读取一次，不会在每次提问时都访问钥匙串。
@MainActor
final class KeychainQuickAIKeyStore: QuickAIKeyStoring {
    private let service: String
    private let account = "quickAI.apiKey"
    private var hasCachedKey = false
    private var cachedKey: String?

    init(service: String = (Bundle.main.bundleIdentifier ?? "OI") + ".quickAI") {
        self.service = service
    }

    func load() -> String? {
        if hasCachedKey { return cachedKey }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // 只缓存确定的结果；用户拒绝授权等失败不缓存，下次读取时再试。
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            cache(String(data: data, encoding: .utf8))
        case errSecItemNotFound:
            cache(nil)
        default:
            return nil
        }
        return cachedKey
    }

    func save(_ apiKey: String?) {
        let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            updateCache(succeeded: status == errSecSuccess || status == errSecItemNotFound, with: nil)
            return
        }
        // 先原地更新、不存在再新增：不经过"先删后写"，写入失败也不会丢掉原有密钥。
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = baseQuery
            attributes[kSecValueData as String] = data
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        updateCache(succeeded: status == errSecSuccess, with: trimmed)
    }

    private func cache(_ key: String?) {
        cachedKey = key
        hasCachedKey = true
    }

    /// 写入成功即以新值为准；失败时丢弃缓存，下次读取以钥匙串实际内容为准。
    private func updateCache(succeeded: Bool, with key: String?) {
        if succeeded {
            cache(key)
        } else {
            hasCachedKey = false
            cachedKey = nil
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

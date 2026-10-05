import Foundation
import Security

/// Quick AI 与划词翻译的 API Key 分别保存在登录钥匙串的通用密码项中（同一 service、不同 account），
/// 不落入 UserDefaults 明文。
/// 读到的值缓存在内存里：本地签名的构建每次重新编译后访问钥匙串都可能弹授权框，
/// 缓存后每次运行最多读取一次，不会在每次提问时都访问钥匙串。
@MainActor
final class KeychainQuickAIKeyStore: QuickAIKeyStoring {
    nonisolated static let quickAIAccount = "quickAI.apiKey"
    nonisolated static let translatorAccount = "translator.apiKey"

    private let service: String
    private let account: String
    /// 本账户还没有条目时从此账户复制初始值：旧版本的划词翻译与 Quick AI 共用密钥。
    private let initialValueAccount: String?
    private var hasCachedKey = false
    private var cachedKey: String?

    init(
        service: String = (Bundle.main.bundleIdentifier ?? "OI") + ".quickAI",
        account: String = KeychainQuickAIKeyStore.quickAIAccount,
        initialValueAccount: String? = nil
    ) {
        self.service = service
        self.account = account
        self.initialValueAccount = initialValueAccount
    }

    func load() -> String? {
        if hasCachedKey { return cachedKey }
        // 只缓存确定的结果；用户拒绝授权等失败不缓存，下次读取时再试。
        switch read(account) {
        case .found(let key):
            cache(key)
        case .notFound:
            if let initialValueAccount {
                return copyInitialValue(from: initialValueAccount)
            }
            cache(nil)
        case .failed:
            return nil
        }
        return cachedKey
    }

    func save(_ apiKey: String?) {
        let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed?.isEmpty == false ? trimmed : nil
        // 有初始值来源的账户清空时写入空值占位而不删除条目：没有条目表示从未保存过，
        // 下次读取会重新复制来源的密钥。
        guard key != nil || initialValueAccount != nil else {
            let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
            updateCache(succeeded: status == errSecSuccess || status == errSecItemNotFound, with: nil)
            return
        }
        updateCache(succeeded: write(key), with: key)
    }

    /// 本账户从未保存过：复制来源账户的密钥写入本账户，此后两者互不影响。
    /// 来源也没有密钥时写入空值占位，避免日后来源新填的密钥被复制过来。
    private func copyInitialValue(from sourceAccount: String) -> String? {
        let initialValue: String?
        switch read(sourceAccount) {
        case .found(let key):
            initialValue = key
        case .notFound:
            initialValue = nil
        case .failed:
            return nil
        }
        updateCache(succeeded: write(initialValue), with: initialValue)
        return initialValue
    }

    private enum ReadResult {
        case found(String?)
        case notFound
        case failed
    }

    private static let emptyPlaceholder = "\0"

    /// 空值（清空后的占位）按没有密钥处理。
    private func read(_ account: String) -> ReadResult {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data else { return .failed }
            let key = String(data: data, encoding: .utf8)
            let validKey = (key == Self.emptyPlaceholder || key?.isEmpty == true) ? nil : key
            return .found(validKey)
        case errSecItemNotFound:
            return .notFound
        default:
            return .failed
        }
    }

    /// 先原地更新、不存在再新增：不经过"先删后写"，写入失败也不会丢掉原有密钥。nil 写入占位符（避免 0 字节 Data 被 SecItemUpdate 忽略）。
    private func write(_ key: String?) -> Bool {
        let text = key?.isEmpty == false ? key! : Self.emptyPlaceholder
        let data = Data(text.utf8)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery(for: account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = baseQuery(for: account)
            attributes[kSecValueData as String] = data
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        return status == errSecSuccess
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

    private func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

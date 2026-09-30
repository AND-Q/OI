import Foundation

/// Quick AI API Key 的持久化端口。密钥与普通设置分开存放，避免明文落入 UserDefaults。
@MainActor
protocol QuickAIKeyStoring: AnyObject {
    func load() -> String?
    /// 传入 nil 或空串即删除已保存的密钥。
    func save(_ apiKey: String?)
}

/// 用作默认实现和测试用的内存存储；不做任何持久化。
@MainActor
final class MemoryQuickAIKeyStore: QuickAIKeyStoring {
    private var storedKey: String?

    init(initial: String? = nil) {
        storedKey = initial
    }

    func load() -> String? {
        storedKey
    }

    func save(_ apiKey: String?) {
        let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        storedKey = (trimmed?.isEmpty == false) ? trimmed : nil
    }
}

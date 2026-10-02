import Foundation

/// 查询与所有索引字段共用的文本归一化（搜索计划 §7.2）：
/// 不区分大小写、变音符号与全角/半角宽度，并提供去分隔符
/// 与分词两种形式，对应两种匹配模式。
enum SearchTextNormalizer {
    private static let separators = CharacterSet(charactersIn: " -_.")
        .union(.whitespacesAndNewlines)

    static func normalize(_ text: String) -> String {
        tokenize(text).joined()
    }

    static func tokenize(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
    }

    /// 将中日韩文本转写为无声调拼音（"微信" -> "weixin"）；拉丁文本
    /// 原样通过。拼音仅作为匹配字段存在，展示的仍是原始名称。
    static func pinyin(of text: String) -> String {
        pinyinSyllables(of: text).joined()
    }

    /// 按字切分的拼音音节（"QQ音乐" -> ["qq", "yin", "le"]）：每个汉字单独转写为一个音节，
    /// 其余文字按分隔符切分，因此每个汉字的拼音起点都确定；不含汉字时为空。
    static func pinyinSyllables(of text: String) -> [String] {
        guard text.unicodeScalars.contains(where: { $0.properties.isIdeographic == true }) else {
            return []
        }
        var result: [String] = []
        var run = ""
        for character in text {
            if character.unicodeScalars.contains(where: { $0.properties.isIdeographic == true }) {
                result += syllables(of: run) + syllables(of: String(character))
                run = ""
            } else {
                run.append(character)
            }
        }
        result += syllables(of: run)
        // 与 query 归一化域对齐：统一小写（文档 §7.2）。
        return result.map { $0.lowercased() }
    }

    /// 取每段以空白分隔的转写结果的首字母，因此拉丁名称得到 "vsc"，
    /// 中文名称得到 "wx" 这样的首字母缩写。
    static func initials(of text: String) -> String {
        syllables(of: text)
            .compactMap(\.first)
            .map { String($0).lowercased() }
            .joined()
    }

    private static func syllables(of text: String) -> [String] {
        let mutable = NSMutableString(string: text)
        // 每次变换都重新传入 range：转写会改变字符串长度。
        mutable.applyTransform(
            .toLatin,
            reverse: false,
            range: NSRange(location: 0, length: mutable.length),
            updatedRange: nil
        )
        mutable.applyTransform(
            .stripCombiningMarks,
            reverse: false,
            range: NSRange(location: 0, length: mutable.length),
            updatedRange: nil
        )
        return (mutable as String)
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
    }
}

/// 单个应用派生出的匹配字段（搜索计划 §7）。自身不持有状态；
/// 应用快照被替换时即重建。
struct ApplicationSearchDocument: Sendable {
    let app: AppDescriptor
    let normalizedName: String
    let nameTokens: [String]
    let normalizedBundleName: String
    let normalizedBundleIdentifier: String
    /// Bundle Identifier 顶级域段（如 `com`）归一化后的长度：查询须越过这一段才按完整 ID 前缀匹配，
    /// 否则 `co`、`com` 这样的短查询会命中几乎所有应用。
    let bundleIdentifierDomainLength: Int
    /// 去掉「顶级域.厂商」两段后的 Bundle Identifier（`com.tencent.xinWeChat` → `xinwechat`）。
    /// 同厂商应用共有的前缀不参与包含匹配，避免短查询把整个厂商的应用挤进同一层级。
    let normalizedBundleIdentifierProduct: String
    let aliases: [String]
    let initials: String
    let pinyin: String
    /// 从每个字开始的全拼（"网易云音乐" -> wangyiyunyinle、yiyunyinle、yunyinle…），
    /// 用于从名字中任意一个字开始匹配全拼；按起点先后排列，第一项即 `pinyin`。
    let pinyinSuffixes: [String]

    init(app: AppDescriptor, aliases: [String] = []) {
        let tokens = SearchTextNormalizer.tokenize(app.name)
        self.app = app
        self.nameTokens = tokens
        self.normalizedName = tokens.joined()
        self.normalizedBundleName = SearchTextNormalizer.normalize(
            app.url.deletingPathExtension().lastPathComponent
        )
        let bundleIdentifier = app.bundleIdentifier ?? ""
        let identifierSegments = bundleIdentifier.split(separator: ".")
        let productSegments = identifierSegments.count > 2
            ? identifierSegments.dropFirst(2)
            : identifierSegments.suffix(1)
        self.normalizedBundleIdentifier = SearchTextNormalizer.normalize(bundleIdentifier)
        self.bundleIdentifierDomainLength = SearchTextNormalizer.normalize(
            String(identifierSegments.first ?? "")
        ).count
        self.normalizedBundleIdentifierProduct = SearchTextNormalizer.normalize(
            productSegments.joined(separator: ".")
        )
        self.aliases = aliases.map(SearchTextNormalizer.normalize)
        self.initials = SearchTextNormalizer.initials(of: app.name)
        let pinyinSyllables = SearchTextNormalizer.pinyinSyllables(of: app.name)
        self.pinyin = pinyinSyllables.joined()
        self.pinyinSuffixes = pinyinSyllables.indices.map { pinyinSyllables[$0...].joined() }
    }
}

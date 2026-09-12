import Foundation

/// Text normalization shared by the query and every indexed field (search plan §7.2):
/// case-, diacritic- and width-insensitive, with separator-stripped and tokenized
/// forms for the two match modes.
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

    /// Toneless transliteration of CJK text ("微信" -> "wei xin"); Latin text
    /// passes through unchanged. Pinyin only exists as a match field, the
    /// original name is what gets displayed.
    static func pinyin(of text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.properties.isIdeographic == true }) else {
            return ""
        }
        // 与 query 归一化域对齐：统一小写（文档 §7.2）。
        return syllables(of: text).joined().lowercased()
    }

    /// First letter of every whitespace-separated transliteration piece, so
    /// Latin names yield "vsc" and Chinese names yield initials like "wx".
    static func initials(of text: String) -> String {
        syllables(of: text)
            .compactMap(\.first)
            .map { String($0).lowercased() }
            .joined()
    }

    private static func syllables(of text: String) -> [String] {
        let mutable = NSMutableString(string: text)
        // The range is rebuilt per transform: transliteration changes the length.
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

/// Derived match fields for one application (search plan §7). Holds no state of
/// its own; rebuilt whenever the application snapshot is replaced.
struct ApplicationSearchDocument: Sendable {
    let app: AppDescriptor
    let normalizedName: String
    let nameTokens: [String]
    let normalizedBundleName: String
    let normalizedBundleIdentifier: String
    let aliases: [String]
    let initials: String
    let pinyin: String

    init(app: AppDescriptor, aliases: [String] = []) {
        let tokens = SearchTextNormalizer.tokenize(app.name)
        self.app = app
        self.nameTokens = tokens
        self.normalizedName = tokens.joined()
        self.normalizedBundleName = SearchTextNormalizer.normalize(
            app.url.deletingPathExtension().lastPathComponent
        )
        self.normalizedBundleIdentifier = SearchTextNormalizer.normalize(app.bundleIdentifier ?? "")
        self.aliases = aliases.map(SearchTextNormalizer.normalize)
        self.initials = SearchTextNormalizer.initials(of: app.name)
        self.pinyin = SearchTextNormalizer.pinyin(of: app.name)
    }
}

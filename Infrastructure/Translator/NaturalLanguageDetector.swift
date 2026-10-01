import NaturalLanguage

/// 基于 NaturalLanguage 框架的语种识别。
struct NaturalLanguageDetector: LanguageDetecting {
    /// 开头这么多字符足以判断语种，长段落也不拖慢气泡弹出。
    private static let sampleLength = 500

    func dominantLanguageCode(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(Self.sampleLength)))
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return language.rawValue
    }
}

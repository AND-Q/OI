import NaturalLanguage

/// 基于 NaturalLanguage 框架的语种识别。划词翻译的原文常是代码标识符、单个单词这类缺少上下文的短文本，
/// 统计模型容易把它们判为丹麦语等小语种、把只有汉字的短词判为日语，所以先按文字种类判断：
/// 汉字为主且不含假名、谚文时按中文，只含 ASCII 字母时按英语（较长且模型很有把握时才判为其他语言），
/// 其余（含假名、谚文、带变音符号的拉丁字母、西里尔字母等）交给模型识别。
struct NaturalLanguageDetector: LanguageDetecting {
    /// 开头这么多字符足以判断语种，长段落也不拖慢气泡弹出。
    private static let sampleLength = 500
    /// 不超过这么多个词的纯 ASCII 文本按英语处理：词太少时模型分不清各种拉丁字母语言。
    private static let shortTextWordLimit = 3
    /// 较长的纯 ASCII 文本只在模型对其他语言的把握达到这一概率时才不按英语处理。
    private static let foreignLanguageMinimumProbability = 0.9

    func dominantLanguageCode(of text: String) -> String? {
        let sample = String(text.prefix(Self.sampleLength))
        // 只有数字、符号或表情时谈不上语种。
        guard sample.contains(where: \.isLetter) else { return nil }

        var hanCount = 0
        var hasKanaOrHangul = false
        var hasNonASCIILetter = false
        for character in sample where character.isLetter {
            guard let scalar = character.unicodeScalars.first else { continue }
            if scalar.properties.isIdeographic {
                hanCount += 1
            } else if Self.isKanaOrHangul(scalar) {
                hasKanaOrHangul = true
            } else if !character.isASCII {
                hasNonASCIILetter = true
            }
        }

        if !hasKanaOrHangul {
            let words = Self.words(in: sample)
            // 中文里夹杂英文术语、标识符很常见（如「调用 reduceKernel 接口」），英文里夹杂汉字很少见：
            // 单词数不超过汉字数的两倍即按中文。
            if hanCount > 0, hanCount * 2 >= words.count {
                return Self.chineseLanguageCode(of: sample)
            }
            if !hasNonASCIILetter, !words.isEmpty {
                let isSingleToken = sample.split(whereSeparator: \.isWhitespace).count == 1
                return Self.asciiLanguageCode(of: words, isSingleToken: isSingleToken)
            }
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return language.rawValue
    }

    /// 把文本切成单词（不含汉字），标识符按驼峰与下划线、连字符等拆开，还原成自然语言的词：
    /// `reduceKernel`、`reduce_kernel` 都切成 reduce、kernel，`XMLHttpRequest` 切成 XML、Http、Request。
    static func words(in text: String) -> [String] {
        var words: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            guard character.isLetter, character.unicodeScalars.first?.properties.isIdeographic == false else {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                continue
            }
            if let previous = current.last {
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                // 小写后接大写处断开（reduce|Kernel）；连续大写在最后一个大写后接小写时断开（XML|Http）。
                let isCamelCaseBoundary = previous.isLowercase && character.isUppercase
                let isAcronymBoundary = previous.isUppercase && character.isUppercase && next?.isLowercase == true
                if isCamelCaseBoundary || isAcronymBoundary {
                    words.append(current)
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty {
            words.append(current)
        }
        return words
    }

    /// 只含 ASCII 字母的文本：单个标识符或单词、不超过三个词的短语按英语；更长的文本交给模型，
    /// 模型很有把握是其他语言（如不带变音符号的法语句子）时才采用，否则仍按英语。
    private static func asciiLanguageCode(of words: [String], isSingleToken: Bool) -> String {
        let english = NLLanguage.english.rawValue
        guard !isSingleToken, words.count > shortTextWordLimit else { return english }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(words.joined(separator: " "))
        guard let hypothesis = recognizer.languageHypotheses(withMaximum: 1).first,
              hypothesis.value >= foreignLanguageMinimumProbability else { return english }
        return hypothesis.key.rawValue
    }

    /// 简繁交给模型在两者之间判断，判断不出时按简体。
    private static func chineseLanguageCode(of text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.simplifiedChinese, .traditionalChinese]
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else {
            return NLLanguage.simplifiedChinese.rawValue
        }
        return language.rawValue
    }

    /// 平假名、片假名（含半角）与谚文：出现即为日文或韩文，汉字再多也不按中文处理。
    private static func isKanaOrHangul(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F:
            true
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7FF:
            true
        default:
            false
        }
    }
}

import Foundation

/// 把输入解析为快速查询（计算、本机 IP）；本机 IP 经端口读取，不在本层访问网络接口。
struct QuickQueryResolver {
    let ipAddressProvider: any LocalIPAddressProviding

    func resolve(_ query: String) -> QuickQueryResult? {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let compactQuery = normalizedQuery
            .filter { !$0.isWhitespace }
            .lowercased()

        if [
            "ip", "ip查询", "localip", "localipaddress", "myip", "myipaddress",
            "本机ip", "本机ip地址", "本机ip查询", "本地ip", "本地ip地址", "本地ip查询", "局域网ip"
        ].contains(compactQuery) {
            return .localIPAddress(ipAddressProvider.currentIPv4Address())
        }

        guard let value = MathExpressionEvaluator.evaluate(normalizedQuery) else { return nil }
        return .calculation(expression: normalizedQuery, value: value)
    }
}

private enum MathExpressionEvaluator {
    static func evaluate(_ expression: String) -> String? {
        guard expression.count <= 256 else { return nil }
        // 日期样式与编号常是要搜索的内容，不是减法算式。
        // 两段的斜杠形式（10/3、1024/8）按除法计算；只有完整的年/月/日才算日期。
        let datePatterns = [
            #"^\d{4}[-/]\d{1,2}[-/]\d{1,2}$"#,
            #"^\d{4}-\d{1,2}$"#,
            #"^\d{1,2}-\d{1,2}$"#
        ]
        guard !datePatterns.contains(where: {
            expression.range(of: $0, options: .regularExpression) != nil
        }) else { return nil }

        var parser = Parser(expression)
        guard let value = parser.parse(), value.isFinite else { return nil }
        return String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private struct Parser {
        private let characters: [Character]
        private var index = 0
        private var containsBinaryOperator = false

        init(_ expression: String) {
            characters = expression.map { character in
                switch character {
                case "＋": return "+"
                case "－", "−": return "-"
                case "（": return "("
                case "）": return ")"
                default: return character
                }
            }
        }

        mutating func parse() -> Double? {
            guard let value = parseSum() else { return nil }
            skipWhitespace()
            return index == characters.count && containsBinaryOperator ? value : nil
        }

        private mutating func parseSum() -> Double? {
            guard var value = parseProduct() else { return nil }

            while true {
                skipWhitespace()
                guard let operation = current, operation == "+" || operation == "-" else {
                    return value
                }
                containsBinaryOperator = true
                index += 1
                guard let right = parseProduct() else { return nil }
                value = operation == "+" ? value + right : value - right
            }
        }

        private mutating func parseProduct() -> Double? {
            guard var value = parseUnary() else { return nil }

            while true {
                skipWhitespace()
                guard let operation = current,
                      operation == "*" || operation == "×"
                        || operation == "/" || operation == "÷" || operation == "%" else {
                    return value
                }
                containsBinaryOperator = true
                index += 1
                guard let right = parseUnary() else { return nil }

                switch operation {
                case "*", "×": value *= right
                case "/", "÷": value /= right
                default: value = value.truncatingRemainder(dividingBy: right)
                }
            }
        }

        private mutating func parseUnary() -> Double? {
            skipWhitespace()
            guard let operation = current, operation == "+" || operation == "-" else {
                return parsePower()
            }
            index += 1
            guard let value = parseUnary() else { return nil }
            return operation == "-" ? -value : value
        }

        private mutating func parsePower() -> Double? {
            guard let value = parsePrimary() else { return nil }
            skipWhitespace()
            guard current == "^" else { return value }

            containsBinaryOperator = true
            index += 1
            guard let exponent = parseUnary() else { return nil }
            return pow(value, exponent)
        }

        private mutating func parsePrimary() -> Double? {
            skipWhitespace()
            if current == "(" {
                index += 1
                guard let value = parseSum() else { return nil }
                skipWhitespace()
                guard current == ")" else { return nil }
                index += 1
                return value
            }
            return parseNumber()
        }

        private mutating func parseNumber() -> Double? {
            skipWhitespace()
            let start = index
            var digitCount = 0

            while isDigit(current) {
                index += 1
                digitCount += 1
            }
            if current == "." {
                index += 1
                while isDigit(current) {
                    index += 1
                    digitCount += 1
                }
            }
            guard digitCount > 0 else { return nil }

            if current == "e" || current == "E" {
                index += 1
                if current == "+" || current == "-" { index += 1 }
                let exponentStart = index
                while isDigit(current) { index += 1 }
                guard index > exponentStart else { return nil }
            }

            return Double(String(characters[start..<index]))
        }

        private mutating func skipWhitespace() {
            while current?.isWhitespace == true { index += 1 }
        }

        private var current: Character? {
            characters.indices.contains(index) ? characters[index] : nil
        }

        private func isDigit(_ character: Character?) -> Bool {
            guard let value = character?.asciiValue else { return false }
            return (48...57).contains(value)
        }
    }
}

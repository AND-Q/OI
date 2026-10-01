import Foundation

/// Block-level Markdown element of a Quick AI answer. SwiftUI `Text` only renders
/// inline Markdown, so headings, lists, quotes and code blocks are split out here.
enum QuickAIMarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(marker: String, text: String, indent: Int)
    case quote(String)
    case code(language: String, code: String)
    case table(header: [String], rows: [[String]])
    case rule
}

enum QuickAIMarkdown {
    /// Splits Markdown into blocks line by line. Streaming output is often cut
    /// mid-block: an unclosed code fence is rendered as code up to the end.
    static func blocks(from markdown: String) -> [QuickAIMarkdownBlock] {
        var blocks: [QuickAIMarkdownBlock] = []
        var paragraph: [String] = []
        var tableLines: [String] = []
        var code: (fence: String, language: String, lines: [String])?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        // 表头下一行是分隔行才按表格渲染；流式输出中分隔行尚未到达时先按段落显示。
        func flushTable() {
            guard !tableLines.isEmpty else { return }
            if tableLines.count >= 2, isTableSeparator(tableLines[1]) {
                let header = tableCells(in: tableLines[0])
                let rows = tableLines.dropFirst(2).map { line in
                    let cells = tableCells(in: line)
                    return Array((cells + Array(repeating: "", count: max(header.count - cells.count, 0)))
                        .prefix(header.count))
                }
                blocks.append(.table(header: header, rows: rows))
            } else {
                blocks.append(.paragraph(tableLines.joined(separator: "\n")))
            }
            tableLines = []
        }

        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        for line in normalized.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let open = code {
                // 只有与开头相同的围栏（``` 或 ~~~）才能闭合代码块。
                if trimmed.hasPrefix(open.fence) {
                    blocks.append(.code(language: open.language, code: open.lines.joined(separator: "\n")))
                    code = nil
                } else {
                    code?.lines.append(line)
                }
                continue
            }
            if let fence = ["```", "~~~"].first(where: { trimmed.hasPrefix($0) }) {
                flushParagraph()
                flushTable()
                code = (fence, String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces), [])
                continue
            }

            if trimmed.hasPrefix("|") {
                flushParagraph()
                tableLines.append(trimmed)
                continue
            }
            flushTable()

            if trimmed.isEmpty {
                flushParagraph()
            } else if let heading = heading(in: trimmed) {
                flushParagraph()
                blocks.append(heading)
            } else if ["---", "***", "___"].contains(trimmed) {
                flushParagraph()
                blocks.append(.rule)
            } else if let item = listItem(in: line) {
                flushParagraph()
                blocks.append(item)
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                // 连续引用行合并为一个引用块。
                if case .quote(let previous)? = blocks.last {
                    blocks[blocks.count - 1] = .quote(previous + "\n" + text)
                } else {
                    blocks.append(.quote(text))
                }
            } else {
                paragraph.append(trimmed)
            }
        }

        flushParagraph()
        flushTable()
        if let open = code {
            blocks.append(.code(language: open.language, code: open.lines.joined(separator: "\n")))
        }
        return blocks
    }

    /// Removes `<think>…</think>` reasoning that some models (e.g. via Ollama) put in
    /// the answer. While streaming, an unclosed `<think>` hides everything after it.
    static func removingThinking(from answer: String) -> String {
        var visible = ""
        var remaining = answer[...]
        while let start = remaining.range(of: "<think>") {
            visible += remaining[..<start.lowerBound]
            guard let end = remaining[start.upperBound...].range(of: "</think>") else {
                remaining = ""
                break
            }
            remaining = remaining[end.upperBound...]
        }
        visible += remaining
        return visible.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Inline Markdown (bold, italic, `code`, links) with line breaks preserved.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    /// `|---|:---:|` 形式的表头分隔行。
    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(in: line)
        return !cells.isEmpty && cells.allSatisfy { cell in
            cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func tableCells(in line: String) -> [String] {
        var content = Substring(line.trimmingCharacters(in: .whitespaces))
        if content.hasPrefix("|") { content = content.dropFirst() }
        if content.hasSuffix("|") { content = content.dropLast() }
        return content.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func heading(in trimmed: String) -> QuickAIMarkdownBlock? {
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.first == " " else { return nil }
        return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(in line: String) -> QuickAIMarkdownBlock? {
        let leadingSpaces = line.prefix(while: { $0 == " " || $0 == "\t" })
            .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let indent = leadingSpaces / 2

        for bullet in ["- ", "* ", "+ "] where trimmed.hasPrefix(bullet) {
            return .listItem(marker: "•", text: String(trimmed.dropFirst(2)), indent: indent)
        }

        let digits = trimmed.prefix(while: { $0.isASCII && $0.isNumber })
        let rest = trimmed.dropFirst(digits.count)
        if !digits.isEmpty, digits.count <= 3,
           let delimiter = rest.first, delimiter == "." || delimiter == ")",
           rest.dropFirst().first == " " {
            return .listItem(
                marker: "\(digits).",
                text: rest.dropFirst(2).trimmingCharacters(in: .whitespaces),
                indent: indent
            )
        }
        return nil
    }
}

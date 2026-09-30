import Foundation

/// Block-level Markdown element of a Quick AI answer. SwiftUI `Text` only renders
/// inline Markdown, so headings, lists, quotes and code blocks are split out here.
enum QuickAIMarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(marker: String, text: String, indent: Int)
    case quote(String)
    case code(language: String, code: String)
    case rule
}

enum QuickAIMarkdown {
    /// Splits Markdown into blocks line by line. Streaming output is often cut
    /// mid-block: an unclosed code fence is rendered as code up to the end.
    static func blocks(from markdown: String) -> [QuickAIMarkdownBlock] {
        var blocks: [QuickAIMarkdownBlock] = []
        var paragraph: [String] = []
        var code: (language: String, lines: [String])?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if let open = code {
                    blocks.append(.code(language: open.language, code: open.lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    code = (String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces), [])
                }
                continue
            }
            if code != nil {
                code?.lines.append(line)
                continue
            }

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
        if let open = code {
            blocks.append(.code(language: open.language, code: open.lines.joined(separator: "\n")))
        }
        return blocks
    }

    /// Inline Markdown (bold, italic, `code`, links) with line breaks preserved.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
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

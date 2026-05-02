import AppKit
import MarkdownToAttributedString
import Splash

/// Splash’s Swift grammar tokenizer (real lexer), isolated here so `import Splash`
/// does not pull `Splash.Color` (= NSColor) into `main.swift` and clash with SwiftUI.Color.
enum CodeBlockSplashHighlighting {
    nonisolated(unsafe) private static let highlighter = SyntaxHighlighter(
        format: AttributedStringOutputFormat(
            theme: .sundellsColors(withFont: Font(size: 13))
        )
    )

    /// Heuristic language gate: only run Swift lexer on blocks that look like Swift so
    /// Python / JS / Go / shell keep tidy monospace styling without bogus token colors.
    static func likelySwiftCode(_ code: String) -> Bool {
        let t = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if t.range(of: #"(?m)^\s*def\s+\w+\s*\("#, options: .regularExpression) != nil { return false }
        if t.range(of: #"\bconsole\.(log|error|warn)\b"#, options: .regularExpression) != nil { return false }
        if t.range(of: #"\bpackage\s+main\b"#, options: .regularExpression) != nil { return false }

        if t.range(of: #"\b(func|struct|class|enum|protocol|extension)\b"#, options: .regularExpression) != nil {
            return true
        }
        if t.range(of: #"\bimport\s+[A-Za-z]"#, options: .regularExpression) != nil { return true }
        if t.contains(" -> ") { return true }
        if t.range(of: #"\blet\s+\w+\s*="#, options: .regularExpression) != nil { return true }
        if t.range(of: #"\bvar\s+\w+\s*="#, options: .regularExpression) != nil { return true }
        if t.range(of: #"\bguard\s+"#, options: .regularExpression) != nil { return true }
        return false
    }

    static func applyToLikelySwiftCodeBlocks(_ attr: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: attr.length)
        var blocks: [NSRange] = []
        attr.enumerateAttribute(.markdownElements, in: full) { value, range, _ in
            guard let elements = value as? MarkdownElementAttributes,
                  elements.includesElementType(.codeBlock) else { return }
            blocks.append(range)
        }
        for range in blocks.sorted(by: { $0.location > $1.location }) {
            let code = (attr.string as NSString).substring(with: range)
            guard likelySwiftCode(code) else { continue }

            let highlighted = highlighter.highlight(code)
            if highlighted.length == 0 { continue }

            let para = attr.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let merged = NSMutableAttributedString(attributedString: highlighted)
            let whole = NSRange(location: 0, length: merged.length)
            if let para {
                merged.addAttribute(.paragraphStyle, value: para, range: whole)
            }
            let codeBg = NSColor.black.withAlphaComponent(0.45)
            merged.addAttribute(.backgroundColor, value: codeBg, range: whole)

            attr.replaceCharacters(in: range, with: merged)
        }
    }
}

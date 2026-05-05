import AppKit
import Highlighter
import MarkdownToAttributedString
import Splash

/// Syntax-color code blocks in the rendered markdown.
///
/// Two-stage strategy:
///   • If a block looks like Swift, use Splash (Sundell theme — Swift-
///     specific lexer, slightly nicer than highlight.js for our domain).
///   • Otherwise route through HighlighterSwift, which wraps the
///     current highlight.js (~190 languages) with auto-detection. Every
///     other code block previously rendered as plain monospace; now
///     shell, JSON, TypeScript, Python, etc. all get coloured.
///
/// Switched from raspu/Highlightr (unmaintained as of 2026) to
/// smittytone/HighlighterSwift (active fork, current highlight.js 11.x).
enum CodeBlockSplashHighlighting {
    nonisolated(unsafe) private static let splashHighlighter = SyntaxHighlighter(
        format: AttributedStringOutputFormat(
            theme: .sundellsColors(withFont: Font(size: 12))
        )
    )

    /// HighlighterSwift instance configured once at first use.
    /// JavaScriptCore lives behind it; reusing the instance avoids
    /// spinning up a fresh JSContext per code block.
    nonisolated(unsafe) private static let highlighter: Highlighter? = {
        let h = Highlighter()
        // Atom one-dark reads well over the panel's translucent dark
        // codeBg. Other dark themes that work: monokai-sublime,
        // androidstudio, gruvbox-dark, vs2015. Light-only themes
        // (xcode, github) wash out against the dark backdrop.
        _ = h?.setTheme("atom-one-dark")
        return h
    }()

    /// Heuristic language gate: only run Swift lexer on blocks that look like Swift.
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
        // Walk blocks back-to-front so range mutations from
        // replaceCharacters(in:) don't shift the ranges we haven't
        // processed yet.
        for range in blocks.sorted(by: { $0.location > $1.location }) {
            let code = (attr.string as NSString).substring(with: range)
            if likelySwiftCode(code) {
                applySplash(attr: attr, range: range, code: code)
            } else {
                applyHighlightr(attr: attr, range: range, code: code)
            }
        }
    }

    private static func applySplash(attr: NSMutableAttributedString, range: NSRange, code: String) {
        let highlighted = splashHighlighter.highlight(code)
        guard highlighted.length > 0 else { return }
        replace(in: attr, range: range, with: highlighted)
    }

    private static func applyHighlightr(attr: NSMutableAttributedString, range: NSRange, code: String) {
        guard let highlighter = highlighter else { return }
        // `as: nil` triggers highlight.js auto-detection. Works well
        // on shell/JSON/TS/Python/etc.; for tiny snippets (1–2 lines)
        // detection can guess wrong, but the worst case is "looks like
        // unstyled mono" which is what we had before this change.
        guard let highlighted = highlighter.highlight(code, as: nil),
              highlighted.length > 0 else { return }
        replace(in: attr, range: range, with: highlighted)
    }

    /// Carry the original paragraph style over the freshly-highlighted
    /// attributed string before splicing it back in. The paragraph
    /// style carries the NSTextBlock that paints the full-width dark
    /// background, so without re-applying it the highlighted block
    /// would lose its head-indent + continuous BG.
    private static func replace(
        in attr: NSMutableAttributedString,
        range: NSRange,
        with highlighted: NSAttributedString
    ) {
        let para = attr.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        let merged = NSMutableAttributedString(attributedString: highlighted)
        let whole = NSRange(location: 0, length: merged.length)
        if let para {
            merged.addAttribute(.paragraphStyle, value: para, range: whole)
        }
        attr.replaceCharacters(in: range, with: merged)
    }
}

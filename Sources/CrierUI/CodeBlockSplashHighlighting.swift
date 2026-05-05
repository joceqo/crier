import AppKit
import Highlighter
import MarkdownToAttributedString
import Splash

/// Syntax-color code blocks in the rendered markdown.
///
/// Two-stage strategy:
///   • If the fence names `swift` (from the markdown AST) or the code
///     looks like Swift and there is no fence, use Splash (Sundell theme).
///   • Otherwise route through HighlighterSwift, which wraps the
///     current highlight.js (~190 languages), passing the fence tag as the
///     language when present and otherwise using auto-detection. Every
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

    /// JavaScriptCore + highlight.js; theme is swapped to match
    /// `NSApp.effectiveAppearance` in `highlight` (xcode in light Aqua,
    /// monokai-sublime in dark Aqua). Constructor leaves `default`.
    nonisolated(unsafe) private static let highlighter: Highlighter? = Highlighter()

    /// Last theme successfully applied to `highlighter` (avoids
    /// re-reading CSS on every code block).
    @MainActor private static var configuredHighlighterTheme: String?

    /// highlight.js theme file names bundled with HighlighterSwift.
    private static let lightHighlightTheme = "xcode"
    private static let darkHighlightTheme = "monokai-sublime"

    /// SwiftUI-side entry point: takes the raw code string, runs it
    /// through Splash (Swift) or HighlighterSwift (everything else),
    /// returns an `AttributedString` ready to drop into a `Text` view.
    /// Bridges `NSAttributedString` → `AttributedString` for SwiftUI's
    /// `Text(_ attributedString: AttributedString)` initializer.
    ///
    /// On highlight failure, falls back to a plain monospace
    /// AttributedString so the code is still legible.
    ///
    /// - Parameter fenceLanguage: The language on the opening fence
    ///   (e.g. `javascript` in ` ```javascript `), when present. When
    ///   the writer tags the block, that wins over heuristics.
    @MainActor
    static func highlight(_ code: String, fenceLanguage: String? = nil) -> AttributedString {
        syncHighlighterThemeWithAppearance()

        let fence = fenceLanguage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = fence.flatMap { $0.isEmpty ? nil : $0.lowercased() }

        if let tag, plainTextFenceTags.contains(tag) {
            return AttributedString(code)
        }

        let useSplash = shouldUseSplash(fenceTag: tag, code: code)
        let nsAttr: NSAttributedString
        if useSplash {
            let s = splashHighlighter.highlight(code)
            let raw = s.length > 0 ? s : NSAttributedString(string: code)
            nsAttr = adjustSplashForLightAqua(raw)
        } else {
            let hljsLang = tag.flatMap { $0 == "swift" ? nil : highlightJSLanguage(fromFenceTag: $0) }
            nsAttr = highlightNonSwift(code, explicitLanguage: hljsLang)
        }
        // Strip per-glyph .backgroundColor attributes from the
        // highlighter output. Most highlight.js themes (xcode and
        // monokai-sublime included) bake the theme's background into every glyph run,
        // which stacks on top of CodeBlockView's SwiftUI .background
        // and reads as an opaque slab with washed-out text. The block
        // background is owned by the SwiftUI side; per-glyph colors
        // here should only be foreground tokens.
        let mutable = NSMutableAttributedString(attributedString: nsAttr)
        let full = NSRange(location: 0, length: mutable.length)
        mutable.removeAttribute(.backgroundColor, range: full)
        return AttributedString(mutable)
    }

    /// Fence tags to show as monospace without running highlighters.
    private static let plainTextFenceTags: Set<String> = [
        "text", "plaintext", "txt", "none",
    ]

    /// Whether Splash should handle this block.
    private static func shouldUseSplash(fenceTag: String?, code: String) -> Bool {
        if let tag = fenceTag {
            return tag == "swift"
        }
        return likelySwiftCode(code)
    }

    /// Map CommonMark fence labels to highlight.js language identifiers.
    private static func highlightJSLanguage(fromFenceTag tag: String) -> String {
        switch tag {
        case "js", "javascript", "ecmascript": return "javascript"
        case "ts", "tsx", "typescript": return "typescript"
        case "py", "python": return "python"
        case "rb", "ruby": return "ruby"
        case "sh", "shell", "bash", "zsh", "fish": return "bash"
        case "yml", "yaml": return "yaml"
        case "md", "markdown": return "markdown"
        case "cpp", "c++", "cxx": return "cpp"
        case "csharp", "c#", "cs": return "csharp"
        case "kt", "kotlin": return "kotlin"
        case "rs", "rust": return "rust"
        case "objc", "objective-c", "objectivec", "mm": return "objectivec"
        default: return tag
        }
    }

    @MainActor
    private static func highlightNonSwift(_ code: String, explicitLanguage: String?) -> NSAttributedString {
        guard let h = highlighter else {
            return NSAttributedString(string: code)
        }
        if let lang = explicitLanguage, !lang.isEmpty,
           let out = h.highlight(code, as: lang), out.length > 0 {
            return out
        }
        if let out = h.highlight(code, as: nil), out.length > 0 {
            return out
        }
        return NSAttributedString(string: code)
    }

    /// Heuristic language gate: only run Swift lexer on blocks that look like Swift.
    static func likelySwiftCode(_ code: String) -> Bool {
        let t = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if t.range(of: #"(?m)^\s*def\s+\w+\s*\("#, options: .regularExpression) != nil { return false }
        if t.range(of: #"\bconsole\.(log|error|warn)\b"#, options: .regularExpression) != nil { return false }
        if t.range(of: #"\bpackage\s+main\b"#, options: .regularExpression) != nil { return false }

        // ECMAScript shares `let` / `var` with Swift; disqualify before the
        // `let` heuristic so JS quickstarts go through highlight.js.
        if t.range(of: #"\bconst\b"#, options: .regularExpression) != nil { return false }
        if t.range(of: #"\bfunction\b"#, options: .regularExpression) != nil { return false }
        if t.range(of: #"\)\s*=>"#, options: .regularExpression) != nil { return false }

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

    @MainActor
    private static func syncHighlighterThemeWithAppearance() {
        guard let h = highlighter else { return }
        let name = (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            ? darkHighlightTheme
            : lightHighlightTheme
        if configuredHighlighterTheme == name { return }
        if h.setTheme(name) {
            configuredHighlighterTheme = name
        } else {
            FileHandle.standardError.write(Data(
                "CrierUI: HighlighterSwift could not load '\(name)' — keeping prior theme\n".utf8
            ))
        }
    }

    @MainActor
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

    @MainActor
    private static func adjustSplashForLightAqua(_ attr: NSAttributedString) -> NSAttributedString {
        if NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return attr
        }
        let m = NSMutableAttributedString(attributedString: attr)
        let full = NSRange(location: 0, length: m.length)
        let replacement = NSColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1)
        m.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
            guard let c = value as? NSColor else { return }
            guard let rgb = c.usingColorSpace(.deviceRGB) else { return }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
            let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            // Splash’s Sundell theme uses light plain text and white for
            // unknown `.custom` tokens — fine on a dark canvas, illegible on
            // our light code-fence tint. Boost only high-luminance runs.
            if lum > 0.68 {
                m.addAttribute(.foregroundColor, value: replacement, range: range)
            }
        }
        return m
    }

    @MainActor
    private static func applySplash(attr: NSMutableAttributedString, range: NSRange, code: String) {
        let highlighted = splashHighlighter.highlight(code)
        guard highlighted.length > 0 else { return }
        replace(in: attr, range: range, with: adjustSplashForLightAqua(highlighted))
    }

    @MainActor
    private static func applyHighlightr(attr: NSMutableAttributedString, range: NSRange, code: String) {
        syncHighlighterThemeWithAppearance()
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

import Markdown
import SwiftUI

// Render a markdown string as a SwiftUI view tree. Replaces the old
// single-NSTextView pipeline (NSAttributedString + NSTextBlock) so we
// can put real SwiftUI .background + .clipShape(RoundedRectangle) on
// per-block code containers — something NSAttributedString attributes
// cannot do (they only paint rectangles, no corner radius).
//
// Strategy: parse with swift-markdown's Document, walk top-level
// block children, emit a typed view per block (Heading / Paragraph /
// CodeBlock / List / BlockQuote / ThematicBreak). Inline children of
// paragraphs / headings / list items are flattened into an
// AttributedString and handed to SwiftUI's Text — that gives us
// strong / emphasis / link / inlineCode runs in a single text node
// while still letting block-level views own their own backgrounds.

struct MarkdownContent: View {
    let markdown: String

    var body: some View {
        let document = Document(parsing: markdown)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(document.blockChildren.enumerated()), id: \.offset) { _, node in
                blockView(for: node)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor
    @ViewBuilder
    fileprivate func blockView(for node: any BlockMarkup) -> some View {
        switch node {
        case let h as Heading: HeadingView(heading: h)
        case let p as Paragraph: ParagraphView(paragraph: p)
        case let cb as CodeBlock: CodeBlockView(code: cb.code, language: cb.language)
        case let l as UnorderedList: ListView(items: Array(l.listItems), ordered: false, startIndex: 1)
        case let l as OrderedList: ListView(items: Array(l.listItems), ordered: true, startIndex: Int(l.startIndex))
        case let bq as BlockQuote: BlockQuoteView(blockQuote: bq)
        case is ThematicBreak: Divider().padding(.vertical, 4)
        default: EmptyView()
        }
    }
}

// MARK: - Block views

private struct HeadingView: View {
    let heading: Heading
    var body: some View {
        Text(inlineAttributedString(from: heading))
            .font(headingFont(for: heading.level))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .system(size: 22, weight: .bold)
        case 2: return .system(size: 19, weight: .bold)
        case 3: return .system(size: 17, weight: .semibold)
        case 4: return .system(size: 15, weight: .semibold)
        case 5: return .system(size: 14, weight: .semibold)
        default: return .system(size: 13, weight: .semibold)
        }
    }
}

private struct ParagraphView: View {
    let paragraph: Paragraph
    var body: some View {
        Text(inlineAttributedString(from: paragraph))
            .font(.system(size: 14))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ListView: View {
    let items: [ListItem]
    let ordered: Bool
    let startIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker(for: idx))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(item.blockChildren.enumerated()), id: \.offset) { _, child in
                            ListItemContent.blockView(for: child)
                        }
                    }
                }
            }
        }
    }

    private func marker(for idx: Int) -> String {
        ordered ? "\(startIndex + idx)." : "•"
    }
}

// Helper that lets ListView render nested blocks (paragraphs, code
// blocks, sublists) inside list items without recursing through
// MarkdownContent itself (which would pull in extra wrapping).
private enum ListItemContent {
    @MainActor
    @ViewBuilder
    static func blockView(for node: any BlockMarkup) -> some View {
        switch node {
        case let p as Paragraph: ParagraphView(paragraph: p)
        case let cb as CodeBlock: CodeBlockView(code: cb.code, language: cb.language)
        case let l as UnorderedList: ListView(items: Array(l.listItems), ordered: false, startIndex: 1)
        case let l as OrderedList: ListView(items: Array(l.listItems), ordered: true, startIndex: Int(l.startIndex))
        case let bq as BlockQuote: BlockQuoteView(blockQuote: bq)
        default: EmptyView()
        }
    }
}

private struct BlockQuoteView: View {
    let blockQuote: BlockQuote

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(blockQuote.blockChildren.enumerated()), id: \.offset) { _, child in
                    if let p = child as? Paragraph {
                        Text(inlineAttributedString(from: p))
                            .font(.system(size: 14).italic())
                            .foregroundStyle(.secondary)
                    } else {
                        ListItemContent.blockView(for: child)
                    }
                }
            }
        }
    }
}

/// The load-bearing piece of the rework. Each code block gets its own
/// horizontal `ScrollView`, so over-wide lines scroll independently
/// per block (no more wrap-induced misalignment when comments push a
/// directory-tree line past the panel width). The `RoundedRectangle`
/// clip-shape gives us the rounded corners NSAttributedString could
/// never deliver.
struct CodeBlockView: View {
    let code: String
    let language: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(CodeBlockSplashHighlighting.highlight(code, fenceLanguage: language))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        }
        // Subtle 6 % primary tint — adapts to system dark/light, sits
        // as a hint of "this is a code block" on the panel vibrancy
        // without dominating it. Earlier versions used 18 % black,
        // which read as an opaque slab over the panel and washed out
        // the syntax-coloured text.
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Inline attributed-string builder

/// Walk a block's inline children (or any container) and accumulate
/// runs into an AttributedString. Handles the inline node types
/// emitted by swift-markdown: Text, Strong, Emphasis, InlineCode,
/// Link, Strikethrough, LineBreak, SoftBreak.
private func inlineAttributedString(from container: any Markup) -> AttributedString {
    var result = AttributedString()
    for child in container.children {
        result.append(inlineAttributedString(for: child))
    }
    return result
}

private func inlineAttributedString(for node: any Markup) -> AttributedString {
    switch node {
    case let t as Markdown.Text:
        return AttributedString(t.string)

    case let s as Strong:
        var inner = AttributedString()
        for c in s.children { inner.append(inlineAttributedString(for: c)) }
        inner.font = .system(size: 14, weight: .semibold)
        return inner

    case let e as Emphasis:
        var inner = AttributedString()
        for c in e.children { inner.append(inlineAttributedString(for: c)) }
        inner.font = .system(size: 14).italic()
        return inner

    case let ic as InlineCode:
        var run = AttributedString(ic.code)
        run.font = .system(size: 12.5, design: .monospaced)
        // SwiftUI's AttributedString doesn't support per-run
        // clipShape, so we can't make true capsules here. The
        // backgroundColor renders as a small rounded-ish rectangle
        // behind the glyphs which reads as a pill at this size.
        run.backgroundColor = Color.white.opacity(0.12)
        return run

    case let link as Markdown.Link:
        var inner = AttributedString()
        for c in link.children { inner.append(inlineAttributedString(for: c)) }
        if let dest = link.destination, let url = URL(string: dest) {
            inner.link = url
        }
        inner.foregroundColor = .accentColor
        inner.underlineStyle = .single
        return inner

    case let s as Strikethrough:
        var inner = AttributedString()
        for c in s.children { inner.append(inlineAttributedString(for: c)) }
        inner.strikethroughStyle = .single
        return inner

    case is LineBreak:
        return AttributedString("\n")

    case is SoftBreak:
        return AttributedString(" ")

    default:
        // Image, InlineHTML, custom inline directives, etc. — render
        // their plain-text representation so nothing is ever silently
        // dropped from the user's view.
        return AttributedString(node.format())
    }
}

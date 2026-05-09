import AppKit
import MarkdownToAttributedString
import SwiftUI

// Renders the agent's last assistant message as an NSTextView wrapped
// in an NSViewRepresentable so the user can drag-select arbitrary
// ranges, Cmd+A across the whole message, and Cmd+C copy — none of
// which the previous per-paragraph SwiftUI `Text` tree could do (each
// `Text` had its own .textSelection scope; Cmd+A was a no-op).
//
// Pipeline:
//   1. AttributedStringFormatter.format(markdown:)
//      → NSAttributedString. The package handles headings, paragraphs,
//      lists, bold/italic/strike, inline code, code blocks, and stamps
//      .markdownElements on each block range so we can find them
//      again.
//   2. CodeBlockSplashHighlighting.applyToLikelySwiftCodeBlocks(_:)
//      walks .markdownElements code-block ranges and replaces their
//      contents with Splash-/highlight.js-coloured runs. This helper
//      was already in the codebase from the pre-SwiftUI rendering era,
//      now wired back up.
//   3. The NSTextView is configured non-editable, selectable,
//      transparent background, word-wrap, no padding; sizeThatFits
//      reports the laid-out height so the parent SwiftUI ScrollView
//      grows naturally up to its 460 pt cap.
//
// Trade-off vs the prior SwiftUI `MarkdownContent`: code blocks have
// rectangular paragraph backgrounds, not rounded clip-shapes —
// NSAttributedString can't paint clip-shaped corners. We picked
// real text selection over the rounded corners.

struct SelectableMarkdownView: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.allowsUndo = false
        // Both off — markdown links carry a real .link attribute, so we
        // don't need NSTextView's auto-detection scanning the body for
        // URLs / phone numbers / addresses.
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        tv.textStorage?.setAttributedString(renderedAttributedString(markdown: markdown))
        return tv
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        let attr = renderedAttributedString(markdown: markdown)
        // Skip the textStorage round-trip when the text is unchanged —
        // SwiftUI re-evaluates the view on unrelated state changes
        // (selected session, focus, etc.) and resetting the storage
        // would clobber any in-progress selection.
        if nsView.textStorage?.string != attr.string {
            nsView.textStorage?.setAttributedString(attr)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let container = nsView.textContainer,
              let layoutManager = nsView.layoutManager else {
            return nil
        }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return CGSize(width: width, height: ceil(used.height))
    }

    @MainActor
    private func renderedAttributedString(markdown: String) -> NSAttributedString {
        let raw = AttributedStringFormatter.format(
            markdown: markdown,
            styles: SelectableMarkdownView.crierStyles
        )
        let mutable = NSMutableAttributedString(attributedString: raw)
        CodeBlockSplashHighlighting.applyToLikelySwiftCodeBlocks(mutable)
        return mutable
    }

    @MainActor
    private static let crierStyles: MarkdownStyles = makeStyles()

    @MainActor
    private static func makeStyles() -> MarkdownStyles {
        let bodyFont = NSFont.systemFont(ofSize: 14)
        let inlineCodeFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let codeBlockFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let italicFont = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)

        let codeBlockPara = NSMutableParagraphStyle()
        codeBlockPara.firstLineHeadIndent = 12
        codeBlockPara.headIndent = 12
        codeBlockPara.tailIndent = -12
        codeBlockPara.paragraphSpacingBefore = 6
        codeBlockPara.paragraphSpacing = 6

        let listPara = NSMutableParagraphStyle()
        listPara.headIndent = 18

        let bodyPara = NSMutableParagraphStyle()
        bodyPara.paragraphSpacing = 6

        var styles = MarkdownStyles(
            baseAttributes: [
                .font: bodyFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: bodyPara,
            ],
            styleAttributes: [
                .strong: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold)],
                .emphasis: [.font: italicFont],
                .strikethrough: [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: NSColor.secondaryLabelColor,
                ],
                .inlineCode: [
                    .font: inlineCodeFont,
                    .backgroundColor: NSColor.labelColor.withAlphaComponent(0.10),
                ],
                .codeBlock: [
                    .font: codeBlockFont,
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.labelColor.withAlphaComponent(0.06),
                    .paragraphStyle: codeBlockPara,
                ],
                .listItem: [
                    .font: bodyFont,
                    .foregroundColor: NSColor.labelColor,
                ],
                .heading: [.foregroundColor: NSColor.labelColor],
                .unorderedList: [.paragraphStyle: listPara],
                .orderedList: [.paragraphStyle: listPara],
                .link: [
                    .font: bodyFont,
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ],
            ]
        )
        // Match the SwiftUI HeadingView sizes so the migration is a
        // visual no-op except for selection support.
        styles.headingPointSizes = [22, 19, 17, 15, 14, 13]
        return styles
    }
}

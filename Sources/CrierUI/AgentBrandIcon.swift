import AppKit

/// Loads vendored agent marks (SVG) from SPM’s resource bundle, the host
/// `.app`’s `Resources` (where `build-app.sh` copies the same SVGs), then
/// `NSImage(named:)` as a last resort.
///
/// Many icon SVGs use `1em` for width/height; AppKit often reports `{0,0}`
/// until a nominal size is assigned — do **not** treat zero size as failure.
enum AgentBrandIcon {
    private static let nominalPointSize: CGFloat = 24

    static func image(named name: String) -> NSImage? {
        let candidates: [URL?] = [
            Bundle.module.url(forResource: name, withExtension: "svg"),
            Bundle.main.url(forResource: name, withExtension: "svg"),
        ]
        for url in candidates.compactMap({ $0 }) {
            if let img = NSImage(contentsOf: url), !img.representations.isEmpty {
                normalizeSVGIntrinsicSize(img)
                return img
            }
        }
        if let img = NSImage(named: name), !img.representations.isEmpty {
            normalizeSVGIntrinsicSize(img)
            return img
        }
        return nil
    }

    private static func normalizeSVGIntrinsicSize(_ img: NSImage) {
        if img.size.width < 1 || img.size.height < 1 {
            img.size = NSSize(width: nominalPointSize, height: nominalPointSize)
        }
    }
}

import AppKit

/// Neutral system-symbol mark for the OMP Usage fork.
@MainActor
enum MenuBarIcon {
    /// Side length (points) of the menu bar glyph.
    private static let side: CGFloat = 18

    /// Cached template image.
    static let image: NSImage? = render()

    private static func render() -> NSImage? {
        guard let image = NSImage(systemSymbolName: "chart.bar", accessibilityDescription: "OMP Usage") else {
            return nil
        }
        image.size = NSSize(width: side, height: side)
        image.isTemplate = true
        return image
    }
}

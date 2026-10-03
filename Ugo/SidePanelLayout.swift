import CoreGraphics

/// The sidebar's width for a given window width. It keeps the width the user
/// chose and the editor takes the rest; a narrow window squeezes it toward its minimum.
enum SidePanelLayout {
    static let range: ClosedRange<CGFloat> = 200...420
    static let defaultWidth: CGFloat = 272
    /// What the sidebar leaves the editor for as long as it can still give way.
    static let editorMinimum: CGFloat = 480
    /// The hairline after the sidebar.
    static let divider: CGFloat = 1

    static func width(total: CGFloat, preferred: CGFloat) -> CGFloat {
        let room = total - editorMinimum - divider
        return max(range.lowerBound, min(clamp(preferred, to: range), room)).rounded(.down)
    }

    static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The typeface of note titles, picked in Settings: one of the system's own
/// designs, or any font family installed on this Mac by name.
enum TitleFont {
    static let familyKey = "titleFontFamily"
    static let weightKey = "titleFontWeight"

    /// Stored names for the system designs. Anything else is a family name.
    static let system = "system"
    static let rounded = "rounded"
    static let serif = "serif"
    static let monospaced = "monospaced"

    static let defaultFamily = serif
    static let defaultWeight = Weight.medium.rawValue

    static let builtIn: [(id: String, name: String)] = [
        (system, "San Francisco"),
        (rounded, "San Francisco Rounded"),
        (serif, "New York"),
        (monospaced, "SF Mono"),
    ]

    enum Weight: String, CaseIterable, Identifiable {
        case light, regular, medium, semibold, bold, heavy

        var id: String { rawValue }
        var name: String { rawValue.capitalized }

        var font: Font.Weight {
            switch self {
            case .light: .light
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            case .heavy: .heavy
            }
        }
    }

    static func font(family: String, weight: String, size: CGFloat) -> Font {
        let w = (Weight(rawValue: weight) ?? .medium).font
        switch family {
        case system: return .system(size: size, weight: w)
        case rounded: return .system(size: size, weight: w, design: .rounded)
        case serif: return .system(size: size, weight: w, design: .serif)
        case monospaced: return .system(size: size, weight: w, design: .monospaced)
        default: return .custom(family, size: size).weight(w)
        }
    }

    #if os(macOS)
    /// Every family installed on this Mac, without the hidden system ones.
    static let installedFamilies: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    #endif
}

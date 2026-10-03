import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The look of the whole window, picked in Settings. System follows the
/// macOS appearance with the system colours; the others fix their own.
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case paper
    case midnight
    case ugo
    case ink

    static let storageKey = "theme"

    var id: String { rawValue }

    static func stored(_ raw: String) -> AppTheme { AppTheme(rawValue: raw) ?? .system }

    var name: String {
        switch self {
        case .system: "System"
        case .paper: "Paper"
        case .midnight: "Midnight"
        case .ugo: "Ugo"
        case .ink: "Ink"
        }
    }

    var summary: String {
        switch self {
        case .system: "Follows macOS"
        case .paper: "Warm light"
        case .midnight: "Navy, soft blue"
        case .ugo: "Graphite, nose red"
        case .ink: "Black, no colour"
        }
    }

    /// nil follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .paper: .light
        case .midnight, .ugo, .ink: .dark
        }
    }

    /// nil for System, which keeps the platform's own colours and materials.
    var palette: ThemePalette? {
        switch self {
        case .system: nil
        case .paper: ThemePalette(
            editor: 0xFBFAF7, side: 0xF0EEE8, list: 0xF6F4EF, selection: 0xE3E0D7, highlight: 0xD6CFBE,
            text: 0x2B2A27, heading: 0x1F1E1B, muted: 0x8F8C84, hairline: 0xE4E1D9,
            tabActive: 0xE6E2D8, accent: 0x3A3A38, onAccent: 0xFBFAF7, checkboxBorder: 0xBDB9AF,
            quoteBar: 0xD6D2C7, code: 0xEFEDE6, link: 0x3A3A38, caret: 0x2B2A27)
        case .midnight: ThemePalette(
            editor: 0x141925, side: 0x10141E, list: 0x171D2A, selection: 0x26304A, highlight: 0x2F3F66,
            text: 0xD8DEE9, heading: 0xECEFF4, muted: 0x6E7A91, hairline: 0x232B3C,
            tabActive: 0x1F2A42, accent: 0x88A8D8, onAccent: 0x141925, checkboxBorder: 0x4C5670,
            quoteBar: 0x3A4764, code: 0x1E2536, link: 0x9DB9E4, caret: 0x88A8D8)
        case .ugo: ThemePalette(
            editor: 0x1F1F22, side: 0x2E2E31, list: 0x262629, selection: 0x3E3436, highlight: 0x5C2E34,
            text: 0xE6E4E0, heading: 0xFFFFFF, muted: 0x8C8A90, hairline: 0x36363A,
            tabActive: 0x3A2427, accent: 0xE63946, onAccent: 0xFFFFFF, checkboxBorder: 0x5A585E,
            quoteBar: 0xE63946, code: 0x2B2B2F, link: 0xFF6B75, caret: 0xE63946)
        case .ink: ThemePalette(
            editor: 0x111111, side: 0x0B0B0B, list: 0x141414, selection: 0x262626, highlight: 0x383838,
            text: 0xCFCFCF, heading: 0xFFFFFF, muted: 0x6B6B6B, hairline: 0x1F1F1F,
            tabActive: 0x1E1E1E, accent: 0xE5E5E5, onAccent: 0x111111, checkboxBorder: 0x4A4A4A,
            quoteBar: 0x3A3A3A, code: 0x1C1C1C, link: 0xE5E5E5, caret: 0xFFFFFF)
        }
    }

    /// The colours the Settings preview draws. System shows the macOS look for the current appearance.
    func previewPalette(for scheme: ColorScheme) -> ThemePalette {
        if let palette { return palette }
        return scheme == .dark
            ? ThemePalette(
                editor: 0x1E1E1E, side: 0x2A2A2C, list: 0x232325, selection: 0x3A3A3D, highlight: 0x0A5FC9,
                text: 0xE6E6E8, heading: 0xFFFFFF, muted: 0x8E8E93, hairline: 0x333336,
                tabActive: 0x1D3350, accent: 0x0A84FF, onAccent: 0xFFFFFF, checkboxBorder: 0x5E5E63,
                quoteBar: 0x48484C, code: 0x2C2C2E, link: 0x4FA3FF, caret: 0x0A84FF)
            : ThemePalette(
                editor: 0xFFFFFF, side: 0xEDEDEF, list: 0xF7F7F8, selection: 0xDCDCE0, highlight: 0x0A6CE8,
                text: 0x1D1D1F, heading: 0x1D1D1F, muted: 0x86868B, hairline: 0xE3E3E6,
                tabActive: 0xE8F0FD, accent: 0x007AFF, onAccent: 0xFFFFFF, checkboxBorder: 0xB8B8BD,
                quoteBar: 0xD1D1D6, code: 0xF1F1F3, link: 0x0A66D6, caret: 0x007AFF)
    }

    #if os(macOS)
    /// Sets the whole app's appearance, so menus, the Settings window and the
    /// system colours the views still use match the theme.
    @MainActor func applyAppearance() {
        switch colorScheme {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
    #endif
}

/// A fixed theme's colours as 0xRRGGBB.
struct ThemePalette: Equatable {
    var editor: UInt32
    /// The sidebar.
    var side: UInt32
    /// Quick open's panel.
    var list: UInt32
    var selection: UInt32
    /// Behind the open note in the sidebar, stronger than `selection`.
    var highlight: UInt32
    var text: UInt32
    var heading: UInt32
    var muted: UInt32
    var hairline: UInt32
    /// The focused pane's active tab.
    var tabActive: UInt32
    /// Ticked checkboxes, and the tint of controls.
    var accent: UInt32
    /// The tick drawn on an accent-filled checkbox.
    var onAccent: UInt32
    var checkboxBorder: UInt32
    var quoteBar: UInt32
    var code: UInt32
    var link: UInt32
    var caret: UInt32
}

extension PlatformColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue: ThemePalette? = nil
}

extension EnvironmentValues {
    /// The fixed theme's colours, or nil while the theme is System.
    var palette: ThemePalette? {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

extension View {
    /// Paints a pane with the theme's colour for it; under System the pane keeps its own background.
    @ViewBuilder func paneBackground(_ hex: UInt32?) -> some View {
        if let hex {
            self.scrollContentBackground(.hidden).background(Color(hex: hex))
        } else {
            self
        }
    }

    /// The theme's text colour as the primary style, so .secondary and .tertiary derive from it.
    @ViewBuilder func themedText(_ palette: ThemePalette?) -> some View {
        if let palette {
            self.foregroundStyle(Color(hex: palette.text)).tint(Color(hex: palette.accent))
        } else {
            self
        }
    }
}

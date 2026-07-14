import SwiftUI

struct ThemeOption: Identifiable, Equatable {
    let id: String
    let name: String
    let cost: Int
    let brass: Color
    let brassDim: Color
    let glow: Color
}

enum AppearanceMode: String, Codable {
    case dark
    case light
}

enum Palette {
    // Dark theme colors
    static let ink = Color(hex: "12161B")
    static let ink2 = Color(hex: "1A2028")
    static let ink3 = Color(hex: "232B35")
    static let inkLine = Color(hex: "293240")
    static let green = Color(hex: "4C7A63")
    static let greenGlow = Color(hex: "6FA487")
    static let red = Color(hex: "B24444")
    static let text = Color(hex: "EDEAE2")
    static let textDim = Color(hex: "8F97A3")
    static let textFaint = Color(hex: "5B6270")
    static let background = Color(hex: "05070A")
    
    // Light theme colors
    static let lightInk = Color(hex: "F5F3ED")
    static let lightInk2 = Color(hex: "EDEAE2")
    static let lightInk3 = Color(hex: "E3DFD5")
    static let lightInkLine = Color(hex: "D4CFC2")
    static let lightGreen = Color(hex: "3D6350")
    static let lightGreenGlow = Color(hex: "5A9277")
    static let lightRed = Color(hex: "A63939")
    static let lightText = Color(hex: "1A1714")
    static let lightTextDim = Color(hex: "5A5651")
    static let lightTextFaint = Color(hex: "938E85")
    static let lightBackground = Color(hex: "FDFCF9")

    static let themes: [ThemeOption] = [
        ThemeOption(id: "brass", name: "Brass", cost: 0, brass: Color(hex: "C4903F"), brassDim: Color(hex: "8C6A34"), glow: Color(hex: "E5B667")),
        ThemeOption(id: "jade", name: "Jade", cost: 20, brass: Color(hex: "3F8C63"), brassDim: Color(hex: "2C6248"), glow: Color(hex: "63B587")),
        ThemeOption(id: "crimson", name: "Crimson", cost: 35, brass: Color(hex: "B2454A"), brassDim: Color(hex: "7E2F33"), glow: Color(hex: "DA6C70")),
        ThemeOption(id: "silver", name: "Silver", cost: 50, brass: Color(hex: "8A93A0"), brassDim: Color(hex: "5F6670"), glow: Color(hex: "C4CAD3")),
        ThemeOption(id: "violet", name: "Violet", cost: 70, brass: Color(hex: "7A5FB0"), brassDim: Color(hex: "54407D"), glow: Color(hex: "A688D6")),
    ]

    static func theme(for id: String) -> ThemeOption {
        themes.first(where: { $0.id == id }) ?? themes[0]
    }
    
    // Dynamic color accessors based on appearance mode
    static func ink(for mode: AppearanceMode) -> Color {
        mode == .dark ? ink : lightInk
    }
    
    static func ink2(for mode: AppearanceMode) -> Color {
        mode == .dark ? ink2 : lightInk2
    }
    
    static func ink3(for mode: AppearanceMode) -> Color {
        mode == .dark ? ink3 : lightInk3
    }
    
    static func inkLine(for mode: AppearanceMode) -> Color {
        mode == .dark ? inkLine : lightInkLine
    }
    
    static func green(for mode: AppearanceMode) -> Color {
        mode == .dark ? green : lightGreen
    }
    
    static func greenGlow(for mode: AppearanceMode) -> Color {
        mode == .dark ? greenGlow : lightGreenGlow
    }
    
    static func red(for mode: AppearanceMode) -> Color {
        mode == .dark ? red : lightRed
    }
    
    static func text(for mode: AppearanceMode) -> Color {
        mode == .dark ? text : lightText
    }
    
    static func textDim(for mode: AppearanceMode) -> Color {
        mode == .dark ? textDim : lightTextDim
    }
    
    static func textFaint(for mode: AppearanceMode) -> Color {
        mode == .dark ? textFaint : lightTextFaint
    }
    
    static func background(for mode: AppearanceMode) -> Color {
        mode == .dark ? background : lightBackground
    }
}

extension Color {
    init(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)
        let r = Double((rgb & 0xFF0000) >> 16) / 255
        let g = Double((rgb & 0x00FF00) >> 8) / 255
        let b = Double(rgb & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// Fonts: bundle "Fraunces" + "IBM Plex Mono" if desired; falls back to system serif/mono.
enum AppFont {
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Appearance Mode Helpers

/// Environment key for appearance mode
struct AppearanceModeKey: EnvironmentKey {
    static let defaultValue: AppearanceMode = .dark
}

extension EnvironmentValues {
    var appearanceMode: AppearanceMode {
        get { self[AppearanceModeKey.self] }
        set { self[AppearanceModeKey.self] = newValue }
    }
}

extension View {
    /// Helper to get colors that adapt to the current appearance mode from store state
    func adaptiveColors(for mode: AppearanceMode) -> AdaptivePalette {
        AdaptivePalette(mode: mode)
    }
}

struct AdaptivePalette {
    let mode: AppearanceMode
    
    var ink: Color { Palette.ink(for: mode) }
    var ink2: Color { Palette.ink2(for: mode) }
    var ink3: Color { Palette.ink3(for: mode) }
    var inkLine: Color { Palette.inkLine(for: mode) }
    var green: Color { Palette.green(for: mode) }
    var greenGlow: Color { Palette.greenGlow(for: mode) }
    var red: Color { Palette.red(for: mode) }
    var text: Color { Palette.text(for: mode) }
    var textDim: Color { Palette.textDim(for: mode) }
    var textFaint: Color { Palette.textFaint(for: mode) }
    var background: Color { Palette.background(for: mode) }
}

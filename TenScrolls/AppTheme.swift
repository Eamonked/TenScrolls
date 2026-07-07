import SwiftUI

struct ThemeOption: Identifiable, Equatable {
    let id: String
    let name: String
    let cost: Int
    let brass: Color
    let brassDim: Color
    let glow: Color
}

enum Palette {
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

import SwiftUI

struct ThemeOption: Identifiable, Equatable {
    let id: String
    let name: String
    let cost: Int
    let brass: Color
    let brassDim: Color
    let glow: Color
}

enum AppearanceMode: String, Codable, CaseIterable {
    case light
    case dark
    case system

    /// Resolves `.system` to the concrete `.dark`/`.light` case based on the
    /// device's current system color scheme. `.dark` and `.light` pass through
    /// unchanged. Everything downstream (Palette, AdaptivePalette) only ever
    /// deals in concrete dark/light — this is the single place `.system` gets
    /// resolved away.
    func resolved(systemColorScheme: ColorScheme) -> AppearanceMode {
        switch self {
        case .system: return systemColorScheme == .dark ? .dark : .light
        case .dark, .light: return self
        }
    }

    var label: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .system: return "System"
        }
    }

    var iconName: String {
        switch self {
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
        case .system: return "circle.lefthalf.filled"
        }
    }
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

    /// Injects the resolved appearance mode into the environment for this view
    /// subtree. Takes the raw, possibly-`.system` mode as persisted in
    /// `AppState` and resolves it against the device's live system color
    /// scheme before publishing it — every consumer downstream (via
    /// `@Environment(\.appearanceMode)`) then only ever sees concrete
    /// `.dark`/`.light`. Use this instead of `.environment(\.appearanceMode, _)`
    /// directly at any presentation boundary (sheets, full-screen covers, etc.)
    /// where the environment needs to be re-published.
    func injectAppearanceMode(_ rawMode: AppearanceMode) -> some View {
        modifier(AppearanceModeInjector(rawMode: rawMode))
    }
}

private struct AppearanceModeInjector: ViewModifier {
    @Environment(\.colorScheme) private var systemColorScheme
    let rawMode: AppearanceMode

    func body(content: Content) -> some View {
        content.environment(\.appearanceMode, rawMode.resolved(systemColorScheme: systemColorScheme))
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

// MARK: - $500 Club — Lux Design System
//
// Additive design system for the rebuilt Today/Scrolls/Journal/Caravan/Reader
// views. Deliberately namespaced under `Lux*` rather than replacing
// `Palette`/`AppFont`/`AdaptivePalette` above — Library and PDF still read
// those directly, and rewriting them wasn't in scope.
//
// Unlike `Palette`/`AdaptivePalette` (which need an explicit `mode` passed
// in), every `LuxColor.*` token below is a *dynamic* `Color`: it resolves
// itself to a light or dark value at render time from the active trait
// collection, via `Color.lux(light:dark:)`. That trait collection is kept
// in sync with `\.colorScheme`, which is in turn driven by the app's own
// `AppearanceMode` — for `.light`/`.dark` via the root
// `.preferredColorScheme(...)` set in `TenScrollsApp`, and for `.system` by
// the live system appearance. Practically: nothing downstream needs to read
// `\.appearanceMode` or thread a palette instance through — every call site
// that already writes `LuxColor.gold`/`LuxColor.bg`/etc. just adapts.
//
// `ScrollReaderView` (the reading surface itself) is the one place that
// can't lean on this trick alone — its body text is rendered inside a
// `WKWebView` via `BookChapterWebView`, which builds its own HTML/CSS
// string outside SwiftUI's environment entirely. That view reads
// `\.appearanceMode` explicitly and threads the resolved mode through to
// both the shared `AdaptivePalette`-based document chrome and
// `ScrollReaderView.scrollHTML`'s own light/dark text-color literals, so
// it adapts too — just via an explicit mode rather than a dynamic `Color`.
private extension Color {
    /// Builds a `Color` that resolves to `light` or `dark` at render time
    /// based on the active appearance, rather than being fixed at
    /// construction time like a plain `Color(hex:)` value.
    static func lux(light: Color, dark: Color) -> Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #elseif canImport(AppKit)
        return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        }))
        #else
        return dark
        #endif
    }
}

enum LuxColor {
    static let bg = Color.lux(light: Color(hex: "FAF8F2"), dark: Color(hex: "05070A"))
    static let card = Color.lux(light: Color(hex: "FFFFFF"), dark: Color(hex: "0F1218"))
    static let cardBorder = Color.lux(light: Color(hex: "E5DFD1"), dark: Color(hex: "1C212E"))
    /// The inner hairline along a card's top edge — a sliver of warm gold,
    /// not a full stroke. Use with `.frame(height: 1)` pinned to the top.
    static let hairlineTop = Color.lux(light: Color(hex: "AD8636"), dark: Color(hex: "C49A5C")).opacity(0.125)
    static let textPrimary = Color.lux(light: Color(hex: "1B1712"), dark: Color(hex: "F5F2ED"))
    static let textSecondary = Color.lux(light: Color(hex: "6C665A"), dark: Color(hex: "8A877E"))
    static let textMuted = Color.lux(light: Color(hex: "AFA997"), dark: Color(hex: "4A4842"))
    /// Brand gold — kept constant across both modes; it reads correctly on
    /// both the near-black and parchment backgrounds.
    static let gold = Color(hex: "D4AF37")
    static let goldMuted = Color.lux(light: Color(hex: "6E5A2C"), dark: Color(hex: "8C7A4F"))
    static let goldBg = Color(hex: "D4AF37").opacity(0.078)
    /// Success state reuses gold — this palette has no green.
    static let success = gold
    static let divider = cardBorder.opacity(0.5)
}

/// Font helpers for the Lux system. Names point at Cormorant Garamond,
/// Inter, and JetBrains Mono — add those families to the target (Info.plist
/// `UIAppFonts` + the font files themselves) for the intended look.
///
/// None of those three are currently bundled in the project (no .ttf/.otf
/// files, no `UIAppFonts` entry), so every call below was silently falling
/// back to the system font anyway — but `Font.custom(name:size:).weight(_:)`
/// still asked CoreText to synthesize a specific weight against a font
/// descriptor for a family that doesn't exist. CoreText can't do that (this
/// isn't a variable font, and there's no font there at all right now), so it
/// logs "Unable to update Font Descriptor's weight ... please file a bug
/// report" on every single call — that's the console spam. `resolved` below
/// checks with `UIFont(name:size:)` whether the named face is actually
/// present before deciding how to build the `Font`:
///   - present  -> `.custom(name, size:)` with NO `.weight()` chained (the
///                 weight is already baked into which named face was asked
///                 for; chaining `.weight()` on a static face is exactly
///                 what triggers the synthesis warning even when the font
///                 IS bundled).
///   - missing  -> `.system(size:weight:design:)`, where `.weight()` is
///                 meaningful and produces no warning.
/// Once real font files get added to the target, these calls will pick them
/// up automatically — the exact PostScript names below (e.g. "Inter-Medium")
/// need to match whatever the actual font files register as; check with
/// `UIFont.fontNames(forFamilyName:)` once they're bundled.
enum LuxFont {
    private static func resolved(_ name: String, size: CGFloat, fallbackWeight: Font.Weight, design: Font.Design) -> Font {
        #if canImport(UIKit)
        if UIFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        #endif
        return .system(size: size, weight: fallbackWeight, design: design)
    }

    /// Cormorant Garamond Light, for titles. `tracking(-0.5)` at the call
    /// site approximates the spec's -0.02em at typical title sizes.
    static func serif(_ size: CGFloat, weight: Font.Weight = .light) -> Font {
        resolved("CormorantGaramond-Light", size: size, fallbackWeight: weight, design: .serif)
    }
    /// Inter, for uppercase tracked labels (10pt) and regular body (13pt).
    /// Weight is folded into the requested PostScript name since static
    /// font files can't be reweighted after the fact.
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .semibold, .bold, .heavy, .black: name = "Inter-SemiBold"
        case .medium: name = "Inter-Medium"
        default: name = "Inter-Regular"
        }
        return resolved(name, size: size, fallbackWeight: weight, design: .default)
    }
    /// JetBrains Mono Light, for numbers/codes, tabular where the OS honors it.
    static func mono(_ size: CGFloat, weight: Font.Weight = .light) -> Font {
        resolved("JetBrainsMono-Light", size: size, fallbackWeight: weight, design: .monospaced).monospacedDigit()
    }
}

enum LuxMotion {
    static let standard = Animation.easeInOut(duration: 0.8)
}

extension View {
    /// A label-style uppercase tracked caption in Lux's muted gold — the
    /// small "DAY 17 OF 300" / "ACTIVE SCROLL" / "SEALS" treatment used
    /// throughout the rebuilt views.
    func luxEyebrow(color: Color = LuxColor.goldMuted, tracking: CGFloat = 1.8) -> some View {
        self.font(LuxFont.sans(10, weight: .medium)).tracking(tracking).foregroundColor(color)
    }
}


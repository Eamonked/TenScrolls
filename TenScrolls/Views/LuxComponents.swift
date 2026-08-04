import SwiftUI

// MARK: - $500 Club — shared Lux components
//
// Backs the rebuilt TodayView / ScrollsView / JournalView / CaravanView /
// scroll reader. Additive alongside `CardView`/`SacredCard`/etc. in
// Components.swift — nothing here replaces those, so views that weren't
// part of this pass (Library, PDF reader, Settings, paywalls, widgets)
// keep working unchanged.

// MARK: Noise texture

/// A cheap, seeded 3%-opacity noise overlay for cards — the grain that keeps
/// large flat dark surfaces from looking like a plain color fill. Drawn with
/// `Canvas` rather than a bundled image asset so it costs nothing to ship
/// and scales to any card size. The seed is fixed so the same card doesn't
/// re-randomize its grain every redraw (which would read as flicker).
struct NoiseTextureView: View {
    @Environment(\.colorScheme) private var colorScheme
    var opacity: Double = 0.03
    var body: some View {
        Canvas { context, size in
            var generator = SeededGenerator(seed: 1_009)
            let dotCount = Int((size.width * size.height) / 9)
            let dotColor: Color = colorScheme == .dark ? .white : .black
            for _ in 0..<dotCount {
                let x = Double.random(in: 0...size.width, using: &generator)
                let y = Double.random(in: 0...size.height, using: &generator)
                let shade = Double.random(in: 0.4...1.0, using: &generator)
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)),
                    with: .color(dotColor.opacity(shade))
                )
            }
        }
        // Dark cards get lightened grain (`.plusLighter`); light cards get
        // darkened grain (`.plusDarker`) — additive-white noise over a
        // near-white card would otherwise be invisible.
        .opacity(opacity)
        .allowsHitTesting(false)
        .blendMode(colorScheme == .dark ? .plusLighter : .plusDarker)
    }
}

/// Deterministic RNG so `NoiseTextureView`'s grain is stable across redraws
/// instead of re-rolling (and visibly flickering) on every view update.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

// MARK: - Card

/// The base $500-club card: deep ink fill, 20pt corner radius, a hairline
/// gold sliver along the top edge, faint grain, and a soft long shadow.
/// Use for hero cards (the active-scroll card on Today, "Your Mark" on
/// Caravan); use `LuxRowCard` for the smaller list-row cards.
struct LuxCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = 20
    var showsNoise: Bool = true
    var fill: Color = LuxColor.card
    let content: Content
    init(cornerRadius: CGFloat = 20, showsNoise: Bool = true, fill: Color = LuxColor.card, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.showsNoise = showsNoise
        self.fill = fill
        self.content = content()
    }
    var body: some View {
        content
            .padding(18)
            .background(
                ZStack {
                    fill
                    if showsNoise { NoiseTextureView() }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(LuxColor.cardBorder, lineWidth: 1)
            )
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: cornerRadius / 2)
                    .fill(LuxColor.hairlineTop)
                    .frame(height: 1)
                    .padding(.horizontal, cornerRadius)
                    .padding(.top, 0.5)
            }
            // A near-black 60%-opacity shadow reads as a soft glow on a
            // near-black background but as a heavy smudge on a white one —
            // scale it down (and tighten the blur) in light mode instead.
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.6 : 0.12), radius: colorScheme == .dark ? 32 : 16, x: 0, y: colorScheme == .dark ? 12 : 6)
    }
}

/// A smaller, denser card for list rows (habits, duels, journal entries) —
/// same materials as `LuxCard` at a smaller corner radius, no noise (grain
/// on many small rows reads as visual noise rather than texture).
struct LuxRowCard<Content: View>: View {
    var cornerRadius: CGFloat = 16
    let content: Content
    init(cornerRadius: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }
    var body: some View {
        content
            .background(LuxColor.card)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(LuxColor.cardBorder, lineWidth: 0.5)
            )
    }
}

// MARK: - Divider

struct LuxDivider: View {
    var body: some View {
        Rectangle().fill(LuxColor.divider).frame(height: 0.5)
    }
}

// MARK: - Buttons

/// The single filled button style permitted per screen: solid gold, black
/// text, 48pt tall, 12pt tracked uppercase label.
struct LuxPrimaryButtonStyle: ButtonStyle {
    var disabled: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LuxFont.sans(12, weight: .semibold))
            .tracking(1.2)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(configuration.isPressed ? LuxColor.gold.opacity(0.85) : LuxColor.gold)
            .foregroundColor(.black)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(disabled ? 0.4 : 1)
    }
}

/// A bordered "ghost" button — ornamental gold hairline, no fill. Used for
/// secondary actions ("Continue the current scroll", "Add today's reflection").
struct LuxGhostButtonStyle: ButtonStyle {
    var borderColor: Color = LuxColor.goldMuted
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .foregroundColor(LuxColor.textPrimary)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(borderColor.opacity(configuration.isPressed ? 0.9 : 0.5), lineWidth: 0.5)
            )
    }
}

// MARK: - Breathing dot

/// A small pulsing gold dot — used at the foot of the reader to signal
/// "no rush, take your time" without a spinner or a progress bar.
struct BreathingDot: View {
    @State private var lit = false
    var body: some View {
        Circle()
            .fill(LuxColor.gold)
            .frame(width: 4, height: 4)
            .opacity(lit ? 1 : 0.35)
            .onAppear {
                withAnimation(LuxMotion.standard.repeatForever(autoreverses: true)) {
                    lit = true
                }
            }
    }
}

// MARK: - Level ring

/// The 40pt rank ring in Today's header: a gold progress stroke around a
/// rank letter/numeral, in place of the old filled circle + number badge.
struct LevelRingView: View {
    let progress: Double // 0...1
    let label: String
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            Circle().stroke(LuxColor.cardBorder, lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(LuxColor.gold, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(label)
                .font(LuxFont.mono(12, weight: .regular))
                .foregroundColor(LuxColor.gold)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Seals pill

struct SealsPillView: View {
    let count: Int
    var body: some View {
        HStack(spacing: 4) {
            Text("\(count)").font(LuxFont.mono(12))
                .foregroundColor(LuxColor.gold)
            Text("SEALS").font(LuxFont.sans(8, weight: .medium)).tracking(1.2)
                .foregroundColor(LuxColor.textSecondary)
        }
    }
}

// MARK: - Checkbox

/// A 28pt circular checkbox — stone hairline when empty, filled gold with a
/// black check when done. Replaces the old rounded-square habit checkbox.
struct LuxCheckbox: View {
    let done: Bool
    var size: CGFloat = 28
    var body: some View {
        ZStack {
            Circle()
                .fill(done ? LuxColor.gold : Color.clear)
                .overlay(Circle().stroke(done ? LuxColor.gold : LuxColor.textMuted, lineWidth: 0.5))
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundColor(.black)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Section eyebrow + title, shared header shape

/// The "EYEBROW LABEL" + "Serif Title" header pattern repeated at the top
/// of every rebuilt screen (Today, Scrolls, Journal, Caravan).
struct LuxScreenHeader: View {
    let eyebrow: String
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(eyebrow).luxEyebrow()
            Text(title)
                .font(LuxFont.serif(32))
                .tracking(-0.3)
                .foregroundColor(LuxColor.textPrimary)
        }
    }
}

/// A small circular icon button (36–40pt) with a hairline border — used for
/// the header's utility icons (bell, info, search, compose) across every
/// rebuilt screen.
struct LuxIconButton: View {
    let systemImage: String
    var size: CGFloat = 36
    var tinted: Bool = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .light))
                .foregroundColor(tinted ? LuxColor.gold : LuxColor.textSecondary)
                .frame(width: size, height: size)
                .background(Circle().fill(LuxColor.card))
                .overlay(Circle().stroke(LuxColor.cardBorder, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Empty row (no big padded empty card)

/// A single centered line for "nothing here yet" states — deliberately not
/// a big empty `LuxCard`, per the brief's "no empty cards with big padding".
struct LuxEmptyLine: View {
    let text: String
    var height: CGFloat = 40
    var body: some View {
        Text(text)
            .font(LuxFont.sans(10, weight: .medium))
            .tracking(0.6)
            .foregroundColor(LuxColor.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .multilineTextAlignment(.center)
    }
}

// MARK: - Roman numerals

/// Small integer -> Roman numeral, used throughout the Lux screens for the
/// "DAY XVI OF XXX" / "VIII DAY STREAK" numeral treatment. Falls back to the
/// plain Arabic string above 3999 (never hit in this app's ranges).
enum Roman {
    private static let table: [(Int, String)] = [
        (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
        (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
        (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")
    ]
    static func from(_ n: Int) -> String {
        guard n > 0, n < 4000 else { return "\(n)" }
        var remaining = n
        var result = ""
        for (value, symbol) in table {
            while remaining >= value {
                result += symbol
                remaining -= value
            }
        }
        return result
    }
}


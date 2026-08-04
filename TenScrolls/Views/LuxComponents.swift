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
            // See `LuxColor.cardShadow`'s doc comment for why this scales
            // per mode rather than using one constant opacity/blur.
            .shadow(color: LuxColor.cardShadow, radius: colorScheme == .dark ? 32 : 16, x: 0, y: colorScheme == .dark ? 12 : 6)
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
            .foregroundColor(LuxColor.goldText)
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
                    .foregroundColor(LuxColor.goldText)
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

// MARK: - Reflection book card
//
// Today's single "add" entry point (habit or reflection, disambiguated by
// `TodayView`'s confirmation dialog). Replaces the earlier plain ghost-text
// button with a rendered leather-book-and-quill illustration, drawn entirely
// from SwiftUI shapes/gradients — no image asset — consistent with
// `NoiseTextureView`'s Canvas-drawn grain elsewhere in this file.
struct LuxReflectionBookCard: View {
    let subtitle: String
    let action: () -> Void

    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 16) {
                BookIllustration()
                    .frame(width: 190, height: 168)
                    .scaleEffect(pressed ? 0.97 : 1)
                Text(subtitle.uppercased())
                    .font(LuxFont.sans(10, weight: .medium))
                    .tracking(0.8)
                    .foregroundColor(LuxColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
        .animation(LuxMotion.standard, value: pressed)
    }
}

/// The book-and-quill graphic itself: a fanned page edge behind a worn
/// oxblood-leather cover — raised spine ridges, blind-stamped (not gilt)
/// inner border, brass corner protectors, foil-stamped "TAP TO WRITE
/// REFLECTION..." serif text, and a ribbon bookmark trapped in the pages —
/// with a feather quill resting diagonally across the lower-right corner.
private struct BookIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                pages(w: w, h: h)
                cover(w: w, h: h)
                ribbon(w: w, h: h)
                quill(w: w, h: h)
            }
            .frame(width: w, height: h)
        }
    }

    /// Thin fanned page-edge peeking out from behind the cover's right side.
    private func pages(w: CGFloat, h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(
                LinearGradient(colors: [Color(hex: "EFE3C4"), Color(hex: "DDCC9C")],
                               startPoint: .leading, endPoint: .trailing)
            )
            .frame(width: w * 0.9, height: h * 0.84)
            .position(x: w * 0.53, y: h * 0.51)
            .shadow(color: .black.opacity(0.2), radius: 3, x: 1, y: 2)
    }

    private func cover(w: CGFloat, h: CGFloat) -> some View {
        let bw = w * 0.86, bh = h * 0.8
        return ZStack {
            // Base hide — deep oxblood-brown leather, not flat gold.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "6B3423"), Color(hex: "4A2418"), Color(hex: "2A130C")],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(hex: "1B0B06").opacity(0.75), lineWidth: 1)
                )

            // Leather grain, reusing the card noise texture at a finer, darker setting.
            NoiseTextureView(opacity: 0.07)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Raised spine ridges — the ribs of a hand-bound volume.
            spineRidges(bw: bw, bh: bh)

            // Blind-stamped inner border — pressed into the leather, not gilt.
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.black.opacity(0.45), lineWidth: 1)
                .padding(12)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color(hex: "8C5A3C").opacity(0.3), lineWidth: 0.5)
                .padding(13)

            // Worn brass corner protectors.
            ForEach(0..<4, id: \.self) { i in
                BrassCorner()
                    .rotationEffect(.degrees(Double(i) * 90))
                    .position(cornerPoint(i, bw: bw, bh: bh))
            }

            // Foil-stamped title: a soft dark under-shadow plus a hairline
            // bright highlight, offset by half a point in each direction,
            // reads as gold leaf pressed into leather rather than a flat fill.
            ZStack {
                titleText.foregroundColor(.black.opacity(0.4)).offset(y: 0.75)
                titleText.foregroundColor(Color(hex: "F5DFA0").opacity(0.35)).offset(y: -0.5)
                titleText.foregroundColor(Color(hex: "D9B36C"))
            }
        }
        .frame(width: bw, height: bh)
        .shadow(color: .black.opacity(0.34), radius: 10, x: 0, y: 8)
        .position(x: w / 2, y: h / 2)
    }

    private var titleText: some View {
        VStack(spacing: 5) {
            Text("TAP TO")
            Text("WRITE")
            Text("REFLECTION\u{2026}")
        }
        .font(LuxFont.serif(15))
        .tracking(1.2)
        .multilineTextAlignment(.center)
    }

    /// Horizontal raised bands across the spine (left edge of the cover),
    /// each a tight highlight/shadow pair rather than a flat stripe, so
    /// they read as ribs rather than paint.
    private func spineRidges(bw: CGFloat, bh: CGFloat) -> some View {
        let spineWidth = bw * 0.16
        return VStack(spacing: bh * 0.10) {
            ForEach(0..<5, id: \.self) { _ in
                VStack(spacing: 1) {
                    Rectangle().fill(Color.black.opacity(0.4)).frame(height: 1.5)
                    Rectangle().fill(Color(hex: "8C5A3C").opacity(0.45)).frame(height: 1)
                }
            }
        }
        .frame(width: spineWidth, height: bh * 0.78)
        .position(x: bw * 0.09, y: bh / 2)
    }

    private func cornerPoint(_ i: Int, bw: CGFloat, bh: CGFloat) -> CGPoint {
        let inset: CGFloat = 13
        switch i {
        case 0: return CGPoint(x: inset, y: inset)
        case 1: return CGPoint(x: bw - inset, y: inset)
        case 2: return CGPoint(x: bw - inset, y: bh - inset)
        default: return CGPoint(x: inset, y: bh - inset)
        }
    }

    /// A ribbon bookmark trapped in the pages, its tail hanging below the
    /// bottom edge — the one warm accent color against the dark leather.
    private func ribbon(w: CGFloat, h: CGFloat) -> some View {
        let bh = h * 0.8
        let topY = (h - bh) / 2
        return VStack(spacing: 0) {
            Rectangle()
                .fill(
                    LinearGradient(colors: [Color(hex: "7A1F1F"), Color(hex: "4F1212")],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .frame(width: 7, height: h * 0.22)
            Triangle()
                .fill(Color(hex: "4F1212"))
                .rotationEffect(.degrees(180))
                .frame(width: 7, height: 6)
        }
        .position(x: w * 0.30, y: topY + bh + h * 0.08)
        .shadow(color: .black.opacity(0.2), radius: 1, x: 0.5, y: 1)
    }

    /// A feather quill — vane, shaft and nib — replacing the old ballpoint pen.
    private func quill(w: CGFloat, h: CGFloat) -> some View {
        let shaft = h * 0.6
        return ZStack {
            FeatherVane()
                .fill(
                    LinearGradient(colors: [Color(hex: "F2ECDD"), Color(hex: "D8CBA8"), Color(hex: "A99568")],
                                   startPoint: .top, endPoint: .bottom)
                )
                .overlay(
                    VStack(spacing: 2) {
                        ForEach(0..<10, id: \.self) { _ in
                            Rectangle().fill(Color(hex: "7A6640").opacity(0.3)).frame(height: 0.6)
                        }
                    }
                    .padding(.vertical, 3)
                    .clipShape(FeatherVane())
                )
                .overlay(
                    Rectangle().fill(Color(hex: "8C7A4E").opacity(0.5)).frame(width: 0.75)
                )
                .frame(width: 15, height: shaft * 0.66)
                .offset(y: -shaft * 0.2)
            Capsule()
                .fill(
                    LinearGradient(colors: [Color(hex: "EDE3C8"), Color(hex: "C7B686"), Color(hex: "8C7A4E")],
                                   startPoint: .top, endPoint: .bottom)
                )
                .frame(width: 3, height: shaft)
            Triangle()
                .fill(Color(hex: "3B2A14"))
                .frame(width: 5, height: 9)
                .offset(y: shaft / 2 + 4)
        }
        .rotationEffect(.degrees(30))
        .position(x: w * 0.83, y: h * 0.5)
        .shadow(color: .black.opacity(0.25), radius: 3, x: 2, y: 3)
    }
}

/// A worn brass corner protector — two overlapping metal triangles with a
/// visible rivet, pinned over the leather corner.
private struct BrassCorner: View {
    var body: some View {
        ZStack {
            CornerTriangle()
                .fill(
                    LinearGradient(colors: [Color(hex: "D9B36C"), Color(hex: "9C7526"), Color(hex: "5C4415")],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            CornerTriangle()
                .stroke(Color(hex: "3E2E0E").opacity(0.65), lineWidth: 0.75)
            Circle()
                .fill(Color(hex: "5C4415"))
                .frame(width: 2.5, height: 2.5)
                .offset(x: 6.5, y: 6.5)
        }
        .frame(width: 18, height: 18)
        .shadow(color: .black.opacity(0.3), radius: 1.5, x: 1, y: 1)
    }
}

private struct CornerTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// A leaf-shaped feather vane (the quill's barbs), used for the reflection
/// book's quill illustration.
private struct FeatherVane: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY),
                       control: CGPoint(x: rect.maxX, y: rect.midY))
        p.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                       control: CGPoint(x: rect.minX, y: rect.midY))
        p.closeSubpath()
        return p
    }
}

/// A simple upward-pointing triangle, used for the reflection book's quill
/// nib and the ribbon bookmark's pointed tail.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}


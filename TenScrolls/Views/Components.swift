import SwiftUI

// MARK: - Card container

struct CardView<Content: View>: View {
    @Environment(\.appearanceMode) var appearanceMode
    let content: Content
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(18)
            .background(colors.ink2)
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(colors.inkLine, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

// MARK: - Sacred container

/// A quieter, more spacious card for the ritual layer of Today — the active
/// scroll and the day's journey. Deliberately lighter chrome than `CardView`
/// (no stroke) so the reading moment doesn't compete visually with the
/// system UI (XP, seals, habits) that sits below it.
struct SacredCard<Content: View>: View {
    @Environment(\.appearanceMode) var appearanceMode
    let content: Content
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        VStack(alignment: .center, spacing: 0) { content }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .background(colors.ink2.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 22))
    }
}

/// A small ornamental divider marking the boundary between the Sacred layer
/// (the ritual — reading) and the System layer (XP, seals, habits) below it.
struct RitualDivider: View {
    @Environment(\.appearanceMode) var appearanceMode
    let label: String
    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        HStack(spacing: 10) {
            Rectangle().fill(colors.inkLine).frame(height: 1)
            Text(label.uppercased())
                .font(AppFont.mono(10))
                .tracking(2)
                .foregroundColor(colors.textFaint)
                .fixedSize()
            Rectangle().fill(colors.inkLine).frame(height: 1)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Day journey (dawn / midday / dusk as a single path)

/// Replaces three disconnected stamp circles with one horizontal path the
/// day travels along — sunrise to moon, with the three sessions as waypoints.
/// Shows a live "opens in…" / "…left" countdown instead of a bare "Soon",
/// and a caption describing where the day stands right now.
struct DayJourneyPath: View {
    @Environment(\.appearanceMode) var appearanceMode
    let entry: DayEntry?
    let customPrefs: SessionWindowPrefs?
    var brass: Color
    var glow: Color
    let onToggle: (Session) -> Void

    private let nodeSize: CGFloat = 56
    private let endcapSize: CGFloat = 20

    private var doneCount: Int {
        Session.allCases.filter { entry?.isCompleted(for: $0) ?? false }.count
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let colors = AdaptivePalette(mode: appearanceMode)
            VStack(spacing: 12) {
                GeometryReader { geo in
                    let inset = endcapSize / 2
                    let usable = geo.size.width - inset * 2
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(colors.ink3)
                            .frame(height: 3)
                            .padding(.horizontal, inset)

                        Capsule()
                            .fill(LinearGradient(colors: [brass.opacity(0.75), glow], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(0, usable * (CGFloat(doneCount) / 3)), height: 3)
                            .padding(.leading, inset)

                        HStack(spacing: 0) {
                            endcap("sunrise")
                            Spacer()
                            node(.dawn, now: context.date, colors: colors)
                            Spacer()
                            node(.midday, now: context.date, colors: colors)
                            Spacer()
                            node(.dusk, now: context.date, colors: colors)
                            Spacer()
                            endcap("moon.stars.fill")
                        }
                    }
                }
                .frame(height: nodeSize)

                Text(journeyCaption(now: context.date))
                    .font(AppFont.mono(11))
                    .foregroundColor(colors.textFaint)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func endcap(_ systemImage: String) -> some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        return Image(systemName: systemImage)
            .font(.system(size: 13))
            .foregroundColor(colors.textFaint.opacity(0.6))
            .frame(width: endcapSize, height: endcapSize)
    }

    private func node(_ session: Session, now: Date, colors: AdaptivePalette) -> some View {
        let done = entry?.isCompleted(for: session) ?? false
        let status = session.windowStatus(at: now, startedAt: entry?.startedAt(for: session), customPrefs: customPrefs)
        let disabled = !done && status != .open && status != .grace

        return Button {
            onToggle(session)
        } label: {
            ZStack {
                Circle()
                    .fill(done
                        ? AnyShapeStyle(RadialGradient(colors: [glow, brass], center: .init(x: 0.35, y: 0.3), startRadius: 2, endRadius: nodeSize / 2))
                        : AnyShapeStyle(colors.ink2))
                    .overlay(Circle().stroke(done ? brass : colors.inkLine.opacity(disabled ? 0.4 : 1), lineWidth: 2))
                    .frame(width: nodeSize, height: nodeSize)
                    .overlay(
                        Image(systemName: session.systemImage)
                            .font(.system(size: 20))
                            .foregroundColor(done ? Color(hex: "1A1207") : (disabled ? colors.textFaint.opacity(0.5) : colors.textDim))
                    )
                    .shadow(color: done ? brass.opacity(0.35) : .clear, radius: 8)

                if !done, status == .closed {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundColor(Color.red.opacity(0.7))
                                .background(Circle().fill(colors.ink2).padding(-3))
                        }
                    }
                    .frame(width: nodeSize, height: nodeSize)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled && status == .upcoming ? 0.5 : 1)
    }

    private func journeyCaption(now: Date) -> String {
        guard let entry else { return "The journey begins at dawn." }
        if entry.allComplete { return "The caravan rests — today is sealed." }
        for session in Session.allCases where !entry.isCompleted(for: session) {
            if let countdown = session.countdownText(at: now, customPrefs: customPrefs) {
                return "\(session.label) \(countdown)"
            }
        }
        switch doneCount {
        case 0: return "The journey begins at dawn."
        case 1: return "One session in. Keep moving."
        default: return "Almost there — one more to go."
        }
    }
}

struct SectionLabel: View {
    @Environment(\.appearanceMode) var appearanceMode
    let text: String
    var trailing: String? = nil
    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        HStack {
            Text(text.uppercased())
                .font(AppFont.mono(11))
                .tracking(1.4)
                .foregroundColor(colors.textFaint)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(AppFont.mono(11))
                    .foregroundColor(colors.textFaint)
            }
        }
        .padding(.vertical, 6)
    }
}

struct EmptyState: View {
    @Environment(\.appearanceMode) var appearanceMode
    let text: String
    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(colors.textFaint)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
    }
}

// MARK: - Rank / level bar

struct RankBar: View {
    @Environment(\.appearanceMode) var appearanceMode
    let info: AppState.LevelInfo
    var brass: Color
    var brassDim: Color
    var glow: Color

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        CardView {
            HStack(spacing: 14) {
                Circle()
                    .fill(RadialGradient(colors: [glow, brass], center: .init(x: 0.35, y: 0.3), startRadius: 2, endRadius: 26))
                    .frame(width: 44, height: 44)
                    .overlay(Text("\(info.level)").font(AppFont.display(17, weight: .bold)).foregroundColor(Color(hex: "1A1207")))
                VStack(alignment: .leading, spacing: 6) {
                    Text(info.rank).font(AppFont.display(15))
                        .foregroundColor(colors.text)
                    ProgressTrack(pct: info.pct, brassDim: brassDim, glow: glow)
                    Text("\(info.into) / \(info.need) XP to next level")
                        .font(AppFont.mono(11))
                        .foregroundColor(colors.textFaint)
                }
            }
        }
    }
}

struct ProgressTrack: View {
    @Environment(\.appearanceMode) var appearanceMode
    let pct: Double
    var brassDim: Color
    var glow: Color
    var height: CGFloat = 6

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2).fill(colors.ink3)
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(LinearGradient(colors: [brassDim, glow], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * max(0, min(1, pct / 100)))
            }
        }
        .frame(height: height)
    }
}

// MARK: - Habit row

struct HabitRow: View {
    @Environment(\.appearanceMode) var appearanceMode
    let habit: Habit
    let done: Bool
    let streak: Int
    var green: Color?
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        let greenColor = green ?? colors.green
        HStack(spacing: 10) {
            Button(action: onToggle) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(done ? greenColor : colors.ink2)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(done ? greenColor : colors.inkLine, lineWidth: 1.5))
                    .frame(width: 22, height: 22)
                    .overlay(done ? Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundColor(.white) : nil)
            }
            .buttonStyle(.plain)
            Text(habit.name).font(.system(size: 13.5)).foregroundColor(colors.text)
            Spacer()
            Text("\(streak)d").font(AppFont.mono(11)).foregroundColor(colors.textFaint)
            Button(action: onDelete) {
                Image(systemName: "trash").font(.system(size: 12)).foregroundColor(colors.textFaint)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 9)
    }
}

// MARK: - Toast

struct ToastView: View {
    @Environment(\.appearanceMode) var appearanceMode
    let message: String
    var brass: Color
    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundColor(brass)
            Text(message).font(.system(size: 12.5)).foregroundColor(colors.text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(colors.ink2)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(brass.opacity(0.6), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
        .padding(.horizontal, 16)
    }
}

// MARK: - Text field styling

struct AppTextFieldStyle: TextFieldStyle {
    @Environment(\.appearanceMode) var appearanceMode
    func _body(configuration: TextField<Self._Label>) -> some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        configuration
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(colors.ink3)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(colors.inkLine, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .foregroundColor(colors.text)
            .font(.system(size: 13.5))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var brass: Color
    var glow: Color
    var disabled: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(configuration.isPressed ? glow : brass)
            .foregroundColor(Color(hex: "1A1207"))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .opacity(disabled ? 0.5 : 1)
    }
}

struct GhostButtonStyle: ButtonStyle {
    @Environment(\.appearanceMode) var appearanceMode
    func makeBody(configuration: Configuration) -> some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        configuration.label
            .font(.system(size: 13))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .foregroundColor(colors.textDim)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(colors.inkLine, lineWidth: 1))
    }
}

extension View {
    func hideNavigationBar() -> some View {
        #if os(iOS)
        self.navigationBarHidden(true)
        #else
        self
        #endif
    }

    func inlineNavigationBarTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

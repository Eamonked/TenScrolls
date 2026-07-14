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

// MARK: - Stamp button (dawn / midday / dusk)

struct StampButton: View {
    @Environment(\.appearanceMode) var appearanceMode
    let label: String
    let systemImage: String
    let done: Bool
    var brass: Color
    var glow: Color
    var windowStatus: SessionWindowStatus = .open
    let action: () -> Void

    private var isDisabled: Bool {
        !done && windowStatus != .open && windowStatus != .grace
    }
    
    private func statusColor(_ colors: AdaptivePalette) -> Color {
        if done { return brass }
        switch windowStatus {
        case .open, .grace: return colors.textDim
        case .upcoming: return colors.textFaint.opacity(0.5)
        case .closed: return Color.red.opacity(0.6)
        }
    }
    
    private var statusText: String? {
        guard !done else { return nil }
        switch windowStatus {
        case .open, .grace: return nil
        case .upcoming: return "Soon"
        case .closed: return "Missed"
        }
    }

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        VStack(spacing: 8) {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(done
                            ? AnyShapeStyle(RadialGradient(colors: [glow, brass], center: .init(x: 0.35, y: 0.3), startRadius: 2, endRadius: 34))
                            : AnyShapeStyle(colors.ink2))
                        .overlay(Circle().stroke(done ? brass : (isDisabled ? colors.inkLine.opacity(0.4) : colors.inkLine), lineWidth: done ? 2 : 2))
                        .frame(width: 64, height: 64)
                        .overlay(
                            Image(systemName: systemImage)
                                .font(.system(size: 22))
                                .foregroundColor(done ? Color(hex: "1A1207") : statusColor(colors))
                        )
                        .shadow(color: done ? brass.opacity(0.35) : .clear, radius: 10)
                    
                    // Lock icon for unavailable sessions
                    if isDisabled {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Image(systemName: windowStatus == .closed ? "xmark.circle.fill" : "lock.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(statusColor(colors))
                                    .background(Circle().fill(colors.ink2).padding(-4))
                            }
                        }
                        .frame(width: 64, height: 64)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.6 : 1.0)
            
            VStack(spacing: 2) {
                Text(label)
                    .font(AppFont.mono(11))
                    .tracking(0.6)
                    .foregroundColor(colors.textDim)
                
                if let status = statusText {
                    Text(status)
                        .font(AppFont.mono(9))
                        .foregroundColor(statusColor(colors))
                }
            }
        }
        .frame(maxWidth: .infinity)
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

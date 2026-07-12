import SwiftUI

// MARK: - Card container

struct CardView<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(18)
            .background(Palette.ink2)
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.inkLine, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

struct SectionLabel: View {
    let text: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(AppFont.mono(11))
                .tracking(1.4)
                .foregroundColor(Palette.textFaint)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(AppFont.mono(11))
                    .foregroundColor(Palette.textFaint)
            }
        }
        .padding(.vertical, 6)
    }
}

struct EmptyState: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(Palette.textFaint)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
    }
}

// MARK: - Stamp button (dawn / midday / dusk)

struct StampButton: View {
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
    
    private var statusColor: Color {
        if done { return brass }
        switch windowStatus {
        case .open, .grace: return Palette.textDim
        case .upcoming: return Palette.textFaint.opacity(0.5)
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
        VStack(spacing: 8) {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(done
                            ? AnyShapeStyle(RadialGradient(colors: [glow, brass], center: .init(x: 0.35, y: 0.3), startRadius: 2, endRadius: 34))
                            : AnyShapeStyle(Palette.ink2))
                        .overlay(Circle().stroke(done ? brass : (isDisabled ? Palette.inkLine.opacity(0.4) : Palette.inkLine), lineWidth: done ? 2 : 2))
                        .frame(width: 64, height: 64)
                        .overlay(
                            Image(systemName: systemImage)
                                .font(.system(size: 22))
                                .foregroundColor(done ? Color(hex: "1A1207") : statusColor)
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
                                    .foregroundColor(statusColor)
                                    .background(Circle().fill(Palette.ink2).padding(-4))
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
                    .foregroundColor(Palette.textDim)
                
                if let status = statusText {
                    Text(status)
                        .font(AppFont.mono(9))
                        .foregroundColor(statusColor)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Rank / level bar

struct RankBar: View {
    let info: AppState.LevelInfo
    var brass: Color
    var brassDim: Color
    var glow: Color

    var body: some View {
        CardView {
            HStack(spacing: 14) {
                Circle()
                    .fill(RadialGradient(colors: [glow, brass], center: .init(x: 0.35, y: 0.3), startRadius: 2, endRadius: 26))
                    .frame(width: 44, height: 44)
                    .overlay(Text("\(info.level)").font(AppFont.display(17, weight: .bold)).foregroundColor(Color(hex: "1A1207")))
                VStack(alignment: .leading, spacing: 6) {
                    Text(info.rank).font(AppFont.display(15))
                        .foregroundColor(Palette.text)
                    ProgressTrack(pct: info.pct, brassDim: brassDim, glow: glow)
                    Text("\(info.into) / \(info.need) XP to next level")
                        .font(AppFont.mono(11))
                        .foregroundColor(Palette.textFaint)
                }
            }
        }
    }
}

struct ProgressTrack: View {
    let pct: Double
    var brassDim: Color
    var glow: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2).fill(Palette.ink3)
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
    let habit: Habit
    let done: Bool
    let streak: Int
    var green: Color = Palette.green
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(done ? green : Palette.ink2)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(done ? green : Palette.inkLine, lineWidth: 1.5))
                    .frame(width: 22, height: 22)
                    .overlay(done ? Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundColor(.white) : nil)
            }
            .buttonStyle(.plain)
            Text(habit.name).font(.system(size: 13.5)).foregroundColor(Palette.text)
            Spacer()
            Text("\(streak)d").font(AppFont.mono(11)).foregroundColor(Palette.textFaint)
            Button(action: onDelete) {
                Image(systemName: "trash").font(.system(size: 12)).foregroundColor(Palette.textFaint)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 9)
    }
}

// MARK: - Toast

struct ToastView: View {
    let message: String
    var brass: Color
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundColor(brass)
            Text(message).font(.system(size: 12.5)).foregroundColor(Palette.text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.ink2)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(brass.opacity(0.6), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
        .padding(.horizontal, 16)
    }
}

// MARK: - Text field styling

struct AppTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Palette.ink3)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.inkLine, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .foregroundColor(Palette.text)
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .foregroundColor(Palette.textDim)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.inkLine, lineWidth: 1))
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
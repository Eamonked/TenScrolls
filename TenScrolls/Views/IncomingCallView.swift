import SwiftUI
import AudioToolbox

/// Full-screen "incoming call" presented when a reading session goes unanswered past
/// its timeout. Rings + vibrates on a repeating timer while visible; Accept lands the
/// user back in the app, Decline just dismisses.
struct IncomingCallView: View {
    let session: Session
    var onAccept: () -> Void
    var onDecline: () -> Void

    @State private var ringTimer: Timer?
    @State private var pulse = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "0B0F14"), Color(hex: "05070A")],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 70)

                Text("Ten Scrolls")
                    .font(AppFont.mono(13))
                    .tracking(2)
                    .foregroundColor(Palette.textDim)

                Text("incoming call")
                    .font(.system(size: 14))
                    .foregroundColor(Palette.textFaint)
                    .padding(.top, 4)

                avatar
                    .padding(.top, 44)

                Text("\(session.label) Reading")
                    .font(AppFont.display(26))
                    .foregroundColor(Palette.text)
                    .padding(.top, 26)

                Text("Your \(session.label.lowercased()) session is still unfinished.")
                    .font(.system(size: 14))
                    .foregroundColor(Palette.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, 8)

                Spacer()

                controls
                    .padding(.bottom, 60)
            }
        }
        .onAppear {
            pulse = true
            startRinging()
        }
        .onDisappear(perform: stopRinging)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(Color(hex: "E5B667").opacity(0.18))
                .frame(width: 190, height: 190)
                .scaleEffect(pulse ? 1.12 : 0.9)
                .opacity(pulse ? 0 : 0.8)
                .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)

            Circle()
                .fill(RadialGradient(
                    colors: [Color(hex: "E5B667"), Color(hex: "C4903F")],
                    center: .init(x: 0.35, y: 0.3), startRadius: 4, endRadius: 80))
                .frame(width: 130, height: 130)
                .overlay(
                    Image(systemName: session.systemImage)
                        .font(.system(size: 48))
                        .foregroundColor(Color(hex: "1A1207"))
                )
                .shadow(color: Color(hex: "E5B667").opacity(0.4), radius: 24)
        }
    }

    private var controls: some View {
        HStack(spacing: 70) {
            callButton(color: Palette.red, icon: "phone.down.fill", label: "Decline") {
                stopRinging()
                onDecline()
            }
            callButton(color: Palette.green, icon: "phone.fill", label: "Accept") {
                stopRinging()
                onAccept()
            }
        }
    }

    private func callButton(color: Color, icon: String, label: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Button(action: action) {
                Circle()
                    .fill(color)
                    .frame(width: 74, height: 74)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 30, weight: .medium))
                            .foregroundColor(.white)
                    )
                    .shadow(color: color.opacity(0.5), radius: 14)
            }
            .buttonStyle(.plain)
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(Palette.textDim)
        }
    }

    // MARK: - Ringtone

    private func startRinging() {
        ring() // fire immediately
        let timer = Timer(timeInterval: 2.6, repeats: true) { _ in
            Task { @MainActor in ring() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ringTimer = timer
    }

    private func ring() {
        // System "new mail"/alert tone (1005) plus a vibration burst — no bundled audio needed.
        AudioServicesPlaySystemSound(1005)
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }

    private func stopRinging() {
        ringTimer?.invalidate()
        ringTimer = nil
    }
}

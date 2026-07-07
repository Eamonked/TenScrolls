import SwiftUI
import UIKit

struct CaravanView: View {
    @EnvironmentObject var store: AppStore

    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var friendInput = ""
    @State private var friendError = ""
    @State private var copied = false

    @State private var leaderboard: [LeaderboardEntry]? = nil
    @State private var loadError = false
    @State private var friendData: [String: FriendSnapshot] = [:]
    @State private var cheersReceived = 0
    @State private var cheerSentFor: Set<String> = []

    var theme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }
    var myStreak: Int { store.state.currentStreak }
    var myLevel: Int { store.state.levelInfo().level }

    var sortedBoard: [LeaderboardEntry]? {
        leaderboard?.sorted { $0.snapshot.xp > $1.snapshot.xp }
    }
    var myRankIndex: Int? {
        sortedBoard?.firstIndex(where: { $0.code == store.state.traderCode })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FELLOW TRADERS").font(AppFont.mono(11)).tracking(1.4).foregroundColor(theme.brass)
                    Text("The Caravan").font(AppFont.display(28)).foregroundColor(Palette.text)
                }
                Text("Set a trader handle to appear on the shared leaderboard, then add friends by their trader code to compare streaks and send encouragement.")
                    .font(.system(size: 13)).foregroundColor(Palette.textDim)
                    .padding(.bottom, 6)

                identityCard
                addFriendCard
                duelsSection
                leaderboardSection

                Color.clear.frame(height: 10)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
        }
        .background(Palette.background)
        .task(id: "\(store.state.friendCodes.joined())-\(store.state.traderCode)") {
            await loadCircle()
        }
        .onAppear {
            if store.state.traderName.isEmpty { editingName = true }
        }
    }

    // MARK: - Identity

    private var identityCard: some View {
        CardView {
            Text("YOUR MARK").font(AppFont.mono(10)).tracking(1.4).foregroundColor(Palette.textFaint)
                .padding(.bottom, 8)

            if editingName {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Choose a trader handle…", text: $nameDraft)
                        .textFieldStyle(AppTextFieldStyle())
                        .onSubmit(saveName)
                    Button("Save handle", action: saveName)
                        .buttonStyle(PrimaryButtonStyle(brass: theme.brass, glow: theme.glow, disabled: nameDraft.trimmingCharacters(in: .whitespaces).isEmpty))
                        .disabled(nameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                HStack(spacing: 13) {
                    Circle()
                        .fill(RadialGradient(colors: [theme.glow, theme.brass], center: .init(x: 0.35, y: 0.3), startRadius: 2, endRadius: 26))
                        .frame(width: 46, height: 46)
                        .overlay(Text(String(store.state.traderName.prefix(1)).uppercased()).font(AppFont.display(17, weight: .bold)).foregroundColor(Color(hex: "1A1207")))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(store.state.traderName).font(AppFont.display(19)).foregroundColor(Palette.text)
                            Button {
                                nameDraft = store.state.traderName
                                editingName = true
                            } label: {
                                Image(systemName: "pencil").font(.system(size: 12)).foregroundColor(Palette.textFaint)
                            }
                            .buttonStyle(.plain)
                        }
                        Text("Level \(myLevel) · \(myStreak)d streak · \(cheersReceived) cheer\(cheersReceived == 1 ? "" : "s") received")
                            .font(AppFont.mono(11)).foregroundColor(Palette.textFaint)
                    }
                    Spacer()
                }
            }

            HStack(spacing: 8) {
                Text(store.state.traderCode)
                    .font(AppFont.mono(12.5)).tracking(1.2).foregroundColor(theme.brass)
                Spacer()
                Button {
                    UIPasteboard.general.string = store.state.traderCode
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundColor(copied ? Palette.green : Palette.textDim)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Palette.ink3)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.inkLine, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.top, 12)
        }
    }

    private func saveName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.setTraderName(trimmed)
        editingName = false
    }

    // MARK: - Add friend

    private var addFriendCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Add a Friend")
            CardView {
                HStack(spacing: 8) {
                    TextField("Enter their trader code…", text: $friendInput)
                        .textFieldStyle(AppTextFieldStyle())
                        .textInputAutocapitalization(.characters)
                        .onSubmit(submitFriend)
                    Button(action: submitFriend) {
                        Image(systemName: "person.badge.plus")
                    }
                    .frame(width: 40, height: 40)
                    .background(Palette.ink3)
                    .foregroundColor(theme.brass)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.inkLine, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                if !friendError.isEmpty {
                    Text(friendError).font(AppFont.mono(11)).foregroundColor(Palette.red).padding(.top, 8)
                }
                Text("Share your own code above so they can add you back.")
                    .font(AppFont.mono(11)).foregroundColor(Palette.textFaint)
                    .padding(.top, friendError.isEmpty ? 8 : 4)
            }
        }
    }

    private func submitFriend() {
        let code = friendInput.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty else { return }
        if code == store.state.traderCode { friendError = "That's your own code."; return }
        if store.state.friendCodes.contains(code) { friendError = "Already in your circle."; return }
        friendError = ""
        store.addFriend(code)
        friendInput = ""
    }

    // MARK: - Duels

    private var duelsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Streak Duels")
            if store.state.friendCodes.isEmpty {
                CardView { EmptyState(text: "No friends added yet. Add a trader code above to start a streak duel.") }
            } else {
                ForEach(store.state.friendCodes, id: \.self) { code in
                    DuelCard(
                        code: code,
                        friend: friendData[code],
                        myStreak: myStreak,
                        theme: theme,
                        cheerSent: cheerSentFor.contains(code),
                        onRemove: { store.removeFriend(code) },
                        onCheer: { await sendCheer(code) }
                    )
                }
            }
        }
    }

    // MARK: - Leaderboard

    private var leaderboardSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Leaderboard", trailing: sortedBoard.map { "\($0.count) traders" })
            CardView {
                if sortedBoard == nil {
                    EmptyState(text: "Loading the caravan…")
                } else if loadError {
                    EmptyState(text: "Couldn't reach the shared board right now. Try again shortly.")
                } else if sortedBoard!.isEmpty {
                    EmptyState(text: "No traders on the board yet. Set your handle above to be first.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(sortedBoard!.prefix(20).enumerated()), id: \.element.id) { idx, entry in
                            LeaderRow(rank: idx, entry: entry, isSelf: entry.code == store.state.traderCode, theme: theme)
                        }
                    }
                    if let myRankIndex, myRankIndex >= 20 {
                        Text("You're ranked #\(myRankIndex + 1) of \(sortedBoard!.count)")
                            .font(AppFont.mono(11)).foregroundColor(Palette.textFaint).padding(.top, 8)
                    }
                }
            }
        }
    }

    // MARK: - Data loading

    private func loadCircle() async {
        loadError = false
        do {
            leaderboard = try await store.leaderboard.fetchLeaderboard()
        } catch {
            leaderboard = []
            loadError = true
        }

        var map: [String: FriendSnapshot] = [:]
        for code in store.state.friendCodes {
            if let snap = await store.leaderboard.fetchFriend(code: code) {
                map[code] = snap
            }
        }
        friendData = map

        cheersReceived = await store.leaderboard.fetchCheerCount(code: store.state.traderCode)
    }

    private func sendCheer(_ code: String) async {
        cheerSentFor.insert(code)
        await store.leaderboard.sendCheer(code: code)
    }
}

private struct DuelCard: View {
    let code: String
    let friend: FriendSnapshot?
    let myStreak: Int
    let theme: ThemeOption
    let cheerSent: Bool
    let onRemove: () -> Void
    let onCheer: () async -> Void

    var body: some View {
        CardView {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(friend?.name ?? code).font(AppFont.display(15)).foregroundColor(Palette.text)
                    Text(friend != nil ? "Level \(friend!.level) · \(code)" : "Hasn't set a handle yet")
                        .font(AppFont.mono(11)).foregroundColor(Palette.textFaint)
                }
                Spacer()
                Button(action: onRemove) {
                    Image(systemName: "trash").font(.system(size: 13)).foregroundColor(Palette.textFaint)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 12)

            if let friend {
                let friendStreak = friend.streak
                let diff = myStreak - friendStreak
                HStack {
                    VStack(spacing: 3) {
                        HStack(spacing: 5) { Image(systemName: "flame.fill"); Text("\(myStreak)") }
                            .font(AppFont.mono(19)).foregroundColor(theme.brass)
                        Text("YOU").font(AppFont.mono(10)).foregroundColor(Palette.textFaint)
                    }
                    .frame(maxWidth: .infinity)
                    Text("vs").font(AppFont.display(12)).italic().foregroundColor(Palette.textFaint)
                    VStack(spacing: 3) {
                        HStack(spacing: 5) { Image(systemName: "flame.fill"); Text("\(friendStreak)") }
                            .font(AppFont.mono(19)).foregroundColor(theme.brass)
                        Text(friend.name.uppercased()).font(AppFont.mono(10)).foregroundColor(Palette.textFaint)
                    }
                    .frame(maxWidth: .infinity)
                }
                Text(diff > 0 ? "You're \(diff) day\(diff == 1 ? "" : "s") ahead"
                     : diff == 0 ? "Dead even — first to blink loses"
                     : "\(abs(diff)) day\(abs(diff) == 1 ? "" : "s") behind — catch up")
                    .font(.system(size: 11)).italic().foregroundColor(Palette.textDim)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
            } else {
                Text("They haven't set a trader handle yet, so no stats to compare.")
                    .font(AppFont.mono(11)).foregroundColor(Palette.textFaint)
            }

            Button {
                Task { await onCheer() }
            } label: {
                Label(cheerSent ? "Encouragement sent" : "Send encouragement", systemImage: "megaphone.fill")
                    .font(.system(size: 12.5))
            }
            .disabled(friend == nil || cheerSent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(Palette.ink3)
            .foregroundColor(theme.brass)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.brassDim, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(friend == nil || cheerSent ? 0.55 : 1)
            .padding(.top, 12)
        }
    }
}

private struct LeaderRow: View {
    let rank: Int
    let entry: LeaderboardEntry
    let isSelf: Bool
    let theme: ThemeOption

    var rankColor: Color {
        switch rank {
        case 0: return Color(hex: "E8C27A")
        case 1: return Color(hex: "C7CCD4")
        case 2: return Color(hex: "C99A6B")
        default: return Palette.textFaint
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if rank == 0 {
                    Image(systemName: "trophy.fill")
                } else {
                    Text("\(rank + 1)")
                }
            }
            .font(AppFont.mono(12))
            .foregroundColor(rankColor)
            .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text("\(entry.snapshot.name)\(isSelf ? " (you)" : "")")
                    .font(.system(size: 13.5, weight: .semibold)).foregroundColor(Palette.text)
                    .lineLimit(1)
                Text("\(entry.snapshot.streak)d streak · \(timeAgo(entry.snapshot.lastActive))")
                    .font(AppFont.mono(10.5)).foregroundColor(Palette.textFaint)
            }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "diamond").font(.system(size: 10))
                Text("\(entry.snapshot.xp)")
            }
            .font(AppFont.mono(12)).foregroundColor(theme.brass)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, isSelf ? 18 : 0)
        .background(isSelf ? theme.brass.opacity(0.09) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: isSelf ? 10 : 0))
    }
}

private func timeAgo(_ date: Date) -> String {
    let seconds = max(0, Date().timeIntervalSince(date))
    let mins = Int(seconds / 60)
    if mins < 1 { return "just now" }
    if mins < 60 { return "\(mins)m ago" }
    let hrs = mins / 60
    if hrs < 24 { return "\(hrs)h ago" }
    return "\(hrs / 24)d ago"
}

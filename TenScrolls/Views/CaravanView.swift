import SwiftUI
import CoreImage.CIFilterBuiltins
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// $500 Club rebuild of the Caravan screen — "The Caravan": a private ledger
/// of fellow traders. No chat, no DMs; presence and numbers only. Reuses
/// every existing AppStore/Supabase call from the previous implementation
/// (leaderboard, sharing, cheers, reading groups) — only the presentation
/// and copy changed. Reading Groups is kept (existing, wired functionality)
/// even though it wasn't in the visual brief, styled to match; a true
/// "Salons" presence-only feature would need new server-side data (a daily
/// note + per-member last-read-today flag) that doesn't exist yet, so it's
/// deliberately left out rather than faked with placeholder data.
struct CaravanView: View {
    @EnvironmentObject var store: AppStore

    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var friendInput = ""
    @State private var friendError = ""
    @State private var copied = false

    @State private var tieredEntries: [TieredLeaderboardEntry]? = nil
    @State private var loadError = false
    @State private var friendData: [String: FriendSnapshot] = [:]
    @State private var cheersReceived = 0
    @State private var cheerSentAt: [String: Date] = [:]
    @State private var cheerAckStatus: [String: CheerAckStatus] = [:]
    #if canImport(UIKit)
    @State private var shareImage: UIImage?
    @State private var showStreakShare = false
    #endif
    @State private var selectedShare: PendingScrollShare?
    @State private var groupNameDraft = ""
    @State private var groupCodeDraft = ""
    @State private var groupMessage: String?

    var myStreak: Int { store.state.currentStreak }
    var myLevel: Int { store.state.levelInfo().level }

    var fullBoard: [LeaderboardEntry]? {
        tieredEntries?.compactMap { row -> LeaderboardEntry? in
            guard !row.isLocked,
                  let code = row.traderCode, let name = row.traderName,
                  let level = row.level, let xp = row.xp,
                  let streak = row.currentStreak, let bestStreak = row.bestStreak,
                  let totalDays = row.totalDays, let mastered = row.scrollsMastered,
                  let lastActive = row.lastActive else { return nil }
            return LeaderboardEntry(code: code, snapshot: FriendSnapshot(
                name: name, level: level, xp: xp, streak: streak, bestStreak: bestStreak,
                totalDays: totalDays, mastered: mastered, lastActive: lastActive))
        }
    }
    var lockedSelfEntry: TieredLeaderboardEntry? {
        tieredEntries?.first(where: { $0.isLocked })
    }
    var inviteURL: URL {
        URL(string: "tenscrolls://addfriend?code=\(store.state.traderCode)")!
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                yourMarkCard
                if !store.pendingCheers.isEmpty { pendingCheersRow }
                notificationsSection
                inviteSection
                duelsSection
                readingGroupsSection
                leaderboardSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 120)
        }
        .background(LuxColor.bg.ignoresSafeArea())
        .task(id: "\(store.state.friendCodes.joined())-\(store.state.traderCode)") {
            await loadCircle()
            await store.refreshReadingGroups()
            await store.refreshPendingShares()
            await store.refreshPendingCheers()
            await store.syncFriendLinks()
        }
        .onAppear {
            if store.state.traderName.isEmpty { editingName = true }
            consumePendingFriendCode()
            consumePendingGroupCode()
            Task {
                await store.refreshPendingShares()
                await store.refreshPendingCheers()
            }
        }
        .onChange(of: store.pendingFriendCode) { _, _ in consumePendingFriendCode() }
        .onChange(of: store.pendingGroupCode) { _, _ in consumePendingGroupCode() }
        #if canImport(UIKit)
        .sheet(isPresented: $showStreakShare) {
            if let shareImage { ActivityShareSheet(items: [shareImage]) }
        }
        #endif
        .sheet(item: $selectedShare) { share in
            ScrollShareDetailView(share: share)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FELLOW TRADERS").luxEyebrow()
            Text("The Caravan")
                .font(LuxFont.serif(34))
                .tracking(-0.3)
                .foregroundColor(LuxColor.textPrimary)
            Text("A private ledger of those walking the same path. By invitation only.")
                .font(LuxFont.sans(13))
                .foregroundColor(LuxColor.textSecondary)
                .lineSpacing(4)
        }
    }

    // MARK: - Your Mark

    private var yourMarkCard: some View {
        LuxCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("YOUR MARK").luxEyebrow()
                    Spacer()
                    Text("EST. \(estYear)")
                        .font(LuxFont.mono(10))
                        .foregroundColor(LuxColor.textMuted)
                }

                if editingName {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("", text: $nameDraft, prompt: Text("Choose a trader handle\u{2026}").foregroundColor(LuxColor.textMuted))
                            .font(LuxFont.serif(18))
                            .foregroundColor(LuxColor.textPrimary)
                            .onSubmit(saveName)
                        Button("Save Handle", action: saveName)
                            .buttonStyle(LuxPrimaryButtonStyle(disabled: nameDraft.trimmingCharacters(in: .whitespaces).isEmpty))
                            .disabled(nameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    HStack(spacing: 14) {
                        Circle()
                            .fill(LuxColor.cardBorder)
                            .overlay(Circle().stroke(LuxColor.gold, lineWidth: 0.5))
                            .frame(width: 56, height: 56)
                            .overlay(
                                Text(String(store.state.traderName.prefix(1)).uppercased())
                                    .font(LuxFont.serif(22))
                                    .foregroundColor(LuxColor.gold)
                            )
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(store.state.traderName)
                                    .font(LuxFont.serif(24))
                                    .foregroundColor(LuxColor.textPrimary)
                                Button {
                                    nameDraft = store.state.traderName
                                    editingName = true
                                } label: {
                                    Image(systemName: "pencil").font(.system(size: 11, weight: .light)).foregroundColor(LuxColor.textMuted)
                                }
                                .buttonStyle(.plain)
                            }
                            Text("LEVEL \(Roman.from(max(1, myLevel))) \u{2022} \(Roman.from(max(0, myStreak))) DAY STREAK")
                                .font(LuxFont.mono(10))
                                .tracking(1)
                                .foregroundColor(LuxColor.textSecondary)
                        }
                        Spacer()
                    }
                }

                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TRADER CODE").luxEyebrow(tracking: 1.2)
                        Text(store.state.traderCode)
                            .font(LuxFont.mono(18, weight: .regular))
                            .tracking(3)
                            .foregroundColor(LuxColor.textPrimary)
                    }
                    Spacer()
                    QRCodeView(string: inviteURL.absoluteString)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    ShareLink(item: inviteURL, subject: Text("Join me on Ten Scrolls"), message: Text("Add me as a fellow trader \u{2014} my code is \(store.state.traderCode)")) {
                        squareIcon("square.and.arrow.up")
                    }
                    Button {
                        copyCode()
                    } label: {
                        squareIcon(copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var estYear: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy"
        return f.string(from: Date())
    }

    private func squareIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .light))
            .foregroundColor(LuxColor.textSecondary)
            .frame(width: 36, height: 36)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(LuxColor.cardBorder, lineWidth: 0.5))
    }

    private func copyCode() {
        #if canImport(UIKit)
        UIPasteboard.general.string = store.state.traderCode
        #elseif canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(store.state.traderCode, forType: .string)
        #endif
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { copied = false }
    }

    private func saveName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.setTraderName(trimmed)
        editingName = false
    }

    // MARK: - Pending cheers (in-app fallback)

    private var pendingCheersRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ACKNOWLEDGEMENTS").luxEyebrow()
            VStack(spacing: 8) {
                ForEach(store.pendingCheers) { cheer in
                    LuxRowCard(cornerRadius: 12) {
                        HStack(spacing: 10) {
                            Text("\(cheer.from_trader_name) acknowledged your practice")
                                .font(LuxFont.sans(13))
                                .foregroundColor(LuxColor.textPrimary)
                            Spacer()
                            Button("Got it") { store.acknowledgeCheer(id: cheer.cheer_id) }
                                .font(LuxFont.sans(12, weight: .semibold))
                                .foregroundColor(LuxColor.gold)
                        }
                        .padding(12)
                    }
                }
            }
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NOTIFICATIONS").luxEyebrow()
            if store.pendingScrollShares.isEmpty {
                LuxEmptyLine(text: "No messages in the ledger.")
            } else {
                VStack(spacing: 8) {
                    ForEach(store.pendingScrollShares) { share in
                        notificationRow(share)
                    }
                }
            }
        }
    }

    private func notificationRow(_ share: PendingScrollShare) -> some View {
        Button { selectedShare = share } label: {
            LuxRowCard(cornerRadius: 14) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(share.from_trader_name.isEmpty ? share.from_trader_code : share.from_trader_name) shared \(share.title.isEmpty ? "a scroll" : "\u{201C}\(share.title)\u{201D}")")
                            .font(LuxFont.sans(13, weight: .medium))
                            .foregroundColor(LuxColor.textPrimary)
                            .lineLimit(2)
                        Text(timeAgo(share.created_at))
                            .font(LuxFont.mono(9))
                            .foregroundColor(LuxColor.textMuted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .light)).foregroundColor(LuxColor.textMuted)
                }
                .padding(14)
            }
        }
        .buttonStyle(.plain)
    }

    private func consumePendingFriendCode() {
        guard let code = store.pendingFriendCode else { return }
        friendInput = code
        submitFriend()
        store.pendingFriendCode = nil
    }

    private func consumePendingGroupCode() {
        guard let code = store.pendingGroupCode else { return }
        groupCodeDraft = code
        store.pendingGroupCode = nil
        Task { await submitJoinGroup() }
    }

    // MARK: - Invite

    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("INVITE").luxEyebrow()
            if store.state.hasPlusAccess {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        TextField("", text: $friendInput, prompt: Text("Enter trader code").font(.custom("CormorantGaramond-Italic", size: 16)).foregroundColor(LuxColor.textMuted))
                            .font(LuxFont.serif(16))
                            .tracking(1)
                            .foregroundColor(LuxColor.textPrimary)
                            #if os(iOS)
                            .textInputAutocapitalization(.characters)
                            #endif
                            .onSubmit(submitFriend)
                        Rectangle().fill(Color.clear).frame(width: 0, height: 0) // spacer keeps HStack from collapsing underline
                        Button("Invite \u{2192}", action: submitFriend)
                            .font(LuxFont.sans(12, weight: .semibold))
                            .tracking(0.6)
                            .foregroundColor(LuxColor.gold)
                    }
                    Rectangle().fill(LuxColor.divider).frame(height: 0.5)
                    if !friendError.isEmpty {
                        Text(friendError).font(LuxFont.mono(10)).foregroundColor(.red.opacity(0.8))
                    }
                    Text("Your code is private. Share only with those you trust.")
                        .font(LuxFont.sans(10))
                        .italic()
                        .foregroundColor(LuxColor.textMuted)
                        .padding(.top, 8)
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "lock").font(.system(size: 12, weight: .light)).foregroundColor(LuxColor.textMuted)
                    Text("Inviting new traders is a Plus feature.")
                        .font(LuxFont.sans(12))
                        .foregroundColor(LuxColor.textSecondary)
                    Spacer()
                    Button("Upgrade") { store.shouldShowDay30Paywall = true }
                        .font(LuxFont.sans(12, weight: .semibold))
                        .foregroundColor(LuxColor.gold)
                }
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

    // MARK: - Duels ("The Ledger")

    private var duelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("DUELS").luxEyebrow()
                Spacer()
                Text("\(store.state.friendCodes.count) ACTIVE")
                    .font(LuxFont.mono(10))
                    .foregroundColor(LuxColor.textMuted)
            }
            if store.state.friendCodes.isEmpty {
                LuxEmptyLine(text: "No friends added yet. Invite a trader code above.")
            } else {
                VStack(spacing: 12) {
                    ForEach(store.state.friendCodes.prefix(5), id: \.self) { code in
                        let ack = cheerAckStatus[code]
                        let ackSentToday = (ack?.sent ?? false) && isToday(ack?.sent_at)
                        let sentLocallyToday = isToday(cheerSentAt[code])
                        DuelRow(
                            code: code,
                            friend: friendData[code],
                            myStreak: myStreak,
                            cheerSent: sentLocallyToday || ackSentToday,
                            cheerSeen: ackSentToday && (ack?.acknowledged ?? false),
                            hasPlusAccess: store.state.hasPlusAccess,
                            onRemove: { store.removeFriend(code) },
                            onCheer: { await sendCheer(code) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Reading Groups (existing functionality, not in visual brief)

    private var readingGroupsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("READING GROUPS").luxEyebrow()
                Spacer()
                if !store.myReadingGroups.isEmpty {
                    Text("\(store.myReadingGroups.count) GROUP\(store.myReadingGroups.count == 1 ? "" : "S")")
                        .font(LuxFont.mono(10)).foregroundColor(LuxColor.textMuted)
                }
            }
            LuxRowCard {
                VStack(alignment: .leading, spacing: 14) {
                    if !store.myReadingGroups.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(store.myReadingGroups.enumerated()), id: \.element.id) { idx, group in
                                if idx > 0 { LuxDivider() }
                                readingGroupRow(group)
                            }
                        }
                        LuxDivider()
                    }
                    HStack(spacing: 8) {
                        TextField("", text: $groupNameDraft, prompt: Text("Group name\u{2026}").foregroundColor(LuxColor.textMuted))
                            .font(LuxFont.sans(13)).foregroundColor(LuxColor.textPrimary)
                            .onSubmit { Task { await submitCreateGroup() } }
                        Button { Task { await submitCreateGroup() } } label: { squareIcon("plus") }
                            .buttonStyle(.plain)
                    }
                    HStack(spacing: 8) {
                        TextField("", text: $groupCodeDraft, prompt: Text("Enter group code\u{2026}").foregroundColor(LuxColor.textMuted))
                            .font(LuxFont.sans(13)).foregroundColor(LuxColor.textPrimary)
                            #if os(iOS)
                            .textInputAutocapitalization(.characters)
                            #endif
                            .onSubmit { Task { await submitJoinGroup() } }
                        Button { Task { await submitJoinGroup() } } label: { squareIcon("arrow.right") }
                            .buttonStyle(.plain)
                    }
                    if let msg = groupMessage {
                        Text(msg).font(LuxFont.mono(10)).foregroundColor(LuxColor.gold)
                    }
                }
                .padding(16)
            }
        }
    }

    private func readingGroupRow(_ group: ReadingGroupSummary) -> some View {
        let url = URL(string: "tenscrolls://joingroup?code=\(group.group_code)")!
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name).font(LuxFont.serif(15)).foregroundColor(LuxColor.textPrimary)
                Text("\(group.member_count) member\(group.member_count == 1 ? "" : "s") \u{2022} \(group.group_code)")
                    .font(LuxFont.mono(10)).foregroundColor(LuxColor.textMuted)
            }
            Spacer()
            ShareLink(item: url, subject: Text("Join \(group.name)"), message: Text("Use code \(group.group_code)")) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 12, weight: .light)).foregroundColor(LuxColor.textMuted)
            }
        }
        .padding(.vertical, 6)
    }

    private func submitCreateGroup() async {
        switch await store.createReadingGroup(name: groupNameDraft) {
        case .success(let msg): groupNameDraft = ""; groupMessage = msg
        case .failure(let msg): groupMessage = msg
        }
        clearGroupMessageAfterDelay()
    }

    private func submitJoinGroup() async {
        switch await store.joinReadingGroup(code: groupCodeDraft) {
        case .success(let msg): groupCodeDraft = ""; groupMessage = msg
        case .failure(let msg): groupMessage = msg
        }
        clearGroupMessageAfterDelay()
    }

    private func clearGroupMessageAfterDelay() {
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            groupMessage = nil
        }
    }

    // MARK: - Leaderboard ("The Ledger" terminal)

    private var leaderboardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("STANDING").luxEyebrow()
                Spacer()
                // Only shown once the ledger is actually unlocked — a locked
                // (non-Plus) reader shouldn't learn the leaderboard's size
                // from this header either. See `lockedLedgerCard` below.
                if lockedSelfEntry == nil, let fullBoard { Text("\(fullBoard.count) TRADERS").font(LuxFont.mono(10)).foregroundColor(LuxColor.textMuted) }
            }

            if tieredEntries == nil {
                LuxEmptyLine(text: "Loading the ledger\u{2026}")
            } else if loadError {
                LuxEmptyLine(text: "Couldn't reach the ledger right now.")
            } else if let locked = lockedSelfEntry {
                lockedLedgerCard(locked)
            } else if let fullBoard {
                LuxRowCard {
                    VStack(spacing: 0) {
                        if fullBoard.isEmpty {
                            LuxEmptyLine(text: "No traders on the ledger yet.")
                        } else {
                            ForEach(Array(fullBoard.prefix(20).enumerated()), id: \.element.id) { idx, entry in
                                if idx > 0 { LuxDivider() }
                                ledgerRow(rank: idx, entry: entry)
                            }
                        }
                    }
                }
            }
        }
    }

    private func lockedLedgerCard(_ locked: TieredLeaderboardEntry) -> some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("TOP \(locked.percentile ?? 50)%")
                    .font(LuxFont.serif(48))
                    .tracking(-1)
                    .foregroundColor(LuxColor.textPrimary)
                // Deliberately no headcount here — how many traders are on
                // the ledger is itself part of what's locked behind Plus,
                // not just their identities/ranks. Percentile alone still
                // gives a locked reader a sense of standing without
                // revealing the ledger's size.
                Text("Other traders are ranked ahead of you.")
                    .font(LuxFont.sans(13))
                    .foregroundColor(LuxColor.textSecondary)
            }
            ZStack {
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { i in
                        HStack {
                            Text("#\(120 + i)").font(LuxFont.mono(10)).foregroundColor(LuxColor.textMuted)
                            Text("\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}").font(LuxFont.mono(10)).foregroundColor(LuxColor.textMuted.opacity(0.3))
                            Spacer()
                            Text("\u{2022}\u{2022}\u{2022}\u{2022}").font(LuxFont.mono(10)).foregroundColor(LuxColor.gold.opacity(0.2))
                        }
                        .frame(height: 32)
                        .overlay(alignment: .bottom) { LuxDivider().opacity(0.4) }
                    }
                }
                .blur(radius: 12)

                VStack(spacing: 12) {
                    Circle()
                        .fill(Color.black)
                        .frame(width: 48, height: 48)
                        .shadow(color: LuxColor.gold.opacity(0.3), radius: 20)
                        .overlay(Image(systemName: "lock").font(.system(size: 16, weight: .light)).foregroundColor(LuxColor.gold))
                    Text("The full ledger is private to members.")
                        .font(LuxFont.sans(10))
                        .tracking(0.6)
                        .foregroundColor(LuxColor.textSecondary)
                }
            }
            .frame(height: 200)

            Button {
                store.shouldShowDay30Paywall = true
            } label: {
                Text("Enter the Ledger \u{2014} $500/yr")
            }
            .buttonStyle(LuxLedgerButtonStyle())
        }
        .padding(24)
        // Deliberately always-near-black regardless of app theme — the
        // spec's "$500 Terminal" locked-ledger panel is meant to read as a
        // vault/monitor, distinct from the surrounding (now theme-adaptive)
        // card surfaces, the same way the Reader intentionally stays dark.
        .background(Color(hex: "0A0D12"))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(LuxColor.gold, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func ledgerRow(rank: Int, entry: LeaderboardEntry) -> some View {
        let isSelf = entry.code == store.state.traderCode
        return HStack(spacing: 12) {
            Text("#\(rank + 1)").font(LuxFont.mono(10)).foregroundColor(LuxColor.textMuted).frame(width: 28, alignment: .leading)
            Text(entry.snapshot.name)
                .font(LuxFont.serif(15))
                .foregroundColor(LuxColor.textPrimary)
            Spacer()
            Text("\(Roman.from(max(0, entry.snapshot.streak)))")
                .font(LuxFont.mono(10))
                .foregroundColor(LuxColor.gold)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, isSelf ? 14 : 0)
        .overlay(alignment: .leading) {
            if isSelf { Rectangle().fill(LuxColor.gold).frame(width: 2) }
        }
    }

    // MARK: - Data loading (unchanged from previous implementation)

    private func loadCircle() async {
        loadError = false
        do {
            tieredEntries = try await store.subscription.fetchTieredLeaderboard()
        } catch {
            tieredEntries = []
            loadError = true
        }
        var map: [String: FriendSnapshot] = [:]
        for code in store.state.friendCodes {
            if let snap = await store.leaderboard.fetchFriend(code: code) { map[code] = snap }
        }
        friendData = map
        cheersReceived = await store.leaderboard.fetchCheerCount(code: store.state.traderCode)
        var ackMap: [String: CheerAckStatus] = [:]
        for code in store.state.friendCodes {
            ackMap[code] = await store.leaderboard.fetchCheerAckStatus(code: code)
        }
        cheerAckStatus = ackMap
    }

    private func sendCheer(_ code: String) async {
        cheerSentAt[code] = Date()
        let result = await store.leaderboard.sendCheer(code: code)
        if let result, !result.success, result.error == "plus_required" {
            cheerSentAt[code] = nil
            await store.refreshSubscriptionStatus()
            return
        }
        cheerAckStatus[code] = await store.leaderboard.fetchCheerAckStatus(code: code)
    }

    private func isToday(_ date: Date?) -> Bool {
        guard let date else { return false }
        return Calendar.current.isDateInToday(date)
    }
}

// MARK: - Duel row

private struct DuelRow: View {
    let code: String
    let friend: FriendSnapshot?
    let myStreak: Int
    let cheerSent: Bool
    let cheerSeen: Bool
    let hasPlusAccess: Bool
    let onRemove: () -> Void
    let onCheer: () async -> Void

    private var maxStreak: Int { max(1, myStreak, friend?.streak ?? 0) }

    var body: some View {
        LuxRowCard {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text((friend?.name ?? code).uppercased())
                        .font(LuxFont.sans(12, weight: .medium))
                        .foregroundColor(LuxColor.textPrimary)
                        .lineLimit(1)
                    Text(code)
                        .font(LuxFont.mono(10))
                        .foregroundColor(LuxColor.textMuted)
                }
                .frame(width: 90, alignment: .leading)

                HStack(spacing: 6) {
                    barBottomAligned(height: CGFloat(myStreak) / CGFloat(maxStreak) * 32, color: LuxColor.gold)
                    Text("\u{2014}").font(LuxFont.serif(12)).foregroundColor(LuxColor.textMuted)
                    barBottomAligned(height: CGFloat(friend?.streak ?? 0) / CGFloat(maxStreak) * 32, color: LuxColor.textMuted)
                }
                .frame(height: 32)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("\(myStreak)").font(LuxFont.mono(22, weight: .regular)).foregroundColor(LuxColor.gold)
                        Text("\(friend?.streak ?? 0)").font(LuxFont.mono(22, weight: .regular)).foregroundColor(LuxColor.textMuted.opacity(0.5))
                    }
                    Text("DAYS").font(LuxFont.sans(8, weight: .medium)).tracking(1).foregroundColor(LuxColor.textMuted)
                }

                actionButton
            }
            .padding(14)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onRemove) {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private func barBottomAligned(height: CGFloat, color: Color) -> some View {
        VStack {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 2, height: max(2, height))
        }
        .frame(height: 32)
    }

    @ViewBuilder
    private var actionButton: some View {
        if hasPlusAccess {
            Button {
                Task { await onCheer() }
            } label: {
                ZStack {
                    Circle()
                        .fill(cheerSeen ? LuxColor.goldBg : Color.clear)
                        .overlay(Circle().stroke(cheerSeen ? Color.clear : LuxColor.gold, lineWidth: 0.5))
                    Image(systemName: cheerSeen ? "checkmark" : "arrow.right")
                        .font(.system(size: 12, weight: .light))
                        .foregroundColor(LuxColor.gold)
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(friend == nil || cheerSent)
            .opacity(friend == nil || (cheerSent && !cheerSeen) ? 0.4 : 1)
        } else {
            Image(systemName: "lock")
                .font(.system(size: 11, weight: .light))
                .foregroundColor(LuxColor.textMuted)
                .frame(width: 32, height: 32)
        }
    }
}

/// The ledger's own bordered-gold "Enter the Ledger" button — visually
/// distinct from `LuxPrimaryButtonStyle` (outlined, not filled) so the
/// paywall CTA doesn't read as "the one filled button" competing with
/// whatever primary action the rest of the screen has.
private struct LuxLedgerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LuxFont.sans(12, weight: .semibold))
            .tracking(1)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .foregroundColor(LuxColor.gold)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(LuxColor.gold, lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - QR code

/// Renders `string` (the invite deep link) as a black-on-white QR code using
/// CoreImage — no third-party dependency needed.
private struct QRCodeView: View {
    let string: String
    var body: some View {
        Image(uiImage: Self.render(string))
            .interpolation(.none)
            .resizable()
            .background(Color.white)
    }

    private static func render(_ string: String) -> UIImage {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return UIImage() }
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaled = outputImage.transformed(by: transform)
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return UIImage() }
        return UIImage(cgImage: cgImage)
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

// MARK: - Previews

#Preview("Free") {
    let store = AppStore()
    store.state.traderName = "M. Voss"
    store.state.traderCode = "7K2QRT"
    store.state.friendCodes = ["A1B2C3", "D4E5F6"]
    store.state.cachedSubscriptionStatus = .free
    return CaravanView().environmentObject(store)
}

#Preview("Plus") {
    let store = AppStore()
    store.state.traderName = "M. Voss"
    store.state.traderCode = "7K2QRT"
    store.state.friendCodes = ["A1B2C3", "D4E5F6"]
    store.state.cachedSubscriptionStatus = .active
    return CaravanView().environmentObject(store)
}

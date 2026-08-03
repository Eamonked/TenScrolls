import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif


struct CaravanView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.appearanceMode) var appearanceMode

    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var friendInput = ""
    @State private var friendError = ""
    @State private var copied = false

    /// Raw rows from the tiered RPC. For Plus users this is the full ranked
    /// list (one row per trader); for free/lapsed users it's a single locked
    /// row carrying only this device's own percentile/population — the
    /// server decides which shape comes back based on subscription status,
    /// this view just renders whichever it received. See `fullBoard` below.
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
    @State private var groupMessageIsError = false

    var theme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }
    var myStreak: Int { store.state.currentStreak }
    var myLevel: Int { store.state.levelInfo().level }

    /// Only meaningful for Plus users — the unlocked rows from `tieredEntries`,
    /// already ranked server-side (`get_leaderboard_tiered` orders by XP), so
    /// no client-side re-sort is needed. Free/lapsed users get a single
    /// `is_locked` row, which maps to an empty board here since there's
    /// nothing to list — see `partialRevealCard` for their view instead.
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
    var myRankIndex: Int? {
        fullBoard?.firstIndex(where: { $0.code == store.state.traderCode })
    }
    /// The locked row for a free/lapsed user — carries just this device's own
    /// percentile and the population count, nothing about anyone else.
    var lockedSelfEntry: TieredLeaderboardEntry? {
        tieredEntries?.first(where: { $0.isLocked })
    }
    /// Deep link opened by `AppStore.handleIncomingURL` on the recipient's
    /// device, pre-filling their add-friend field with this trader's code.
    var inviteURL: URL {
        URL(string: "tenscrolls://addfriend?code=\(store.state.traderCode)")!
    }

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FELLOW TRADERS").font(AppFont.mono(11)).tracking(1.4).foregroundColor(theme.brass)
                    Text("The Caravan").font(AppFont.display(28)).foregroundColor(colors.text)
                }
                Text("Set a trader handle to appear on the shared leaderboard, then add friends by their trader code to compare streaks and send encouragement.")
                    .font(.system(size: 13)).foregroundColor(colors.textDim)
                    .padding(.bottom, 6)

                identityCard
                if !store.pendingCheers.isEmpty {
                    pendingCheersBanner
                }
                notificationsSection
                addFriendCard
                duelsSection
                readingGroupsSection
                leaderboardSection

                Color.clear.frame(height: 10)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
        }
        .background(colors.background)
        .task(id: "\(store.state.friendCodes.joined())-\(store.state.traderCode)") {
            await loadCircle()
            await store.refreshReadingGroups()
            await store.refreshPendingShares()
            await store.refreshPendingCheers()
        }
        .onAppear {
            if store.state.traderName.isEmpty { editingName = true }
            consumePendingFriendCode()
            consumePendingGroupCode()
            // Belt-and-suspenders: catches shares/cheers that arrived while
            // this tab was already loaded and the user just switched back
            // to it, since the .task(id:) above won't refire for that case.
            Task {
                await store.refreshPendingShares()
                await store.refreshPendingCheers()
            }
        }
        .onChange(of: store.pendingFriendCode) { _, _ in
            consumePendingFriendCode()
        }
        .onChange(of: store.pendingGroupCode) { _, _ in
            consumePendingGroupCode()
        }
        #if canImport(UIKit)
        .sheet(isPresented: $showStreakShare) {
            if let shareImage {
                ActivityShareSheet(items: [shareImage])
            }
        }
        #endif
        .sheet(item: $selectedShare) { share in
            ScrollShareDetailView(share: share)
                .environment(\.appearanceMode, appearanceMode)
        }
    }

    /// In-app fallback for cheers whose push was missed, dismissed unseen,
    /// or arrived while notification permission was denied. Each row lets
    /// the recipient explicitly acknowledge — same action as the push's
    /// "Got it" button, just reachable without leaving the app.
    private var pendingCheersBanner: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        return VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Encouragement")
            CardView {
                VStack(spacing: 10) {
                    ForEach(store.pendingCheers) { cheer in
                        HStack(spacing: 10) {
                            Image(systemName: "megaphone.fill").foregroundColor(theme.brass)
                            Text("\(cheer.from_trader_name) sent you encouragement")
                                .font(.system(size: 13)).foregroundColor(colors.text)
                            Spacer()
                            Button("Got it") {
                                store.acknowledgeCheer(id: cheer.cheer_id)
                            }
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(theme.brass)
                        }
                    }
                }
            }
        }
    }

    /// Everything another trader has sent this device that's still awaiting a
    /// decision — currently just shared scrolls, but the section (and
    /// `notificationRow`) is written generically so other received-item types
    /// can join it later without a redesign. Always visible, like the other
    /// Caravan sections, so an empty state is as discoverable as a full one.
    private var notificationsSection: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        return VStack(alignment: .leading, spacing: 0) {
            SectionLabel(
                text: "Notifications",
                trailing: store.pendingScrollShares.isEmpty ? nil : "\(store.pendingScrollShares.count) new"
            )
            CardView {
                if store.pendingScrollShares.isEmpty {
                    EmptyState(text: "Nothing waiting on you right now. Shared scrolls will show up here.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(store.pendingScrollShares.enumerated()), id: \.element.id) { idx, share in
                            if idx > 0 {
                                Divider().overlay(colors.inkLine)
                            }
                            notificationRow(share, colors: colors)
                        }
                    }
                }
            }
        }
    }

    private func notificationRow(_ share: PendingScrollShare, colors: AdaptivePalette) -> some View {
        Button {
            selectedShare = share
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(theme.brass.opacity(0.15))
                    .frame(width: 34, height: 34)
                    .overlay(Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 13)).foregroundColor(theme.brass))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(share.from_trader_name.isEmpty ? share.from_trader_code : share.from_trader_name) shared \(share.title.isEmpty ? "a scroll" : "\u{201C}\(share.title)\u{201D}")")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(colors.text)
                        .lineLimit(2)
                    Text(timeAgo(share.created_at))
                        .font(AppFont.mono(10.5)).foregroundColor(colors.textFaint)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundColor(colors.textFaint)
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    /// Prefills and submits the add-friend field from an opened
    /// `tenscrolls://addfriend?code=...` link, then clears the pending code
    /// so it isn't re-applied on the next appearance.
    private func consumePendingFriendCode() {
        guard let code = store.pendingFriendCode else { return }
        friendInput = code
        submitFriend()
        store.pendingFriendCode = nil
    }

    /// Prefills the join-group field from an opened
    /// `tenscrolls://joingroup?code=...` link and fires the join, then clears
    /// the pending code so it isn't re-applied on the next appearance.
    private func consumePendingGroupCode() {
        guard let code = store.pendingGroupCode else { return }
        groupCodeDraft = code
        store.pendingGroupCode = nil
        Task { await submitJoinGroup() }
    }

    // MARK: - Identity

    private var identityCard: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        return CardView {
            Text("YOUR MARK").font(AppFont.mono(10)).tracking(1.4).foregroundColor(colors.textFaint)
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
                            Text(store.state.traderName).font(AppFont.display(19)).foregroundColor(colors.text)
                            Button {
                                nameDraft = store.state.traderName
                                editingName = true
                            } label: {
                                Image(systemName: "pencil").font(.system(size: 12)).foregroundColor(colors.textFaint)
                            }
                            .buttonStyle(.plain)
                        }
                        Text("Level \(myLevel) · \(myStreak)d streak · \(cheersReceived) cheer\(cheersReceived == 1 ? "" : "s") received")
                            .font(AppFont.mono(11)).foregroundColor(colors.textFaint)
                    }
                    Spacer()
                }
            }

            HStack(spacing: 8) {
                Text(store.state.traderCode)
                    .font(AppFont.mono(12.5)).tracking(1.2).foregroundColor(theme.brass)
                Spacer()
                ShareLink(
                    item: inviteURL,
                    subject: Text("Join me on Ten Scrolls"),
                    message: Text("Add me as a fellow trader in the Caravan \u{2014} my code is \(store.state.traderCode).")
                ) {
                    Image(systemName: "square.and.arrow.up").foregroundColor(colors.textDim)
                }
                Button {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = store.state.traderCode
                    #elseif canImport(AppKit)
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(store.state.traderCode, forType: .string)
                    #endif
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundColor(copied ? colors.green : colors.textDim)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(colors.ink3)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(colors.inkLine, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.top, 12)

            #if canImport(UIKit)
            Button {
                shareImage = ShareCard.renderImage(
                    traderName: store.state.traderName,
                    streak: myStreak,
                    level: myLevel,
                    rank: store.state.levelInfo().rank,
                    theme: theme
                )
                showStreakShare = shareImage != nil
            } label: {
                Label("Share your streak", systemImage: "square.and.arrow.up.on.square")
                    .font(.system(size: 12.5))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(colors.ink3)
            .foregroundColor(theme.brass)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.brassDim, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.top, 10)
            #endif
        }
    }

    private func saveName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.setTraderName(trimmed)
        editingName = false
    }

    // MARK: - Add friend

    /// Growing your circle is a Plus perk — the strategy doc's "View Only"
    /// Caravan rule for free/lapsed users. Existing friends stay fully visible
    /// (see `duelsSection`); this only gates *adding new ones*.
    private var addFriendCard: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        return VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Add a Friend")
            if store.state.hasPlusAccess {
                CardView {
                    HStack(spacing: 8) {
                        TextField("Enter their trader code…", text: $friendInput)
                            .textFieldStyle(AppTextFieldStyle())
                            #if os(iOS)
                            .textInputAutocapitalization(.characters)
                            #endif
                            .onSubmit(submitFriend)
                        Button(action: submitFriend) {
                            Image(systemName: "person.badge.plus")
                        }
                        .frame(width: 40, height: 40)
                        .background(colors.ink3)
                        .foregroundColor(theme.brass)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(colors.inkLine, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    if !friendError.isEmpty {
                        Text(friendError).font(AppFont.mono(11)).foregroundColor(colors.red).padding(.top, 8)
                    }
                    Text("Share your own code above so they can add you back.")
                        .font(AppFont.mono(11)).foregroundColor(colors.textFaint)
                        .padding(.top, friendError.isEmpty ? 8 : 4)
                }
            } else {
                CardView {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.fill").font(.system(size: 13)).foregroundColor(colors.textFaint)
                        Text("Adding new traders is a Plus feature.")
                            .font(.system(size: 12.5)).foregroundColor(colors.textDim)
                        Spacer()
                        Button("Upgrade") { store.shouldShowDay30Paywall = true }
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(theme.brass)
                    }
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

    // MARK: - Duels

    private var duelsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Streak Duels")
            if store.state.friendCodes.isEmpty {
                CardView { EmptyState(text: "No friends added yet. Add a trader code above to start a streak duel.") }
            } else {
                ForEach(store.state.friendCodes, id: \.self) { code in
                    let ack = cheerAckStatus[code]
                    let ackSentToday = (ack?.sent ?? false) && isToday(ack?.sent_at)
                    let sentLocallyToday = isToday(cheerSentAt[code])
                    DuelCard(
                        code: code,
                        friend: friendData[code],
                        myStreak: myStreak,
                        theme: theme,
                        cheerSent: sentLocallyToday || ackSentToday,
                        cheerSeen: ackSentToday && (ack?.acknowledged ?? false),
                        hasPlusAccess: store.state.hasPlusAccess,
                        onRemove: { store.removeFriend(code) },
                        onCheer: { await sendCheer(code) },
                        onUpgrade: { store.shouldShowDay30Paywall = true }
                    )
                }
            }
        }
    }

    // MARK: - Reading Groups

    private var readingGroupsSection: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        return VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Reading Groups", trailing: store.myReadingGroups.isEmpty ? nil : "\(store.myReadingGroups.count) group\(store.myReadingGroups.count == 1 ? "" : "s")")
            CardView {
                VStack(alignment: .leading, spacing: 12) {
                    // Existing groups list
                    if !store.myReadingGroups.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(store.myReadingGroups.enumerated()), id: \.element.id) { idx, group in
                                if idx > 0 { Divider().overlay(colors.inkLine) }
                                ReadingGroupRow(group: group, theme: theme)
                            }
                        }
                        Divider().overlay(colors.inkLine).padding(.top, 4)
                    }

                    // Create group
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Create a group".uppercased())
                            .font(AppFont.mono(10)).tracking(1.2).foregroundColor(colors.textFaint)
                        HStack(spacing: 8) {
                            TextField("Group name…", text: $groupNameDraft)
                                .textFieldStyle(AppTextFieldStyle())
                                .onSubmit { Task { await submitCreateGroup() } }
                            Button { Task { await submitCreateGroup() } } label: {
                                Image(systemName: "plus")
                            }
                            .frame(width: 40, height: 40)
                            .background(colors.ink3)
                            .foregroundColor(theme.brass)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(colors.inkLine, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }

                    // Join group
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Join a group".uppercased())
                            .font(AppFont.mono(10)).tracking(1.2).foregroundColor(colors.textFaint)
                        HStack(spacing: 8) {
                            TextField("Enter group code…", text: $groupCodeDraft)
                                .textFieldStyle(AppTextFieldStyle())
                                #if os(iOS)
                                .textInputAutocapitalization(.characters)
                                #endif
                                .onSubmit { Task { await submitJoinGroup() } }
                            Button { Task { await submitJoinGroup() } } label: {
                                Image(systemName: "arrow.right")
                            }
                            .frame(width: 40, height: 40)
                            .background(colors.ink3)
                            .foregroundColor(theme.brass)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(colors.inkLine, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }

                    // Feedback message
                    if let msg = groupMessage {
                        Text(msg)
                            .font(AppFont.mono(11))
                            .foregroundColor(groupMessageIsError ? colors.red : colors.green)
                            .padding(.top, 2)
                    }
                }
            }
        }
    }

    private func submitCreateGroup() async {
        let result = await store.createReadingGroup(name: groupNameDraft)
        switch result {
        case .success(let msg):
            groupNameDraft = ""
            groupMessage = msg
            groupMessageIsError = false
        case .failure(let msg):
            groupMessage = msg
            groupMessageIsError = true
        }
        clearGroupMessageAfterDelay()
    }

    private func submitJoinGroup() async {
        let result = await store.joinReadingGroup(code: groupCodeDraft)
        switch result {
        case .success(let msg):
            groupCodeDraft = ""
            groupMessage = msg
            groupMessageIsError = false
        case .failure(let msg):
            groupMessage = msg
            groupMessageIsError = true
        }
        clearGroupMessageAfterDelay()
    }

    private func clearGroupMessageAfterDelay() {
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            groupMessage = nil
        }
    }

    // MARK: - Leaderboard

    /// Branches entirely on whether Plus rows came back from the server —
    /// this is presentation only, not the gate itself. The actual withholding
    /// already happened server-side in `get_leaderboard_tiered` (a free/lapsed
    /// caller never receives other traders' rows at all), so there's nothing
    /// for this view to "hide"; it just renders whichever shape it got.
    private var leaderboardSection: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        return VStack(alignment: .leading, spacing: 0) {
            if tieredEntries == nil {
                SectionLabel(text: "Leaderboard")
                CardView { EmptyState(text: "Loading the caravan…") }
            } else if loadError {
                SectionLabel(text: "Leaderboard")
                CardView { EmptyState(text: "Couldn't reach the shared board right now. Try again shortly.") }
            } else if let locked = lockedSelfEntry {
                SectionLabel(text: "Leaderboard")
                PartialRevealLeaderboardCard(
                    percentile: locked.percentile ?? 50,
                    populationCount: locked.populationCount ?? 0,
                    cheerCount: cheersReceived,
                    onUpgrade: { store.shouldShowDay30Paywall = true },
                    brass: theme.brass
                )
            } else if let fullBoard {
                SectionLabel(text: "Leaderboard", trailing: "\(fullBoard.count) traders")
                CardView {
                    if fullBoard.isEmpty {
                        EmptyState(text: "No traders on the board yet. Set your handle above to be first.")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(fullBoard.prefix(20).enumerated()), id: \.element.id) { idx, entry in
                                LeaderRow(rank: idx, entry: entry, isSelf: entry.code == store.state.traderCode, theme: theme)
                            }
                        }
                        if let myRankIndex, myRankIndex >= 20 {
                            Text("You're ranked #\(myRankIndex + 1) of \(fullBoard.count)")
                                .font(AppFont.mono(11)).foregroundColor(colors.textFaint).padding(.top, 8)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Data loading

    private func loadCircle() async {
        loadError = false
        do {
            // Tiered, not the flat `fetchLeaderboard()` — this is what actually
            // enforces the one-way mirror: a free/lapsed caller gets back a
            // single locked row (percentile + population only), never other
            // traders' names or ranks, decided server-side in get_leaderboard_tiered.
            tieredEntries = try await store.subscription.fetchTieredLeaderboard()
        } catch {
            tieredEntries = []
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
            // Stale local hasPlusAccess (trial expired server-side mid-
            // session) — this button shouldn't have been reachable at all.
            // Revert the optimistic "sent" state and silently resync
            // subscription status; the card falls back to its locked state
            // on its own once hasPlusAccess catches up, no paywall interrupt.
            cheerSentAt[code] = nil
            await store.refreshSubscriptionStatus()
            return
        }
        cheerAckStatus[code] = await store.leaderboard.fetchCheerAckStatus(code: code)
    }

    /// Whether `date` falls on today's calendar day. Used to let a duel card's
    /// "Encouragement sent" / "Seen" state expire once the day rolls over,
    /// instead of a stale "Seen" checkmark (or a permanently disabled button)
    /// lingering on screen forever after the one cheer per sender/recipient/day
    /// the backend allows. Once it's a new day, the card falls back to
    /// "Send encouragement" so the duel stays alive.
    private func isToday(_ date: Date?) -> Bool {
        guard let date else { return false }
        return Calendar.current.isDateInToday(date)
    }
}

private struct DuelCard: View {
    @Environment(\.appearanceMode) var appearanceMode
    let code: String
    let friend: FriendSnapshot?
    let myStreak: Int
    let theme: ThemeOption
    let cheerSent: Bool
    let cheerSeen: Bool
    let hasPlusAccess: Bool
    let onRemove: () -> Void
    let onCheer: () async -> Void
    let onUpgrade: () -> Void

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        CardView {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(friend?.name ?? code).font(AppFont.display(15)).foregroundColor(colors.text)
                    Text(friend != nil ? "Level \(friend!.level) · \(code)" : "Hasn't set a handle yet")
                        .font(AppFont.mono(11)).foregroundColor(colors.textFaint)
                }
                Spacer()
                Button(action: onRemove) {
                    Image(systemName: "trash").font(.system(size: 13)).foregroundColor(colors.textFaint)
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
                        Text("YOU").font(AppFont.mono(10)).foregroundColor(colors.textFaint)
                    }
                    .frame(maxWidth: .infinity)
                    Text("vs").font(AppFont.display(12)).italic().foregroundColor(colors.textFaint)
                    VStack(spacing: 3) {
                        HStack(spacing: 5) { Image(systemName: "flame.fill"); Text("\(friendStreak)") }
                            .font(AppFont.mono(19)).foregroundColor(theme.brass)
                        Text(friend.name.uppercased()).font(AppFont.mono(10)).foregroundColor(colors.textFaint)
                    }
                    .frame(maxWidth: .infinity)
                }
                Text(diff > 0 ? "You're \(diff) day\(diff == 1 ? "" : "s") ahead"
                     : diff == 0 ? "Dead even — first to blink loses"
                     : "\(abs(diff)) day\(abs(diff) == 1 ? "" : "s") behind — catch up")
                    .font(.system(size: 11)).italic().foregroundColor(colors.textDim)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
            } else {
                Text("They haven't set a trader handle yet, so no stats to compare.")
                    .font(AppFont.mono(11)).foregroundColor(colors.textFaint)
            }

            if hasPlusAccess {
                Button {
                    Task { await onCheer() }
                } label: {
                    Label(
                        cheerSeen ? "Seen" : (cheerSent ? "Encouragement sent" : "Send encouragement"),
                        systemImage: cheerSeen ? "checkmark.circle.fill" : "megaphone.fill"
                    )
                    .font(.system(size: 12.5))
                }
                .disabled(friend == nil || cheerSent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(colors.ink3)
                .foregroundColor(cheerSeen ? colors.green : theme.brass)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.brassDim, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .opacity(friend == nil || cheerSent ? (cheerSeen ? 1 : 0.55) : 1)
                .padding(.top, 12)
            } else {
                // Free/lapsed: view the duel, but sending encouragement is a
                // Plus-only Caravan interaction — same "view-only" rule as
                // addFriendCard, applied here instead of just disabling the
                // button silently.
                HStack(spacing: 10) {
                    Image(systemName: "lock.fill").font(.system(size: 12)).foregroundColor(colors.textFaint)
                    Text("Encouragement is a Plus feature.")
                        .font(.system(size: 12)).foregroundColor(colors.textDim)
                    Spacer()
                    Button("Upgrade", action: onUpgrade)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.brass)
                }
                .padding(.vertical, 9).padding(.horizontal, 12)
                .background(colors.ink3)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(colors.inkLine, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.top, 12)
            }
        }
    }
}

private struct LeaderRow: View {
    @Environment(\.appearanceMode) var appearanceMode
    let rank: Int
    let entry: LeaderboardEntry
    let isSelf: Bool
    let theme: ThemeOption

    var rankColor: Color {
        let colors = AdaptivePalette(mode: appearanceMode)
        switch rank {
        case 0: return Color(hex: "E8C27A")
        case 1: return Color(hex: "C7CCD4")
        case 2: return Color(hex: "C99A6B")
        default: return colors.textFaint
        }
    }

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
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
                    .font(.system(size: 13.5, weight: .semibold)).foregroundColor(colors.text)
                    .lineLimit(1)
                Text("\(entry.snapshot.streak)d streak · \(timeAgo(entry.snapshot.lastActive))")
                    .font(AppFont.mono(10.5)).foregroundColor(colors.textFaint)
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

private struct ReadingGroupRow: View {
    @Environment(\.appearanceMode) var appearanceMode
    let group: ReadingGroupSummary
    let theme: ThemeOption

    var inviteURL: URL {
        URL(string: "tenscrolls://joingroup?code=\(group.group_code)")!
    }

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name)
                    .font(AppFont.display(15))
                    .foregroundColor(colors.text)
                HStack(spacing: 6) {
                    Text("\(group.member_count) member\(group.member_count == 1 ? "" : "s")")
                        .font(AppFont.mono(11))
                        .foregroundColor(colors.textFaint)
                    Text("·")
                        .font(AppFont.mono(11))
                        .foregroundColor(colors.textFaint)
                    Text(group.group_code)
                        .font(AppFont.mono(11))
                        .foregroundColor(theme.brass)
                        .tracking(0.8)
                }
            }
            Spacer()
            ShareLink(
                item: inviteURL,
                subject: Text("Join \"\(group.name)\" on Ten Scrolls"),
                message: Text("Join our reading group \u{2014} use code \(group.group_code).")
            ) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14))
                    .foregroundColor(colors.textDim)
            }
            .padding(.leading, 8)
        }
        .padding(.vertical, 8)
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

import SwiftUI

// MARK: - Share a scroll to friends / groups

/// Lets the reader pick one or more recipients (trader codes and/or reading
/// groups) and send a scroll's title + notes to them. Presented from the
/// context menu on `ScrollsView`.
struct ShareScrollSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.appearanceMode) var appearanceMode
    @Environment(\.dismiss) private var dismiss

    let scroll: Scroll

    @State private var selectedCodes: Set<String> = []
    @State private var selectedGroupIds: Set<UUID> = []
    @State private var sending = false
    @State private var resultMessage: String?

    var theme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    private var hasRecipients: Bool {
        !selectedCodes.isEmpty || !selectedGroupIds.isEmpty
    }

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Scroll preview
                    VStack(alignment: .leading, spacing: 6) {
                        Text(scroll.title.isEmpty ? "Scroll \(scroll.roman)" : scroll.title)
                            .font(AppFont.display(18)).foregroundColor(colors.text)
                        if !scroll.notes.isEmpty {
                            Text(String(scroll.notes.prefix(120)) + (scroll.notes.count > 120 ? "…" : ""))
                                .font(.system(size: 13)).foregroundColor(colors.textDim)
                                .lineLimit(3)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(colors.ink3)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Friends
                    if !store.state.friendCodes.isEmpty {
                        SectionLabel(text: "Friends")
                        ForEach(store.state.friendCodes, id: \.self) { code in
                            recipientRow(label: code, selected: selectedCodes.contains(code), colors: colors) {
                                if selectedCodes.contains(code) { selectedCodes.remove(code) }
                                else { selectedCodes.insert(code) }
                            }
                        }
                    }

                    // Groups
                    if !store.myReadingGroups.isEmpty {
                        SectionLabel(text: "Reading Groups")
                        ForEach(store.myReadingGroups) { group in
                            recipientRow(
                                label: "\(group.name) (\(group.member_count) member\(group.member_count == 1 ? "" : "s"))",
                                selected: selectedGroupIds.contains(group.group_id),
                                colors: colors
                            ) {
                                if selectedGroupIds.contains(group.group_id) { selectedGroupIds.remove(group.group_id) }
                                else { selectedGroupIds.insert(group.group_id) }
                            }
                        }
                    }

                    if store.state.friendCodes.isEmpty && store.myReadingGroups.isEmpty {
                        EmptyState(text: "Add friends or join a reading group in the Caravan to share scrolls.")
                    }

                    if let resultMessage {
                        Text(resultMessage)
                            .font(AppFont.mono(12))
                            .foregroundColor(resultMessage.starts(with: "Sent") ? colors.green : colors.red)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }
            .background(colors.background)
            .navigationTitle("Share Scroll")
            .inlineNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(colors.textDim)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        Task { await send() }
                    }
                    .disabled(!hasRecipients || sending)
                    .foregroundColor(hasRecipients && !sending ? theme.brass : colors.textFaint)
                }
            }
        }
    }

    private func recipientRow(label: String, selected: Bool, colors: AdaptivePalette, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected ? theme.brass : colors.textFaint)
                Text(label)
                    .font(.system(size: 14)).foregroundColor(colors.text)
                Spacer()
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private func send() async {
        sending = true
        let ok = await store.shareScroll(
            scroll,
            toTraderCodes: Array(selectedCodes),
            toGroupIds: Array(selectedGroupIds)
        )
        sending = false
        resultMessage = ok ? "Sent!" : "Some recipients couldn't be reached."
        if ok {
            try? await Task.sleep(nanoseconds: 800_000_000)
            dismiss()
        }
    }
}

// MARK: - Incoming shared scrolls

/// Shows all scrolls shared to this device and lets the reader import each
/// into one of their ten scroll slots or dismiss it. Presented from the
/// `incomingSharesBanner` in `CaravanView`.
struct IncomingSharedScrollsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.appearanceMode) var appearanceMode
    @Environment(\.dismiss) private var dismiss

    @State private var slotPickerShare: PendingScrollShare?

    var theme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if store.pendingScrollShares.isEmpty {
                        EmptyState(text: "No shared scrolls waiting.")
                    } else {
                        ForEach(store.pendingScrollShares) { share in
                            shareCard(share, colors: colors)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }
            .background(colors.background)
            .navigationTitle("Shared With You")
            .inlineNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(colors.textDim)
                }
            }
            .sheet(item: $slotPickerShare) { share in
                SlotPickerSheet(share: share)
                    .environment(\.appearanceMode, appearanceMode)
            }
        }
    }

    private func shareCard(_ share: PendingScrollShare, colors: AdaptivePalette) -> some View {
        CardView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(share.title.isEmpty ? "Scroll \(share.scroll_number)" : share.title)
                        .font(AppFont.display(16)).foregroundColor(colors.text)
                    Spacer()
                }
                Text("From \(share.from_trader_name.isEmpty ? share.from_trader_code : share.from_trader_name)")
                    .font(AppFont.mono(11)).foregroundColor(colors.textFaint)

                if !share.notes.isEmpty {
                    Text(String(share.notes.prefix(100)) + (share.notes.count > 100 ? "…" : ""))
                        .font(.system(size: 13)).foregroundColor(colors.textDim)
                        .lineLimit(3)
                }

                HStack(spacing: 10) {
                    Button("Import") {
                        slotPickerShare = share
                    }
                    .buttonStyle(PrimaryButtonStyle(brass: theme.brass, glow: theme.glow))

                    Button("Dismiss") {
                        store.dismissSharedScroll(share)
                    }
                    .buttonStyle(GhostButtonStyle())
                }
                .padding(.top, 6)
            }
        }
    }
}

/// Lets the reader choose which of their ten scroll slots to import a
/// shared scroll into. Presented from `IncomingSharedScrollsView`.
private struct SlotPickerSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.appearanceMode) var appearanceMode
    @Environment(\.dismiss) private var dismiss

    let share: PendingScrollShare

    var theme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    Text("Pick a scroll slot to replace with this shared content.")
                        .font(.system(size: 13)).foregroundColor(colors.textDim)
                        .padding(.bottom, 8)

                    ForEach(store.state.scrolls.sorted(by: { $0.id < $1.id })) { scroll in
                        Button {
                            store.importSharedScroll(share, intoSlot: scroll.id)
                            dismiss()
                        } label: {
                            HStack {
                                Text("Scroll \(scroll.roman)")
                                    .font(AppFont.display(15)).foregroundColor(colors.text)
                                Spacer()
                                if !scroll.title.isEmpty {
                                    Text(scroll.title)
                                        .font(AppFont.mono(11)).foregroundColor(colors.textFaint)
                                        .lineLimit(1)
                                }
                                if !scroll.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Image(systemName: "doc.text.fill")
                                        .font(.system(size: 11)).foregroundColor(colors.textFaint)
                                }
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 14)
                            .background(colors.ink3)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(colors.inkLine, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }
            .background(colors.background)
            .navigationTitle("Choose Slot")
            .inlineNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(colors.textDim)
                }
            }
        }
    }
}

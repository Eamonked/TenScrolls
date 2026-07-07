import SwiftUI

struct JournalView: View {
    @EnvironmentObject var store: AppStore
    var openJournal: () -> Void
    var openSearch: () -> Void

    var theme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    var sortedEntries: [JournalEntry] {
        store.state.journal.sorted { $0.date > $1.date }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(sortedEntries.count) ENTRIES").font(AppFont.mono(11)).tracking(1.4).foregroundColor(theme.brass)
                        Text("Journal").font(AppFont.display(28)).foregroundColor(Palette.text)
                    }
                    Spacer()
                    
                    HStack(spacing: 12) {
                        Button(action: openSearch) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(Palette.textDim)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(Palette.ink2))
                                .overlay(Circle().stroke(Palette.inkLine, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: openJournal) {
                            Image(systemName: "plus")
                                .foregroundColor(Palette.textDim)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(Palette.ink2))
                                .overlay(Circle().stroke(Palette.inkLine, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if sortedEntries.isEmpty {
                    EmptyState(text: "No reflections yet.\nTap + to write about today's practice.")
                } else {
                    ForEach(sortedEntries) { entry in
                        JournalEntryRow(entry: entry, scroll: store.state.scrolls.first(where: { $0.id == entry.scrollId })) {
                            store.deleteJournalEntry(entry.id)
                        }
                    }
                }
                Color.clear.frame(height: 10)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
        }
        .background(Palette.background)
    }
}

private struct JournalEntryRow: View {
    let entry: JournalEntry
    let scroll: Scroll?
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(DateKey.short(entry.date)) · Scroll \(scroll?.roman ?? "—")")
                    .font(AppFont.mono(10.5)).foregroundColor(Palette.textFaint)
                Spacer()
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 12)).foregroundColor(Palette.textFaint)
                }
                .buttonStyle(.plain)
            }
            Text(entry.text).font(.system(size: 13.5)).foregroundColor(Palette.text).lineSpacing(4)
        }
        .padding(14)
        .background(Palette.ink2)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.inkLine, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

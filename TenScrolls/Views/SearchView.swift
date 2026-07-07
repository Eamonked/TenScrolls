import SwiftUI

struct SearchView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    var onOpenScroll: (Scroll) -> Void

    var theme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.background.ignoresSafeArea()
                
                if query.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundColor(Palette.ink3)
                        Text("Search your reflections")
                            .font(AppFont.display(20))
                            .foregroundColor(Palette.textDim)
                        Text("Find thoughts across all your journal entries and scroll notes.")
                            .font(.system(size: 14))
                            .foregroundColor(Palette.textFaint)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                } else {
                    let journalMatches = store.state.journal.filter { $0.text.localizedCaseInsensitiveContains(query) }
                    let scrollMatches = store.state.scrolls.filter { $0.notes.localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query) || $0.theme.localizedCaseInsensitiveContains(query) }
                    
                    List {
                        if !journalMatches.isEmpty {
                            Section("Journal Entries") {
                                ForEach(journalMatches) { entry in
                                    JournalMatchRow(entry: entry, scroll: store.state.scrolls.first(where: { $0.id == entry.scrollId }))
                                }
                            }
                        }
                        
                        if !scrollMatches.isEmpty {
                            Section("Scroll Notes") {
                                ForEach(scrollMatches) { scroll in
                                    Button {
                                        onOpenScroll(scroll)
                                    } label: {
                                        ScrollMatchRow(scroll: scroll, themeOption: theme)
                                    }
                                }
                            }
                        }
                        
                        if journalMatches.isEmpty && scrollMatches.isEmpty {
                            Text("No matches found.")
                                .foregroundColor(Palette.textFaint)
                                .listRowBackground(Color.clear)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search notes and journal")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct JournalMatchRow: View {
    let entry: JournalEntry
    let scroll: Scroll?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(DateKey.short(entry.date)) · Scroll \(scroll?.roman ?? "—")")
                .font(AppFont.mono(10.5))
                .foregroundColor(Palette.textFaint)
            Text(entry.text)
                .font(.system(size: 13.5))
                .foregroundColor(Palette.text)
                .lineLimit(5)
                .lineSpacing(4)
        }
        .padding(.vertical, 4)
        .listRowBackground(Palette.ink2)
    }
}

private struct ScrollMatchRow: View {
    let scroll: Scroll
    let themeOption: ThemeOption
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Scroll \(scroll.roman) — \(scroll.title)")
                .font(AppFont.mono(10.5))
                .foregroundColor(themeOption.brass.opacity(0.8))
            Text(scroll.notes)
                .font(.system(size: 13.5))
                .foregroundColor(Palette.text)
                .lineLimit(3)
                .lineSpacing(4)
        }
        .padding(.vertical, 4)
        .listRowBackground(Palette.ink2)
    }
}

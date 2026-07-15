import SwiftUI

struct JournalView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.appearanceMode) var appearanceMode
    var openJournal: () -> Void
    var openSearch: () -> Void

    var theme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    var draftEntries: [JournalEntry] {
        store.state.journal.filter { $0.isDraft }
    }

    var publishedEntries: [JournalEntry] {
        store.state.journal.filter { !$0.isDraft }.sorted { $0.date > $1.date }
    }

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(publishedEntries.count) ENTRIES").font(AppFont.mono(11)).tracking(1.4).foregroundColor(theme.brass)
                        Text("Journal").font(AppFont.display(28)).foregroundColor(colors.text)
                    }
                    Spacer()
                    
                    HStack(spacing: 12) {
                        Button(action: openSearch) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(colors.textDim)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(colors.ink2))
                                .overlay(Circle().stroke(colors.inkLine, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: openJournal) {
                            Image(systemName: "plus")
                                .foregroundColor(colors.textDim)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(colors.ink2))
                                .overlay(Circle().stroke(colors.inkLine, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: { store.addDraftEntry() }) {
                            Image(systemName: "square.and.pencil")
                                .foregroundColor(colors.textDim)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(colors.ink2))
                                .overlay(Circle().stroke(colors.inkLine, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Drafts Section
                if !draftEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("DRAFTS")
                            .font(AppFont.mono(10))
                            .tracking(1.2)
                            .foregroundColor(theme.brass.opacity(0.7))
                            .padding(.top, 8)
                        
                        ForEach(draftEntries) { entry in
                            DraftEntryRow(
                                entry: entry,
                                scroll: store.state.scrolls.first(where: { $0.id == entry.scrollId }),
                                onUpdate: { newText in
                                    store.updateJournalEntry(entry.id, text: newText)
                                },
                                onPublish: {
                                    store.publishDraft(entry.id)
                                },
                                onDelete: {
                                    store.deleteJournalEntry(entry.id)
                                }
                            )
                        }
                    }
                }

                // Published Entries Section
                if !publishedEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        if !draftEntries.isEmpty {
                            Text("PUBLISHED")
                                .font(AppFont.mono(10))
                                .tracking(1.2)
                                .foregroundColor(theme.brass.opacity(0.7))
                                .padding(.top, 12)
                        }
                        
                        ForEach(publishedEntries) { entry in
                            JournalEntryRow(
                                entry: entry,
                                scroll: store.state.scrolls.first(where: { $0.id == entry.scrollId }),
                                onDelete: {
                                    store.deleteJournalEntry(entry.id)
                                },
                                onConvertToDraft: {
                                    store.convertToDraft(entry.id)
                                }
                            )
                        }
                    }
                }

                if draftEntries.isEmpty && publishedEntries.isEmpty {
                    EmptyState(text: "No reflections yet.\nTap + to write about today's practice or ✎ to start a draft.")
                }
                
                Color.clear.frame(height: 10)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
        }
        .background(colors.background)
    }
}

private struct DraftEntryRow: View {
    @Environment(\.appearanceMode) var appearanceMode
    let entry: JournalEntry
    let scroll: Scroll?
    let onUpdate: (String) -> Void
    let onPublish: () -> Void
    let onDelete: () -> Void
    @State private var editedText: String
    @State private var isEditing = false
    @FocusState private var isFocused: Bool

    init(entry: JournalEntry, scroll: Scroll?, onUpdate: @escaping (String) -> Void, onPublish: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.entry = entry
        self.scroll = scroll
        self.onUpdate = onUpdate
        self.onPublish = onPublish
        self.onDelete = onDelete
        _editedText = State(initialValue: entry.text)
    }

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DRAFT · Scroll \(scroll?.roman ?? "—")")
                    .font(AppFont.mono(10.5))
                    .foregroundColor(colors.textFaint)
                Spacer()
                
                HStack(spacing: 12) {
                    if !editedText.isEmpty {
                        Button(action: {
                            onPublish()
                        }) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 16))
                                .foregroundColor(Palette.theme(for: "default").brass)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundColor(colors.textFaint)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            TextEditor(text: $editedText)
                .font(.system(size: 13.5))
                .foregroundColor(colors.text)
                .scrollContentBackground(.hidden)
                .background(colors.ink2)
                .frame(minHeight: 80)
                .focused($isFocused)
                .onChange(of: editedText) { _, newValue in
                    onUpdate(newValue)
                }
                .onAppear {
                    if entry.text.isEmpty {
                        isFocused = true
                    }
                }
        }
        .padding(14)
        .background(colors.ink2)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.theme(for: "default").brass.opacity(0.4), lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct JournalEntryRow: View {
    @Environment(\.appearanceMode) var appearanceMode
    let entry: JournalEntry
    let scroll: Scroll?
    let onDelete: () -> Void
    let onConvertToDraft: () -> Void
    @State private var expanded = false

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(DateKey.short(entry.date)) · Scroll \(scroll?.roman ?? "—")")
                    .font(AppFont.mono(10.5)).foregroundColor(colors.textFaint)
                Spacer()
                if expanded {
                    Button(action: onDelete) {
                        Image(systemName: "trash").font(.system(size: 12)).foregroundColor(colors.textFaint)
                    }
                    .buttonStyle(.plain)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(colors.textFaint)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            Text(entry.text)
                .font(.system(size: 13.5))
                .foregroundColor(colors.text)
                .lineSpacing(4)
                .lineLimit(expanded ? nil : 1)
                .truncationMode(.tail)
        }
        .padding(14)
        .background(colors.ink2)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(colors.inkLine, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        }
        .contextMenu {
            Button {
                onConvertToDraft()
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

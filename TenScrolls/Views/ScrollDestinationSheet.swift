import SwiftUI

/// Presented when the reader picks "Save as Scroll" on a Library excerpt or
/// a whole chapter. Ten Scrolls only ever has ten scroll slots — there's no
/// "create an eleventh" — so this is a destination picker, not a creation
/// form: choose which of the ten the incoming text should become, give it a
/// title, and confirm. Picking a slot that already has notes shows an
/// explicit overwrite warning inline rather than silently clobbering it,
/// since `AppStore.importDocument` replaces a scroll's notes outright.
struct ScrollDestinationSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.appearanceMode) var appearanceMode
    @Environment(\.dismiss) private var dismiss

    /// The text being promoted — a highlighted selection, or a full chapter's
    /// paragraphs already joined with blank-line breaks.
    let text: String
    /// Prefilled from the selection's source: the chapter title if this came
    /// from "make this chapter a scroll", otherwise left blank for the
    /// reader to name a bare excerpt themselves.
    let suggestedTitle: String?
    /// Called after a successful save, so the presenting view can dismiss
    /// any of its own state (e.g. clear a pending-excerpt flag) too.
    var onSaved: () -> Void = {}

    @State private var selectedScrollId: Int?
    @State private var title: String = ""

    private var sortedScrolls: [Scroll] {
        store.state.scrolls.sorted { $0.id < $1.id }
    }

    private var selectedScroll: Scroll? {
        guard let selectedScrollId else { return nil }
        return store.state.scrolls.first { $0.id == selectedScrollId }
    }

    private var willOverwrite: Bool {
        guard let selectedScroll else { return false }
        return !selectedScroll.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var themeOption: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Choose which of the ten scrolls this becomes. Ten Scrolls always has exactly ten — saving here replaces that scroll's current notes.")
                        .font(.system(size: 13))
                        .foregroundColor(colors.textDim)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("SCROLL").font(AppFont.mono(10.5)).tracking(1.2).foregroundColor(colors.textFaint)
                        VStack(spacing: 8) {
                            ForEach(sortedScrolls) { scroll in
                                scrollRow(scroll, colors: colors)
                            }
                        }
                    }

                    if willOverwrite, let selectedScroll {
                        Label("Scroll \(selectedScroll.roman) already has notes — saving will replace them. Its progress and mastery status are kept.", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12.5))
                            .foregroundColor(colors.textDim)
                            .padding(10)
                            .background(colors.ink3)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("TITLE").font(AppFont.mono(10.5)).tracking(1.2).foregroundColor(colors.textFaint)
                        TextField("Give this scroll a title", text: $title).textFieldStyle(AppTextFieldStyle())
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("PREVIEW").font(AppFont.mono(10.5)).tracking(1.2).foregroundColor(colors.textFaint)
                        Text(text)
                            .font(.system(size: 13, design: .serif))
                            .foregroundColor(colors.textDim)
                            .lineLimit(6)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(colors.ink3)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    Button("Save as Scroll\(selectedScroll.map { " \($0.roman)" } ?? "")") {
                        guard let selectedScrollId else { return }
                        store.importDocument(text: text, title: title.isEmpty ? nil : title, intoScrollId: selectedScrollId)
                        onSaved()
                        dismiss()
                    }
                    .buttonStyle(PrimaryButtonStyle(brass: themeOption.brass, glow: themeOption.glow, disabled: selectedScrollId == nil))
                    .disabled(selectedScrollId == nil)

                    Color.clear.frame(height: 10)
                }
                .padding(20)
            }
            .background(colors.ink2.ignoresSafeArea())
            .navigationTitle("Save as Scroll")
            .inlineNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            title = suggestedTitle ?? ""
            // Default to the first empty scroll when there is one, so the
            // common case (filling out scrolls in order) needs no picking —
            // otherwise leave it unselected so an overwrite is always a
            // deliberate tap.
            if selectedScrollId == nil {
                selectedScrollId = sortedScrolls.first { $0.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.id
            }
        }
    }

    @ViewBuilder
    private func scrollRow(_ scroll: Scroll, colors: AdaptivePalette) -> some View {
        let isSelected = selectedScrollId == scroll.id
        let hasNotes = !scroll.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        Button {
            selectedScrollId = scroll.id
        } label: {
            HStack(spacing: 12) {
                Text(scroll.roman)
                    .font(AppFont.display(15))
                    .foregroundColor(isSelected ? themeOption.brass : colors.text)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(scroll.title.isEmpty ? "Untitled" : scroll.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(colors.text)
                    Text(rowStatus(scroll, hasNotes: hasNotes))
                        .font(AppFont.mono(10)).tracking(0.6)
                        .foregroundColor(colors.textFaint)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? themeOption.brass : colors.textFaint)
            }
            .padding(12)
            .background(colors.ink2)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? themeOption.brass : colors.inkLine, lineWidth: isSelected ? 1.5 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func rowStatus(_ scroll: Scroll, hasNotes: Bool) -> String {
        let statusLabel: String
        switch scroll.status {
        case .locked: statusLabel = "Locked"
        case .mastered: statusLabel = "Mastered"
        case .active: statusLabel = "Active"
        }
        return (hasNotes ? "\(statusLabel) · has notes" : "\(statusLabel) · empty").uppercased()
    }
}

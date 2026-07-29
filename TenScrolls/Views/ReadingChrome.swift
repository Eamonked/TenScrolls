import SwiftUI

/// Shared reading-experience chrome for both the Library reader and the
/// Scroll reading view, modeled on Apple Books: one "Aa" text-size control,
/// and a thin bottom progress track with a tappable "Chapter N of M" /
/// percentage readout in place of a row of navigation buttons.

// MARK: - "Aa" text size control

/// The text-size popover — a small "A" and a large "A" flanking a slider,
/// the same shape as Apple Books' own size control. Persisted through
/// `AppStore.setReadingFontScale`, so the choice carries across every book
/// and scroll.
struct ReadingFontSizeControl: View {
    @Environment(\.appearanceMode) var appearanceMode
    @Binding var scale: Double
    var brass: Color

    // The slider drags against this local copy rather than `scale`
    // directly. `scale` is wired straight to `AppStore.setReadingFontScale`
    // (see `Sheets.swift`/`LibraryReaderView.swift`), which triggers a full
    // `@Published` state change and, downstream, a full `WKWebView`
    // `loadHTMLString` reformat in `BookChapterWebView` on every distinct
    // value it's set to. Writing that on every intermediate 0.1 step of a
    // drag — rather than once the drag ends — was queuing a new reload
    // several times a second: reloads chained faster than WebKit's column
    // layout could settle between them, which is what made the reading
    // view's page count/measurement fall out of sync and the swipe
    // occasionally stop registering until the sheet was closed and
    // reopened. `liveScale` keeps the slider itself perfectly smooth; only
    // the final value on release is committed.
    @State private var liveScale: Double = 1.0

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        VStack(alignment: .leading, spacing: 14) {
            Text("Text Size")
                .font(AppFont.mono(11))
                .tracking(1.2)
                .foregroundColor(colors.textFaint)
            HStack(spacing: 12) {
                Text("A")
                    .font(.system(size: 13, weight: .medium, design: .serif))
                    .foregroundColor(colors.textDim)
                Slider(value: $liveScale, in: 0.8...1.6, step: 0.1, onEditingChanged: { editing in
                    if !editing {
                        scale = liveScale
                    }
                })
                    .tint(brass)
                Text("A")
                    .font(.system(size: 24, weight: .medium, design: .serif))
                    .foregroundColor(colors.textDim)
            }
        }
        .padding(18)
        .frame(width: 260)
        .background(colors.ink2)
        .onAppear { liveScale = scale }
    }
}

// MARK: - Bottom progress bar

/// A thin, Apple-Books-style progress indicator pinned to the bottom of a
/// reading view: a hairline track showing how far through the current
/// chapter/scroll the reader has scrolled, a small caption, and optional
/// chevrons for quickly stepping to the previous/next chapter.
struct ReadingProgressBar: View {
    @Environment(\.appearanceMode) var appearanceMode
    let progress: Double // 0...1
    let caption: String
    var brass: Color
    var backgroundColor: Color
    var onTapCaption: (() -> Void)? = nil
    var onPrevious: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(colors.inkLine.opacity(0.7))
                    Capsule().fill(brass).frame(width: geo.size.width * max(0, min(1, progress)))
                }
            }
            .frame(height: 3)

            HStack {
                let showsPaging = onPrevious != nil || onNext != nil
                if showsPaging {
                    stepButton(systemImage: "chevron.left", action: onPrevious, colors: colors)
                    Spacer(minLength: 8)
                }
                Button {
                    onTapCaption?()
                } label: {
                    Text(caption)
                        .font(AppFont.mono(10.5))
                        .tracking(0.6)
                        .foregroundColor(colors.textFaint)
                }
                .buttonStyle(.plain)
                .disabled(onTapCaption == nil)
                .frame(maxWidth: showsPaging ? nil : .infinity)
                if showsPaging {
                    Spacer(minLength: 8)
                    stepButton(systemImage: "chevron.right", action: onNext, colors: colors)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(alignment: .top) {
            LinearGradient(
                colors: [backgroundColor.opacity(0), backgroundColor.opacity(0.96)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 60)
            .allowsHitTesting(false)
        }
        .background(backgroundColor)
    }

    @ViewBuilder
    private func stepButton(systemImage: String, action: (() -> Void)?, colors: AdaptivePalette) -> some View {
        Button {
            action?()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(action == nil ? colors.textFaint.opacity(0.35) : colors.textDim)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

// MARK: - Table of contents

/// A proper contents list for a Library book, replacing a bare dropdown
/// menu — the current chapter is highlighted, and tapping any other one
/// jumps straight there, same as Apple Books' contents sheet.
struct BookTableOfContentsSheet: View {
    @Environment(\.appearanceMode) var appearanceMode
    @Environment(\.dismiss) private var dismiss
    let book: Book
    let currentChapterIndex: Int
    let brass: Color
    let onSelect: (Int) -> Void
    /// Turns a whole chapter into a Scroll (see `ScrollDestinationSheet`).
    /// Optional so this sheet still works anywhere a caller has no such
    /// destination to offer.
    var onMakeScroll: ((Int) -> Void)? = nil

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        NavigationStack {
            List {
                ForEach(Array(book.chapters.enumerated()), id: \.offset) { index, chapter in
                    Button {
                        onSelect(index)
                    } label: {
                        HStack {
                            Text(chapterLabel(chapter, index: index))
                                .font(.system(size: 15, design: .serif))
                                .foregroundColor(index == currentChapterIndex ? brass : colors.text)
                            Spacer()
                            if index == currentChapterIndex {
                                Image(systemName: "book.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(brass)
                            }
                        }
                    }
                    .listRowBackground(colors.ink2)
                    .swipeActions(edge: .trailing) {
                        if let onMakeScroll {
                            Button {
                                onMakeScroll(index)
                            } label: {
                                Label("Save as Scroll", systemImage: "scroll")
                            }
                            .tint(brass)
                        }
                    }
                    .contextMenu {
                        if let onMakeScroll {
                            Button {
                                onMakeScroll(index)
                            } label: {
                                Label("Save as Scroll", systemImage: "scroll")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(colors.background.ignoresSafeArea())
            .navigationTitle(book.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func chapterLabel(_ chapter: BookChapter, index: Int) -> String {
        if let title = chapter.title, !title.isEmpty { return title }
        return "Chapter \(index + 1)"
    }
}

import SwiftUI
import UniformTypeIdentifiers

struct DocumentImportSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.appearanceMode) var appearanceMode
    @Environment(\.dismiss) private var dismiss

    private struct ParsedDocument {
        let filename: String
        /// Ordered natural chunks — EPUB chapters, or PDF pages.
        let chunks: [String]
        let titles: [String?]
    }

    private enum Stage {
        case pickFile
        case parsing
        case configure(ParsedDocument)
        case failed(String)
    }

    private enum Destination: String, CaseIterable, Hashable {
        case singleScroll = "One scroll"
        case allTen = "All ten scrolls"
    }

    @State private var stage: Stage = .pickFile
    @State private var showFilePicker = false
    @State private var destination: Destination = .allTen
    @State private var selectedScrollId: Int?

    var theme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .pickFile: pickFileView
                case .parsing: parsingView
                case .configure(let doc): configureView(doc)
                case .failed(let message): failedView(message)
                }
            }
            .navigationTitle("Import Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.pdf, epubType],
            onCompletion: handlePickedFile
        )
        .onAppear { showFilePicker = true }
    }

    private var epubType: UTType {
        UTType("org.idpf.epub-container") ?? UTType(filenameExtension: "epub") ?? .data
    }

    // MARK: - Stages

    private var pickFileView: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        return VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 40))
                .foregroundColor(colors.textFaint)
            Text("Choose a PDF or EPUB")
                .foregroundColor(colors.textDim)
            Button("Choose File") { showFilePicker = true }
                .buttonStyle(PrimaryButtonStyle(brass: theme.brass, glow: theme.glow, disabled: false))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var parsingView: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        return VStack(spacing: 12) {
            ProgressView()
            Text("Reading document…").foregroundColor(colors.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func failedView(_ message: String) -> some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        return VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(colors.red)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundColor(colors.textDim)
                .padding(.horizontal)
            Button("Try another file") {
                stage = .pickFile
                showFilePicker = true
            }
            .buttonStyle(GhostButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func configureView(_ doc: ParsedDocument) -> some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        return Form {
            Section("Source") {
                Text(doc.filename).foregroundColor(colors.text)
                Text("\(doc.chunks.count) section\(doc.chunks.count == 1 ? "" : "s") found")
                    .font(.system(size: 12))
                    .foregroundColor(colors.textFaint)
            }

            Section("Import into") {
                Picker("Destination", selection: $destination) {
                    ForEach(Destination.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if destination == .singleScroll {
                    Picker("Scroll", selection: $selectedScrollId) {
                        ForEach(store.state.scrolls.sorted(by: { $0.id < $1.id })) { scroll in
                            Text("Scroll \(scroll.roman)\(scroll.title.isEmpty ? "" : " — \(scroll.title)")")
                                .tag(Optional(scroll.id))
                        }
                    }
                }
            }

            if let warning = overwriteWarning {
                Section {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12.5))
                        .foregroundColor(colors.red)
                }
            }

            Section {
                Button("Import") { apply(doc) }
                    .disabled(destination == .singleScroll && selectedScrollId == nil)
            }
        }
        .onAppear {
            if selectedScrollId == nil {
                selectedScrollId = store.state.activeScroll?.id ?? store.state.scrolls.first?.id
            }
        }
    }

    private var overwriteWarning: String? {
        switch destination {
        case .singleScroll:
            guard let id = selectedScrollId,
                  let existing = store.state.scrolls.first(where: { $0.id == id }),
                  !existing.notes.isEmpty else { return nil }
            return "This will replace Scroll \(existing.roman)'s existing notes."
        case .allTen:
            guard store.state.scrolls.contains(where: { !$0.notes.isEmpty }) else { return nil }
            return "This will replace notes on any scroll that already has them."
        }
    }

    // MARK: - Parsing

    private func handlePickedFile(_ result: Result<URL, Error>) {
        switch result {
        case .failure:
            stage = .failed("Couldn't access that file.")
        case .success(let url):
            stage = .parsing
            parse(url)
        }
    }

    private func parse(_ url: URL) {
        Task.detached(priority: .userInitiated) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let ext = url.pathExtension.lowercased()
                let chunks: [String]
                let titles: [String?]
                if ext == "epub" {
                    let parsed = try EPUBParser.extractChapters(from: url)
                    chunks = parsed.map { $0.text }
                    titles = parsed.map { $0.title }
                } else {
                    chunks = try PDFImporter.extractPages(from: url)
                    titles = Array(repeating: nil, count: chunks.count)
                }
                let doc = ParsedDocument(filename: url.lastPathComponent, chunks: chunks, titles: titles)
                await MainActor.run { stage = .configure(doc) }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "This file couldn't be read."
                await MainActor.run { stage = .failed(message) }
            }
        }
    }

    // MARK: - Apply

    private func apply(_ doc: ParsedDocument) {
        switch destination {
        case .singleScroll:
            guard let id = selectedScrollId else { return }
            let text = doc.chunks.joined(separator: "\n\n")
            let title = doc.titles.compactMap { $0 }.first
            store.importDocument(text: text, title: title, intoScrollId: id)
        case .allTen:
            let buckets = DocumentSplitter.distribute(doc.chunks, into: 10)
            store.importDocumentAcrossAllScrolls(buckets)
        }
        dismiss()
    }
}

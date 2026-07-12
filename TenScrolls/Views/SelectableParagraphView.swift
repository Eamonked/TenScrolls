import SwiftUI
import UIKit

/// A read-only, selectable block of scroll text. Two things it adds over a
/// plain SwiftUI `Text`:
///
/// 1. Selecting a phrase and bringing up the system's native copy/lookup menu
///    also shows "Add to Journal" as a real item in that same menu, so quoting
///    a line into the journal feels like part of iOS, not a bolted-on feature.
/// 2. A plain tap anywhere in the paragraph — which a non-editing text view
///    otherwise ignores — reports "this is where I stopped reading," so the
///    scroll can resume here next time it's opened.
struct SelectableParagraphView: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let textColor: UIColor
    let lineSpacing: CGFloat
    var onAddToJournal: (String) -> Void
    var onTapped: () -> Void

    func makeUIView(context: Context) -> ParagraphTextView {
        let view = ParagraphTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        // Non-editable UITextViews don't otherwise respond to a plain single
        // tap (selection uses long-press/double/triple-tap), so this doesn't
        // fight the built-in selection gestures.
        view.addGestureRecognizer(tap)

        applyText(to: view)
        return view
    }

    func updateUIView(_ uiView: ParagraphTextView, context: Context) {
        context.coordinator.onTapped = onTapped
        uiView.onAddToJournal = onAddToJournal
        applyText(to: uiView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ParagraphTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTapped: onTapped)
    }

    private func applyText(to view: ParagraphTextView) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        let font = serifFont(size: fontSize)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: style
        ])
        // Avoid clobbering an in-progress selection on redundant updates.
        if view.attributedText != attributed {
            view.attributedText = attributed
        }
        view.onAddToJournal = onAddToJournal
    }

    private func serifFont(size: CGFloat) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: .regular)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTapped: () -> Void
        init(onTapped: @escaping () -> Void) {
            self.onTapped = onTapped
        }

        @objc func handleTap() {
            onTapped()
        }
    }
}

/// UITextView subclass that injects "Add to Journal" into the native
/// selection menu when there's an active, non-empty selection.
final class ParagraphTextView: UITextView {
    var onAddToJournal: ((String) -> Void)?

    override func editMenu(for textRange: UITextRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let selectedRange = selectedTextRange,
              let excerpt = text(in: selectedRange)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !excerpt.isEmpty else {
            return super.editMenu(for: textRange, suggestedActions: suggestedActions)
        }
        let addToJournal = UIAction(title: "Add to Journal", image: UIImage(systemName: "book")) { [weak self] _ in
            self?.onAddToJournal?(excerpt)
            self?.selectedTextRange = nil
        }
        return UIMenu(children: [addToJournal] + suggestedActions)
    }
}
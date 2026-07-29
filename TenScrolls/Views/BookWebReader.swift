import SwiftUI
import WebKit

// MARK: - Reading engine (CSS-column pagination)

/// Renders one chapter's sanitized HTML (see `EPUBParser.extractChapters`)
/// as a horizontally paged book, using the browser's own CSS multi-column
/// layout to do the actual measuring — the same technique behind Apple
/// Books and virtually every other EPUB reader. Tables, images,
/// blockquotes, and footnotes all survive because nothing ever flattens
/// the DOM the way a paragraph-based approach (measuring plain text and
/// packing it into pages, as the old Library reader and `ScrollEditorSheet`
/// still do) has to.
///
/// The trick (standard for WKWebView-based paginated readers): give the
/// document a fixed `height` equal to the available reading area and let
/// `column-fill: auto` stack content top-to-bottom within that height
/// before starting a new column — instead of overflowing vertically, the
/// overflow becomes additional *columns*, which extends the document's
/// rendered width far past one screen. That horizontal overflow is exactly
/// what the webview's own `UIScrollView` already knows how to page through
/// (`isPagingEnabled = true`), so no separate estimation pass is needed —
/// unlike `TextPaginator.measuredHeight`, which is a second, independent
/// guess at layout that can drift from what's actually rendered.
///
/// `column-width` is set to the *content* width (view width minus side
/// margins) and `column-gap` to twice the side margin, so each margin is
/// really half of the gap between two adjacent columns — the standard way
/// to get symmetric left/right margins on every page rather than only the
/// very first and last one. See `Self.document(...)` for the exact CSS.
struct BookChapterWebView: UIViewRepresentable {
    let html: String
    let theme: ThemeOption
    let appearanceMode: AppearanceMode
    let fontScale: CGFloat
    /// The reading area's size — explicit, rather than read from
    /// `webView.bounds`, so that a pure size change from an upstream
    /// `GeometryReader` (rotation, split view) reliably triggers
    /// `updateUIView` the way SwiftUI's normal diffing does for any other
    /// value-typed input, rather than depending on UIKit layout timing.
    let size: CGSize
    @Binding var currentPage: Int
    @Binding var pageCount: Int
    /// A 0...1 fraction to restore the first time *this* chapter's content
    /// finishes laying out — e.g. a saved bookmark. Read once and ignored
    /// after; subsequent reloads of the same chapter (rotation, font-size
    /// change, theme switch) instead preserve whatever page the reader is
    /// currently on, the same way `LibraryReaderView.paginate`'s
    /// `preservePosition` does for the paragraph-based reader. Pass nil to
    /// start at the first page.
    var initialFraction: Double? = nil
    /// Lets a hosting view drive paging programmatically (footer chevrons,
    /// swiping past the last page into the next chapter) — the WKWebView
    /// counterpart to `PageTurnContainer`'s `selection` binding, since a
    /// web view's own scroll offset isn't something a plain `Binding<Int>`
    /// can set directly.
    var proxy: BookWebReaderProxy? = nil
    /// Fired when the reader swipes past the last page of this chapter —
    /// detected via elastic overscroll (see `Coordinator.scrollViewDidScroll`)
    /// rather than a real next page existing, since a chapter can be a
    /// single page with nothing to page into. `LibraryReaderView` uses this
    /// to advance `htmlCurrentChapterIndex` and land on the next chapter's
    /// first page, the WKWebView counterpart to the old paragraph reader's
    /// flat, book-wide page list.
    var onRequestNextChapter: (() -> Void)? = nil
    /// Mirrors `onRequestNextChapter` for swiping past the first page,
    /// landing on the previous chapter's last page (`initialFraction: 1`).
    var onRequestPreviousChapter: (() -> Void)? = nil
    /// Mirrors `SelectableParagraphView.onAddToJournal` — nil wherever
    /// there's nowhere to send a quoted excerpt. Wired into the system
    /// selection menu via `BookWebView.buildMenu(with:)`, not a SwiftUI
    /// gesture, since a WKWebView's own text selection isn't visible to
    /// SwiftUI at all.
    var onAddToJournal: ((String) -> Void)? = nil
    /// Mirrors `SelectableParagraphView.onSaveAsScroll`.
    var onSaveAsScroll: ((String) -> Void)? = nil
    /// Fired when a paragraph carrying a `data-p="N"` attribute is tapped —
    /// see `Self.paragraphTapBridgeScript`. Mirrors `SelectableParagraphView.onTapped`
    /// for callers (currently `ScrollEditorSheet`) that bookmark a reading
    /// position at paragraph granularity rather than `BookWebReaderProxy`'s
    /// page/chapter granularity. Only paragraphs the caller actually marks up
    /// with `data-p` fire this — plain chapter HTML with no such markup never
    /// does, so this is a no-op for `LibraryReaderView`.
    var onParagraphTap: ((Int) -> Void)? = nil
    /// Fired when an element carrying a `data-action="..."` attribute is
    /// tapped — see `Self.actionTapBridgeScript`. A generic counterpart to
    /// `onParagraphTap` for header/chrome elements flowed into the document
    /// (e.g. `ScrollEditorSheet.statusPillHTML`) that need to trigger a
    /// native action rather than bookmark a reading position. The string
    /// passed back is whatever the caller put in `data-action`, so one
    /// bridge can serve several different tappable elements in the same
    /// document.
    var onActionTap: ((String) -> Void)? = nil

    /// Side margin each page gets — half of `column-gap`, the other half
    /// belonging to the adjacent page. Mirrors `TextPaginator.horizontalPadding / 2`.
    static let sideMargin: CGFloat = 28
    static let topPadding: CGFloat = 22
    static let bottomPadding: CGFloat = 22
    static let baseFontSize: CGFloat = 16

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> BookWebView {
        let config = WKWebViewConfiguration()
        config.dataDetectorTypes = []
        // Every chapter is sanitized (see `EPUBParser`) to strip scripts,
        // stylesheets, and external references before it ever reaches
        // here, but this is defense in depth against a chapter loaded from
        // an older, pre-sanitization saved book file.
        config.limitsNavigationsToAppBoundDomains = true
        // JS stays enabled — the stage 3 selection menu (`window.getSelection()`)
        // depends on it. See `EPUBParser.sanitizeChapterHTML`'s stripping of
        // inline event-handler attributes and `javascript:` URIs, which is
        // what makes turning this on safe: `<script>` tags alone aren't the
        // only way markup can run code.

        // Selection bridge: WKWebView has no SwiftUI-visible notion of "what's
        // currently selected", and `BookWebView.buildMenu(with:)` (below) is
        // only handed a menu builder, not the selection — so a small
        // always-listening script keeps `BookWebView.selectedExcerpt` in sync
        // on every `selectionchange`, and the menu build reads whatever's
        // already there instead of awaiting JS at build time.
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: Coordinator.selectionMessageName)
        controller.addUserScript(WKUserScript(
            source: Self.selectionBridgeScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        controller.add(context.coordinator, name: Coordinator.paragraphTapMessageName)
        controller.addUserScript(WKUserScript(
            source: Self.paragraphTapBridgeScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        controller.add(context.coordinator, name: Coordinator.actionTapMessageName)
        controller.addUserScript(WKUserScript(
            source: Self.actionTapBridgeScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        config.userContentController = controller

        let webView = BookWebView(frame: .zero, configuration: config)
        webView.onAddToJournal = onAddToJournal
        webView.onSaveAsScroll = onSaveAsScroll
        webView.navigationDelegate = context.coordinator
        webView.scrollView.delegate = context.coordinator
        context.coordinator.webView = webView
        webView.scrollView.isPagingEnabled = true
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.bounces = true
        // Forces elastic overscroll even when a chapter is a single page
        // with no scrollable content of its own — otherwise a swipe on a
        // short chapter would produce no scroll events at all, and
        // `scrollViewDidScroll`'s edge detection (which is what lets a
        // swipe cross a chapter boundary) would never fire.
        webView.scrollView.alwaysBounceHorizontal = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif
        return webView
    }

    static func dismantleUIView(_ webView: BookWebView, coordinator: Coordinator) {
        // `WKUserContentController.add(_:name:)` retains its handler, so
        // without this the coordinator (and everything it closes over)
        // would leak for as long as the webview's configuration is alive.
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.selectionMessageName)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.paragraphTapMessageName)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.actionTapMessageName)
    }

    func updateUIView(_ webView: BookWebView, context: Context) {
        context.coordinator.parent = self
        proxy?.scrollView = webView.scrollView
        webView.onAddToJournal = onAddToJournal
        webView.onSaveAsScroll = onSaveAsScroll

        guard size.width > 0, size.height > 0 else { return }
        let key = Coordinator.RenderKey(
            themeId: theme.id, mode: appearanceMode, fontScale: fontScale,
            width: size.width, height: size.height
        )
        guard context.coordinator.loadedHTML != html || context.coordinator.loadedKey != key else { return }

        // Only preserve the current scroll position across a reload when
        // the chapter's content itself hasn't changed — a size/theme/font
        // change on the SAME chapter should keep the reader's place, but
        // switching to a genuinely new chapter should not carry over the
        // old chapter's fraction.
        let sameContent = context.coordinator.loadedHTML == html
        let fraction: Double?
        if sameContent, context.coordinator.pageCount > 0 {
            fraction = context.coordinator.currentFraction(in: webView)
        } else {
            fraction = initialFraction
        }

        // A font-size slider fires several of these updates in quick
        // succession as it's dragged (one per 0.1 step). Each one used to
        // call `loadHTMLString` immediately, which cancels whatever
        // navigation was already in flight — but `measureAndSettle` for
        // that cancelled load could still be mid-flight (it runs one
        // runloop turn after `didFinish`), so it could end up measuring
        // the wrong document, or racing the newer load's own settle and
        // leaving `pageCount`/the scroll offset in a state that doesn't
        // match what's actually on screen — which is what made paging
        // look broken right after adjusting text size. While a navigation
        // is already in flight, coalesce into `pendingRender` instead of
        // starting another one; `didFinish` below picks up the latest
        // pending request (if any) once the current one actually settles,
        // so only ever one navigation is in flight at a time.
        let request = Coordinator.RenderRequest(html: html, key: key, fraction: fraction, isReformat: sameContent)
        if context.coordinator.isNavigating {
            context.coordinator.pendingRender = request
            return
        }
        context.coordinator.performLoad(request, on: webView)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate, WKScriptMessageHandler {
        /// Name shared between `WKUserContentController.add(_:name:)` and
        /// `Self.selectionBridgeScript`'s `postMessage` call — kept as one
        /// constant so the two can't drift apart.
        static let selectionMessageName = "selection"
        /// Mirrors `selectionMessageName` for `Self.paragraphTapBridgeScript`'s
        /// tap-position postMessage.
        static let paragraphTapMessageName = "paragraphTap"
        /// Mirrors `selectionMessageName` for `Self.actionTapBridgeScript`'s
        /// `data-action` postMessage.
        static let actionTapMessageName = "actionTap"

        var parent: BookChapterWebView
        var loadedHTML: String?
        var loadedKey: RenderKey?
        /// The webview this coordinator is currently attached to, so
        /// `userContentController(_:didReceive:)` — which only gets a
        /// message, not the webview it came from — has somewhere to write
        /// the selection. Set alongside `webView.navigationDelegate` in
        /// `makeUIView`.
        weak var webView: BookWebView?
        var pageCount: Int = 0 {
            didSet {
                if pageCount != oldValue { parent.pageCount = pageCount }
            }
        }
        var pendingRestoreFraction: Double?
        /// True from the moment `loadHTMLString` is called until this
        /// webview's `didFinish` (or a failed navigation) reports back —
        /// guards against starting a second navigation while one is still
        /// in flight (see `performLoad` and `pendingRender`).
        var isNavigating = false
        /// The most recently requested render, coalesced here whenever
        /// `updateUIView` is called while `isNavigating` is already true.
        /// Only ever holds the latest request, never a queue — once a
        /// navigation is in flight there's no value in replaying every
        /// intermediate font-size step, only the final one.
        var pendingRender: RenderRequest?
        /// Set once per drag gesture so a single swipe past an edge can
        /// only trigger one chapter change, even though `scrollViewDidScroll`
        /// fires many times over the course of that same drag.
        private var firedEdgeThisGesture = false
        /// How far past the content bounds (in points) a drag has to
        /// stretch before it counts as "trying to turn past this chapter"
        /// rather than just the normal rubber-band resistance at a real
        /// page boundary. Chosen empirically — small enough to feel
        /// responsive, large enough that a page that merely overshoots its
        /// snap target on a fast swipe doesn't accidentally trigger it.
        private static let edgeOverscrollThreshold: CGFloat = 56

        init(_ parent: BookChapterWebView) {
            self.parent = parent
        }

        struct RenderKey: Equatable {
            let themeId: String
            let mode: AppearanceMode
            let fontScale: CGFloat
            let width: CGFloat
            let height: CGFloat
        }

        /// One coalesced ask from `updateUIView`: the fully-assembled HTML
        /// to load, the key that produced it, and the 0...1 fraction to
        /// restore once it settles.
        struct RenderRequest {
            let html: String
            let key: RenderKey
            let fraction: Double?
            /// True when this reload is reformatting the SAME chapter's
            /// content — a font size, theme, or size change — rather than
            /// loading genuinely new content. Lets `performLoad` leave the
            /// last-known `pageCount` in place as a placeholder instead of
            /// zeroing it out for the duration of the reload, which used to
            /// send `pageCount` on a 0 -> N round trip on every single font
            /// size tick — visible as the bottom progress bar/chevrons
            /// flickering, and (via `ScrollEditorSheet`'s pageCount == 1
            /// check) as the friction gate falsely completing early.
            let isReformat: Bool
        }

        /// Starts a navigation for `request` — the only place that calls
        /// `loadHTMLString`, so `isNavigating` can never drift out of sync
        /// with reality. Reads `theme`/`appearanceMode`/`fontScale`/`size`
        /// from `parent` at call time rather than from `request` itself,
        /// since `parent` is always kept current (see `updateUIView`'s
        /// first line) and may have moved on since `request` was queued as
        /// `pendingRender` — `request.key` already reflects whatever was
        /// current at the moment it was built, so there's nothing stale
        /// about pairing it with `parent`'s latest values here.
        func performLoad(_ request: RenderRequest, on webView: BookWebView) {
            let isFirstLoadEver = loadedHTML == nil
            if isFirstLoadEver { webView.alpha = 0 }

            loadedHTML = request.html
            loadedKey = request.key
            // Only clear pageCount for genuinely new content — a reformat
            // of the SAME chapter (font size/theme/size) keeps whatever
            // was last measured as a placeholder until `measureAndSettle`
            // reports the real number, rather than bouncing every reload
            // through 0 (see `RenderRequest.isReformat`'s doc comment).
            if !request.isReformat {
                pageCount = 0
            }
            pendingRestoreFraction = request.fraction
            // A stale excerpt from the outgoing chapter must not survive
            // into the incoming one's selection menu — the
            // `selectionchange` listener won't fire again until something
            // is actually selected in the new document, so without this a
            // menu built before that first selection would otherwise
            // still see the old text.
            webView.selectedExcerpt = nil
            isNavigating = true

            webView.loadHTMLString(
                BookChapterWebView.document(
                    html: request.html, theme: parent.theme, mode: parent.appearanceMode,
                    fontScale: parent.fontScale, viewportSize: parent.size
                ),
                baseURL: nil
            )
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // The chapter is loaded exactly once per reload via
            // `loadHTMLString`, whose navigation type is `.other`. Anything
            // past that — a stray anchor tap, or a malicious EPUB attempting
            // a meta-refresh — is refused outright. Sanitization already
            // neutralizes real `href`s to "#", so this is defense in depth,
            // not the primary safeguard.
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Column layout only settles once the webview has actually laid
            // out at its final bounds, which for a freshly-loaded page can
            // lag one runloop turn behind `didFinish` — nudge once more on
            // the next runloop rather than trusting this callback's timing
            // exactly.
            DispatchQueue.main.async { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.isNavigating = false
                // A newer request arrived while this navigation was still
                // in flight (see `updateUIView`'s coalescing) — load that
                // instead of measuring the document that just finished,
                // which is already stale.
                if let pending = self.pendingRender {
                    self.pendingRender = nil
                    self.performLoad(pending, on: webView as! BookWebView)
                    return
                }
                self.measureAndSettle(webView)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            didEndNavigation()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            didEndNavigation()
        }

        /// Shared cleanup for a navigation that ended without finishing —
        /// without this, a failed load would leave `isNavigating` stuck
        /// `true` forever, and every future font/theme/size change would
        /// silently coalesce into `pendingRender` and never actually load.
        /// Uses `self.webView` (set in `makeUIView`) rather than the
        /// delegate callback's own parameter, since that's already typed
        /// as the `BookWebView` `performLoad` needs.
        private func didEndNavigation() {
            isNavigating = false
            guard let webView, let pending = pendingRender else { return }
            pendingRender = nil
            performLoad(pending, on: webView)
        }

        // MARK: WKScriptMessageHandler

        /// Fires on every `selectionchange` reported by `Self.selectionBridgeScript`
        /// — keeps `BookWebView.selectedExcerpt` current so a later
        /// `buildMenu(with:)` call has something to read synchronously. The
        /// message body is the plain selected text (or "" once the
        /// selection collapses), never HTML — `window.getSelection().toString()`
        /// already strips markup, which is what makes this safe to hand
        /// straight to `onAddToJournal`/`onSaveAsScroll` without further
        /// sanitization.
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case Self.selectionMessageName:
                webView?.selectedExcerpt = message.body as? String
            case Self.paragraphTapMessageName:
                // The script only ever posts a paragraph's own `data-p` value
                // parsed with `parseInt`, so anything that isn't a plain
                // number here would mean the bridge script itself is broken,
                // not a malformed page — fail quiet rather than crash.
                guard let index = (message.body as? NSNumber)?.intValue else { return }
                parent.onParagraphTap?(index)
            case Self.actionTapMessageName:
                // The script only ever posts the tapped element's own
                // `data-action` string verbatim (see
                // `Self.actionTapBridgeScript`) — never anything derived
                // from user-entered text — so this is safe to hand straight
                // to `onActionTap` without further sanitization.
                guard let action = message.body as? String else { return }
                parent.onActionTap?(action)
            default:
                break
            }
        }

        private func measureAndSettle(_ webView: WKWebView) {
            // Measured against `parent.size.width` — the value the CSS
            // document was actually built with (see `Self.document`,
            // where `columnWidth + columnGap == size.width` by
            // construction) — rather than `webView.bounds.width`. On a
            // fresh load, `didFinish` (plus this method's one-runloop
            // nudge) can fire before SwiftUI has finished giving the
            // WKWebView its real frame, so `webView.bounds.width` briefly
            // reads 0 and this whole measurement would silently no-op,
            // leaving `pageCount` stuck at its initial value (1) — which
            // is what made the friction gate (and the close button) look
            // permanently stuck until something else forced a reload
            // (e.g. changing the font scale) at a point where the bounds
            // had since caught up.
            let pageWidth = parent.size.width
            guard pageWidth > 0 else { return }
            let scrollWidth = webView.scrollView.contentSize.width
            // Ceiling, not nearest-rounding: `columnWidth`/`columnGap` are
            // sized so each column's on-screen footprint is exactly
            // `pageWidth` (see the type's own doc comment), but a genuine
            // partial last column — the common case, since content rarely
            // ends exactly on a page boundary — is still its own page and
            // needs to be counted as one. Rounding to nearest instead would
            // silently drop that trailing column whenever it covered less
            // than half a page width, undercounting `pageCount` by one; the
            // viewport for what the app then thinks is the "last" page
            // would land a page early, showing a mix of two columns' worth
            // of text sheared together — which is what made the true last
            // page look like its text had shifted. The small epsilon
            // subtracted first keeps ordinary floating-point noise on an
            // exact multiple (e.g. 2.0000001) from rounding up into a
            // phantom extra blank page.
            let ratio = scrollWidth / pageWidth
            let count = max(1, Int((ratio - 0.001).rounded(.up)))
            pageCount = count

            let targetOffsetX: CGFloat
            if let fraction = pendingRestoreFraction, count > 1 {
                let maxOffset = pageWidth * CGFloat(count - 1)
                targetOffsetX = (maxOffset * CGFloat(max(0, min(1, fraction)))).rounded()
            } else {
                targetOffsetX = 0
            }
            pendingRestoreFraction = nil
            webView.scrollView.setContentOffset(CGPoint(x: targetOffsetX, y: 0), animated: false)
            updateCurrentPage(webView.scrollView)

            if webView.alpha == 0 {
                UIView.animate(withDuration: 0.15) { webView.alpha = 1 }
            }
        }

        /// Where the reader currently is within the chapter, as a 0...1
        /// fraction of total scrollable width — survives a reload the way a
        /// raw page index wouldn't, since the page *count* itself can
        /// change when font size or view size changes. Mirrors
        /// `LibraryIndexEntry.bookmarkScrollFraction`'s reasoning.
        func currentFraction(in webView: WKWebView) -> Double {
            let scrollView = webView.scrollView
            let maxOffset = scrollView.contentSize.width - scrollView.bounds.width
            guard maxOffset > 0 else { return 0 }
            return Double(scrollView.contentOffset.x / maxOffset)
        }

        // MARK: UIScrollViewDelegate

        // Reporting the current page only once a swipe has actually
        // settled (rather than on every `scrollViewDidScroll` tick) mirrors
        // how `TabView(.page)` reports page changes — avoids a flurry of
        // binding updates mid-drag.
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { updateCurrentPage(scrollView) }
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { updateCurrentPage(scrollView) }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { updateCurrentPage(scrollView) }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            firedEdgeThisGesture = false
        }

        /// Detects a swipe stretching past either edge of the chapter's
        /// content — the WKWebView equivalent of swiping past the last/first
        /// page in the old `PageTurnContainer`-based reader. Works even for
        /// a single-page chapter because `alwaysBounceHorizontal` (set in
        /// `makeUIView`) guarantees elastic scroll events fire regardless of
        /// whether there's anything to actually scroll.
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard scrollView.isDragging, !firedEdgeThisGesture, pageCount > 0 else { return }
            let maxOffset = max(0, scrollView.contentSize.width - scrollView.bounds.width)
            let overscrollRight = scrollView.contentOffset.x - maxOffset
            if overscrollRight > Coordinator.edgeOverscrollThreshold {
                firedEdgeThisGesture = true
                parent.onRequestNextChapter?()
                return
            }
            let overscrollLeft = -scrollView.contentOffset.x
            if overscrollLeft > Coordinator.edgeOverscrollThreshold {
                firedEdgeThisGesture = true
                parent.onRequestPreviousChapter?()
            }
        }

        private func updateCurrentPage(_ scrollView: UIScrollView) {
            let pageWidth = scrollView.bounds.width
            guard pageWidth > 0 else { return }
            let page = Int((scrollView.contentOffset.x / pageWidth).rounded())
            let clamped = max(0, min(page, max(0, pageCount - 1)))
            if clamped != parent.currentPage {
                parent.currentPage = clamped
            }
        }
    }

    // MARK: - Selection bridge

    /// Keeps `BookWebView.selectedExcerpt` current for `buildMenu(with:)` by
    /// posting the plain-text selection to Swift on every `selectionchange`.
    /// Only posts when the text actually changed, so dragging a selection
    /// handle doesn't flood the native side with a message per pixel.
    /// Registered once per webview (see `makeUIView`) via `WKUserScript`, so
    /// it survives every chapter's `loadHTMLString` reload without being
    /// re-injected.
    static let selectionBridgeScript = """
    (function () {
      var lastText = '';
      document.addEventListener('selectionchange', function () {
        var text = window.getSelection().toString();
        if (text === lastText) { return; }
        lastText = text;
        if (window.webkit && window.webkit.messageHandlers.selection) {
          window.webkit.messageHandlers.selection.postMessage(text);
        }
      });
    })();
    """

    /// Posts a paragraph's `data-p` index to Swift when it's tapped, for
    /// callers that mark up their HTML with `<p data-p="0">`, `<p data-p="1">`,
    /// etc. (see `ScrollEditorSheet.scrollHTML`). Bound once per webview via
    /// event delegation on `document` — not a per-paragraph listener — so it
    /// survives every chapter/page reload without being re-attached, the
    /// same reasoning as `selectionBridgeScript`. `closest` walks up from
    /// whatever was actually tapped (e.g. a `<strong>` inside the paragraph)
    /// to the nearest ancestor carrying `data-p`, so taps anywhere in a
    /// paragraph's text register, not just its own root node.
    static let paragraphTapBridgeScript = """
    (function () {
      document.addEventListener('click', function (event) {
        var target = event.target.closest('[data-p]');
        if (!target) { return; }
        var index = parseInt(target.getAttribute('data-p'), 10);
        if (isNaN(index)) { return; }
        if (window.webkit && window.webkit.messageHandlers.paragraphTap) {
          window.webkit.messageHandlers.paragraphTap.postMessage(index);
        }
      });
    })();
    """

    /// Posts a `data-action` element's own attribute value to Swift when it's
    /// tapped, for callers that flow header/chrome markup into the document
    /// (e.g. `ScrollEditorSheet.statusPillHTML`) needing to trigger a native
    /// action rather than bookmark a reading position — see `onActionTap`.
    /// Mirrors `paragraphTapBridgeScript`'s event-delegation/`closest`
    /// approach, but posts the raw string verbatim instead of parsing it as
    /// a paragraph index, since `data-action` is caller-defined text, not a
    /// number.
    static let actionTapBridgeScript = """
    (function () {
      document.addEventListener('click', function (event) {
        var target = event.target.closest('[data-action]');
        if (!target) { return; }
        var action = target.getAttribute('data-action');
        if (!action) { return; }
        if (window.webkit && window.webkit.messageHandlers.actionTap) {
          window.webkit.messageHandlers.actionTap.postMessage(action);
        }
      });
    })();
    """

    // MARK: - HTML document assembly

    /// Wraps a chapter's already-sanitized inner HTML in a full document
    /// with injected theme CSS. Structural tags (`<table>`, `<ul>`/`<li>`,
    /// `<blockquote>`, headings) are left to render with their native
    /// semantics — only spacing, color, and the column-pagination mechanics
    /// are the app's own.
    static func document(html: String, theme: ThemeOption, mode: AppearanceMode, fontScale: CGFloat, viewportSize: CGSize) -> String {
        let width = max(1, Int(viewportSize.width.rounded()))
        let height = max(1, Int(viewportSize.height.rounded()))
        let columnWidth = max(1, width - Int(sideMargin) * 2)
        let columnGap = Int(sideMargin) * 2
        let fontSize = (baseFontSize * fontScale).rounded()

        let colors = AdaptivePalette(mode: mode)
        let textColor = colors.text.hexString()
        let dimColor = colors.textDim.hexString()
        let lineColor = colors.inkLine.hexString()
        let brassColor = theme.brass.hexString()

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=\(width), initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style>
        html {
          margin: 0; padding: 0; height: 100%;
          background: transparent;
          -webkit-text-size-adjust: 100%;
        }
        body {
          box-sizing: border-box;
          margin: 0;
          width: \(width)px;
          height: \(height)px;
          padding: \(Int(topPadding))px \(Int(sideMargin))px \(Int(bottomPadding))px \(Int(sideMargin))px;
          column-width: \(columnWidth)px;
          -webkit-column-width: \(columnWidth)px;
          column-gap: \(columnGap)px;
          -webkit-column-gap: \(columnGap)px;
          column-fill: auto;
          -webkit-column-fill: auto;
          font-family: Georgia, "Iowan Old Style", "Palatino Linotype", Palatino, serif;
          font-size: \(Int(fontSize))px;
          line-height: 1.5;
          color: \(textColor);
          background: transparent;
          -webkit-user-select: text;
          -webkit-touch-callout: none;
        }
        p { margin: 0 0 1em 0; text-align: justify; -webkit-hyphens: auto; hyphens: auto; }
        h1, h2, h3, h4 {
          font-weight: 600; line-height: 1.25;
          margin: 0 0 0.6em 0;
          break-after: avoid-column; page-break-after: avoid;
        }
        ul, ol { margin: 0 0 1em 0; padding-left: 1.4em; }
        li { margin-bottom: 0.35em; }
        img { max-width: 100%; height: auto; display: block; margin: 0.6em auto; break-inside: avoid; }
        table { border-collapse: collapse; table-layout: fixed; width: 100%; margin: 0 0 1em 0; break-inside: avoid; font-size: 0.72em; }
        td, th {
          border: 1px solid \(lineColor); padding: 3px 4px; text-align: left;
          overflow-wrap: break-word; word-break: break-word;
          -webkit-hyphens: auto; hyphens: auto;
        }
        blockquote {
          margin: 0 0 1em 0; padding-left: 12px;
          border-left: 3px solid \(brassColor);
          font-style: italic; color: \(dimColor);
        }
        hr { border: none; border-top: 1px solid \(lineColor); margin: 1em 0; }
        a { color: \(brassColor); text-decoration: none; -webkit-touch-callout: none; }
        * { -webkit-tap-highlight-color: transparent; }
        /* Bookmark styling for `ScrollEditorSheet.scrollHTML`'s `data-p`
           paragraphs — baked into the document rather than toggled live,
           since the bookmarked index only ever changes on a fresh reload
           (a paragraph tap regenerates the whole `html` string). */
        p.bookmarked { background: \(brassColor)12; border-radius: 8px; padding: 8px 10px; margin-left: -10px; margin-right: -10px; }
        .bookmark-label { display: block; font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: 10px; letter-spacing: 0.6px; text-transform: uppercase; color: \(brassColor); margin-bottom: 6px; }
        </style>
        </head>
        <body>
        \(html)
        </body>
        </html>
        """
    }
}

// MARK: - Selection menu

/// `WKWebView` subclass that surfaces "Save as Scroll" and "Add to Journal"
/// in the system menu that appears over selected chapter text — the
/// WKWebView counterpart to `ParagraphTextView.editMenu(for:suggestedActions:)`
/// in the paragraph-based reader.
///
/// WKWebView doesn't conform to `UITextInput`, so it can't use that same
/// `editMenu(for:suggestedActions:)` override point. Its own selection menu
/// is instead built through `UIEditMenuInteraction` via the standard
/// `buildMenu(with:)` responder-chain hook (confirmed by Apple engineers on
/// the developer forums as the supported way to extend it, since there's no
/// WKUIDelegate method for it) — WebKit's internal content view forwards an
/// unhandled `buildMenu(with:)` up to this view when it's about to present
/// the menu, which is also why the override below only touches anything
/// when `builder.system == .context`: that's the specific menu system the
/// edit-menu interaction builds against (see WWDC22 "Adopt desktop-class
/// editing interactions"), as opposed to the app-wide `.main` menu bar.
///
/// `buildMenu(with:)` only hands over a menu builder, never the selected
/// text — `selectedExcerpt` is what closes that gap, kept in sync by
/// `BookChapterWebView.selectionBridgeScript` via `Coordinator`'s
/// `WKScriptMessageHandler` conformance.
final class BookWebView: WKWebView {
    /// The current selection's plain text, or nil/empty when nothing's
    /// selected. Written by `Coordinator.userContentController(_:didReceive:)`;
    /// read here at menu-build time.
    var selectedExcerpt: String?
    var onAddToJournal: ((String) -> Void)?
    var onSaveAsScroll: ((String) -> Void)?

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .context,
              onAddToJournal != nil || onSaveAsScroll != nil,
              let excerpt = selectedExcerpt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !excerpt.isEmpty else { return }

        // Typed as `[UIMenuElement]`, not `[UIAction]`, so it lines up
        // with `existing`'s element type below without an extra cast.
        var actions: [UIMenuElement] = []
        // Listed above "Add to Journal", same as `ParagraphTextView`: turning
        // a passage into a scroll is the bigger commitment, so it gets the
        // more prominent position.
        if let onSaveAsScroll {
            actions.append(UIAction(title: "Save as Scroll", image: UIImage(systemName: "scroll")) { [weak self] _ in
                onSaveAsScroll(excerpt)
                self?.clearSelection()
            })
        }
        if let onAddToJournal {
            actions.append(UIAction(title: "Add to Journal", image: UIImage(systemName: "book")) { [weak self] _ in
                onAddToJournal(excerpt)
                self?.clearSelection()
            })
        }
        guard !actions.isEmpty else { return }

        // Appended onto the existing standard-edit children (Copy, Look Up,
        // etc.) rather than replacing them — mirrors the Objective-C
        // `replaceChildrenOfMenuForIdentifier:fromChildrenBlock:` pattern
        // Apple's own forum reply gives for this exact WKWebView case.
        builder.replaceChildren(ofMenu: .standardEdit) { existing in
            existing + actions
        }
    }

    /// Collapses the selection once a quoting action has been taken, so the
    /// highlighted text doesn't linger after the menu dismisses. Mirrors
    /// `ParagraphTextView`'s `selectedTextRange = nil` in the same spot.
    private func clearSelection() {
        evaluateJavaScript("window.getSelection().removeAllRanges();")
    }
}

/// A tiny handle a hosting SwiftUI view can hold to drive paging
/// programmatically — see `BookChapterWebView.proxy`. A plain class rather
/// than an `ObservableObject`: nothing about it needs to trigger a SwiftUI
/// re-render on its own, since `currentPage`/`pageCount` bindings already
/// do that.
final class BookWebReaderProxy {
    fileprivate weak var scrollView: UIScrollView?

    func goToPage(_ page: Int, animated: Bool = true) {
        guard let scrollView, scrollView.bounds.width > 0 else { return }
        let x = CGFloat(max(0, page)) * scrollView.bounds.width
        scrollView.setContentOffset(CGPoint(x: x, y: 0), animated: animated)
    }

    func goToNextPage(animated: Bool = true) {
        guard let scrollView, scrollView.bounds.width > 0 else { return }
        let current = Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded())
        goToPage(current + 1, animated: animated)
    }

    func goToPreviousPage(animated: Bool = true) {
        guard let scrollView, scrollView.bounds.width > 0 else { return }
        let current = Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded())
        goToPage(max(0, current - 1), animated: animated)
    }
}

extension Color {
    /// Best-effort `#RRGGBB` string for handing a SwiftUI color to CSS.
    /// Every color this is actually called with (`AdaptivePalette`,
    /// `ThemeOption.brass`) is built from an sRGB hex literal in
    /// `AppTheme.swift`, so the round trip through `UIColor` is exact; the
    /// fallback only matters for a color this was never designed to
    /// receive.
    func hexString() -> String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#888888" }
        func clamp(_ v: CGFloat) -> Int { max(0, min(255, Int((v * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }
}

// MARK: - Stage 2 test harness

/// Standalone harness for poking at the reading engine directly — sample
/// chapter content with a heading, paragraphs, a blockquote, a table, and
/// an image, so pagination, theming, and font scaling can all be checked
/// without needing a real imported EPUB or any of stage 3's selection-menu
/// wiring (that lives on `LibraryReaderView`, not this harness).
/// Note: WKWebView content generally needs Xcode's *Live Preview* (the
/// play button) rather than the static canvas snapshot to actually render.
private struct BookWebReaderDemo: View {
    @State private var currentPage = 0
    @State private var pageCount = 1
    @State private var mode: AppearanceMode = .dark
    @State private var fontScale: CGFloat = 1.0
    private let proxy = BookWebReaderProxy()

    var body: some View {
        let colors = AdaptivePalette(mode: mode)
        VStack(spacing: 0) {
            GeometryReader { geo in
                BookChapterWebView(
                    html: Self.sampleHTML,
                    theme: Palette.themes[0],
                    appearanceMode: mode,
                    fontScale: fontScale,
                    size: geo.size,
                    currentPage: $currentPage,
                    pageCount: $pageCount,
                    proxy: proxy
                )
            }
            .background(colors.background)

            HStack {
                Button { proxy.goToPreviousPage() } label: { Image(systemName: "chevron.left") }
                    .disabled(currentPage == 0)
                Spacer()
                Text("Page \(currentPage + 1) of \(pageCount)")
                    .font(AppFont.mono(11))
                    .foregroundColor(colors.textDim)
                Spacer()
                Button { proxy.goToNextPage() } label: { Image(systemName: "chevron.right") }
                    .disabled(currentPage >= pageCount - 1)
            }
            .padding()

            VStack(spacing: 8) {
                Button("Toggle \(mode == .dark ? "Light" : "Dark")") {
                    mode = mode == .dark ? .light : .dark
                }
                HStack {
                    Text("A").font(.system(size: 12, design: .serif))
                    Slider(value: $fontScale, in: 0.8...1.6, step: 0.1)
                    Text("A").font(.system(size: 22, design: .serif))
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
            .foregroundColor(colors.text)
        }
        .background(colors.background.ignoresSafeArea())
    }

    static let sampleHTML = """
    <h1>Chapter One: The Long Room</h1>
    <p>The library had not changed in forty years, which was, Mercer thought, either a testament to its caretakers or an indictment of everyone else. Dust motes turned in the light from the clerestory windows, and the smell of old paper hung in the air like incense in a church nobody attended anymore.</p>
    <p>He ran a finger along the spines of the third shelf, the one nobody catalogued properly, and felt the small satisfaction of a man doing something no one had asked him to do.</p>
    <blockquote>To keep a library is to keep a promise to people you will never meet.</blockquote>
    <p>The promise, as it happened, was about to be broken — though not by Mercer, and not on purpose. That would come later, in the part of the story where things generally go wrong.</p>
    <img src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=" alt="a small illustration">
    <p>Consider, for a moment, the ledger. It recorded acquisitions dating back to 1911, in six different hands, none of them legible past 1940.</p>
    <table>
    <tr><th>Year</th><th>Acquired</th><th>Condition</th></tr>
    <tr><td>1911</td><td>214 volumes</td><td>Fair</td></tr>
    <tr><td>1926</td><td>88 volumes</td><td>Good</td></tr>
    <tr><td>1940</td><td>12 volumes</td><td>Poor</td></tr>
    </table>
    <p>Nobody had opened the ledger in decades, which is precisely why nobody had noticed what was missing from it.</p>
    <p>Mercer closed the drawer. Somewhere above him, a pipe knocked twice against its bracket — the building settling, or something that wanted him to think it was the building settling.</p>
    <h2>A Visitor</h2>
    <p>The bell over the door rang at eleven, an hour before the library technically opened, which meant either a mistake or a member of the board.</p>
    <p>It was neither. It was a woman he did not recognize, carrying a box he recognized immediately — the same gray archival boxes the library itself used, the ones with the reinforced corners, the ones that were not, as far as he knew, sold to the public.</p>
    <p>"I believe," she said, setting it on the counter, "that you're missing this."</p>
    <p>He looked at the box for a long moment before he looked at her. Some part of him already suspected what year was written on the label, and some larger part of him did not want to be right.</p>
    """
}

#Preview("Book Web Reader") {
    BookWebReaderDemo()
}

import AppKit
import SwiftUI

/// Where a scrolling text view is scrolled to: its offset from the top, its content height and the visible height.
struct TextScrollState: Equatable {
    var offset: CGFloat
    var content: CGFloat
    var visible: CGFloat
}

/// Reports the scroll position of the `TextEditor` it sits behind, placed with
/// `.background { TextScrollObserver { state = $0 } }`.
///
/// SwiftUI's `onScrollGeometryChange` does not fire for a `TextEditor` (checked on macOS 26), so this finds the
/// editor's own `NSScrollView` (the one around an `NSTextView` that covers this view) and follows its clip view.
struct TextScrollObserver: NSViewRepresentable {
    let onChange: (TextScrollState) -> Void

    func makeNSView(context: Context) -> TextScrollObserverView {
        let view = TextScrollObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TextScrollObserverView, context: Context) {
        view.onChange = onChange
        view.attachIfNeeded()
    }
}

final class TextScrollObserverView: NSView {
    var onChange: ((TextScrollState) -> Void)?
    private weak var scrollView: NSScrollView?
    private var observers: [NSObjectProtocol] = []
    private var last: TextScrollState?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The editor's views are in place once this layout pass is done.
        DispatchQueue.main.async { [weak self] in self?.attachIfNeeded() }
    }

    override func layout() {
        super.layout()
        attachIfNeeded()
    }

    func attachIfNeeded() {
        guard scrollView == nil, let window, let root = window.contentView else { return }
        let mine = convert(bounds, to: nil)
        guard mine.width > 0, mine.height > 0 else { return }
        // The text scroll view overlapping this one the most: the editor this observer is the background of.
        var best: (NSScrollView, CGFloat)?
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, scroll.documentView is NSTextView {
                let overlap = scroll.convert(scroll.bounds, to: nil).intersection(mine)
                let area = overlap.isNull ? 0 : overlap.width * overlap.height
                if area > (best?.1 ?? 0) { best = (scroll, area) }
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        guard let scroll = best?.0 else { return }
        scrollView = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.documentView?.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.report() }
            },
            center.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.documentView, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.report() }
            },
            center.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.report() }
            },
        ]
        scroll.contentView.postsFrameChangedNotifications = true
        report()
    }

    private func report() {
        guard let scroll = scrollView, let document = scroll.documentView else { return }
        let clip = scroll.contentView.bounds
        // A flipped document (NSTextView is) scrolls down from y 0; otherwise measure from its top.
        let offset = document.isFlipped ? clip.minY : document.frame.height - clip.maxY
        let state = TextScrollState(offset: offset, content: document.frame.height, visible: clip.height)
        guard state != last else { return }
        last = state
        onChange?(state)
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

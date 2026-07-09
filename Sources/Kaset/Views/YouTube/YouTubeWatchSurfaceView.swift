import SwiftUI
import WebKit

// MARK: - YouTubeWatchSurfaceView

/// Hosts the extracted YouTube video surface (the watch WebView) inside a
/// native view. Used by both the inline WatchView and the floating window;
/// whichever is on screen reparents the singleton WebView into itself.
struct YouTubeWatchSurfaceView: NSViewRepresentable {
    func makeNSView(context _: Context) -> YouTubeWatchContainerView {
        let container = YouTubeWatchContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        return container
    }

    func updateNSView(_ nsView: YouTubeWatchContainerView, context _: Context) {
        YouTubeWatchWebView.shared.ensureInHierarchy(container: nsView)
    }
}

// MARK: - ScrollForwardingWKWebView

/// `WKWebView` that never keeps trackpad/mouse-wheel scrolls for its own
/// document. Extracted YouTube surfaces have no page chrome to scroll, so
/// events are forwarded to the enclosing SwiftUI `ScrollView` / responder chain.
///
/// Clicks, drags, and media keys still hit the WebView normally.
final class ScrollForwardingWKWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        Self.forwardScroll(event, from: self)
    }

    /// Also catch magnify-style two-finger pans that sometimes arrive as
    /// smart-magnify / swipe variants on newer macOS.
    override func wantsScrollEventsForSwipeTracking(on axis: NSEvent.GestureAxis) -> Bool {
        // Do not claim swipe tracking — let the parent ScrollView own it.
        false
    }

    static func forwardScroll(_ event: NSEvent, from view: NSView) {
        // Prefer the nearest NSScrollView (SwiftUI ScrollView backing).
        if let scrollView = view.enclosingScrollView {
            scrollView.scrollWheel(with: event)
            return
        }
        // Walk the responder / superview chain until something handles it.
        var responder: NSResponder? = view.nextResponder
        while let current = responder {
            if let scrollView = current as? NSScrollView {
                scrollView.scrollWheel(with: event)
                return
            }
            responder = current.nextResponder
        }
        var ancestor: NSView? = view.superview
        while let current = ancestor {
            if let scrollView = current as? NSScrollView {
                scrollView.scrollWheel(with: event)
                return
            }
            if let scrollView = current.enclosingScrollView {
                scrollView.scrollWheel(with: event)
                return
            }
            ancestor = current.superview
        }
        view.nextResponder?.scrollWheel(with: event)
    }
}

// MARK: - YouTubeWatchContainerView

/// Custom NSView that keeps the WebView sized with the container and
/// forwards scroll-wheel events to the enclosing ScrollView so the page
/// remains scrollable when the cursor is over the playing video.
final class YouTubeWatchContainerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.postsFrameChangedNotifications = true
        self.wantsLayer = true
        self.layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        // Overscan the WebView slightly: fractional-point rounding between
        // SwiftUI's aspect-fitted frame and the page's 100vw video leaves
        // hairline black slivers at the edges otherwise. The container's
        // layer clips the overflow.
        for subview in self.subviews where subview is WKWebView {
            subview.frame = self.bounds.insetBy(dx: -1.5, dy: -1.5)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        ScrollForwardingWKWebView.forwardScroll(event, from: self)
    }
}

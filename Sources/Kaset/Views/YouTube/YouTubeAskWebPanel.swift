import AppKit
import SwiftUI
import WebKit

// MARK: - YouTubeAskWebPanel

/// YouTube’s real **“Ask about this video”** panel (Gemini on youtube.com),
/// embedded via WKWebView with the user’s login cookies.
///
/// This intentionally does **not** use Apple Intelligence. Results come from
/// YouTube’s web product: we load the watch page, mute/pause its player so it
/// doesn’t fight Kaset’s native playback WebView, then open the Ask UI.
struct YouTubeAskWebPanel: View {
    let videoId: String
    var onClose: (() -> Void)?

    @Environment(WebKitManager.self) private var webKitManager
    @Environment(AuthService.self) private var authService

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .foregroundStyle(PackageResourceLookup.brandAccent)
                Text("Ask about this video", comment: "YouTube Ask panel title")
                    .font(.headline)
                Spacer()
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Close Ask"))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().opacity(0.4)

            YouTubeAskWebView(
                videoId: self.videoId,
                webKitManager: self.webKitManager,
                usesCookieFreeDataStore: self.authService.shouldUseCookieFreePlaybackDataStore
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 6) {
                Text("Powered by YouTube · Ask", comment: "Web Ask footer")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("Results from youtube.com", comment: "Web Ask source note")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.askWebPanel)
    }
}

// MARK: - WKWebView host

/// Loads `youtube.com/watch?v=` with shared cookies and injects scripts to
/// open Ask while keeping the embedded page silent.
struct YouTubeAskWebView: NSViewRepresentable {
    let videoId: String
    let webKitManager: WebKitManager
    var usesCookieFreeDataStore: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator(videoId: self.videoId, webKitManager: self.webKitManager)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = self.webKitManager.createWebViewConfiguration(
            websiteDataStore: self.usesCookieFreeDataStore ? .nonPersistent() : nil
        )
        // Never autoplay in the Ask surface — Kaset’s player owns audio.
        configuration.mediaTypesRequiringUserActionForPlayback = [.all]
        configuration.allowsAirPlayForMediaPlayback = false

        let controller = configuration.userContentController
        let muteScript = WKUserScript(
            source: Self.muteAndOpenAskScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        controller.addUserScript(muteScript)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = WebKitManager.userAgent
        webView.setValue(false, forKey: "drawsBackground")
        #if DEBUG
            webView.isInspectable = true
        #endif

        context.coordinator.webView = webView
        self.webKitManager.registerExtensionHostWebView(webView, role: .youtubeWatch)
        context.coordinator.loadVideo()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.videoId != self.videoId {
            context.coordinator.videoId = self.videoId
            context.coordinator.loadVideo()
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        coordinator.webView = nil
    }

    // MARK: - Injected script

    /// Mutes/pauses any media, repeatedly tries to open YouTube’s Ask entry
    /// points, and nudges the layout toward a panel-first view.
    private static let muteAndOpenAskScript = #"""
    (function() {
      if (window.__kasetAskHooked) return;
      window.__kasetAskHooked = true;

      function silence() {
        try {
          document.querySelectorAll('video, audio').forEach(function(el) {
            el.muted = true;
            el.volume = 0;
            try { el.pause(); } catch (e) {}
            el.removeAttribute('autoplay');
          });
          var p = document.getElementById('movie_player');
          if (p) {
            try { if (typeof p.mute === 'function') p.mute(); } catch (e) {}
            try { if (typeof p.pauseVideo === 'function') p.pauseVideo(); } catch (e) {}
            try { if (typeof p.setVolume === 'function') p.setVolume(0); } catch (e) {}
          }
        } catch (e) {}
      }

      function clickAsk() {
        // Various YouTube UI generations for the Ask / Gemini entry point.
        var selectors = [
          'button[aria-label*="Ask" i]',
          'button[aria-label*="Gemini" i]',
          'yt-button-shape button[aria-label*="Ask" i]',
          '#flexible-item-buttons button[aria-label*="Ask" i]',
          'ytd-button-renderer a[aria-label*="Ask" i]',
          'button[title*="Ask" i]',
          // Text content fallbacks
        ];
        for (var i = 0; i < selectors.length; i++) {
          var nodes = document.querySelectorAll(selectors[i]);
          for (var j = 0; j < nodes.length; j++) {
            var el = nodes[j];
            var label = ((el.getAttribute('aria-label') || '') + ' ' + (el.textContent || '')).toLowerCase();
            if (label.indexOf('ask') !== -1 || label.indexOf('gemini') !== -1) {
              try { el.click(); return true; } catch (e) {}
            }
          }
        }
        // Walk buttons by visible text
        var buttons = document.querySelectorAll('button, a, yt-button-shape, tp-yt-paper-button');
        for (var k = 0; k < buttons.length; k++) {
          var t = (buttons[k].innerText || buttons[k].textContent || '').trim().toLowerCase();
          if (t === 'ask' || t.indexOf('ask ') === 0 || t.indexOf('gemini') !== -1) {
            try {
              var clickable = buttons[k].querySelector('button') || buttons[k];
              clickable.click();
              return true;
            } catch (e) {}
          }
        }
        return false;
      }

      function applyPanelFocusCSS() {
        if (document.getElementById('kaset-ask-style')) return;
        var style = document.createElement('style');
        style.id = 'kaset-ask-style';
        style.textContent = `
          /* Soften the full watch chrome so Ask panel is the focus */
          ytd-masthead, #masthead-container, #guide, #guide-content,
          ytd-mini-guide-renderer, #chips-wrapper, ytd-feed-nudge-renderer {
            display: none !important;
          }
          ytd-watch-flexy[flexy] #columns {
            max-width: 100% !important;
          }
          /* Prefer secondary column (comments / engagement panels) */
          #secondary {
            width: 100% !important;
            max-width: 100% !important;
            min-width: 0 !important;
          }
          #primary {
            max-width: 0 !important;
            min-width: 0 !important;
            overflow: hidden !important;
            opacity: 0.15 !important;
            pointer-events: none !important;
          }
          ytd-watch-flexy {
            --ytd-watch-flexy-sidebar-width: 100%;
          }
          /* Engagement / Ask panel sheets */
          ytd-engagement-panel-section-list-renderer[target-id*="ask" i],
          ytd-engagement-panel-section-list-renderer[visibility="ENGAGEMENT_PANEL_VISIBILITY_EXPANDED"] {
            display: block !important;
            width: 100% !important;
          }
        `;
        document.documentElement.appendChild(style);
      }

      silence();
      applyPanelFocusCSS();

      var tries = 0;
      var timer = setInterval(function() {
        silence();
        applyPanelFocusCSS();
        var opened = clickAsk();
        tries += 1;
        if (opened || tries > 40) {
          clearInterval(timer);
          // Keep silencing for a bit after open in case media restarts.
          var silenceTimer = setInterval(silence, 800);
          setTimeout(function() { clearInterval(silenceTimer); }, 12000);
        }
      }, 600);

      // Mutation observer for late-loading buttons / panels
      try {
        var mo = new MutationObserver(function() {
          silence();
          if (tries < 25) clickAsk();
        });
        mo.observe(document.documentElement, { childList: true, subtree: true });
      } catch (e) {}
    })();
    """#

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var videoId: String
        let webKitManager: WebKitManager
        weak var webView: WKWebView?
        private let logger = DiagnosticsLogger.webKit

        init(videoId: String, webKitManager: WebKitManager) {
            self.videoId = videoId
            self.webKitManager = webKitManager
        }

        func loadVideo() {
            guard let webView else { return }
            let urlString = "https://www.youtube.com/watch?v=\(self.videoId)"
            guard let url = URL(string: urlString) else { return }
            self.logger.info("YouTube Ask WebView loading \(self.videoId, privacy: .public)")
            self.webKitManager.extensionHostWebViewWillNavigate(webView, to: url)
            webView.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            self.webKitManager.extensionHostWebViewDidStartNavigation(webView)
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            self.webKitManager.extensionHostWebViewDidFinishNavigation(webView)
            // Re-run open-ask after navigation settles.
            webView.evaluateJavaScript(YouTubeAskWebView.muteAndOpenAskScript, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: Error) {
            self.webKitManager.extensionHostWebViewDidFailNavigation(webView)
            self.logger.error("YouTube Ask navigation failed: \(error.localizedDescription, privacy: .public)")
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation _: WKNavigation!,
            withError error: Error
        ) {
            self.webKitManager.extensionHostWebViewDidFailNavigation(webView)
            self.logger.error("YouTube Ask provisional fail: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Accessibility

extension AccessibilityID.YouTubeContent {
    static let askWebPanel = "youtubeContent.askWebPanel"
}

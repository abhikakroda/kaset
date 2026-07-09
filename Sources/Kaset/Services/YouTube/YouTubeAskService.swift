import AppKit
import Foundation
import Observation
import WebKit

// MARK: - Ask models

struct YouTubeAskMessage: Identifiable, Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case assistant
        case user
    }

    let id: UUID
    let role: Role
    var text: String
    var isStreaming: Bool

    init(id: UUID = UUID(), role: Role, text: String, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
    }
}

// MARK: - YouTubeAskService

/// Fetches YouTube’s **Ask about this video** experience from the live website
/// in a **hidden** `WKWebView`, then surfaces suggestions and answers in Kaset’s
/// native UI. The webpage is never shown to the user.
@MainActor
@Observable
final class YouTubeAskService: NSObject {
    static let shared = YouTubeAskService()

    private(set) var videoId: String?
    private(set) var messages: [YouTubeAskMessage] = []
    private(set) var suggestions: [String] = []
    private(set) var isPageReady = false
    private(set) var isLoadingPage = false
    private(set) var isAnswering = false
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?

    private var webView: WKWebView?
    private var webKitManager: WebKitManager?
    private var hostWindow: NSWindow?
    private var loadGeneration = 0
    private var answerMessageId: UUID?
    private let logger = DiagnosticsLogger.webKit

    private static let bridgeName = "kasetAsk"

    override private init() {
        super.init()
    }

    // MARK: - Public API

    /// Loads the YouTube watch page off-screen and prepares Ask extraction.
    func prepare(
        videoId: String,
        webKitManager: WebKitManager,
        usesCookieFreeDataStore: Bool = false
    ) {
        if self.videoId == videoId, self.webView != nil, self.isPageReady || self.isLoadingPage {
            return
        }

        self.tearDown(keepMessages: false)
        self.videoId = videoId
        self.webKitManager = webKitManager
        self.isLoadingPage = true
        self.isPageReady = false
        self.errorMessage = nil
        self.statusMessage = String(localized: "Connecting to YouTube Ask…")
        self.suggestions = Self.defaultSuggestions
        self.messages = [
            YouTubeAskMessage(
                role: .assistant,
                text: String(localized: "Loading YouTube’s Ask for this video… Suggested questions will appear when ready.")
            ),
        ]

        self.loadGeneration += 1
        let generation = self.loadGeneration

        let configuration = webKitManager.createWebViewConfiguration(
            websiteDataStore: usesCookieFreeDataStore ? .nonPersistent() : nil
        )
        configuration.mediaTypesRequiringUserActionForPlayback = [.all]
        configuration.allowsAirPlayForMediaPlayback = false

        let controller = configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.bridgeName)
        controller.add(self, name: Self.bridgeName)
        controller.addUserScript(
            WKUserScript(
                source: Self.bridgeScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 720), configuration: configuration)
        webView.navigationDelegate = self
        webView.customUserAgent = WebKitManager.userAgent
        webView.setValue(false, forKey: "drawsBackground")
        #if DEBUG
            webView.isInspectable = true
        #endif

        // Keep the view in a hidden window so WebKit fully runs scripts/layout.
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 420, height: 720),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = webView
        window.orderBack(nil)

        self.webView = webView
        self.hostWindow = window
        webKitManager.registerExtensionHostWebView(webView, role: .youtubeWatch)

        guard generation == self.loadGeneration else { return }
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)") else { return }
        webKitManager.extensionHostWebViewWillNavigate(webView, to: url)
        webView.load(URLRequest(url: url))
        self.logger.info("YouTube Ask (hidden) loading \(videoId, privacy: .public)")
    }

    /// Sends a question through the hidden YouTube page and streams the answer
    /// into native `messages`.
    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        guard let webView else {
            self.errorMessage = String(localized: "Ask is not ready yet.")
            return
        }

        self.errorMessage = nil
        self.isAnswering = true
        self.statusMessage = String(localized: "Asking YouTube…")
        self.messages.append(YouTubeAskMessage(role: .user, text: q))

        let assistant = YouTubeAskMessage(role: .assistant, text: "", isStreaming: true)
        self.answerMessageId = assistant.id
        self.messages.append(assistant)

        let escaped = Self.escapeForJSString(q)
        let js = "window.__kasetAskSubmit && window.__kasetAskSubmit(\"\(escaped)\");"
        webView.evaluateJavaScript(js) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.failAnswer(String(localized: "Could not send question: \(error.localizedDescription)"))
                }
            }
        }
    }

    func askSuggestion(_ text: String) {
        self.ask(text)
    }

    func clearConversation(keepIntro: Bool = true) {
        self.answerMessageId = nil
        self.isAnswering = false
        if keepIntro {
            self.messages = [
                YouTubeAskMessage(
                    role: .assistant,
                    text: String(localized: "Ask anything about this video. Answers come from YouTube’s web Ask feature.")
                ),
            ]
        } else {
            self.messages = []
        }
    }

    func tearDown(keepMessages: Bool = false) {
        self.loadGeneration += 1
        if let webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeName)
        }
        self.hostWindow?.contentView = nil
        self.hostWindow?.close()
        self.hostWindow = nil
        self.webView = nil
        self.webKitManager = nil
        self.isLoadingPage = false
        self.isPageReady = false
        self.isAnswering = false
        self.answerMessageId = nil
        self.statusMessage = nil
        if !keepMessages {
            self.messages = []
            self.suggestions = []
            self.videoId = nil
            self.errorMessage = nil
        }
    }

    // MARK: - Bridge handling

    private func handleBridgePayload(_ payload: [String: Any]) {
        let type = payload["type"] as? String ?? ""
        switch type {
        case "ready":
            self.isLoadingPage = false
            self.isPageReady = true
            self.statusMessage = String(localized: "YouTube Ask ready")
            if let intro = payload["intro"] as? String, !intro.isEmpty {
                self.replaceOrSetIntro(intro)
            } else {
                self.replaceOrSetIntro(
                    String(localized: "Hello! Ask me anything about this video. Pick a suggestion or type your own question.")
                )
            }

        case "suggestions":
            if let list = payload["suggestions"] as? [String] {
                let cleaned = list
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !cleaned.isEmpty {
                    self.suggestions = Array(cleaned.prefix(8))
                }
            }

        case "answerDelta":
            if let text = payload["text"] as? String {
                self.updateStreamingAnswer(text, done: false)
            }

        case "answer":
            let text = (payload["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                self.failAnswer(String(localized: "YouTube returned an empty answer. Try again."))
            } else {
                self.updateStreamingAnswer(text, done: true)
            }

        case "status":
            if let message = payload["message"] as? String {
                self.statusMessage = message
            }

        case "error":
            let message = (payload["message"] as? String)
                ?? String(localized: "YouTube Ask failed.")
            if self.isAnswering {
                self.failAnswer(message)
            } else {
                self.errorMessage = message
                self.isLoadingPage = false
                self.statusMessage = nil
            }

        case "fallbackMeta":
            // Page loaded but Ask UI missing — still provide useful chips/meta.
            self.isLoadingPage = false
            self.isPageReady = true
            self.statusMessage = String(localized: "Using video details from YouTube page")
            if let title = payload["title"] as? String, !title.isEmpty {
                self.replaceOrSetIntro(
                    String(localized: "YouTube Ask panel wasn’t available for this account/region. I can still answer from the page details for “\(title)”.")
                )
            }
            if let list = payload["suggestions"] as? [String], !list.isEmpty {
                self.suggestions = list
            }

        default:
            break
        }
    }

    private func replaceOrSetIntro(_ text: String) {
        if let first = self.messages.first, first.role == .assistant, self.messages.count == 1 {
            self.messages[0] = YouTubeAskMessage(role: .assistant, text: text)
        } else if self.messages.isEmpty {
            self.messages = [YouTubeAskMessage(role: .assistant, text: text)]
        }
    }

    private func updateStreamingAnswer(_ text: String, done: Bool) {
        guard let id = self.answerMessageId,
              let index = self.messages.firstIndex(where: { $0.id == id })
        else { return }
        self.messages[index].text = text
        self.messages[index].isStreaming = !done
        if done {
            self.isAnswering = false
            self.answerMessageId = nil
            self.statusMessage = String(localized: "Answer from YouTube")
        }
    }

    private func failAnswer(_ message: String) {
        if let id = self.answerMessageId,
           let index = self.messages.firstIndex(where: { $0.id == id })
        {
            self.messages[index].text = message
            self.messages[index].isStreaming = false
        } else {
            self.messages.append(YouTubeAskMessage(role: .assistant, text: message))
        }
        self.isAnswering = false
        self.answerMessageId = nil
        self.errorMessage = message
        self.statusMessage = nil
    }

    private static func escapeForJSString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    private static let defaultSuggestions: [String] = [
        String(localized: "What is this video about?"),
        String(localized: "Summarize the main points"),
        String(localized: "Who is this for?"),
        String(localized: "Key takeaways"),
    ]

    // MARK: - Injected bridge script

    private static let bridgeScript = #"""
    (function() {
      if (window.__kasetAskBridge) return;
      window.__kasetAskBridge = true;

      function post(payload) {
        try {
          window.webkit.messageHandlers.kasetAsk.postMessage(payload);
        } catch (e) {}
      }

      function silence() {
        try {
          document.querySelectorAll('video, audio').forEach(function(el) {
            el.muted = true; el.volume = 0;
            try { el.pause(); } catch (e) {}
          });
          var p = document.getElementById('movie_player');
          if (p) {
            try { p.mute && p.mute(); } catch (e) {}
            try { p.pauseVideo && p.pauseVideo(); } catch (e) {}
            try { p.setVolume && p.setVolume(0); } catch (e) {}
          }
        } catch (e) {}
      }

      function textOf(el) {
        return (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim();
      }

      function findAskButtons() {
        var out = [];
        var nodes = document.querySelectorAll('button, a, yt-button-shape, tp-yt-paper-button');
        for (var i = 0; i < nodes.length; i++) {
          var el = nodes[i];
          var label = ((el.getAttribute('aria-label') || '') + ' ' + textOf(el)).toLowerCase();
          if (label.indexOf('ask') !== -1 || label.indexOf('gemini') !== -1) {
            out.push(el.querySelector('button') || el);
          }
        }
        return out;
      }

      function openAsk() {
        var buttons = findAskButtons();
        for (var i = 0; i < buttons.length; i++) {
          try { buttons[i].click(); return true; } catch (e) {}
        }
        return false;
      }

      function panelRoot() {
        // Engagement panels / dialogs used by Ask
        var panels = document.querySelectorAll(
          'ytd-engagement-panel-section-list-renderer, tp-yt-paper-dialog, ytd-interactive-tabbed-header-renderer, #panels'
        );
        for (var i = 0; i < panels.length; i++) {
          var t = textOf(panels[i]).toLowerCase();
          if (t.indexOf('ask') !== -1 || t.indexOf('gemini') !== -1 || t.indexOf('question') !== -1) {
            return panels[i];
          }
        }
        // Fallback: whole secondary column
        return document.querySelector('#secondary') || document.body;
      }

      function scrapeSuggestions() {
        var root = panelRoot() || document;
        var chips = [];
        var nodes = root.querySelectorAll(
          'button, yt-chip-cloud-chip-renderer, tp-yt-paper-chip, .ytChipShapeButtonReset, ytd-button-renderer'
        );
        for (var i = 0; i < nodes.length; i++) {
          var t = textOf(nodes[i]);
          if (!t || t.length < 4 || t.length > 80) continue;
          var low = t.toLowerCase();
          if (low === 'ask' || low === 'send' || low === 'close' || low === 'learn more') continue;
          if (low.indexOf('subscribe') !== -1) continue;
          // Prefer question-like chips
          if (t.indexOf('?') !== -1 || t.split(' ').length >= 3) {
            if (chips.indexOf(t) === -1) chips.push(t);
          }
        }
        return chips.slice(0, 8);
      }

      function scrapeAnswerText() {
        var root = panelRoot() || document;
        // Prefer message-like blocks inside the panel
        var candidates = root.querySelectorAll(
          'yt-formatted-string, #content-text, .markdown-inline-block, .ytd-comment-renderer #content-text, p, span'
        );
        var best = '';
        for (var i = 0; i < candidates.length; i++) {
          var t = textOf(candidates[i]);
          if (t.length > best.length && t.length > 40 && t.length < 8000) {
            // Skip chrome
            var low = t.toLowerCase();
            if (low.indexOf('skip navigation') !== -1) continue;
            if (low.indexOf('sign in') === 0) continue;
            best = t;
          }
        }
        return best;
      }

      function findInput() {
        var root = panelRoot() || document;
        return root.querySelector(
          'textarea, input[type="text"], div[contenteditable="true"], #contenteditable-root, [aria-label*="question" i], [aria-label*="Ask" i]'
        );
      }

      function setInputValue(el, value) {
        if (!el) return false;
        if (el.isContentEditable || el.getAttribute('contenteditable') === 'true') {
          el.focus();
          el.textContent = value;
          el.dispatchEvent(new InputEvent('input', { bubbles: true, data: value }));
          return true;
        }
        var proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
        var desc = Object.getOwnPropertyDescriptor(proto, 'value');
        if (desc && desc.set) desc.set.call(el, value); else el.value = value;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
      }

      function clickSend() {
        var root = panelRoot() || document;
        var buttons = root.querySelectorAll('button, yt-button-shape button, #submit-button');
        for (var i = 0; i < buttons.length; i++) {
          var el = buttons[i];
          var label = ((el.getAttribute('aria-label') || '') + ' ' + textOf(el)).toLowerCase();
          if (label.indexOf('send') !== -1 || label.indexOf('submit') !== -1 || label === 'ask') {
            try { el.click(); return true; } catch (e) {}
          }
        }
        // Enter key on input
        var input = findInput();
        if (input) {
          input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true }));
          input.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true }));
          return true;
        }
        return false;
      }

      var lastAnswer = '';
      var answerWatch = null;

      window.__kasetAskSubmit = function(question) {
        silence();
        openAsk();
        post({ type: 'status', message: 'Sending to YouTube Ask…' });
        setTimeout(function() {
          var input = findInput();
          if (!input) {
            // Fallback: answer from page metadata if Ask UI not present
            var meta = scrapeMeta();
            var reply = metaFallbackAnswer(question, meta);
            post({ type: 'answer', text: reply });
            return;
          }
          setInputValue(input, question);
          setTimeout(function() {
            clickSend();
            lastAnswer = scrapeAnswerText();
            var stable = 0;
            if (answerWatch) clearInterval(answerWatch);
            answerWatch = setInterval(function() {
              silence();
              var now = scrapeAnswerText();
              if (now && now !== lastAnswer && now.length > lastAnswer.length) {
                lastAnswer = now;
                stable = 0;
                post({ type: 'answerDelta', text: now });
              } else if (now && now.length > 20) {
                stable += 1;
                if (stable >= 4) {
                  clearInterval(answerWatch);
                  answerWatch = null;
                  post({ type: 'answer', text: now });
                }
              } else {
                stable += 1;
                if (stable >= 20) {
                  clearInterval(answerWatch);
                  answerWatch = null;
                  var meta = scrapeMeta();
                  post({ type: 'answer', text: metaFallbackAnswer(question, meta) });
                }
              }
            }, 700);
          }, 400);
        }, 500);
      };

      function scrapeMeta() {
        var title = '';
        var desc = '';
        try {
          title = textOf(document.querySelector('h1.ytd-watch-metadata yt-formatted-string, h1 yt-formatted-string, h1')) || document.title;
          desc = textOf(document.querySelector('#description-inline-expander, ytd-text-inline-expander, #description')) || '';
          if (!desc && window.ytInitialPlayerResponse) {
            desc = (window.ytInitialPlayerResponse.videoDetails && window.ytInitialPlayerResponse.videoDetails.shortDescription) || '';
            title = title || (window.ytInitialPlayerResponse.videoDetails && window.ytInitialPlayerResponse.videoDetails.title) || '';
          }
        } catch (e) {}
        return { title: title, description: desc.slice(0, 2500) };
      }

      function metaFallbackAnswer(question, meta) {
        var q = (question || '').toLowerCase();
        var title = meta.title || 'This video';
        var desc = meta.description || '';
        if (!desc) {
          return 'I could not open YouTube’s interactive Ask UI for this video (it may be unavailable in this region/account). Title: “' + title + '”. Try again later or open the video on youtube.com to use Ask there.';
        }
        if (q.indexOf('summar') !== -1 || q.indexOf('about') !== -1 || q.indexOf('point') !== -1 || q.indexOf('takeaway') !== -1) {
          return 'Based on the YouTube page for “' + title + '”:\n\n' + desc.slice(0, 900) + (desc.length > 900 ? '…' : '') + '\n\n(YouTube Ask UI was not available; this is from the public video description on youtube.com.)';
        }
        return 'From the YouTube page (“' + title + '”):\n\n' + desc.slice(0, 700) + (desc.length > 700 ? '…' : '') + '\n\n(YouTube Ask UI was not available; answer derived from page metadata.)';
      }

      // Boot sequence
      silence();
      // Lighter boot: fewer polls, stop early. Aggressive MutationObservers
      // on a full YouTube page made the whole app feel laggy.
      var tries = 0;
      var boot = setInterval(function() {
        silence();
        var opened = openAsk();
        tries += 1;
        if (tries === 3 || tries === 8 || opened) {
          var chips = scrapeSuggestions();
          if (chips.length) post({ type: 'suggestions', suggestions: chips });
        }
        if (opened || tries > 12) {
          clearInterval(boot);
          var meta = scrapeMeta();
          if (opened) {
            post({ type: 'ready', intro: 'Hello! Ask me anything about this video. Answers come from YouTube’s Ask on the web.' });
            setTimeout(function() {
              var more = scrapeSuggestions();
              if (more.length) post({ type: 'suggestions', suggestions: more });
            }, 1200);
          } else {
            post({
              type: 'fallbackMeta',
              title: meta.title,
              suggestions: [
                'What is this video about?',
                'Summarize the description',
                'Key details from the page'
              ]
            });
          }
        }
      }, 900);
    })();
    """#
}

// MARK: - WKScriptMessageHandler

extension YouTubeAskService: WKScriptMessageHandler {
    nonisolated func userContentController(
        _: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // Copy payload off the message before hopping to MainActor.
        let body = message.body as? [String: Any]
        Task { @MainActor in
            if let body {
                self.handleBridgePayload(body)
            }
        }
    }
}

// MARK: - Navigation

extension YouTubeAskService: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        self.webKitManager?.extensionHostWebViewDidStartNavigation(webView)
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        self.webKitManager?.extensionHostWebViewDidFinishNavigation(webView)
        // Re-inject readiness after SPA settles
        webView.evaluateJavaScript(Self.bridgeScript, completionHandler: nil)
        self.statusMessage = String(localized: "Page loaded — opening Ask…")
    }

    func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        self.webKitManager?.extensionHostWebViewDidFailNavigation(webView)
        self.isLoadingPage = false
        self.errorMessage = error.localizedDescription
        self.statusMessage = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation _: WKNavigation!,
        withError error: Error
    ) {
        self.webKitManager?.extensionHostWebViewDidFailNavigation(webView)
        self.isLoadingPage = false
        self.errorMessage = error.localizedDescription
        self.statusMessage = nil
    }
}

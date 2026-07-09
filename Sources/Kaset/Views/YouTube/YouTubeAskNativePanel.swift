import SwiftUI

// MARK: - YouTubeAskNativePanel

/// Native “Ask about this video” UI (YouTube-style). Answers are fetched from
/// YouTube’s website in a **hidden** WebView — the webpage is never shown.
struct YouTubeAskNativePanel: View {
    let videoId: String
    var onClose: (() -> Void)?

    @Environment(WebKitManager.self) private var webKitManager
    @Environment(AuthService.self) private var authService
    @State private var askService = YouTubeAskService.shared
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private static let brandAccent = PackageResourceLookup.brandAccent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.header
            Divider().opacity(0.4)
            self.chat
            if !self.askService.suggestions.isEmpty, !self.askService.isAnswering {
                Divider().opacity(0.3)
                self.suggestions
            }
            Divider().opacity(0.4)
            self.composer
            self.footer
        }
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.askWebPanel)
        .task(id: self.videoId) {
            self.askService.prepare(
                videoId: self.videoId,
                webKitManager: self.webKitManager,
                usesCookieFreeDataStore: self.authService.shouldUseCookieFreePlaybackDataStore
            )
        }
        .onDisappear {
            // Tear down the hidden YouTube page when Ask closes — leaving a
            // full watch WebView + mutation observers alive is a major lag source.
            self.askService.tearDown(keepMessages: true)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .foregroundStyle(Self.brandAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Ask about this video", comment: "Native Ask panel title")
                    .font(.headline)
                if let status = self.askService.statusMessage {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if self.askService.isLoadingPage || self.askService.isAnswering {
                ProgressView()
                    .controlSize(.small)
            }
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
    }

    // MARK: - Chat

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(self.askService.messages) { message in
                        self.bubble(message)
                            .id(message.id)
                    }
                    if let error = self.askService.errorMessage, !self.askService.isAnswering {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(14)
            }
            .onChange(of: self.askService.messages.count) { _, _ in
                if let last = self.askService.messages.last?.id {
                    withAnimation {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .onChange(of: self.askService.messages.last?.text) { _, _ in
                if let last = self.askService.messages.last?.id {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func bubble(_ message: YouTubeAskMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 36) }
            VStack(alignment: .leading, spacing: 6) {
                Text(message.text.isEmpty && message.isStreaming
                    ? String(localized: "Thinking…")
                    : message.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .foregroundStyle(.primary)
                if message.isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(message.role == .user
                        ? Self.brandAccent.opacity(0.18)
                        : Color.primary.opacity(0.06))
            }
            if message.role == .assistant { Spacer(minLength: 20) }
        }
    }

    // MARK: - Suggestions

    private var suggestions: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(self.askService.suggestions, id: \.self) { suggestion in
                Button {
                    self.askService.askSuggestion(suggestion)
                } label: {
                    Text(suggestion)
                        .font(.caption.weight(.medium))
                        .multilineTextAlignment(.trailing)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: 320, alignment: .trailing)
                        .background(.quaternary.opacity(0.55), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(self.askService.isAnswering || self.askService.isLoadingPage)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 8) {
            TextField(
                String(localized: "Ask a question…"),
                text: self.$draft,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1 ... 4)
            .focused(self.$inputFocused)
            .onSubmit { self.send() }
            .disabled(self.askService.isAnswering)

            Button(action: self.send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(
                        self.canSend ? Self.brandAccent : Color.secondary.opacity(0.4)
                    )
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .disabled(!self.canSend)
            .accessibilityLabel(String(localized: "Send"))
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.aiAskButton)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var canSend: Bool {
        !self.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !self.askService.isAnswering
            && !self.askService.isLoadingPage
    }

    private func send() {
        let q = self.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        self.draft = ""
        self.askService.ask(q)
    }

    private var footer: some View {
        HStack {
            Text("Ask · YouTube (web)", comment: "Native ask footer")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("Results fetched from youtube.com — not shown as a page", comment: "Native ask source")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

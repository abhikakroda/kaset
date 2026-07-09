import FoundationModels
import os
import SwiftUI

// MARK: - YouTubeVideoAIPanel

/// YouTube **Ask** — on-device Apple Intelligence for the current video.
///
/// Designed to work the same way Music AI does: always visible entry, refresh
/// availability on open, and a plain-text generation path that does not depend
/// solely on `@Generable` structured decoding (which was failing more often
/// on video prompts).
@available(macOS 26.0, *)
struct YouTubeVideoAIPanel: View {
    let video: YouTubeVideo
    let viewModel: YouTubeWatchViewModel
    var isExpanded: Binding<Bool>?

    @State private var summaryText: String?
    @State private var isSummarizing = false
    @State private var summaryError: String?

    @State private var question = ""
    @State private var turns: [VideoAskTurn] = []
    @State private var isAnswering = false
    @State private var answerError: String?
    @State private var availabilityHint: String?

    @State private var suggestedQuestions: [String] = []
    @FocusState private var isQuestionFocused: Bool

    private let logger = DiagnosticsLogger.ai

    private var expanded: Bool {
        self.isExpanded?.wrappedValue ?? true
    }

    private var subtitleText: String {
        if let availabilityHint {
            return availabilityHint
        }
        return String(localized: "Ask questions about this video")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            self.header

            if self.expanded {
                self.expandedContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.purple.opacity(0.18), lineWidth: 1)
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.aiPanel)
        .task(id: self.video.videoId) {
            self.turns = []
            self.summaryText = nil
            self.suggestedQuestions = self.heuristicSuggestions
            self.question = ""
            self.answerError = nil
            self.summaryError = nil
            await self.refreshAIStatus()
            if self.expanded {
                self.isQuestionFocused = true
            }
        }
        .onChange(of: self.expanded) { _, isOpen in
            if isOpen {
                self.isQuestionFocused = true
                Task { await self.refreshAIStatus() }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(.purple.opacity(0.18))
                    .frame(width: 32, height: 32)
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.purple)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Ask", comment: "YouTube-style Ask feature title")
                    .font(.headline)
                Text(self.subtitleText)
                    .font(.caption)
                    .foregroundStyle(self.availabilityHint == nil ? Color.secondary : Color.orange)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if let isExpanded {
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        isExpanded.wrappedValue.toggle()
                    }
                } label: {
                    Image(systemName: self.expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    self.expanded
                        ? String(localized: "Collapse Ask")
                        : String(localized: "Expand Ask")
                )
            }
        }
    }

    // MARK: - Expanded

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    Task { await self.summarize() }
                } label: {
                    if self.isSummarizing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(
                            self.summaryText == nil
                                ? String(localized: "Summarize video")
                                : String(localized: "Re-summarize"),
                            systemImage: "text.alignleft"
                        )
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(self.isSummarizing)

                if !self.turns.isEmpty {
                    Button(String(localized: "Clear chat")) {
                        self.turns = []
                        self.answerError = nil
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if let summaryText {
                Text(summaryText)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            } else if let summaryError {
                Text(summaryError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !self.turns.isEmpty {
                self.conversation
            } else if !self.suggestedQuestions.isEmpty {
                self.suggestionsSection
            } else {
                Text(
                    "Ask anything about this video. Uses on-device Apple Intelligence with the title, channel, and comments.",
                    comment: "Ask empty help"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let answerError {
                Text(answerError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            self.composer
        }
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggested", comment: "Ask suggested questions header")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 6) {
                ForEach(self.suggestedQuestions, id: \.self) { suggestion in
                    Button {
                        Task { await self.ask(prefilled: suggestion) }
                    } label: {
                        Text(suggestion)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.purple.opacity(0.12), in: Capsule())
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(self.isAnswering)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.askSuggestions)
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(self.turns) { turn in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Spacer(minLength: 40)
                        Text(turn.question)
                            .font(.callout)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.purple.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .textSelection(.enabled)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        if let answer = turn.answer, !answer.isEmpty {
                            Text(answer)
                                .font(.callout)
                                .textSelection(.enabled)
                        } else if turn.isStreaming {
                            ProgressView().controlSize(.mini)
                        }
                        if let caveat = turn.caveat,
                           !caveat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        {
                            Text(caveat)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.askConversation)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField(
                String(localized: "Ask anything about this video…"),
                text: self.$question
            )
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(.quaternary.opacity(0.55), in: Capsule())
            .focused(self.$isQuestionFocused)
            .onSubmit { Task { await self.ask() } }
            .disabled(self.isAnswering)
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.aiQuestionField)

            Button {
                Task { await self.ask() }
            } label: {
                if self.isAnswering {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.purple)
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .buttonStyle(.plain)
            .disabled(
                self.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || self.isAnswering
            )
            .accessibilityLabel(String(localized: "Ask"))
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.aiAskButton)
        }
    }

    // MARK: - Context

    private var title: String {
        self.viewModel.data.videoTitle ?? self.video.title
    }

    private var channelName: String? {
        self.viewModel.data.channel?.name ?? self.video.channelName
    }

    private var contextBlock: String {
        let channel = self.channelName ?? "Unknown channel"
        let views = self.viewModel.data.viewCountText ?? self.video.viewCountText ?? "unknown views"
        let published = self.viewModel.data.publishedText ?? self.video.publishedText ?? "unknown date"
        let length = self.video.lengthText ?? "unknown length"

        let comments = self.viewModel.comments.prefix(5).map { comment in
            let text = comment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = text.count > 120 ? String(text.prefix(120)) + "…" : text
            return "- \(comment.author): \(clipped)"
        }.joined(separator: "\n")

        let related = self.viewModel.data.related.prefix(5).map(\.title)
            .enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        return """
        Title: \(self.title)
        Channel: \(channel)
        Views: \(views)
        Published: \(published)
        Length: \(length)

        Comments:
        \(comments.isEmpty ? "(none)" : comments)

        Related:
        \(related.isEmpty ? "(none)" : related)
        """
    }

    private var heuristicSuggestions: [String] {
        var items = [
            String(localized: "What is this video about?"),
            String(localized: "Who is this for?"),
            String(localized: "What are the key takeaways?"),
        ]
        if let channel = self.channelName, !channel.isEmpty {
            items.append(String(localized: "Who is \(channel)?"))
        }
        items.append(String(localized: "Is this worth watching?"))
        return Array(items.prefix(5))
    }

    // MARK: - AI actions

    private func refreshAIStatus() async {
        if let reason = await FoundationModelsService.shared.prepareForInteractiveUse() {
            self.availabilityHint = reason
            self.logger.warning("YouTube Ask not ready: \(reason, privacy: .public)")
        } else {
            self.availabilityHint = nil
            self.logger.info("YouTube Ask ready")
        }
    }

    private func makeSession(instructions: String) -> LanguageModelSession? {
        FoundationModelsService.shared.createAnalysisSession(instructions: instructions)
    }

    private func summarize() async {
        self.isSummarizing = true
        self.summaryError = nil
        defer { self.isSummarizing = false }

        if let reason = await FoundationModelsService.shared.prepareForInteractiveUse() {
            self.summaryError = reason
            self.availabilityHint = reason
            return
        }

        let instructions = """
        You summarize YouTube videos for the Kaset macOS app.
        Use only the provided metadata. Do not invent a transcript.
        Reply with a short plain-text summary (3-6 sentences). No JSON.
        """

        guard let session = self.makeSession(instructions: instructions) else {
            self.summaryError = String(localized: "Apple Intelligence is not available")
            return
        }

        let prompt = """
        Summarize this video for a viewer deciding whether to watch:

        \(self.contextBlock)

        Write a clear plain-text summary.
        """

        do {
            // Plain-text path — same reliability model as free-form generation.
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                self.summaryError = String(localized: "Couldn’t generate a summary. Try again.")
            } else {
                self.summaryText = text
            }
        } catch {
            // Structured fallback if plain text fails for any reason.
            do {
                let structured = try await session.respond(to: prompt, generating: VideoSummary.self)
                let s = structured.content
                self.summaryText = "\(s.headline)\n\n\(s.overview)"
            } catch {
                self.summaryError = AIErrorHandler.handleAndMessage(error, context: "video summary")
                    ?? error.localizedDescription
                self.logger.error("YouTube summarize failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func ask(prefilled: String? = nil) async {
        let q = (prefilled ?? self.question).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }

        self.isAnswering = true
        self.answerError = nil
        self.question = ""
        defer { self.isAnswering = false }

        let turn = VideoAskTurn(question: q, isStreaming: true)
        self.turns.append(turn)
        let turnID = turn.id

        if let reason = await FoundationModelsService.shared.prepareForInteractiveUse() {
            self.answerError = reason
            self.availabilityHint = reason
            self.updateTurn(id: turnID) {
                $0.isStreaming = false
                $0.answer = reason
            }
            return
        }

        let prior = self.turns
            .filter { $0.id != turnID }
            .suffix(3)
            .compactMap { t -> String? in
                guard let a = t.answer, !a.isEmpty else { return nil }
                return "User: \(t.question)\nAssistant: \(a)"
            }
            .joined(separator: "\n\n")

        let instructions = """
        You answer questions about a YouTube video in the Kaset app.
        Use only the provided metadata (title, channel, stats, comments, related titles).
        If you cannot know the answer from that context, say so briefly.
        Reply in plain text only. No JSON. Be concise and helpful.
        """

        guard let session = self.makeSession(instructions: instructions) else {
            let message = String(localized: "Apple Intelligence is not available")
            self.answerError = message
            self.updateTurn(id: turnID) {
                $0.isStreaming = false
                $0.answer = message
            }
            return
        }

        let historyBlock = prior.isEmpty ? "" : "\nRecent conversation:\n\(prior)\n"
        let prompt = """
        Question: \(q)

        Video metadata:
        \(self.contextBlock)
        \(historyBlock)
        Answer the question in plain text.
        """

        do {
            // Primary path: plain text (matches Music free-form reliability).
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            self.updateTurn(id: turnID) {
                $0.isStreaming = false
                $0.answer = text.isEmpty
                    ? String(localized: "I couldn’t generate an answer. Try rephrasing.")
                    : text
            }
        } catch {
            self.logger.warning("YouTube Ask plain-text failed, trying structured: \(error.localizedDescription, privacy: .public)")
            do {
                let structured = try await session.respond(to: prompt, generating: VideoAnswer.self)
                self.updateTurn(id: turnID) {
                    $0.isStreaming = false
                    $0.answer = structured.content.answer
                    $0.caveat = structured.content.caveat
                }
            } catch {
                let message = AIErrorHandler.handleAndMessage(error, context: "video ask")
                    ?? error.localizedDescription
                self.answerError = message
                self.updateTurn(id: turnID) {
                    $0.isStreaming = false
                    $0.answer = message
                }
                self.logger.error("YouTube Ask failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func updateTurn(id: UUID, mutate: (inout VideoAskTurn) -> Void) {
        guard let index = self.turns.firstIndex(where: { $0.id == id }) else { return }
        var copy = self.turns[index]
        mutate(&copy)
        self.turns[index] = copy
    }
}

// MARK: - FlowLayout

@available(macOS 26.0, *)
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += rowHeight + self.spacing
                totalHeight = y
                x = 0
                rowHeight = 0
            }
            x += size.width + self.spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, x - self.spacing)
            totalHeight = y + rowHeight
        }

        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowHeight + self.spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + self.spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

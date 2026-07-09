import Foundation
import FoundationModels

// MARK: - VideoAskSuggestions

/// Suggested starter questions for the YouTube-style **Ask** feature.
@available(macOS 26.0, *)
@Generable
struct VideoAskSuggestions {
    /// 3–5 short, natural questions a viewer might ask about this video.
    @Guide(description: "List of 3-5 short, natural questions a viewer might ask about this video. Each question should be under 12 words and grounded in the provided metadata.")
    let questions: [String]
}

// MARK: - VideoAskTurn

/// One user/assistant exchange in the Ask conversation.
@available(macOS 26.0, *)
struct VideoAskTurn: Identifiable, Equatable {
    let id: UUID
    let question: String
    var answer: String?
    var caveat: String?
    var isStreaming: Bool

    init(
        id: UUID = UUID(),
        question: String,
        answer: String? = nil,
        caveat: String? = nil,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.caveat = caveat
        self.isStreaming = isStreaming
    }
}

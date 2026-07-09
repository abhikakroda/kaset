import Foundation
import FoundationModels

// MARK: - VideoSummary

/// On-device AI summary of a YouTube video from available metadata context.
@available(macOS 26.0, *)
@Generable
struct VideoSummary {
    /// One-line elevator pitch for the video.
    @Guide(description: "A single concise sentence capturing what the video is about.")
    let headline: String

    /// 2–4 key topics or themes.
    @Guide(description: "List of 2-4 key topics or themes in the video.")
    let topics: [String]

    /// Overall tone or style (e.g. educational, entertainment, news).
    @Guide(description: "A short phrase for the video's style or tone (e.g. 'tutorial', 'vlog', 'news analysis').")
    let style: String

    /// Multi-sentence overview based only on provided metadata.
    @Guide(description: "A 2-5 sentence summary of the video based only on the provided title, channel, and context. Do not invent claims not supported by the context.")
    let overview: String
}

// MARK: - VideoAnswer

/// On-device AI answer to a user question about a YouTube video.
@available(macOS 26.0, *)
@Generable
struct VideoAnswer {
    /// Direct answer to the user's question.
    @Guide(description: "A clear, helpful answer to the user's question about the video, grounded only in the provided metadata and context.")
    let answer: String

    /// Confidence note when context is thin.
    @Guide(description: "Optional short caveat when metadata is incomplete (e.g. 'Based only on the title and channel — no transcript was available.'). Empty string when not needed.")
    let caveat: String
}

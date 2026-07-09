import SwiftUI

// MARK: - YouTubeNotesSheet

/// Sheet that generates structured lecture notes from a YouTube video using
/// Antigravity CLI (`agy`), then exports them as a LaTeX PDF to ~/Downloads.
///
/// Shows generation progress, a preview of the generated notes, and the export result.
struct YouTubeNotesSheet: View {
    let video: YouTubeVideo
    let viewModel: YouTubeWatchViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var notesService = LectureNotesService()
    @State private var showLatexSource = false

    var body: some View {
        VStack(spacing: 0) {
            self.header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch self.notesService.state {
                    case .idle:
                        self.idleContent
                    case .generatingNotes:
                        self.generatingContent(phase: "Generating lecture notes with Antigravity…")
                    case .renderingPDF:
                        self.generatingContent(phase: "Compiling LaTeX to PDF…")
                    case let .completed(url):
                        self.completedContent(url: url)
                    case let .failed(message):
                        self.failedContent(message: message)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 520)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Generate Lecture Notes", comment: "Notes sheet title")
                    .font(.headline)
                Text(self.video.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                self.dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    // MARK: - Idle State

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Description
            HStack(spacing: 12) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.purple)

                VStack(alignment: .leading, spacing: 4) {
                    Text("AI-Powered Lecture Notes", comment: "Notes feature headline")
                        .font(.subheadline.weight(.semibold))
                    Text(
                        "Generate structured notes from this video using Antigravity CLI. Notes are exported as a beautifully formatted LaTeX PDF to your Downloads folder.",
                        comment: "Notes feature description"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))

            // What's included
            VStack(alignment: .leading, spacing: 8) {
                Text("Your notes will include:", comment: "Notes include section title")
                    .font(.subheadline.weight(.medium))

                Self.featureRow(icon: "text.alignleft", text: "Title & abstract")
                Self.featureRow(icon: "lightbulb", text: "Key concepts & definitions")
                Self.featureRow(icon: "list.bullet.rectangle", text: "Detailed structured sections")
                Self.featureRow(icon: "checkmark.circle", text: "Key takeaways")
                Self.featureRow(icon: "book", text: "References & further reading")
            }

            Divider()

            // Context info
            VStack(alignment: .leading, spacing: 6) {
                Text("Context sources:", comment: "Notes context sources header")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    Self.contextBadge(
                        icon: "film",
                        label: "Video metadata",
                        available: true
                    )
                    Self.contextBadge(
                        icon: "text.bubble",
                        label: "Comments",
                        available: !self.viewModel.comments.isEmpty
                    )
                    Self.contextBadge(
                        icon: "terminal",
                        label: "Antigravity CLI",
                        available: true
                    )
                }
            }

            // Powered by badge
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 10))
                    .foregroundStyle(.purple)
                Text("Powered by Antigravity CLI (agy)", comment: "Powered by badge")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)

            Spacer(minLength: 16)

            // Generate button
            Button {
                Task { await self.generateNotes() }
            } label: {
                Label("Generate Notes", systemImage: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .controlSize(.large)
        }
    }

    // MARK: - Generating State

    private func generatingContent(phase: String) -> some View {
        VStack(spacing: 20) {
            Spacer(minLength: 40)

            ProgressView()
                .controlSize(.large)

            Text(phase)
                .font(.headline)

            Text("Using Antigravity CLI to analyze video content and generate structured notes.", comment: "Progress note during notes generation")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Completed State

    private func completedContent(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Success banner
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Notes generated!", comment: "Notes generation success title")
                        .font(.subheadline.weight(.semibold))
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(12)
            .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            // Preview of generated notes
            if !self.notesService.notesSections.isEmpty {
                self.notesPreview
            }

            // Actions
            HStack(spacing: 12) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label(
                        url.pathExtension == "pdf" ? "Open PDF" : "Open File",
                        systemImage: "doc.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)

                Button {
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                if self.notesService.latexSource != nil {
                    Button {
                        self.showLatexSource.toggle()
                    } label: {
                        Label(
                            self.showLatexSource ? "Hide LaTeX" : "Show LaTeX",
                            systemImage: "chevron.left.forwardslash.chevron.right"
                        )
                    }
                    .buttonStyle(.bordered)
                }
            }

            if url.pathExtension == "tex" {
                Text("No LaTeX compiler found — saved .tex source. Install tectonic (`brew install tectonic`) for PDF output.", comment: "No compiler hint")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if self.showLatexSource, let latex = self.notesService.latexSource {
                ScrollView {
                    Text(latex)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Failed State

    private func failedContent(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 40)

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)

            Text("Generation failed", comment: "Notes generation failure title")
                .font(.headline)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            Button("Try Again") {
                self.notesService.reset()
            }
            .buttonStyle(.bordered)

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Notes Preview

    private var notesPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sections", comment: "Notes preview section header")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(self.notesService.notesSections.enumerated()), id: \.offset) { index, heading in
                    HStack(spacing: 8) {
                        Text("\(index + 1).")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 20, alignment: .trailing)
                        Text(heading)
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Helpers

    private static func featureRow(icon: String, text: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.purple)
                .frame(width: 20)
            Text(text)
                .font(.caption)
        }
    }

    private static func contextBadge(icon: String, label: String, available: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(label)
                .font(.system(size: 10))
        }
        .foregroundStyle(available ? .primary : .tertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            available ? Color.purple.opacity(0.1) : Color.secondary.opacity(0.08),
            in: Capsule()
        )
    }

    // MARK: - Generation

    private func generateNotes() async {
        let title = self.viewModel.data.videoTitle ?? self.video.title
        let channel = self.viewModel.data.channel?.name ?? self.video.channelName
        let views = self.viewModel.data.viewCountText ?? self.video.viewCountText ?? ""
        let published = self.viewModel.data.publishedText ?? self.video.publishedText ?? ""
        let length = self.video.lengthText ?? ""

        let metadata = """
        Views: \(views)
        Published: \(published)
        Length: \(length)
        """

        let comments = self.viewModel.comments.prefix(10).map { comment in
            let text = comment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.count > 150 ? String(text.prefix(150)) + "…" : text
        }

        do {
            _ = try await self.notesService.generateAndExport(
                videoTitle: title,
                channelName: channel,
                metadata: metadata,
                comments: Array(comments),
                captionsContext: nil
            )
        } catch {
            DiagnosticsLogger.ai.error("Lecture notes generation failed: \(error.localizedDescription)")
        }
    }
}

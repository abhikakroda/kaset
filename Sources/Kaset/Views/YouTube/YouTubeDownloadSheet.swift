import AppKit
import SwiftUI

// MARK: - YouTubeDownloadSheet

/// Sheet for downloading a YouTube video via the system yt-dlp CLI.
struct YouTubeDownloadSheet: View {
    let video: YouTubeVideo

    @Environment(\.dismiss) private var dismiss
    @State private var settings = SettingsManager.shared
    @State private var downloadService = YTDLPService.shared
    @State private var quality: DownloadQuality = SettingsManager.shared.downloadDefaultQuality
    @State private var errorMessage: String?
    @State private var activeJobID: UUID?

    private var activeJob: DownloadJob? {
        guard let id = self.activeJobID else { return nil }
        return self.downloadService.jobs.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Download", comment: "Download sheet title")
                        .font(.title2.bold())
                    Text(self.video.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    self.dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent(String(localized: "Quality")) {
                        Picker("", selection: self.$quality) {
                            ForEach(DownloadQuality.allCases) { q in
                                Text(q.displayName).tag(q)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                    }

                    LabeledContent(String(localized: "Save to")) {
                        Text(self.destinationLabel)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: 260, alignment: .trailing)
                    }

                    LabeledContent(String(localized: "yt-dlp")) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(self.downloadService.isAvailable ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(self.downloadService.resolvedBinaryPath ?? String(localized: "Not found"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let job = self.activeJob {
                self.jobProgress(job)
            }

            HStack {
                Button(String(localized: "Open in Terminal")) {
                    self.openInTerminal()
                }
                .disabled(!self.downloadService.isAvailable && self.settings.ytdlpBinaryPath.isEmpty)

                Spacer()

                Button(String(localized: "Cancel Download")) {
                    if let id = self.activeJobID {
                        self.downloadService.cancel(id)
                    }
                }
                .disabled(self.activeJob == nil || self.activeJob?.status != .running)

                Button {
                    self.startDownload()
                } label: {
                    if self.activeJob?.status == .running {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(String(localized: "Download"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(self.activeJob?.status == .running)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            self.downloadService.refreshBinaryPath()
            self.quality = self.settings.downloadDefaultQuality
        }
    }

    private var destinationLabel: String {
        switch self.settings.downloadFolderPreference {
        case .downloads:
            String(localized: "Downloads folder")
        case .custom:
            self.settings.downloadFolderDisplayPath.isEmpty
                ? String(localized: "Custom folder (not set)")
                : self.settings.downloadFolderDisplayPath
        }
    }

    @ViewBuilder
    private func jobProgress(_ job: DownloadJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch job.status {
            case .queued:
                Text("Queued…", comment: "Download job queued")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .running:
                ProgressView(value: job.progress ?? 0, total: 1) {
                    HStack {
                        Text(String(localized: "Downloading…"))
                        Spacer()
                        if let speed = job.speedText {
                            Text(speed).foregroundStyle(.secondary)
                        }
                        if let eta = job.etaText {
                            Text("ETA \(eta)").foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
            case .completed:
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(String(localized: "Download complete"))
                    Spacer()
                    Button(String(localized: "Show in Finder")) {
                        self.downloadService.revealInFinder(job: job)
                    }
                }
                .font(.callout)
            case let .failed(message):
                VStack(alignment: .leading, spacing: 4) {
                    Label(String(localized: "Download failed"), systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            case .cancelled:
                Text(String(localized: "Cancelled"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func startDownload() {
        self.errorMessage = nil
        do {
            let job = try self.downloadService.download(
                videoId: self.video.videoId,
                title: self.video.title,
                quality: self.quality
            )
            self.activeJobID = job.id
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    private func openInTerminal() {
        self.errorMessage = nil
        do {
            try self.downloadService.openInTerminal(
                videoId: self.video.videoId,
                title: self.video.title,
                quality: self.quality
            )
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
}

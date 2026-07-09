import SwiftUI

// MARK: - DownloadJobSnapshot

/// Main-thread snapshot of a download job for safe SwiftUI rendering.
/// Avoids walking live `@Observable` class graphs inside `filter` during
/// rapid progress updates (which crashed the app on download complete).
private struct DownloadJobSnapshot: Identifiable, Equatable {
    let id: UUID
    let videoId: String
    let title: String
    let qualityName: String
    let status: DownloadJob.Status
    let progress: Double?
    let speedText: String?
    let etaText: String?
    let startedAt: Date
    let progressRevision: UInt

    init(_ job: DownloadJob) {
        self.id = job.id
        self.videoId = job.videoId
        self.title = job.title
        self.qualityName = job.quality.displayName
        self.status = job.status
        self.progress = job.progress
        self.speedText = job.speedText
        self.etaText = job.etaText
        self.startedAt = job.startedAt
        self.progressRevision = job.progressRevision
    }

    var isVisible: Bool {
        switch self.status {
        case .queued, .running:
            true
        case .completed, .failed, .cancelled:
            Date().timeIntervalSince(self.startedAt) < 90
        }
    }
}

// MARK: - YouTubeDownloadHUD

/// Floating Liquid Glass HUD for background yt-dlp downloads.
/// Shows real-time progress percentage, speed, and ETA without blocking the UI.
struct YouTubeDownloadHUD: View {
    /// Observe the shared service directly (do NOT store it in `@State` —
    /// that pattern raced with progress updates and crashed on completion).
    private var downloadService: YTDLPService { YTDLPService.shared }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var visibleSnapshots: [DownloadJobSnapshot] {
        // Touch progressRevision so Observation tracks throttled progress.
        let snapshots = self.downloadService.jobs.map { job in
            _ = job.progressRevision
            return DownloadJobSnapshot(job)
        }
        return Array(snapshots.filter(\.isVisible).prefix(4))
    }

    var body: some View {
        let snapshots = self.visibleSnapshots
        if !snapshots.isEmpty {
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(snapshots) { snapshot in
                    DownloadJobCard(
                        snapshot: snapshot,
                        onCancel: {
                            self.downloadService.cancel(snapshot.id)
                        },
                        reveal: {
                            if let job = self.downloadService.jobs.first(where: { $0.id == snapshot.id }) {
                                self.downloadService.revealInFinder(job: job)
                            }
                        }
                    )
                    .transition(
                        self.reduceMotion
                            ? .opacity
                            : .move(edge: .trailing).combined(with: .opacity)
                    )
                    .id("\(snapshot.id)-\(snapshot.progressRevision)-\(String(describing: snapshot.status))")
                }
            }
            .padding(.trailing, 16)
            .padding(.top, 12)
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.downloadHUD)
        }
    }
}

// MARK: - DownloadJobCard

private struct DownloadJobCard: View {
    let snapshot: DownloadJobSnapshot
    let onCancel: () -> Void
    let reveal: () -> Void

    private static let brandAccent = PackageResourceLookup.brandAccent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                self.statusIcon
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(self.snapshot.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                    Text(self.snapshot.qualityName)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(self.percentLabel)
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(Self.brandAccent)
                    .accessibilityIdentifier(AccessibilityID.YouTubeContent.downloadPercent)
            }

            GeometryReader { geo in
                let fraction = min(max(self.snapshot.progress ?? (self.snapshot.status == .completed ? 1 : 0), 0), 1)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.primary.opacity(0.08))
                    Capsule()
                        .fill(Self.brandAccent)
                        .frame(width: max(4, geo.size.width * fraction))
                }
            }
            .frame(height: 6)

            HStack(spacing: 8) {
                Text(self.statusText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                switch self.snapshot.status {
                case .running, .queued:
                    Button(String(localized: "Cancel"), action: self.onCancel)
                        .buttonStyle(.borderless)
                        .font(.system(size: 10, weight: .semibold))
                case .completed:
                    Button(String(localized: "Show"), action: self.reveal)
                        .buttonStyle(.borderless)
                        .font(.system(size: 10, weight: .semibold))
                case .failed, .cancelled:
                    EmptyView()
                }
            }
        }
        .padding(12)
        .frame(width: 280)
        .compatGlass(interactive: true, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }

    private var percentLabel: String {
        switch self.snapshot.status {
        case .completed:
            return "100%"
        case .failed, .cancelled:
            return "—"
        case .queued, .running:
            if let progress = self.snapshot.progress {
                return "\(Int((progress * 100).rounded()))%"
            }
            return "…"
        }
    }

    private var statusText: String {
        switch self.snapshot.status {
        case .queued:
            return String(localized: "Queued…")
        case .running:
            var parts: [String] = [String(localized: "Downloading")]
            if let speed = self.snapshot.speedText { parts.append(speed) }
            if let eta = self.snapshot.etaText { parts.append("ETA \(eta)") }
            return parts.joined(separator: " · ")
        case .completed:
            return String(localized: "Saved")
        case let .failed(message):
            return message
        case .cancelled:
            return String(localized: "Cancelled")
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch self.snapshot.status {
        case .queued:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - OneClickDownloadButton

/// Instant download control with live ring progress for the current video.
struct OneClickDownloadButton: View {
    let video: YouTubeVideo
    var quality: DownloadQuality = SettingsManager.shared.downloadDefaultQuality

    private var downloadService: YTDLPService { YTDLPService.shared }

    @State private var errorMessage: String?
    @State private var showError = false

    private var activeJob: DownloadJob? {
        self.downloadService.jobs.first {
            $0.videoId == self.video.videoId
                && ($0.status == .running || $0.status == .queued)
        }
    }

    private var completedJob: DownloadJob? {
        self.downloadService.jobs.first {
            $0.videoId == self.video.videoId && $0.status == .completed
        }
    }

    var body: some View {
        // Observe throttled revision so the ring updates without hanging off
        // every intermediate progress write.
        let revision = self.activeJob?.progressRevision ?? self.completedJob?.progressRevision ?? 0
        _ = revision

        return Button {
            self.handleTap()
        } label: {
            HStack(spacing: 8) {
                if let job = self.activeJob {
                    ZStack {
                        Circle()
                            .stroke(.primary.opacity(0.12), lineWidth: 2.5)
                        Circle()
                            .trim(from: 0, to: job.progress ?? 0.05)
                            .stroke(
                                PackageResourceLookup.brandAccent,
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                        Text(self.shortPercent(job))
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                    }
                    .frame(width: 22, height: 22)

                    Text(self.shortPercent(job) + " " + String(localized: "Downloading"))
                } else if self.completedJob != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(String(localized: "Downloaded"))
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                    Text(String(localized: "Download"))
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .compatGlass(interactive: true, in: Capsule())
        .disabled(self.activeJob != nil)
        .help(String(localized: "One-click download with yt-dlp (background)"))
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.downloadButton)
        .alert(String(localized: "Download"), isPresented: self.$showError) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(self.errorMessage ?? "")
        }
    }

    private func shortPercent(_ job: DownloadJob) -> String {
        if let progress = job.progress {
            return "\(Int((progress * 100).rounded()))%"
        }
        return "…"
    }

    private func handleTap() {
        if let completed = self.completedJob {
            self.downloadService.revealInFinder(job: completed)
            return
        }
        do {
            _ = try self.downloadService.download(
                videoId: self.video.videoId,
                title: self.video.title,
                quality: self.quality
            )
            HapticService.toggle()
        } catch {
            self.errorMessage = error.localizedDescription
            self.showError = true
        }
    }
}

extension AccessibilityID.YouTubeContent {
    static let downloadHUD = "youtubeContent.downloadHUD"
    static let downloadPercent = "youtubeContent.downloadPercent"
}

import SwiftUI

// MARK: - YouTubeInAppMiniPlayer

/// Compact mini player when navigating away from a playing YouTube video.
///
/// Intentionally minimal controls:
/// - Progress bar (scrubbable)
/// - −30s / +30s seek
/// - Tap the strip to expand back to the watch view
struct YouTubeInAppMiniPlayer: View {
    private static let brandAccent = PackageResourceLookup.brandAccent
    private static let barHeight: CGFloat = 52

    @Environment(YouTubePlayerService.self) private var youtubePlayer
    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0

    var body: some View {
        if self.youtubePlayer.surfaceLocation == .miniPlayer,
           let video = self.youtubePlayer.currentVideo
        {
            self.miniPlayerCard(for: video)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    )
                )
        }
    }

    // MARK: - Card

    @ViewBuilder
    private func miniPlayerCard(for video: YouTubeVideo) -> some View {
        VStack(spacing: 0) {
            // Scrubbable progress
            self.progressBar
                .frame(height: 18)
                .padding(.horizontal, 12)
                .padding(.top, 6)

            HStack(spacing: 12) {
                // −30s
                Button {
                    HapticService.playback()
                    self.youtubePlayer.seekBackward()
                } label: {
                    Image(systemName: "gobackward.30")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Back 30 seconds"))
                .accessibilityIdentifier(AccessibilityID.YouTubeContent.miniPlayerSeekBack)

                // Title (tap expands)
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(Self.formatTime(self.displayProgress))
                            .font(.system(size: 10).monospacedDigit())
                        Text("/")
                            .font(.system(size: 10))
                        Text(Self.formatTime(self.youtubePlayer.duration))
                            .font(.system(size: 10).monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    HapticService.toggle()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        self.youtubePlayer.expandFromMiniPlayer()
                    }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(String(localized: "Expand video"))
                .accessibilityHint(video.title)

                // +30s
                Button {
                    HapticService.playback()
                    self.youtubePlayer.seekForward()
                } label: {
                    Image(systemName: "goforward.30")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Forward 30 seconds"))
                .accessibilityIdentifier(AccessibilityID.YouTubeContent.miniPlayerSeekForward)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .frame(height: Self.barHeight)
        }
        .background {
            Rectangle()
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 10, y: -3)
        }
        .overlay(alignment: .top) {
            Divider().opacity(0.45)
        }
        .onChange(of: self.youtubePlayer.progress) { _, _ in
            if !self.isScrubbing {
                self.scrubFraction = self.progressFraction
            }
        }
        .onAppear {
            self.scrubFraction = self.progressFraction
        }
    }

    // MARK: - Progress bar

    private var progressBar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = self.isScrubbing ? self.scrubFraction : self.progressFraction

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.12))
                    .frame(height: 4)
                Capsule()
                    .fill(Self.brandAccent)
                    .frame(width: max(4, width * fraction), height: 4)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        self.isScrubbing = true
                        self.scrubFraction = min(max(value.location.x / max(width, 1), 0), 1)
                    }
                    .onEnded { value in
                        let fraction = min(max(value.location.x / max(width, 1), 0), 1)
                        self.scrubFraction = fraction
                        let duration = self.youtubePlayer.duration
                        if duration > 0 {
                            self.youtubePlayer.seek(to: fraction * duration)
                        }
                        self.isScrubbing = false
                    }
            )
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.miniPlayerProgress)
    }

    // MARK: - Helpers

    private var progressFraction: Double {
        let dur = self.youtubePlayer.duration
        guard dur > 0 else { return 0 }
        return min(max(self.youtubePlayer.progress / dur, 0), 1)
    }

    private var displayProgress: Double {
        if self.isScrubbing {
            return self.scrubFraction * max(self.youtubePlayer.duration, 0)
        }
        return self.youtubePlayer.progress
    }

    private static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Convenience Modifier

extension View {
    /// Attaches the in-app mini player to the bottom of any YouTube content
    /// view, sitting above the `YouTubePlayerBar` inset.
    func youtubeMiniPlayerOverlay() -> some View {
        self.safeAreaInset(edge: .bottom, spacing: 0) {
            YouTubeInAppMiniPlayer()
        }
    }
}

// MARK: - AccessibilityID Additions

extension AccessibilityID.YouTubeContent {
    static let miniPlayerSeekBack = "youtubeContent.miniPlayer.seekBack"
    static let miniPlayerSeekForward = "youtubeContent.miniPlayer.seekForward"
    static let miniPlayerProgress = "youtubeContent.miniPlayer.progress"
    /// Kept for existing UI tests / references.
    static let miniPlayerPlayPause = "youtubeContent.miniPlayer.playPause"
    static let miniPlayerClose = "youtubeContent.miniPlayer.close"
}

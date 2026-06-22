import Foundation

// MARK: - MusicVideoQualitySource

/// The async quality-control surface backing music video mode. The production
/// implementation is `SingletonPlayerWebView`; tests inject a recorder so the
/// discovery/retry logic can be exercised without a live WebView.
@MainActor
protocol MusicVideoQualitySource: AnyObject {
    /// The videoId the WebView's player currently reports as loaded (reads the
    /// live `#movie_player`), or nil if not yet known. Used to confirm the page
    /// has actually navigated before trusting its quality levels.
    func loadedVideoId() async -> String?
    func availableQualityLevels() async -> [String]
    func currentQualityLevel() async -> String?
    func setQualityLevel(_ level: String)
}

// MARK: - SingletonPlayerWebView + MusicVideoQualitySource

extension SingletonPlayerWebView: MusicVideoQualitySource {
    /// Reads the videoId the live player reports (via `currentPlaybackSnapshot`),
    /// which reflects the actually-loaded page rather than the requested id.
    func loadedVideoId() async -> String? {
        await self.currentPlaybackSnapshot()?.videoId
    }
}

// MARK: - PlayerService Video Quality

/// Resolution selection for music **video mode** (Official Music Videos).
///
/// Parallels the YouTube side's quality handling (`YouTubePlayerService`), but
/// drives the music `SingletonPlayerWebView`'s `#movie_player`. Only meaningful
/// while `showVideo` is active; audio-only playback reports no levels. See
/// ADR-0023.
///
/// Discovery is keyed to the active `videoId` (mirroring
/// `YouTubePlayerService.updatePlaybackState`), not to the video-window-open
/// transition — so the quality menu repopulates when the track changes while
/// video mode stays open, and a slow/empty first probe can retry.
extension PlayerService {
    /// Loads the resolution levels for the current video if they haven't been
    /// loaded yet. Idempotent: the per-video guard is set only **after** a
    /// successful fetch whose levels are confirmed to belong to the requested
    /// video. When the player isn't ready yet — or still has the *previous*
    /// video loaded after a skip (the WebView navigates asynchronously, and
    /// `play(song:)` updates `currentTrack` before the page changes) — it
    /// retries a few times internally rather than latching stale levels.
    /// Re-checks `showVideo`/`videoId` between attempts so it can't loop forever
    /// or leak across track changes.
    func refreshVideoQualityOptionsIfNeeded() async {
        guard self.showVideo, let videoId = self.currentTrack?.videoId else { return }
        guard self.videoQualityOptionsVideoId != videoId else { return }

        for attempt in 0 ..< 3 {
            // Confirm the player has actually navigated to the requested video
            // before trusting its quality levels — otherwise a skip can latch
            // the previous page's levels under the new videoId.
            let loadedId = await self.videoQualitySource.loadedVideoId()
            guard self.showVideo, self.currentTrack?.videoId == videoId else { return }

            let levels = loadedId == videoId ? await self.videoQualitySource.availableQualityLevels() : []

            // Bail if video mode closed or the track changed mid-fetch.
            guard self.showVideo, self.currentTrack?.videoId == videoId else { return }

            if !levels.isEmpty {
                let current = await self.videoQualitySource.currentQualityLevel()

                // Re-check after the second await as well, so a track change
                // mid-fetch can't leak the previous video's state onto the new one.
                guard self.showVideo, self.currentTrack?.videoId == videoId else { return }

                self.videoQualityLevels = levels
                self.currentVideoQuality = current
                self.videoQualityOptionsVideoId = videoId
                return
            }

            // Player not ready / still on the old page; wait and retry (guard
            // stays unset).
            if attempt < 2 {
                try? await Task.sleep(for: .milliseconds(1500))
                guard self.showVideo, self.currentTrack?.videoId == videoId else { return }
            }
        }
    }

    /// Selects a playback resolution and remembers it optimistically.
    func selectVideoQuality(_ level: String) {
        self.currentVideoQuality = level
        self.videoQualitySource.setQualityLevel(level)
        HapticService.toggle()
    }

    /// Clears per-track quality state (called from ``resetTrackStatus()``).
    func resetVideoQualityOptions() {
        self.videoQualityLevels = []
        self.currentVideoQuality = nil
        self.videoQualityOptionsVideoId = nil
    }
}

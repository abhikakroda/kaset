import AppKit
import SwiftUI

// MARK: - YouTubeFullscreenChrome

/// Liquid Glass chrome for the floating / fullscreen YouTube video window.
///
/// - Auto-hides after a short idle period (fullscreen and windowed).
/// - Reappears on mouse movement.
/// - Uses a compact glass control strip (not the full main-window player bar)
///   so layout does not thrash or introduce scroll jank when chrome appears.
struct YouTubeFullscreenChrome: View {
    @Environment(YouTubePlayerService.self) private var youtubePlayer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var isScrubbing = false
    @State private var seekValue: Double = 0

    /// PiP + fullscreen control strip auto-hides after this idle period.
    private static let idleHideDelay: Duration = .seconds(3)
    private static let brandAccent = PackageResourceLookup.brandAccent

    var body: some View {
        ZStack(alignment: .bottom) {
            // Activity catcher — full-bleed, transparent, passes clicks through
            // except when we need to count movement. Mouse movement is tracked
            // via an NSView monitor so WebView scroll/hover does not fight us.
            MouseActivityTracker {
                self.noteActivity()
            }
            .allowsHitTesting(false)

            if self.controlsVisible {
                self.glassControlStrip
                    .padding(.horizontal, 20)
                    .padding(.bottom, self.youtubePlayer.isWindowFullscreen ? 28 : 16)
                    .transition(
                        self.reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            self.syncSeekFromPlayer()
            self.noteActivity()
            YouTubeVideoWindowController.shared.setWindowChromeVisible(true)
        }
        .onDisappear {
            self.hideTask?.cancel()
            self.hideTask = nil
        }
        .onChange(of: self.youtubePlayer.progress) { _, _ in
            if !self.isScrubbing {
                self.syncSeekFromPlayer()
            }
        }
        .onChange(of: self.youtubePlayer.duration) { _, _ in
            if !self.isScrubbing {
                self.syncSeekFromPlayer()
            }
        }
        .onChange(of: self.youtubePlayer.isWindowFullscreen) { _, isFull in
            // Entering fullscreen: show briefly then auto-hide.
            self.controlsVisible = true
            YouTubeVideoWindowController.shared.setWindowChromeVisible(true)
            if isFull {
                self.scheduleHide()
            }
        }
        .onExitCommand {
            if self.youtubePlayer.isWindowFullscreen {
                YouTubeVideoWindowController.shared.toggleFullscreen()
            }
        }
    }

    // MARK: - Glass strip

    private var glassControlStrip: some View {
        VStack(spacing: 10) {
            // Title row
            if let video = self.youtubePlayer.currentVideo {
                HStack(spacing: 10) {
                    Text(video.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    if let channel = video.channelName {
                        Text(channel)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 4)
            }

            // Scrubber
            HStack(spacing: 10) {
                Text(Self.formatTime(self.displayTime))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)

                Slider(
                    value: self.$seekValue,
                    in: 0 ... 1,
                    onEditingChanged: { editing in
                        self.isScrubbing = editing
                        self.noteActivity()
                        if !editing {
                            let target = self.seekValue * max(self.youtubePlayer.duration, 0.001)
                            self.youtubePlayer.seek(to: target)
                        }
                    }
                )
                .controlSize(.small)
                .tint(Self.brandAccent)

                Text(Self.formatTime(self.youtubePlayer.duration))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            // Transport
            HStack(spacing: 14) {
                chromeButton(systemName: "gobackward.30", label: String(localized: "Back 30 seconds")) {
                    self.youtubePlayer.seekBackward()
                    self.noteActivity()
                }

                Button {
                    HapticService.playback()
                    self.youtubePlayer.playPause()
                    self.noteActivity()
                } label: {
                    Image(systemName: self.youtubePlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .compatGlass(interactive: true, tint: Self.brandAccent.opacity(0.35), in: Circle())
                .accessibilityLabel(
                    self.youtubePlayer.isPlaying
                        ? String(localized: "Pause")
                        : String(localized: "Play")
                )

                chromeButton(systemName: "goforward.30", label: String(localized: "Forward 30 seconds")) {
                    self.youtubePlayer.seekForward()
                    self.noteActivity()
                }

                Spacer(minLength: 8)

                chromeButton(
                    systemName: self.youtubePlayer.isWindowFullscreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right",
                    label: self.youtubePlayer.isWindowFullscreen
                        ? String(localized: "Exit Full Screen")
                        : String(localized: "Full Screen")
                ) {
                    YouTubeVideoWindowController.shared.toggleFullscreen()
                    self.noteActivity()
                }

                if !self.youtubePlayer.isWindowFullscreen {
                    chromeButton(systemName: "pip.exit", label: String(localized: "Dock inline")) {
                        self.youtubePlayer.requestPopIn()
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: 720)
        .compatGlass(interactive: true, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 24, y: 8)
        // Keep pointer activity over the strip from immediately re-hiding.
        .onHover { hovering in
            if hovering {
                self.noteActivity(forceVisible: true, scheduleHide: false)
            } else {
                self.scheduleHide()
            }
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.fullscreenChrome)
    }

    private func chromeButton(
        systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            HapticService.toggle()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .compatGlass(interactive: true, in: Circle())
        .accessibilityLabel(label)
    }

    // MARK: - Activity / auto-hide

    private func noteActivity(forceVisible: Bool = true, scheduleHide: Bool = true) {
        if forceVisible, !self.controlsVisible {
            withAnimation(self.reduceMotion ? .easeInOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.88)) {
                self.controlsVisible = true
            }
            YouTubeVideoWindowController.shared.setWindowChromeVisible(true)
        } else if forceVisible {
            self.controlsVisible = true
            YouTubeVideoWindowController.shared.setWindowChromeVisible(true)
        }

        if scheduleHide, !self.isScrubbing {
            self.scheduleHide()
        }
    }

    private func scheduleHide() {
        self.hideTask?.cancel()
        self.hideTask = Task { @MainActor in
            try? await Task.sleep(for: Self.idleHideDelay)
            guard !Task.isCancelled, !self.isScrubbing else { return }
            withAnimation(.easeOut(duration: 0.28)) {
                self.controlsVisible = false
            }
            YouTubeVideoWindowController.shared.setWindowChromeVisible(false)
            // Hide cursor in true fullscreen for a theater feel.
            if self.youtubePlayer.isWindowFullscreen {
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }

    // MARK: - Seek helpers

    private var displayTime: Double {
        if self.isScrubbing {
            return self.seekValue * max(self.youtubePlayer.duration, 0)
        }
        return self.youtubePlayer.progress
    }

    private func syncSeekFromPlayer() {
        let duration = self.youtubePlayer.duration
        guard duration > 0 else {
            self.seekValue = 0
            return
        }
        self.seekValue = min(max(self.youtubePlayer.progress / duration, 0), 1)
    }

    private static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - MouseActivityTracker

/// Reports local mouse-move events so chrome can reappear without relying on
/// SwiftUI `.onHover` (which fails over WKWebView hit testing).
private struct MouseActivityTracker: NSViewRepresentable {
    var onActivity: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onActivity = self.onActivity
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        (nsView as? TrackingView)?.onActivity = self.onActivity
    }

    private final class TrackingView: NSView {
        var onActivity: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.teardown()
            guard self.window != nil else { return }
            self.monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
                // Only react to events for our window to avoid waking chrome from other windows.
                if event.window == self?.window {
                    DispatchQueue.main.async {
                        self?.onActivity?()
                    }
                }
                return event
            }
        }

        override func removeFromSuperview() {
            self.teardown()
            super.removeFromSuperview()
        }

        private func teardown() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

// MARK: - Accessibility

extension AccessibilityID.YouTubeContent {
    static let fullscreenChrome = "youtubeContent.fullscreenChrome"
}

import Foundation
import Testing
@testable import Kaset

@Suite("YTDLPService", .tags(.service))
@MainActor
struct YTDLPServiceTests {
    @Test("Quality presets produce non-empty format selectors")
    func formatSelectors() {
        for quality in DownloadQuality.allCases {
            #expect(!quality.formatSelector.isEmpty)
        }
        #expect(DownloadQuality.audioMP3.audioExtractFormat == "mp3")
        #expect(DownloadQuality.audioM4A.audioExtractFormat == "m4a")
        #expect(DownloadQuality.best.audioExtractFormat == nil)
        #expect(DownloadQuality.audioMP3.isAudioOnly)
        #expect(!DownloadQuality.fullHD1080.isAudioOnly)
    }

    @Test("buildArguments includes video URL, format, and destination")
    func buildArguments() {
        let dest = URL(fileURLWithPath: "/tmp/kaset-downloads")
        let args = YTDLPService.buildArguments(
            binary: "/opt/homebrew/bin/yt-dlp",
            videoId: "dQw4w9WgXcQ",
            title: "Never Gonna Give You Up",
            quality: .fullHD1080,
            destination: dest
        )

        #expect(args.first == "/opt/homebrew/bin/yt-dlp")
        #expect(args.contains("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        #expect(args.contains("-f"))
        #expect(args.contains(DownloadQuality.fullHD1080.formatSelector))
        #expect(args.contains("-P"))
        #expect(args.contains(dest.path))
        #expect(args.contains("--no-playlist"))
    }

    @Test("Audio quality adds extract flags")
    func audioArguments() {
        let dest = URL(fileURLWithPath: "/tmp/kaset-downloads")
        let args = YTDLPService.buildArguments(
            binary: "yt-dlp",
            videoId: "abc123",
            title: "Song",
            quality: .audioMP3,
            destination: dest
        )
        #expect(args.contains("-x"))
        #expect(args.contains("--audio-format"))
        #expect(args.contains("mp3"))
        #expect(!args.contains("--merge-output-format"))
    }

    @Test("parsePercent reads yt-dlp progress lines")
    func parsePercent() {
        #expect(YTDLPService.parsePercent(from: "[download]  45.2% of  10.00MiB at  1.23MiB/s ETA 00:04") == 45.2)
        #expect(YTDLPService.parsePercent(from: "[download] 100% of 1.00KiB") == 100)
        #expect(YTDLPService.parsePercent(from: "no progress here") == nil)
    }

    @Test("parseDestination recognizes Destination lines")
    func parseDestination() {
        let path = YTDLPService.parseDestination(from: "Destination: /Users/me/Downloads/video.mp4")
        #expect(path == "/Users/me/Downloads/video.mp4")
    }

    @Test("discoverBinaryPath respects override when executable")
    func discoverOverride() throws {
        // /bin/sh is always executable on macOS; use it as a stand-in override.
        let path = try #require(YTDLPService.discoverBinaryPath(override: "/bin/sh"))
        #expect(path == "/bin/sh")
    }
}

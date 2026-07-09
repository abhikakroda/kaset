import Foundation

// MARK: - DownloadQuality

/// Predefined quality / media targets for yt-dlp downloads.
enum DownloadQuality: String, CaseIterable, Identifiable, Sendable {
    case best
    case uhd2160
    case qhd1440
    case fullHD1080
    case hd720
    case sd480
    case sd360
    case audioM4A
    case audioMP3
    case videoOnlyBest

    var id: String {
        self.rawValue
    }

    var displayName: String {
        switch self {
        case .best: String(localized: "Best available")
        case .uhd2160: "2160p (4K)"
        case .qhd1440: "1440p"
        case .fullHD1080: "1080p"
        case .hd720: "720p"
        case .sd480: "480p"
        case .sd360: "360p"
        case .audioM4A: String(localized: "Audio only (M4A)")
        case .audioMP3: String(localized: "Audio only (MP3)")
        case .videoOnlyBest: String(localized: "Video only (best)")
        }
    }

    /// Whether this preset extracts audio-only media.
    var isAudioOnly: Bool {
        switch self {
        case .audioM4A, .audioMP3: true
        default: false
        }
    }

    /// yt-dlp `-f` format selection string.
    var formatSelector: String {
        switch self {
        case .best:
            "bv*+ba/b"
        case .uhd2160:
            "bv*[height<=2160]+ba/b[height<=2160]/bv*+ba/b"
        case .qhd1440:
            "bv*[height<=1440]+ba/b[height<=1440]/bv*+ba/b"
        case .fullHD1080:
            "bv*[height<=1080]+ba/b[height<=1080]/bv*+ba/b"
        case .hd720:
            "bv*[height<=720]+ba/b[height<=720]/bv*+ba/b"
        case .sd480:
            "bv*[height<=480]+ba/b[height<=480]/bv*+ba/b"
        case .sd360:
            "bv*[height<=360]+ba/b[height<=360]/bv*+ba/b"
        case .audioM4A, .audioMP3:
            "ba/b"
        case .videoOnlyBest:
            "bv*"
        }
    }

    /// Optional post-processor audio format (`-x --audio-format`).
    var audioExtractFormat: String? {
        switch self {
        case .audioM4A: "m4a"
        case .audioMP3: "mp3"
        default: nil
        }
    }
}

// MARK: - DownloadFolderPreference

/// Where completed downloads should land.
enum DownloadFolderPreference: String, CaseIterable, Identifiable, Sendable {
    /// macOS Downloads folder (requires downloads entitlement).
    case downloads
    /// User-chosen folder persisted via security-scoped bookmark.
    case custom

    var id: String {
        self.rawValue
    }

    var displayName: String {
        switch self {
        case .downloads: String(localized: "Downloads folder")
        case .custom: String(localized: "Custom folder")
        }
    }
}

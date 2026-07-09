import Foundation

// MARK: - YouTubeCourseFolder

/// A nested folder in the Courses library (folders can contain folders + courses).
struct YouTubeCourseFolder: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    /// `nil` means root of the library.
    var parentId: String?
    var createdAt: Date

    init(id: String = UUID().uuidString, name: String, parentId: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.createdAt = createdAt
    }
}

// MARK: - YouTubeCourseCatalogEntry

/// A playlist saved as a course in the library, with progress + preview thumbs.
struct YouTubeCourseCatalogEntry: Identifiable, Codable, Hashable, Sendable {
    var id: String { self.playlistId }

    var playlistId: String
    var title: String
    var channelName: String?
    var thumbnailURLString: String?
    /// Up to a handful of lesson thumbnail URLs for the card collage.
    var lessonThumbnailURLStrings: [String]
    var lessonCount: Int
    var completedCount: Int
    /// Folder this course lives in (`nil` = root).
    var folderId: String?
    var lastOpenedAt: Date
    var createdAt: Date
    /// Pinned courses float to the top of the library.
    var isPinned: Bool
    /// Last lesson the user was watching (for Continue Learning).
    var lastLessonVideoId: String?
    var lastLessonTitle: String?
    /// Approximate total duration in seconds (sum of parsed length texts).
    var totalDurationSeconds: Int
    /// Optional user goal: lessons to finish per week.
    var weeklyGoal: Int?

    var thumbnailURL: URL? {
        self.thumbnailURLString.flatMap(URL.init(string:))
    }

    var lessonThumbnailURLs: [URL] {
        self.lessonThumbnailURLStrings.compactMap(URL.init(string:))
    }

    var progressFraction: Double {
        guard self.lessonCount > 0 else { return 0 }
        return min(1, Double(self.completedCount) / Double(self.lessonCount))
    }

    var status: YouTubeCourseProgressStatus {
        if self.lessonCount > 0, self.completedCount >= self.lessonCount {
            .completed
        } else if self.completedCount > 0 || self.lastLessonVideoId != nil {
            .inProgress
        } else {
            .notStarted
        }
    }

    init(
        playlistId: String,
        title: String,
        channelName: String? = nil,
        thumbnailURL: URL? = nil,
        lessonThumbnailURLs: [URL] = [],
        lessonCount: Int = 0,
        completedCount: Int = 0,
        folderId: String? = nil,
        lastOpenedAt: Date = Date(),
        createdAt: Date = Date(),
        isPinned: Bool = false,
        lastLessonVideoId: String? = nil,
        lastLessonTitle: String? = nil,
        totalDurationSeconds: Int = 0,
        weeklyGoal: Int? = nil
    ) {
        self.playlistId = playlistId
        self.title = title
        self.channelName = channelName
        self.thumbnailURLString = thumbnailURL?.absoluteString
        self.lessonThumbnailURLStrings = lessonThumbnailURLs.prefix(6).map(\.absoluteString)
        self.lessonCount = lessonCount
        self.completedCount = completedCount
        self.folderId = folderId
        self.lastOpenedAt = lastOpenedAt
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.lastLessonVideoId = lastLessonVideoId
        self.lastLessonTitle = lastLessonTitle
        self.totalDurationSeconds = totalDurationSeconds
        self.weeklyGoal = weeklyGoal
    }
}

// MARK: - Progress status / filters

enum YouTubeCourseProgressStatus: String, CaseIterable, Identifiable, Sendable {
    case notStarted
    case inProgress
    case completed

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .notStarted: String(localized: "Not started")
        case .inProgress: String(localized: "In progress")
        case .completed: String(localized: "Completed")
        }
    }
}

enum YouTubeCourseLibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case inProgress
    case completed
    case notStarted
    case pinned

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .all: String(localized: "All")
        case .inProgress: String(localized: "In Progress")
        case .completed: String(localized: "Completed")
        case .notStarted: String(localized: "Not Started")
        case .pinned: String(localized: "Pinned")
        }
    }
}

enum YouTubeCourseLibrarySort: String, CaseIterable, Identifiable, Sendable {
    case recent
    case progress
    case title
    case duration

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .recent: String(localized: "Recent")
        case .progress: String(localized: "Progress")
        case .title: String(localized: "A–Z")
        case .duration: String(localized: "Duration")
        }
    }
}

// MARK: - Lesson note

struct YouTubeCourseLessonNote: Identifiable, Codable, Hashable, Sendable {
    var id: String { self.videoId }
    var videoId: String
    var text: String
    var updatedAt: Date

    init(videoId: String, text: String, updatedAt: Date = Date()) {
        self.videoId = videoId
        self.text = text
        self.updatedAt = updatedAt
    }
}

// MARK: - Resume position

struct YouTubeCourseResumePosition: Codable, Hashable, Sendable {
    var videoId: String
    var seconds: Double
    var updatedAt: Date
}

// MARK: - Library snapshot

/// Codable root document for the courses library on disk.
struct YouTubeCourseLibrarySnapshot: Codable, Sendable {
    var folders: [YouTubeCourseFolder]
    var courses: [YouTubeCourseCatalogEntry]
    /// playlistId → videoId → note
    var notesByPlaylist: [String: [String: YouTubeCourseLessonNote]]
    /// playlistId → resume
    var resumeByPlaylist: [String: YouTubeCourseResumePosition]
    /// ISO day keys (yyyy-MM-dd) → lessons completed that day
    var completionHistory: [String: Int]

    static let empty = YouTubeCourseLibrarySnapshot(
        folders: [],
        courses: [],
        notesByPlaylist: [:],
        resumeByPlaylist: [:],
        completionHistory: [:]
    )

    init(
        folders: [YouTubeCourseFolder],
        courses: [YouTubeCourseCatalogEntry],
        notesByPlaylist: [String: [String: YouTubeCourseLessonNote]] = [:],
        resumeByPlaylist: [String: YouTubeCourseResumePosition] = [:],
        completionHistory: [String: Int] = [:]
    ) {
        self.folders = folders
        self.courses = courses
        self.notesByPlaylist = notesByPlaylist
        self.resumeByPlaylist = resumeByPlaylist
        self.completionHistory = completionHistory
    }

    // Backward-compatible decode for older library blobs.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.folders = try container.decodeIfPresent([YouTubeCourseFolder].self, forKey: .folders) ?? []
        self.courses = try container.decodeIfPresent([YouTubeCourseCatalogEntry].self, forKey: .courses) ?? []
        self.notesByPlaylist = try container.decodeIfPresent(
            [String: [String: YouTubeCourseLessonNote]].self,
            forKey: .notesByPlaylist
        ) ?? [:]
        self.resumeByPlaylist = try container.decodeIfPresent(
            [String: YouTubeCourseResumePosition].self,
            forKey: .resumeByPlaylist
        ) ?? [:]
        self.completionHistory = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .completionHistory
        ) ?? [:]
    }
}

// MARK: - Duration helpers

enum YouTubeCourseDuration {
    /// Parses YouTube display lengths like "12:34", "1:02:03".
    static func seconds(from lengthText: String?) -> Int {
        guard let lengthText, !lengthText.isEmpty else { return 0 }
        let parts = lengthText.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { return 0 }
        if parts.count == 1 { return parts[0] }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        if parts.count >= 3 {
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
        }
        return 0
    }

    static func totalSeconds(in lessons: [YouTubeVideo]) -> Int {
        lessons.reduce(0) { $0 + self.seconds(from: $1.lengthText) }
    }

    static func format(seconds: Int) -> String {
        guard seconds > 0 else { return "—" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 {
            return String(localized: "\(h)h \(m)m")
        }
        return String(localized: "\(m) min")
    }
}

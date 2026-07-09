import Foundation
import Observation

// MARK: - YouTubeCourseSession

/// Active “course mode” while watching a YouTube playlist as a learning path.
///
/// Start it by opening any playlist and playing a video from it. The watch
/// page then shows a course sidebar: completed lessons, the current topic,
/// and what’s next — with progress persisted per playlist.
@MainActor
@Observable
final class YouTubeCourseSession {
    static let shared = YouTubeCourseSession()

    // MARK: - Active course

    /// Whether a playlist is currently being taken as a course.
    private(set) var isActive = false

    private(set) var playlistId: String?
    private(set) var playlistTitle: String = ""
    private(set) var playlistChannelName: String?
    private(set) var lessons: [YouTubeVideo] = []

    /// Index of the lesson currently being watched (if it is in the course).
    private(set) var currentIndex: Int?

    /// Video IDs marked complete for the active playlist (this session + disk).
    private(set) var completedVideoIds: Set<String> = []

    /// Whether the course sidebar should be visible in the watch layout.
    var isSidebarVisible = true

    private let defaults = UserDefaults.standard
    private let logger = DiagnosticsLogger.player

    private init() {}

    // MARK: - Derived

    var lessonCount: Int {
        self.lessons.count
    }

    var completedCount: Int {
        self.lessons.filter { self.completedVideoIds.contains($0.videoId) }.count
    }

    var progressFraction: Double {
        guard self.lessonCount > 0 else { return 0 }
        return Double(self.completedCount) / Double(self.lessonCount)
    }

    var currentLesson: YouTubeVideo? {
        guard let currentIndex, self.lessons.indices.contains(currentIndex) else {
            return nil
        }
        return self.lessons[currentIndex]
    }

    var nextLesson: YouTubeVideo? {
        guard let currentIndex else { return self.lessons.first }
        let next = currentIndex + 1
        guard self.lessons.indices.contains(next) else { return nil }
        return self.lessons[next]
    }

    var previousLesson: YouTubeVideo? {
        guard let currentIndex, currentIndex > 0 else { return nil }
        return self.lessons[currentIndex - 1]
    }

    /// Remaining lessons after the current one (for player up-next).
    var remainingLessons: [YouTubeVideo] {
        guard let currentIndex else { return self.lessons }
        let start = currentIndex + 1
        guard start < self.lessons.count else { return [] }
        return Array(self.lessons[start...])
    }

    func isCompleted(_ videoId: String) -> Bool {
        self.completedVideoIds.contains(videoId)
    }

    func isCurrent(_ videoId: String) -> Bool {
        self.currentLesson?.videoId == videoId
    }

    func index(of videoId: String) -> Int? {
        self.lessons.firstIndex { $0.videoId == videoId }
    }

    // MARK: - Lifecycle

    /// Begins course mode from a playlist detail, focusing the given video.
    func start(
        playlist: YouTubePlaylist,
        lessons: [YouTubeVideo],
        startingAt video: YouTubeVideo
    ) {
        let ordered = lessons.filter { !$0.isShort && !$0.videoId.isEmpty }
        guard !ordered.isEmpty else {
            self.logger.warning("Course: cannot start — playlist has no usable videos")
            return
        }

        self.playlistId = playlist.playlistId
        self.playlistTitle = playlist.title
        self.playlistChannelName = playlist.channelName
        self.lessons = ordered
        self.completedVideoIds = Self.loadCompleted(playlistId: playlist.playlistId)
        self.currentIndex = ordered.firstIndex { $0.videoId == video.videoId } ?? 0
        self.isActive = true
        self.isSidebarVisible = true
        // Register / refresh in the Courses library (sidebar catalog).
        YouTubeCourseLibrary.shared.registerOrUpdateCourse(
            playlist: playlist,
            lessons: ordered,
            completedCount: self.completedCount,
            lastLesson: video
        )
        self.logger.info(
            "Course started: \(playlist.playlistId, privacy: .public) (\(ordered.count) lessons)"
        )
    }

    /// Updates the current lesson when the player is on a course video.
    /// Returns whether the video belongs to the active course.
    @discardableResult
    func syncCurrent(to video: YouTubeVideo) -> Bool {
        guard self.isActive else { return false }
        guard let index = self.index(of: video.videoId) else { return false }
        self.currentIndex = index
        if let playlistId {
            YouTubeCourseLibrary.shared.updateLastLesson(playlistId: playlistId, video: video)
        }
        return true
    }

    // MARK: - Notes / resume (delegates to library)

    func note(for videoId: String) -> String {
        guard let playlistId else { return "" }
        return YouTubeCourseLibrary.shared.note(playlistId: playlistId, videoId: videoId)
    }

    func setNote(for videoId: String, text: String) {
        guard let playlistId else { return }
        YouTubeCourseLibrary.shared.setNote(playlistId: playlistId, videoId: videoId, text: text)
    }

    func hasNote(for videoId: String) -> Bool {
        guard let playlistId else { return false }
        return YouTubeCourseLibrary.shared.hasNote(playlistId: playlistId, videoId: videoId)
    }

    func saveResume(videoId: String, seconds: Double) {
        guard let playlistId else { return }
        YouTubeCourseLibrary.shared.saveResume(
            playlistId: playlistId,
            videoId: videoId,
            seconds: seconds
        )
    }

    func resumeSeconds(for videoId: String) -> Double? {
        guard let playlistId,
              let resume = YouTubeCourseLibrary.shared.resumePosition(playlistId: playlistId),
              resume.videoId == videoId
        else { return nil }
        return resume.seconds
    }

    /// Marks a lesson complete (when the user finishes watching it).
    func markCompleted(videoId: String?) {
        guard self.isActive, let videoId, !videoId.isEmpty else { return }
        guard self.lessons.contains(where: { $0.videoId == videoId }) else { return }
        guard !self.completedVideoIds.contains(videoId) else { return }
        self.completedVideoIds.insert(videoId)
        if let playlistId {
            Self.saveCompleted(self.completedVideoIds, playlistId: playlistId)
            YouTubeCourseLibrary.shared.updateProgress(
                playlistId: playlistId,
                completedCount: self.completedCount,
                lessonCount: self.lessonCount
            )
        }
        self.logger.info("Course lesson completed: \(videoId, privacy: .public)")
    }

    /// Marks complete by index (e.g. user toggles from the sidebar).
    func toggleCompleted(videoId: String) {
        guard self.isActive else { return }
        guard self.lessons.contains(where: { $0.videoId == videoId }) else { return }
        if self.completedVideoIds.contains(videoId) {
            self.completedVideoIds.remove(videoId)
        } else {
            self.completedVideoIds.insert(videoId)
        }
        if let playlistId {
            Self.saveCompleted(self.completedVideoIds, playlistId: playlistId)
            YouTubeCourseLibrary.shared.updateProgress(
                playlistId: playlistId,
                completedCount: self.completedCount,
                lessonCount: self.lessonCount
            )
        }
    }

    /// Leaves course mode (sidebar goes away; progress stays on disk).
    func endCourse() {
        self.isActive = false
        self.playlistId = nil
        self.playlistTitle = ""
        self.playlistChannelName = nil
        self.lessons = []
        self.currentIndex = nil
        self.completedVideoIds = []
        self.isSidebarVisible = true
        self.logger.info("Course ended")
    }

    // MARK: - Persistence

    private static func storageKey(playlistId: String) -> String {
        "youtube.course.completed.\(playlistId)"
    }

    private static func loadCompleted(playlistId: String) -> Set<String> {
        let key = Self.storageKey(playlistId: playlistId)
        if let array = UserDefaults.standard.array(forKey: key) as? [String] {
            return Set(array)
        }
        return []
    }

    private static func saveCompleted(_ ids: Set<String>, playlistId: String) {
        UserDefaults.standard.set(Array(ids), forKey: Self.storageKey(playlistId: playlistId))
    }
}

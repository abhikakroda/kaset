import Foundation
import Observation

// MARK: - YouTubeCourseLibrary

/// Persistent library of courses organized into nested folders, with notes,
/// resume positions, pins, and simple study stats.
@MainActor
@Observable
final class YouTubeCourseLibrary {
    static let shared = YouTubeCourseLibrary()

    private(set) var folders: [YouTubeCourseFolder] = []
    private(set) var courses: [YouTubeCourseCatalogEntry] = []
    private(set) var notesByPlaylist: [String: [String: YouTubeCourseLessonNote]] = [:]
    private(set) var resumeByPlaylist: [String: YouTubeCourseResumePosition] = [:]
    private(set) var completionHistory: [String: Int] = [:]

    private let storageKey = "youtube.course.library.v2"
    private let legacyStorageKey = "youtube.course.library.v1"
    private let logger = DiagnosticsLogger.player

    private init() {
        self.load()
    }

    // MARK: - Queries

    func folders(in parentId: String?) -> [YouTubeCourseFolder] {
        self.folders
            .filter { $0.parentId == parentId }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    func courses(
        in folderId: String?,
        filter: YouTubeCourseLibraryFilter = .all,
        sort: YouTubeCourseLibrarySort = .recent,
        search: String = ""
    ) -> [YouTubeCourseCatalogEntry] {
        var list = self.courses.filter { $0.folderId == folderId }

        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || ($0.channelName?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }

        switch filter {
        case .all:
            break
        case .inProgress:
            list = list.filter { $0.status == .inProgress }
        case .completed:
            list = list.filter { $0.status == .completed }
        case .notStarted:
            list = list.filter { $0.status == .notStarted }
        case .pinned:
            list = list.filter(\.isPinned)
        }

        list.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            switch sort {
            case .recent:
                return lhs.lastOpenedAt > rhs.lastOpenedAt
            case .progress:
                return lhs.progressFraction > rhs.progressFraction
            case .title:
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            case .duration:
                return lhs.totalDurationSeconds > rhs.totalDurationSeconds
            }
        }
        return list
    }

    func folder(id: String) -> YouTubeCourseFolder? {
        self.folders.first { $0.id == id }
    }

    func course(playlistId: String) -> YouTubeCourseCatalogEntry? {
        self.courses.first { $0.playlistId == playlistId }
    }

    /// Best course to resume (pinned incomplete, else most recent incomplete).
    var continueLearningCourse: YouTubeCourseCatalogEntry? {
        let incomplete = self.courses.filter { $0.status != .completed }
        return incomplete.first(where: \.isPinned)
            ?? incomplete.sorted { $0.lastOpenedAt > $1.lastOpenedAt }.first
    }

    /// Breadcrumb path from root → folder (inclusive).
    func path(to folderId: String?) -> [YouTubeCourseFolder] {
        guard let folderId else { return [] }
        var path: [YouTubeCourseFolder] = []
        var current = self.folder(id: folderId)
        var guardCount = 0
        while let folder = current, guardCount < 32 {
            path.insert(folder, at: 0)
            current = folder.parentId.flatMap { self.folder(id: $0) }
            guardCount += 1
        }
        return path
    }

    var isEmpty: Bool {
        self.courses.isEmpty && self.folders.isEmpty
    }

    var totalCourses: Int { self.courses.count }
    var completedCourses: Int { self.courses.filter { $0.status == .completed }.count }
    var inProgressCourses: Int { self.courses.filter { $0.status == .inProgress }.count }

    var lessonsCompletedThisWeek: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let weekAgo = calendar.date(byAdding: .day, value: -6, to: today) else { return 0 }
        let formatter = Self.dayFormatter
        return self.completionHistory.reduce(into: 0) { sum, pair in
            guard let day = formatter.date(from: pair.key), day >= weekAgo else { return }
            sum += pair.value
        }
    }

    // MARK: - Folder mutations

    @discardableResult
    func createFolder(name: String, parentId: String? = nil) -> YouTubeCourseFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = YouTubeCourseFolder(
            name: trimmed.isEmpty ? String(localized: "New Folder") : trimmed,
            parentId: parentId
        )
        self.folders.append(folder)
        self.persist()
        return folder
    }

    func renameFolder(id: String, name: String) {
        guard let index = self.folders.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.folders[index].name = trimmed
        self.persist()
    }

    func deleteFolder(id: String) {
        let parentId = self.folder(id: id)?.parentId
        for index in self.folders.indices where self.folders[index].parentId == id {
            self.folders[index].parentId = parentId
        }
        for index in self.courses.indices where self.courses[index].folderId == id {
            self.courses[index].folderId = parentId
        }
        self.folders.removeAll { $0.id == id }
        self.persist()
    }

    func moveCourse(playlistId: String, toFolderId folderId: String?) {
        guard let index = self.courses.firstIndex(where: { $0.playlistId == playlistId }) else {
            return
        }
        self.courses[index].folderId = folderId
        self.persist()
    }

    func moveFolder(id: String, toParentId parentId: String?) {
        guard let index = self.folders.firstIndex(where: { $0.id == id }) else { return }
        if let parentId {
            if parentId == id { return }
            if self.descendantFolderIds(of: id).contains(parentId) { return }
        }
        self.folders[index].parentId = parentId
        self.persist()
    }

    func removeCourse(playlistId: String) {
        self.courses.removeAll { $0.playlistId == playlistId }
        self.notesByPlaylist[playlistId] = nil
        self.resumeByPlaylist[playlistId] = nil
        self.persist()
    }

    func togglePin(playlistId: String) {
        guard let index = self.courses.firstIndex(where: { $0.playlistId == playlistId }) else {
            return
        }
        self.courses[index].isPinned.toggle()
        self.persist()
    }

    func setWeeklyGoal(playlistId: String, goal: Int?) {
        guard let index = self.courses.firstIndex(where: { $0.playlistId == playlistId }) else {
            return
        }
        self.courses[index].weeklyGoal = goal.flatMap { $0 > 0 ? $0 : nil }
        self.persist()
    }

    func resetProgress(playlistId: String) {
        UserDefaults.standard.removeObject(forKey: "youtube.course.completed.\(playlistId)")
        if let index = self.courses.firstIndex(where: { $0.playlistId == playlistId }) {
            self.courses[index].completedCount = 0
            self.courses[index].lastLessonVideoId = nil
            self.courses[index].lastLessonTitle = nil
        }
        self.resumeByPlaylist[playlistId] = nil
        self.persist()
    }

    // MARK: - Course registration / progress

    func registerOrUpdateCourse(
        playlist: YouTubePlaylist,
        lessons: [YouTubeVideo],
        completedCount: Int,
        lastLesson: YouTubeVideo? = nil
    ) {
        let usable = lessons.filter { !$0.isShort }
        let thumbs = usable.compactMap(\.thumbnailURL)
        let primary = playlist.thumbnailURL ?? thumbs.first
        let lessonThumbs = Array(thumbs.prefix(6))
        let duration = YouTubeCourseDuration.totalSeconds(in: usable)

        if let index = self.courses.firstIndex(where: { $0.playlistId == playlist.playlistId }) {
            self.courses[index].title = playlist.title
            self.courses[index].channelName = playlist.channelName
            if let primary {
                self.courses[index].thumbnailURLString = primary.absoluteString
            }
            if !lessonThumbs.isEmpty {
                self.courses[index].lessonThumbnailURLStrings = lessonThumbs.map(\.absoluteString)
            }
            self.courses[index].lessonCount = usable.count
            self.courses[index].completedCount = completedCount
            self.courses[index].totalDurationSeconds = duration
            self.courses[index].lastOpenedAt = Date()
            if let lastLesson {
                self.courses[index].lastLessonVideoId = lastLesson.videoId
                self.courses[index].lastLessonTitle = lastLesson.title
            }
        } else {
            var entry = YouTubeCourseCatalogEntry(
                playlistId: playlist.playlistId,
                title: playlist.title,
                channelName: playlist.channelName,
                thumbnailURL: primary,
                lessonThumbnailURLs: lessonThumbs,
                lessonCount: usable.count,
                completedCount: completedCount,
                totalDurationSeconds: duration
            )
            if let lastLesson {
                entry.lastLessonVideoId = lastLesson.videoId
                entry.lastLessonTitle = lastLesson.title
            }
            self.courses.insert(entry, at: 0)
        }
        self.persist()
    }

    func updateProgress(playlistId: String, completedCount: Int, lessonCount: Int? = nil) {
        guard let index = self.courses.firstIndex(where: { $0.playlistId == playlistId }) else {
            return
        }
        let previous = self.courses[index].completedCount
        self.courses[index].completedCount = completedCount
        if let lessonCount {
            self.courses[index].lessonCount = lessonCount
        }
        self.courses[index].lastOpenedAt = Date()
        if completedCount > previous {
            self.recordCompletion(count: completedCount - previous)
        }
        self.persist()
    }

    func updateLastLesson(playlistId: String, video: YouTubeVideo) {
        guard let index = self.courses.firstIndex(where: { $0.playlistId == playlistId }) else {
            return
        }
        self.courses[index].lastLessonVideoId = video.videoId
        self.courses[index].lastLessonTitle = video.title
        self.courses[index].lastOpenedAt = Date()
        self.persist()
    }

    // MARK: - Notes

    func note(playlistId: String, videoId: String) -> String {
        self.notesByPlaylist[playlistId]?[videoId]?.text ?? ""
    }

    func setNote(playlistId: String, videoId: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var map = self.notesByPlaylist[playlistId] ?? [:]
        if trimmed.isEmpty {
            map[videoId] = nil
        } else {
            map[videoId] = YouTubeCourseLessonNote(videoId: videoId, text: trimmed)
        }
        if map.isEmpty {
            self.notesByPlaylist[playlistId] = nil
        } else {
            self.notesByPlaylist[playlistId] = map
        }
        self.persist()
    }

    func hasNote(playlistId: String, videoId: String) -> Bool {
        !(self.notesByPlaylist[playlistId]?[videoId]?.text.isEmpty ?? true)
    }

    func noteCount(playlistId: String) -> Int {
        self.notesByPlaylist[playlistId]?.values.filter { !$0.text.isEmpty }.count ?? 0
    }

    // MARK: - Resume positions

    func resumePosition(playlistId: String) -> YouTubeCourseResumePosition? {
        self.resumeByPlaylist[playlistId]
    }

    func saveResume(playlistId: String, videoId: String, seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        // Don't store tiny positions as "resume".
        guard seconds >= 5 else { return }
        self.resumeByPlaylist[playlistId] = YouTubeCourseResumePosition(
            videoId: videoId,
            seconds: seconds,
            updatedAt: Date()
        )
        self.persist()
    }

    func clearResume(playlistId: String) {
        self.resumeByPlaylist[playlistId] = nil
        self.persist()
    }

    // MARK: - Stats

    private func recordCompletion(count: Int) {
        let key = Self.dayFormatter.string(from: Date())
        self.completionHistory[key, default: 0] += max(0, count)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - Helpers

    private func descendantFolderIds(of folderId: String) -> Set<String> {
        var result: Set<String> = []
        var queue = [folderId]
        while let current = queue.popLast() {
            let children = self.folders.filter { $0.parentId == current }.map(\.id)
            for child in children where !result.contains(child) {
                result.insert(child)
                queue.append(child)
            }
        }
        return result
    }

    // MARK: - Persistence

    private func load() {
        let data = UserDefaults.standard.data(forKey: self.storageKey)
            ?? UserDefaults.standard.data(forKey: self.legacyStorageKey)
        guard let data else { return }
        do {
            let snapshot = try JSONDecoder().decode(YouTubeCourseLibrarySnapshot.self, from: data)
            self.folders = snapshot.folders
            self.courses = snapshot.courses
            self.notesByPlaylist = snapshot.notesByPlaylist
            self.resumeByPlaylist = snapshot.resumeByPlaylist
            self.completionHistory = snapshot.completionHistory
        } catch {
            self.logger.error("Failed to load course library: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist() {
        let snapshot = YouTubeCourseLibrarySnapshot(
            folders: self.folders,
            courses: self.courses,
            notesByPlaylist: self.notesByPlaylist,
            resumeByPlaylist: self.resumeByPlaylist,
            completionHistory: self.completionHistory
        )
        do {
            let data = try JSONEncoder().encode(snapshot)
            UserDefaults.standard.set(data, forKey: self.storageKey)
        } catch {
            self.logger.error("Failed to save course library: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Catalog entry Codable (defaults for new fields)

extension YouTubeCourseCatalogEntry {
    enum CodingKeys: String, CodingKey {
        case playlistId, title, channelName, thumbnailURLString
        case lessonThumbnailURLStrings, lessonCount, completedCount
        case folderId, lastOpenedAt, createdAt
        case isPinned, lastLessonVideoId, lastLessonTitle
        case totalDurationSeconds, weeklyGoal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.playlistId = try c.decode(String.self, forKey: .playlistId)
        self.title = try c.decode(String.self, forKey: .title)
        self.channelName = try c.decodeIfPresent(String.self, forKey: .channelName)
        self.thumbnailURLString = try c.decodeIfPresent(String.self, forKey: .thumbnailURLString)
        self.lessonThumbnailURLStrings = try c.decodeIfPresent([String].self, forKey: .lessonThumbnailURLStrings) ?? []
        self.lessonCount = try c.decodeIfPresent(Int.self, forKey: .lessonCount) ?? 0
        self.completedCount = try c.decodeIfPresent(Int.self, forKey: .completedCount) ?? 0
        self.folderId = try c.decodeIfPresent(String.self, forKey: .folderId)
        self.lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt) ?? Date()
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        self.lastLessonVideoId = try c.decodeIfPresent(String.self, forKey: .lastLessonVideoId)
        self.lastLessonTitle = try c.decodeIfPresent(String.self, forKey: .lastLessonTitle)
        self.totalDurationSeconds = try c.decodeIfPresent(Int.self, forKey: .totalDurationSeconds) ?? 0
        self.weeklyGoal = try c.decodeIfPresent(Int.self, forKey: .weeklyGoal)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.playlistId, forKey: .playlistId)
        try c.encode(self.title, forKey: .title)
        try c.encodeIfPresent(self.channelName, forKey: .channelName)
        try c.encodeIfPresent(self.thumbnailURLString, forKey: .thumbnailURLString)
        try c.encode(self.lessonThumbnailURLStrings, forKey: .lessonThumbnailURLStrings)
        try c.encode(self.lessonCount, forKey: .lessonCount)
        try c.encode(self.completedCount, forKey: .completedCount)
        try c.encodeIfPresent(self.folderId, forKey: .folderId)
        try c.encode(self.lastOpenedAt, forKey: .lastOpenedAt)
        try c.encode(self.createdAt, forKey: .createdAt)
        try c.encode(self.isPinned, forKey: .isPinned)
        try c.encodeIfPresent(self.lastLessonVideoId, forKey: .lastLessonVideoId)
        try c.encodeIfPresent(self.lastLessonTitle, forKey: .lastLessonTitle)
        try c.encode(self.totalDurationSeconds, forKey: .totalDurationSeconds)
        try c.encodeIfPresent(self.weeklyGoal, forKey: .weeklyGoal)
    }
}

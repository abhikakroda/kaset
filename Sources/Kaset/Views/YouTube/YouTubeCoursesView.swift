import SwiftUI

// MARK: - YouTubeCoursesView

/// Courses library: nested folders, search/filter/sort, continue learning,
/// pins, progress, and course cards with video thumbnails.
struct YouTubeCoursesView: View {
    private static let brandAccent = PackageResourceLookup.brandAccent
    private static let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 16),
    ]

    @State private var library = YouTubeCourseLibrary.shared
    @State private var currentFolderId: String?
    @State private var searchText = ""
    @State private var filter: YouTubeCourseLibraryFilter = .all
    @State private var sort: YouTubeCourseLibrarySort = .recent
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var renameTarget: YouTubeCourseFolder?
    @State private var renameText = ""
    @State private var moveCourseTarget: YouTubeCourseCatalogEntry?
    @State private var showMoveSheet = false
    @State private var goalTarget: YouTubeCourseCatalogEntry?
    @State private var goalText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.headerStack
            Divider().opacity(0.35)
            self.browser
        }
        .navigationTitle(Text("Courses", comment: "Courses library title"))
        .searchable(text: self.$searchText, prompt: String(localized: "Search courses"))
        .alert(String(localized: "New Folder"), isPresented: self.$showNewFolderAlert) {
            TextField(String(localized: "Folder name"), text: self.$newFolderName)
            Button(String(localized: "Cancel"), role: .cancel) { self.newFolderName = "" }
            Button(String(localized: "Create")) {
                _ = self.library.createFolder(name: self.newFolderName, parentId: self.currentFolderId)
                self.newFolderName = ""
            }
        }
        .alert(
            String(localized: "Rename Folder"),
            isPresented: Binding(
                get: { self.renameTarget != nil },
                set: { if !$0 { self.renameTarget = nil } }
            )
        ) {
            TextField(String(localized: "Folder name"), text: self.$renameText)
            Button(String(localized: "Cancel"), role: .cancel) { self.renameTarget = nil }
            Button(String(localized: "Rename")) {
                if let id = self.renameTarget?.id {
                    self.library.renameFolder(id: id, name: self.renameText)
                }
                self.renameTarget = nil
            }
        }
        .alert(
            String(localized: "Weekly goal"),
            isPresented: Binding(
                get: { self.goalTarget != nil },
                set: { if !$0 { self.goalTarget = nil } }
            )
        ) {
            TextField(String(localized: "Lessons per week"), text: self.$goalText)
            Button(String(localized: "Cancel"), role: .cancel) { self.goalTarget = nil }
            Button(String(localized: "Save")) {
                if let id = self.goalTarget?.playlistId {
                    self.library.setWeeklyGoal(playlistId: id, goal: Int(self.goalText))
                }
                self.goalTarget = nil
            }
        } message: {
            Text("How many lessons do you want to finish each week?", comment: "Weekly goal prompt")
        }
        .sheet(isPresented: self.$showMoveSheet) {
            if let course = self.moveCourseTarget {
                CourseMoveFolderSheet(
                    course: course,
                    folders: self.library.folders,
                    onPick: { folderId in
                        self.library.moveCourse(playlistId: course.playlistId, toFolderId: folderId)
                        self.showMoveSheet = false
                        self.moveCourseTarget = nil
                    },
                    onCancel: {
                        self.showMoveSheet = false
                        self.moveCourseTarget = nil
                    }
                )
            }
        }
    }

    // MARK: - Header

    private var headerStack: some View {
        VStack(alignment: .leading, spacing: 12) {
            if self.currentFolderId == nil {
                self.statsRow
                if let continueCourse = self.library.continueLearningCourse, self.searchText.isEmpty {
                    self.continueCard(continueCourse)
                }
            }
            self.toolbar
            self.filterSortRow
        }
        .padding(.horizontal, DetailContentLayout.horizontalInset)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            CourseStatChip(
                title: String(localized: "Courses"),
                value: "\(self.library.totalCourses)",
                systemImage: "square.stack.3d.up.fill"
            )
            CourseStatChip(
                title: String(localized: "In progress"),
                value: "\(self.library.inProgressCourses)",
                systemImage: "play.circle.fill"
            )
            CourseStatChip(
                title: String(localized: "Done"),
                value: "\(self.library.completedCourses)",
                systemImage: "checkmark.seal.fill"
            )
            CourseStatChip(
                title: String(localized: "This week"),
                value: "\(self.library.lessonsCompletedThisWeek)",
                systemImage: "flame.fill"
            )
            Spacer(minLength: 0)
        }
    }

    private func continueCard(_ course: YouTubeCourseCatalogEntry) -> some View {
        NavigationLink(value: YouTubeRoute.playlist(playlistId: course.playlistId)) {
            HStack(spacing: 14) {
                CachedAsyncImage(
                    url: course.thumbnailURL ?? course.lessonThumbnailURLs.first,
                    targetSize: CGSize(width: 240, height: 135)
                ) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.quaternary)
                }
                .frame(width: 120, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Continue learning", comment: "Continue course hero")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Self.brandAccent)
                    Text(course.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                    if let last = course.lastLessonTitle {
                        Text(String(localized: "Resume: \(last)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    ProgressView(value: course.progressFraction)
                        .tint(Self.brandAccent)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Self.brandAccent)
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            self.breadcrumbs
            Spacer()
            Button {
                self.newFolderName = ""
                self.showNewFolderAlert = true
            } label: {
                Label(String(localized: "New Folder"), systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var breadcrumbs: some View {
        HStack(spacing: 6) {
            Button {
                self.currentFolderId = nil
            } label: {
                Label(String(localized: "All Courses"), systemImage: "square.stack.3d.up.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.currentFolderId == nil ? Self.brandAccent : .primary)
            .font(.subheadline.weight(.semibold))

            ForEach(self.library.path(to: self.currentFolderId)) { folder in
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                Button {
                    self.currentFolderId = folder.id
                } label: {
                    Text(folder.name)
                }
                .buttonStyle(.plain)
                .font(.subheadline.weight(folder.id == self.currentFolderId ? .semibold : .regular))
                .foregroundStyle(folder.id == self.currentFolderId ? Self.brandAccent : .primary)
            }
        }
    }

    private var filterSortRow: some View {
        HStack(spacing: 10) {
            Picker(String(localized: "Filter"), selection: self.$filter) {
                ForEach(YouTubeCourseLibraryFilter.allCases) { item in
                    Text(item.displayName).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)

            Spacer()

            Picker(String(localized: "Sort"), selection: self.$sort) {
                ForEach(YouTubeCourseLibrarySort.allCases) { item in
                    Text(item.displayName).tag(item)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 130)
        }
    }

    // MARK: - Browser

    @ViewBuilder
    private var browser: some View {
        let folders = self.searchText.isEmpty ? self.library.folders(in: self.currentFolderId) : []
        let courses = self.library.courses(
            in: self.currentFolderId,
            filter: self.filter,
            sort: self.sort,
            search: self.searchText
        )

        if folders.isEmpty, courses.isEmpty {
            ContentUnavailableView {
                Label(
                    self.library.isEmpty
                        ? String(localized: "No courses yet")
                        : String(localized: "No matching courses"),
                    systemImage: "list.bullet.rectangle.portrait"
                )
            } description: {
                Text(
                    self.library.isEmpty
                        ? "Open any YouTube playlist and choose “Play as Course”. Organize courses into folders, pin favorites, take notes, and track weekly goals."
                        : "Try another filter or search term.",
                    comment: "Courses empty / no results"
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: Self.columns, spacing: 18) {
                    ForEach(folders) { folder in
                        CourseFolderCard(
                            folder: folder,
                            courseCount: self.library.courses(in: folder.id).count,
                            subfolderCount: self.library.folders(in: folder.id).count
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                self.currentFolderId = folder.id
                            }
                        }
                        .contextMenu {
                            Button(String(localized: "Rename…")) {
                                self.renameTarget = folder
                                self.renameText = folder.name
                            }
                            Button(String(localized: "Delete Folder"), role: .destructive) {
                                if self.currentFolderId == folder.id {
                                    self.currentFolderId = folder.parentId
                                }
                                self.library.deleteFolder(id: folder.id)
                            }
                        }
                    }

                    ForEach(courses) { course in
                        NavigationLink(value: YouTubeRoute.playlist(playlistId: course.playlistId)) {
                            CourseCatalogCard(course: course)
                        }
                        .buttonStyle(.interactiveCard)
                        .contextMenu {
                            Button {
                                self.library.togglePin(playlistId: course.playlistId)
                            } label: {
                                Label(
                                    course.isPinned
                                        ? String(localized: "Unpin")
                                        : String(localized: "Pin"),
                                    systemImage: course.isPinned ? "pin.slash" : "pin"
                                )
                            }
                            Button(String(localized: "Move to Folder…")) {
                                self.moveCourseTarget = course
                                self.showMoveSheet = true
                            }
                            Button(String(localized: "Weekly goal…")) {
                                self.goalTarget = course
                                self.goalText = course.weeklyGoal.map(String.init) ?? "5"
                            }
                            Button(String(localized: "Reset progress"), role: .destructive) {
                                self.library.resetProgress(playlistId: course.playlistId)
                            }
                            Button(String(localized: "Remove from Courses"), role: .destructive) {
                                self.library.removeCourse(playlistId: course.playlistId)
                            }
                        }
                    }
                }
                .padding(.vertical, 20)
            }
            .contentMargins(.horizontal, DetailContentLayout.horizontalInset, for: .scrollContent)
        }
    }
}

// MARK: - Stat chip

private struct CourseStatChip: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: self.systemImage)
                .foregroundStyle(PackageResourceLookup.brandAccent)
            VStack(alignment: .leading, spacing: 0) {
                Text(self.value)
                    .font(.system(size: 14, weight: .bold).monospacedDigit())
                Text(self.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Folder card

private struct CourseFolderCard: View {
    let folder: YouTubeCourseFolder
    let courseCount: Int
    let subfolderCount: Int
    let onOpen: () -> Void

    var body: some View {
        Button(action: self.onOpen) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.quaternary.opacity(0.55))
                        .aspectRatio(16 / 10, contentMode: .fit)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(.yellow.opacity(0.9))
                        .symbolRenderingMode(.hierarchical)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(self.folder.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Text(self.metaLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.courseFolderCard)
    }

    private var metaLabel: String {
        var parts: [String] = []
        if self.subfolderCount > 0 {
            parts.append(String(localized: "\(self.subfolderCount) folders"))
        }
        parts.append(String(localized: "\(self.courseCount) courses"))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Course card

private struct CourseCatalogCard: View {
    private static let brandAccent = PackageResourceLookup.brandAccent
    let course: YouTubeCourseCatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                self.thumbnailCollage
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                if self.course.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2.weight(.bold))
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(8)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(self.course.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)

                if let channel = self.course.channelName, !channel.isEmpty {
                    Text(channel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(self.course.status.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(self.statusColor)
                    if self.course.totalDurationSeconds > 0 {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(YouTubeCourseDuration.format(seconds: self.course.totalDurationSeconds))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let goal = self.course.weeklyGoal {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(String(localized: "Goal \(goal)/wk"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Text(
                        String(localized: "\(self.course.completedCount)/\(self.course.lessonCount)")
                    )
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.primary.opacity(0.08))
                            Capsule()
                                .fill(Self.brandAccent)
                                .frame(width: max(3, geo.size.width * self.course.progressFraction))
                        }
                    }
                    .frame(height: 4)

                    Text("\(Int((self.course.progressFraction * 100).rounded()))%")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(Self.brandAccent)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.courseCatalogCard)
    }

    private var statusColor: Color {
        switch self.course.status {
        case .completed: .green
        case .inProgress: Self.brandAccent
        case .notStarted: .secondary
        }
    }

    @ViewBuilder
    private var thumbnailCollage: some View {
        let urls = self.course.lessonThumbnailURLs
        if urls.count >= 4 {
            let grid = Array(urls.prefix(4))
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)],
                spacing: 2
            ) {
                ForEach(Array(grid.enumerated()), id: \.offset) { _, url in
                    CachedAsyncImage(url: url, targetSize: CGSize(width: 320, height: 180)) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(.quaternary)
                    }
                    .frame(minHeight: 54)
                    .clipped()
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
        } else if let url = self.course.thumbnailURL ?? urls.first {
            CachedAsyncImage(url: url, targetSize: CGSize(width: 640, height: 360)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                self.placeholderThumb
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipped()
        } else {
            self.placeholderThumb
                .aspectRatio(16 / 10, contentMode: .fit)
        }
    }

    private var placeholderThumb: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                Image(systemName: "list.bullet.rectangle.portrait.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
    }
}

// MARK: - Move sheet

private struct CourseMoveFolderSheet: View {
    let course: YouTubeCourseCatalogEntry
    let folders: [YouTubeCourseFolder]
    let onPick: (String?) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Button {
                    self.onPick(nil)
                } label: {
                    Label(String(localized: "All Courses (root)"), systemImage: "square.stack.3d.up")
                }
                ForEach(
                    self.folders.sorted {
                        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                ) { folder in
                    Button {
                        self.onPick(folder.id)
                    } label: {
                        Label(folder.name, systemImage: "folder")
                    }
                }
            }
            .navigationTitle(Text("Move “\(self.course.title)”"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel"), action: self.onCancel)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 320)
    }
}

// MARK: - Accessibility

extension AccessibilityID.YouTubeContent {
    static let courseFolderCard = "youtubeContent.courseFolderCard"
    static let courseCatalogCard = "youtubeContent.courseCatalogCard"
}

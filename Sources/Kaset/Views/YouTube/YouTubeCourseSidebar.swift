import SwiftUI

// MARK: - YouTubeCourseSidebar

/// Course outline while watching: curriculum, progress, notes, resume badges.
struct YouTubeCourseSidebar: View {
    private static let brandAccent = PackageResourceLookup.brandAccent

    @State private var course = YouTubeCourseSession.shared
    @State private var library = YouTubeCourseLibrary.shared
    @Environment(YouTubePlayerService.self) private var youtubePlayer
    var onSelectLesson: (YouTubeVideo) -> Void

    @State private var noteDraft = ""
    @State private var showNotes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.header
            Divider().opacity(0.4)
            self.progressSection
            Divider().opacity(0.4)
            if self.showNotes {
                self.notesEditor
                Divider().opacity(0.4)
            }
            self.lessonList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.courseSidebar)
        .onAppear {
            self.reloadNoteDraft()
        }
        .onChange(of: self.course.currentIndex) { _, _ in
            self.reloadNoteDraft()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle.portrait.fill")
                    .foregroundStyle(Self.brandAccent)
                Text("Course", comment: "Course sidebar title")
                    .font(.headline)
                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.showNotes.toggle()
                    }
                } label: {
                    Image(systemName: self.showNotes ? "note.text" : "square.and.pencil")
                        .foregroundStyle(self.showNotes ? Self.brandAccent : .secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Lesson notes"))

                if let playlistId = self.course.playlistId {
                    Button {
                        self.library.togglePin(playlistId: playlistId)
                    } label: {
                        Image(systemName: self.library.course(playlistId: playlistId)?.isPinned == true
                            ? "pin.fill"
                            : "pin")
                            .foregroundStyle(
                                self.library.course(playlistId: playlistId)?.isPinned == true
                                    ? Self.brandAccent
                                    : .secondary
                            )
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Pin course"))
                }

                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        self.course.endCourse()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Exit course mode"))
            }

            Text(self.course.playlistTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)

            if let channel = self.course.playlistChannelName, !channel.isEmpty {
                Text(channel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(
                    String(
                        localized: "\(self.course.completedCount) of \(self.course.lessonCount) completed"
                    )
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((self.course.progressFraction * 100).rounded()))%")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(Self.brandAccent)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.08))
                    Capsule()
                        .fill(Self.brandAccent)
                        .frame(width: max(4, geo.size.width * self.course.progressFraction))
                }
            }
            .frame(height: 6)

            let remainingSeconds = self.course.remainingLessons.reduce(0) {
                $0 + YouTubeCourseDuration.seconds(from: $1.lengthText)
            }
            if remainingSeconds > 0 {
                Text(
                    String(
                        localized: "About \(YouTubeCourseDuration.format(seconds: remainingSeconds)) left"
                    )
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            if let next = self.course.nextLesson {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundStyle(Self.brandAccent)
                        .font(.caption)
                    Text("Next: \(next.title)", comment: "Next course lesson preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else if self.course.completedCount == self.course.lessonCount, self.course.lessonCount > 0 {
                Label(String(localized: "Course complete — nice work!"), systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Notes

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "Notes for this lesson"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let lesson = self.course.currentLesson {
                    Text(lesson.title)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            TextEditor(text: self.$noteDraft)
                .font(.callout)
                .frame(minHeight: 80, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: self.noteDraft) { _, newValue in
                    if let id = self.course.currentLesson?.videoId {
                        self.course.setNote(for: id, text: newValue)
                    }
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func reloadNoteDraft() {
        if let id = self.course.currentLesson?.videoId {
            self.noteDraft = self.course.note(for: id)
        } else {
            self.noteDraft = ""
        }
    }

    // MARK: - Lessons

    private var lessonList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(self.course.lessons.enumerated()), id: \.element.videoId) { index, lesson in
                        YouTubeCourseLessonRow(
                            index: index + 1,
                            lesson: lesson,
                            isCurrent: self.course.isCurrent(lesson.videoId),
                            isCompleted: self.course.isCompleted(lesson.videoId),
                            hasNote: self.course.hasNote(for: lesson.videoId),
                            resumeSeconds: self.course.resumeSeconds(for: lesson.videoId),
                            onSelect: { self.onSelectLesson(lesson) },
                            onToggleComplete: {
                                self.course.toggleCompleted(videoId: lesson.videoId)
                            }
                        )
                        .id(lesson.videoId)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .onAppear { self.scrollToCurrent(proxy) }
            .onChange(of: self.course.currentIndex) { _, _ in
                self.scrollToCurrent(proxy)
            }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let id = self.course.currentLesson?.videoId else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

// MARK: - Lesson row

private struct YouTubeCourseLessonRow: View {
    private static let brandAccent = PackageResourceLookup.brandAccent

    let index: Int
    let lesson: YouTubeVideo
    let isCurrent: Bool
    let isCompleted: Bool
    let hasNote: Bool
    let resumeSeconds: Double?
    let onSelect: () -> Void
    let onToggleComplete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: self.onToggleComplete) {
                Image(systemName: self.statusIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(self.statusColor)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)

            Button(action: self.onSelect) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(String(format: "%02d", self.index))
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(self.isCurrent ? Self.brandAccent : .secondary)
                        if self.isCurrent {
                            Text("NOW", comment: "Current course lesson badge")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Self.brandAccent.opacity(0.18), in: Capsule())
                                .foregroundStyle(Self.brandAccent)
                        }
                        if self.hasNote {
                            Image(systemName: "note.text")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if let length = self.lesson.lengthText {
                            Text(length)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Text(self.lesson.title)
                        .font(.system(size: 12, weight: self.isCurrent ? .semibold : .regular))
                        .foregroundStyle(self.isCurrent ? .primary : .secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)

                    if let resume = self.resumeSeconds, resume > 5, !self.isCompleted {
                        Text(
                            String(
                                localized: "Resume at \(Self.format(seconds: resume))"
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(Self.brandAccent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background {
            if self.isCurrent {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Self.brandAccent.opacity(0.10))
            }
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.courseLessonRow)
    }

    private var statusIcon: String {
        if self.isCompleted {
            "checkmark.circle.fill"
        } else if self.isCurrent {
            "play.circle.fill"
        } else {
            "circle"
        }
    }

    private var statusColor: Color {
        if self.isCompleted {
            .green
        } else if self.isCurrent {
            Self.brandAccent
        } else {
            .secondary
        }
    }

    private static func format(seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Accessibility

extension AccessibilityID.YouTubeContent {
    static let courseSidebar = "youtubeContent.courseSidebar"
    static let courseLessonRow = "youtubeContent.courseLessonRow"
}

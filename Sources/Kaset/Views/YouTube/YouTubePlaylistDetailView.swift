import SwiftUI

/// A YouTube playlist page: header plus its video rows.
/// Playing any video (or “Play as course”) starts course mode — the watch
/// page then shows a curriculum sidebar with completed / current / next topics.
struct YouTubePlaylistDetailView: View {
    @State private var viewModel: YouTubePlaylistViewModel
    @Environment(YouTubePlayerService.self) private var youtubePlayer
    @Environment(AuthService.self) private var authService

    private static let brandAccent = PackageResourceLookup.brandAccent
    private static let columns = [
        GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 16),
    ]

    init(playlistId: String, client: any YouTubeClientProtocol) {
        self._viewModel = State(
            initialValue: YouTubePlaylistViewModel(playlistId: playlistId, client: client)
        )
    }

    var body: some View {
        Group {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                LoadingView()
            case let .error(error):
                ErrorView(
                    title: error.title,
                    message: error.message,
                    isRetryable: error.isRetryable
                ) {
                    Task {
                        await self.viewModel.load()
                    }
                }
            case .loaded, .loadingMore:
                if let detail = self.viewModel.detail {
                    self.content(for: detail)
                }
            }
        }
        .navigationTitle(Text(self.viewModel.detail?.playlist.title ?? ""))
        .task {
            await self.viewModel.load()
        }
    }

    private func content(for detail: YouTubePlaylistDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(detail.playlist.title)
                        .font(.title.bold())
                        .lineLimit(2)

                    let meta = [detail.playlist.channelName, detail.playlist.videoCountText]
                        .compactMap(\.self)
                    if !meta.isEmpty {
                        Text(meta.joined(separator: " · "))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if !detail.videos.isEmpty {
                        HStack(spacing: 10) {
                            // Start course from the first incomplete lesson, or the first video.
                            NavigationLink(value: YouTubeRoute.watch(self.courseStartVideo(in: detail))) {
                                Label(
                                    String(localized: "Play as Course"),
                                    systemImage: "list.bullet.rectangle.portrait.fill"
                                )
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 14)
                                .frame(height: 34)
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .compatGlass(interactive: true, tint: Self.brandAccent, in: Capsule())
                            .simultaneousGesture(TapGesture().onEnded {
                                self.beginCourse(detail: detail, startingAt: self.courseStartVideo(in: detail))
                            })

                            Text(
                                "Watch as a course with progress, completed lessons, and what’s next.",
                                comment: "Course mode explainer under playlist header"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        }
                        .padding(.top, 4)
                    }
                }

                if detail.videos.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "No videos"), systemImage: "list.and.film")
                    }
                } else {
                    LazyVGrid(columns: Self.columns, spacing: 20) {
                        ForEach(detail.videos) { video in
                            NavigationLink(value: YouTubeRoute.watch(video)) {
                                VideoCard(video: video)
                            }
                            .buttonStyle(.interactiveCard)
                            .simultaneousGesture(TapGesture().onEnded {
                                self.beginCourse(detail: detail, startingAt: video)
                            })
                        }
                    }
                }
            }
            .padding(.vertical, 20)
        }
        // Edge-to-edge with a resting inset so content extends under the
        // floating glass sidebar.
        .contentMargins(.horizontal, DetailContentLayout.horizontalInset, for: .scrollContent)
    }

    // MARK: - Course entry

    private func courseStartVideo(in detail: YouTubePlaylistDetail) -> YouTubeVideo {
        let course = YouTubeCourseSession.shared
        // Prefer first incomplete if we already have progress for this playlist.
        let completed = course.playlistId == detail.playlist.playlistId
            ? course.completedVideoIds
            : Set(
                (UserDefaults.standard.array(
                    forKey: "youtube.course.completed.\(detail.playlist.playlistId)"
                ) as? [String]) ?? []
            )
        return detail.videos.first { !completed.contains($0.videoId) && !$0.isShort }
            ?? detail.videos.first { !$0.isShort }
            ?? detail.videos[0]
    }

    private func beginCourse(detail: YouTubePlaylistDetail, startingAt video: YouTubeVideo) {
        YouTubeCourseSession.shared.start(
            playlist: detail.playlist,
            lessons: detail.videos,
            startingAt: video
        )
        // Pre-seed the player queue so skip-next walks the course.
        if self.youtubePlayer.currentVideo?.videoId == video.videoId {
            self.youtubePlayer.setCourseQueue(YouTubeCourseSession.shared.remainingLessons)
        }
        HapticService.toggle()
    }
}

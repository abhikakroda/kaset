import AppKit
import Foundation
import Observation

// MARK: - DownloadJob

/// A single yt-dlp download in progress or completed.
///
/// Not actor-isolated: all mutations happen on the main actor via
/// `YTDLPService`. Keeping this a plain `@Observable` class avoids
/// MainActor executor checks during SwiftUI list filters (which crashed
/// the app when progress updates and body re-renders interleaved).
@Observable
final class DownloadJob: Identifiable {
    enum Status: Equatable {
        case queued
        case running
        case completed
        case failed(String)
        case cancelled
    }

    let id: UUID
    let videoId: String
    let title: String
    let quality: DownloadQuality
    let destinationDirectory: URL
    let startedAt: Date

    var status: Status = .queued
    /// 0...1 when yt-dlp reports progress; nil while unknown.
    var progress: Double?
    var speedText: String?
    var etaText: String?
    var logTail: String = ""
    var outputURL: URL?

    /// Bumped on meaningful progress so SwiftUI can observe a simple value.
    var progressRevision: UInt = 0

    init(
        id: UUID = UUID(),
        videoId: String,
        title: String,
        quality: DownloadQuality,
        destinationDirectory: URL
    ) {
        self.id = id
        self.videoId = videoId
        self.title = title
        self.quality = quality
        self.destinationDirectory = destinationDirectory
        self.startedAt = Date()
    }
}

// MARK: - YTDLPService

/// Terminal-backed download service that shells out to the system `yt-dlp`
/// binary (optionally with `ffmpeg` for merge / audio extract).
///
/// Downloads land in the user's Downloads folder or a custom folder chosen
/// in Settings → YouTube. The binary path is auto-detected from common
/// Homebrew locations, or can be overridden in settings.
@MainActor
@Observable
final class YTDLPService {
    static let shared = YTDLPService()

    private(set) var jobs: [DownloadJob] = []
    private(set) var lastError: String?
    private(set) var resolvedBinaryPath: String?

    private var processes: [UUID: Process] = [:]
    /// Retained pipes so handlers stay valid until we explicitly tear them down.
    private var pipes: [UUID: (stdout: Pipe, stderr: Pipe)] = [:]
    /// Jobs that should ignore further pipe output (finished / cancelled).
    private var finishedJobIDs: Set<UUID> = []
    /// Throttle UI progress writes (ms since reference date of last update).
    private var lastProgressUIUpdate: [UUID: TimeInterval] = [:]
    private let logger = DiagnosticsLogger.download
    private let settings = SettingsManager.shared

    private init() {
        self.resolvedBinaryPath = Self.discoverBinaryPath(override: self.settings.ytdlpBinaryPath)
    }

    // MARK: - Availability

    /// Whether a usable yt-dlp binary is currently resolvable.
    var isAvailable: Bool {
        self.resolvedBinaryPath != nil
    }

    /// Re-scan for yt-dlp (after install or path change).
    func refreshBinaryPath() {
        self.resolvedBinaryPath = Self.discoverBinaryPath(override: self.settings.ytdlpBinaryPath)
        if let path = self.resolvedBinaryPath {
            self.logger.info("yt-dlp resolved at \(path, privacy: .public)")
            self.lastError = nil
        } else {
            self.logger.warning("yt-dlp not found on PATH / common install locations")
        }
    }

    /// Candidate absolute paths checked when auto-detecting yt-dlp.
    static let defaultSearchPaths: [String] = [
        "/opt/homebrew/bin/yt-dlp",
        "/usr/local/bin/yt-dlp",
        "/opt/local/bin/yt-dlp",
        "/usr/bin/yt-dlp",
    ]

    static func discoverBinaryPath(override: String?) -> String? {
        if let override, !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return expanded
            }
        }

        for path in Self.defaultSearchPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        // Last resort: ask the login shell (works outside sandbox; may fail inside).
        if let which = Self.which("yt-dlp"), FileManager.default.isExecutableFile(atPath: which) {
            return which
        }
        return nil
    }

    private static func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.environment = Self.augmentedEnvironment()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch {
            return nil
        }
    }

    // MARK: - Destination

    /// Resolves the active download directory from settings, starting
    /// security-scoped access when a custom bookmark is used.
    ///
    /// Caller must pair with `endAccessingDestination` when finished.
    func beginAccessingDestination() throws -> (url: URL, didStartSecurityScope: Bool) {
        switch self.settings.downloadFolderPreference {
        case .downloads:
            let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return (url, false)

        case .custom:
            guard let bookmark = self.settings.downloadFolderBookmarkData else {
                throw YTDLPError.noCustomFolder
            }
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                // Re-create bookmark so access survives across relaunches.
                if let refreshed = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    self.settings.downloadFolderBookmarkData = refreshed
                }
            }
            let started = url.startAccessingSecurityScopedResource()
            guard started || url.path.hasPrefix(NSHomeDirectory()) else {
                throw YTDLPError.folderAccessDenied(url.path)
            }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return (url, started)
        }
    }

    func endAccessingDestination(_ url: URL, didStartSecurityScope: Bool) {
        if didStartSecurityScope {
            url.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Download

    /// Enqueues and starts a yt-dlp download for the given video.
    @discardableResult
    func download(
        videoId: String,
        title: String,
        quality: DownloadQuality? = nil
    ) throws -> DownloadJob {
        self.refreshBinaryPath()
        guard let binary = self.resolvedBinaryPath else {
            throw YTDLPError.binaryNotFound
        }

        let quality = quality ?? self.settings.downloadDefaultQuality
        let access = try self.beginAccessingDestination()
        let job = DownloadJob(
            videoId: videoId,
            title: title,
            quality: quality,
            destinationDirectory: access.url
        )
        self.jobs.insert(job, at: 0)
        self.lastError = nil

        Task { @MainActor in
            await self.run(job: job, binary: binary, destinationAccess: access)
        }
        return job
    }

    func cancel(_ jobID: UUID) {
        self.finishedJobIDs.insert(jobID)
        if let job = self.jobs.first(where: { $0.id == jobID }) {
            job.status = .cancelled
        }
        if let process = self.processes[jobID], process.isRunning {
            process.terminate()
        }
        self.detachPipes(for: jobID)
        self.processes[jobID] = nil
    }

    func clearFinishedJobs() {
        self.jobs.removeAll { job in
            switch job.status {
            case .completed, .failed, .cancelled: true
            case .queued, .running: false
            }
        }
    }

    /// Reveals the download folder (or a completed file) in Finder.
    func revealInFinder(job: DownloadJob) {
        if let output = job.outputURL {
            NSWorkspace.shared.activateFileViewerSelecting([output])
        } else {
            NSWorkspace.shared.open(job.destinationDirectory)
        }
    }

    /// Opens Terminal.app with a ready-to-run yt-dlp command for power users.
    func openInTerminal(
        videoId: String,
        title: String,
        quality: DownloadQuality? = nil
    ) throws {
        self.refreshBinaryPath()
        let binary = self.resolvedBinaryPath ?? "yt-dlp"
        let quality = quality ?? self.settings.downloadDefaultQuality
        let access = try self.beginAccessingDestination()
        defer {
            self.endAccessingDestination(access.url, didStartSecurityScope: access.didStartSecurityScope)
        }

        let args = Self.buildArguments(
            binary: binary,
            videoId: videoId,
            title: title,
            quality: quality,
            destination: access.url
        )
        // Escape for a double-quoted shell string.
        let command = args.map { arg in
            "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")

        let script = """
        #!/bin/zsh
        cd \(shellSingleQuoted(access.url.path))
        echo "Kaset → yt-dlp"
        echo "\(title.replacingOccurrences(of: "\"", with: "\\\""))"
        \(command)
        echo ""
        echo "Done. Press any key to close."
        read -k1
        """

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaset-ytdlp-\(videoId).command")
        try script.write(to: temp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
        NSWorkspace.shared.open(temp)
    }

    // MARK: - Internals

    private func run(
        job: DownloadJob,
        binary: String,
        destinationAccess: (url: URL, didStartSecurityScope: Bool)
    ) async {
        job.status = .running
        self.finishedJobIDs.remove(job.id)

        let args = Self.buildArguments(
            binary: binary,
            videoId: job.videoId,
            title: job.title,
            quality: job.quality,
            destination: destinationAccess.url
        )

        let process = Process()
        // args[0] is the binary path; Process wants executable + remaining args.
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = Array(args.dropFirst())
        process.currentDirectoryURL = destinationAccess.url
        process.environment = Self.augmentedEnvironment()

        // Keep pipes alive for the lifetime of the process. Detaching
        // standardOutput before clearing readabilityHandler used to race and
        // crash the app when yt-dlp finished (EXC_BAD_ACCESS in FileHandle +
        // SwiftUI re-render of the download HUD).
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let jobID = job.id
        self.processes[jobID] = process
        self.pipes[jobID] = (stdout, stderr)

        self.attachPipeReader(stdout, jobID: jobID)
        self.attachPipeReader(stderr, jobID: jobID)

        do {
            self.logger.info(
                "Starting yt-dlp for \(job.videoId, privacy: .public) → \(destinationAccess.url.path, privacy: .public)"
            )
            try process.run()

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in
                    // Detach pipe handlers on the termination queue first so
                    // no further availableData calls race with MainActor cleanup.
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    continuation.resume()
                }
            }
        } catch {
            job.status = .failed(error.localizedDescription)
            self.lastError = error.localizedDescription
            self.logger.error("yt-dlp failed to launch: \(error.localizedDescription, privacy: .public)")
            self.cleanup(jobID: job.id, destinationAccess: destinationAccess)
            return
        }

        // Process has exited — mark finished so any late MainActor pipe tasks no-op.
        self.finishedJobIDs.insert(jobID)

        let code = process.terminationStatus
        if job.status == .cancelled {
            self.cleanup(jobID: job.id, destinationAccess: destinationAccess)
            return
        }

        if code == 0 {
            job.status = .completed
            job.progress = 1
            job.progressRevision &+= 1
            if job.outputURL == nil {
                job.outputURL = Self.guessOutputURL(
                    destination: destinationAccess.url,
                    title: job.title,
                    videoId: job.videoId
                )
            }
            self.logger.info("yt-dlp completed for \(job.videoId, privacy: .public)")
        } else {
            let message = job.logTail.split(separator: "\n").suffix(3).joined(separator: "\n")
            let failure = message.isEmpty
                ? "yt-dlp exited with code \(code)"
                : String(message)
            job.status = .failed(failure)
            self.lastError = failure
            self.logger.error(
                "yt-dlp exit \(code) for \(job.videoId, privacy: .public): \(failure, privacy: .public)"
            )
        }

        self.cleanup(jobID: job.id, destinationAccess: destinationAccess)
    }

    private func attachPipeReader(_ pipe: Pipe, jobID: UUID) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // Empty data == EOF. Drop the handler immediately.
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.finishedJobIDs.contains(jobID) else { return }
                guard self.processes[jobID] != nil else { return }
                self.appendLog(jobID: jobID, text: text)
                self.parseProgress(jobID: jobID, text: text)
            }
        }
    }

    private func detachPipes(for jobID: UUID) {
        if let pair = self.pipes[jobID] {
            pair.stdout.fileHandleForReading.readabilityHandler = nil
            pair.stderr.fileHandleForReading.readabilityHandler = nil
        }
        self.pipes[jobID] = nil
    }

    private func cleanup(
        jobID: UUID,
        destinationAccess: (url: URL, didStartSecurityScope: Bool)
    ) {
        self.finishedJobIDs.insert(jobID)
        self.detachPipes(for: jobID)

        if let process = self.processes[jobID] {
            process.terminationHandler = nil
            // Only clear process IO after handlers are gone.
            process.standardOutput = nil
            process.standardError = nil
        }
        self.processes[jobID] = nil
        self.lastProgressUIUpdate[jobID] = nil
        self.endAccessingDestination(
            destinationAccess.url,
            didStartSecurityScope: destinationAccess.didStartSecurityScope
        )
    }

    private func appendLog(jobID: UUID, text: String) {
        guard !self.finishedJobIDs.contains(jobID) else { return }
        guard let job = self.jobs.first(where: { $0.id == jobID }) else { return }
        let combined = job.logTail + text
        job.logTail = combined.count > 4000 ? String(combined.suffix(4000)) : combined
        if let dest = Self.parseDestination(from: text) {
            job.outputURL = URL(fileURLWithPath: dest)
        }
    }

    private func parseProgress(jobID: UUID, text: String) {
        guard !self.finishedJobIDs.contains(jobID) else { return }
        guard let job = self.jobs.first(where: { $0.id == jobID }) else { return }

        var didChange = false
        // yt-dlp may flush multiple --newline progress rows in one pipe chunk.
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            if let percent = Self.parsePercent(from: line) {
                let next = percent / 100
                let current = job.progress ?? 0
                if next > current + 0.001 {
                    job.progress = next
                    didChange = true
                } else if job.progress == nil {
                    job.progress = next
                    didChange = true
                }
            }
            if let speed = Self.parseField(from: line, label: "at"), speed != job.speedText {
                job.speedText = speed
                didChange = true
            }
            if let eta = Self.parseField(from: line, label: "ETA"), eta != job.etaText {
                job.etaText = eta
                didChange = true
            }
            if line.localizedCaseInsensitiveContains("Merging formats")
                || line.localizedCaseInsensitiveContains("Extracting audio")
                || line.localizedCaseInsensitiveContains("Embedding thumbnail")
            {
                let next = max(job.progress ?? 0, 0.97)
                if job.progress != next {
                    job.progress = next
                    didChange = true
                }
                job.speedText = nil
                job.etaText = String(localized: "Finishing…")
                didChange = true
            }
        }

        // Throttle Observation/SwiftUI invalidations — yt-dlp can emit many
        // progress lines per second; updating every tick crashed the download HUD.
        guard didChange else { return }
        let now = Date().timeIntervalSinceReferenceDate
        let last = self.lastProgressUIUpdate[jobID] ?? 0
        if now - last >= 0.15 || (job.progress ?? 0) >= 0.999 {
            self.lastProgressUIUpdate[jobID] = now
            job.progressRevision &+= 1
        }
    }

    // MARK: - Argument / parse helpers (pure, unit-testable)

    /// Builds the full argv including the binary as argv[0].
    static func buildArguments(
        binary: String,
        videoId: String,
        title: String,
        quality: DownloadQuality,
        destination: URL
    ) -> [String] {
        let url = "https://www.youtube.com/watch?v=\(videoId)"
        // Sanitize title for the output template (yt-dlp also sanitizes).
        let safeTitle = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\0", with: "")

        var args: [String] = [
            binary,
            "--no-playlist",
            "--newline",
            "--no-colors",
            "--progress",
            "-f", quality.formatSelector,
            "-o", "%(title).200B [%(id)s].%(ext)s",
            "-P", destination.path,
            "--print", "after_move:filepath",
            "--print", "after_video:filepath",
        ]

        if let audioFormat = quality.audioExtractFormat {
            args += ["-x", "--audio-format", audioFormat]
        }

        // Prefer mp4 when merging so Finder/Quick Look are happy.
        if !quality.isAudioOnly {
            args += ["--merge-output-format", "mp4"]
        }

        // Embed metadata / thumbnail when possible.
        args += [
            "--embed-metadata",
            "--embed-thumbnail",
            "--convert-thumbnails", "jpg",
        ]

        // Soft-fail thumbnail/embed if unsupported for this media.
        args += ["--ignore-errors"]

        // Keep a readable fallback name in logs.
        _ = safeTitle

        args.append(url)
        return args
    }

    static func parsePercent(from text: String) -> Double? {
        // Example: [download]  45.2% of  10.00MiB at  1.23MiB/s ETA 00:04
        guard let range = text.range(of: #"(\d{1,3}(?:\.\d+)?)%"#, options: .regularExpression) else {
            return nil
        }
        let token = text[range].dropLast() // strip %
        return Double(token)
    }

    static func parseField(from text: String, label: String) -> String? {
        // Match "at 1.23MiB/s" or "ETA 00:04"
        let pattern = #"\#(label)\s+([^\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2
        else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    static func parseDestination(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // after_move / after_video print a bare path.
        if trimmed.hasPrefix("/"), FileManager.default.fileExists(atPath: trimmed) {
            return trimmed
        }
        // Destination: /path/to/file.mp4
        if let range = trimmed.range(of: "Destination: ") {
            let path = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        }
        if trimmed.contains("has already been downloaded") {
            // [download] File.mp4 has already been downloaded
            if let start = trimmed.range(of: "[download] ")?.upperBound,
               let end = trimmed.range(of: " has already")?.lowerBound
            {
                return String(trimmed[start ..< end])
            }
        }
        return nil
    }

    static func guessOutputURL(destination: URL, title: String, videoId: String) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let matches = contents.filter { $0.lastPathComponent.contains(videoId) }
        if let best = matches.max(by: { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }) {
            return best
        }
        // Fall back: any recent file with a media extension.
        let media = contents.filter {
            ["mp4", "mkv", "webm", "m4a", "mp3", "opus"].contains($0.pathExtension.lowercased())
        }
        return media.max(by: { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        })
    }

    static func augmentedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extras = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "/usr/bin",
            "/bin",
        ]
        let existing = env["PATH"] ?? ""
        env["PATH"] = (extras + [existing]).joined(separator: ":")
        // Avoid interactive prompts.
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - YTDLPError

enum YTDLPError: LocalizedError {
    case binaryNotFound
    case noCustomFolder
    case folderAccessDenied(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            String(localized: "yt-dlp was not found. Install it with Homebrew (brew install yt-dlp) or set the path in Settings → YouTube.")
        case .noCustomFolder:
            String(localized: "Choose a custom download folder in Settings → YouTube.")
        case let .folderAccessDenied(path):
            String(localized: "Could not access the download folder: \(path)")
        }
    }
}

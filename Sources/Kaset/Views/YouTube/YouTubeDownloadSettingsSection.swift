import AppKit
import SwiftUI

// MARK: - YouTubeDownloadSettingsSection

/// Settings controls for yt-dlp downloads (folder, quality, binary path).
struct YouTubeDownloadSettingsSection: View {
    @Bindable var settings: SettingsManager
    @State private var downloadService = YTDLPService.shared

    var body: some View {
        Section {
            Picker(String(localized: "Save downloads to"), selection: self.$settings.downloadFolderPreference) {
                ForEach(DownloadFolderPreference.allCases) { preference in
                    Text(preference.displayName).tag(preference)
                }
            }

            if self.settings.downloadFolderPreference == .custom {
                HStack {
                    Text(self.settings.downloadFolderDisplayPath.isEmpty
                        ? String(localized: "No folder selected")
                        : self.settings.downloadFolderDisplayPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer()
                    Button(String(localized: "Choose…")) {
                        self.chooseCustomFolder()
                    }
                }
            }

            Picker(String(localized: "Default quality"), selection: self.$settings.downloadDefaultQuality) {
                ForEach(DownloadQuality.allCases) { quality in
                    Text(quality.displayName).tag(quality)
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "yt-dlp path"))
                    Text(self.downloadService.resolvedBinaryPath
                        ?? String(localized: "Not found — install with: brew install yt-dlp ffmpeg"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button(String(localized: "Refresh")) {
                    self.downloadService.refreshBinaryPath()
                }
                Button(String(localized: "Browse…")) {
                    self.chooseBinary()
                }
            }

            if !self.settings.ytdlpBinaryPath.isEmpty {
                HStack {
                    Text(self.settings.ytdlpBinaryPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(String(localized: "Clear override")) {
                        self.settings.ytdlpBinaryPath = ""
                        self.downloadService.refreshBinaryPath()
                    }
                }
            }
        } header: {
            Text("Downloads (yt-dlp)")
        } footer: {
            Text("Kaset shells out to the system yt-dlp tool (and ffmpeg when needed) to save videos or audio. Default location is your Downloads folder; pick a custom folder for another destination.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            self.downloadService.refreshBinaryPath()
        }
        .onChange(of: self.settings.ytdlpBinaryPath) { _, _ in
            self.downloadService.refreshBinaryPath()
        }
    }

    private func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Download Folder")
        panel.message = String(localized: "Videos and audio downloaded via yt-dlp will be saved here.")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.level = .modalPanel

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            self.settings.downloadFolderBookmarkData = bookmark
            self.settings.downloadFolderDisplayPath = url.path
            self.settings.downloadFolderPreference = .custom
        } catch {
            DiagnosticsLogger.download.error("Failed to bookmark download folder: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Locate yt-dlp")
        panel.message = String(localized: "Select the yt-dlp executable (for example /opt/homebrew/bin/yt-dlp).")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.level = .modalPanel
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        self.settings.ytdlpBinaryPath = url.path
        self.downloadService.refreshBinaryPath()
    }
}

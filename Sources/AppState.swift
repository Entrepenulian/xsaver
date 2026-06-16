import AppKit
import SwiftUI

/// Decides where downloads are saved: videos in ~/Downloads, extracted audio in
/// ~/Downloads/xsaver Audio, both with readable, collision-free filenames.
enum DownloadLocation {
    private static var downloads: URL {
        let fm = FileManager.default
        return fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    private static func base(for video: ExtractedVideo) -> String {
        if let handle = video.authorHandle, !handle.isEmpty {
            return "\(handle)-\(video.tweetID)"
        }
        return "twitter-\(video.tweetID)"
    }

    private static func unique(in dir: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent("\(base).\(ext)")
        var i = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) (\(i)).\(ext)")
            i += 1
        }
        return candidate
    }

    /// Final destination for a downloaded video, in the ~/Downloads/X downloads folder.
    static func uniqueVideo(for video: ExtractedVideo) -> URL {
        let dir = downloads.appendingPathComponent("X downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return unique(in: dir, base: base(for: video), ext: "mp4")
    }

    /// Final destination for extracted audio, in the ~/Downloads/X-Audio folder.
    static func uniqueAudio(for video: ExtractedVideo) -> URL {
        let dir = downloads.appendingPathComponent("X-Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return unique(in: dir, base: base(for: video), ext: "m4a")
    }

    /// Scratch location for the MP4 we download before stripping its audio.
    static func tempVideo(for video: ExtractedVideo) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("xsaver-\(video.tweetID)-\(UUID().uuidString).mp4")
    }
}

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(String)
        case downloading(Double)
        case success(URL)
        case failure(String)
    }

    enum Mode: CaseIterable {
        case video, audio
        var title: String { self == .video ? "Video" : "Audio" }
    }

    @Published var urlText = ""
    @Published var phase: Phase = .idle
    @Published var mode: Mode = .video
    /// Bumped on each failure so the input can play one shake cycle.
    @Published var shakeToken = 0

    // Held strongly for the lifetime of an in-flight download.
    private var downloader: VideoDownloader?

    init() {
        // The panel closes when the app resigns active (you click outside). Clear the
        // field then, so reopening always starts empty even if the SwiftUI lifecycle
        // callbacks don't fire reliably for the menu-bar window.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetUnlessDownloading() }
        }
    }

    var isBusy: Bool {
        switch phase {
        case .working, .downloading: return true
        default: return false
        }
    }

    /// Open and close both start the field from empty. The only thing that survives
    /// is a download that's still running, so closing the panel mid-download and
    /// reopening still shows its progress.
    func onPanelAppear() { resetUnlessDownloading() }
    func onPanelDisappear() { resetUnlessDownloading() }

    private func resetUnlessDownloading() {
        switch phase {
        case .working, .downloading:
            break
        default:
            reset()
        }
    }

    func start() {
        let input = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isBusy else { return }

        let mode = self.mode
        phase = .working("Finding video…")
        Task {
            do {
                let video = try await TweetVideoExtractor.extract(from: input)
                phase = .downloading(0)

                let dl = VideoDownloader()
                downloader = dl
                let onProgress: @Sendable (Double) -> Void = { fraction in
                    Task { @MainActor in
                        if case .downloading = self.phase {
                            self.phase = .downloading(fraction)
                        }
                    }
                }

                switch mode {
                case .video:
                    let dest = DownloadLocation.uniqueVideo(for: video)
                    let saved = try await dl.download(from: video.url, to: dest, progress: onProgress)
                    downloader = nil
                    phase = .success(saved)

                case .audio:
                    let temp = DownloadLocation.tempVideo(for: video)
                    let downloaded = try await dl.download(from: video.url, to: temp, progress: onProgress)
                    downloader = nil
                    phase = .working("Extracting audio…")
                    let audioDest = DownloadLocation.uniqueAudio(for: video)
                    try await AudioExtractor.extractM4A(from: downloaded, to: audioDest)
                    try? FileManager.default.removeItem(at: downloaded)
                    phase = .success(audioDest)
                }
                scheduleAutoReset()
            } catch {
                downloader = nil
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                shakeToken += 1
                phase = .failure(message)
            }
        }
    }

    func reset() {
        phase = .idle
        urlText = ""
        downloader = nil
    }

    /// Clear a finished download on its own after 5 seconds.
    private func scheduleAutoReset() {
        Task {
            try? await Task.sleep(for: .seconds(5))
            if case .success = phase { reset() }
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

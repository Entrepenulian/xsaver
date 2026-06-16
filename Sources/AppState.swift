import AppKit
import SwiftUI

/// Decides where a downloaded video is saved (~/Downloads, with a readable,
/// collision-free filename).
enum DownloadLocation {
    static func unique(for video: ExtractedVideo) -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")

        let base: String = {
            if let handle = video.authorHandle, !handle.isEmpty {
                return "\(handle)-\(video.tweetID)"
            }
            return "twitter-\(video.tweetID)"
        }()

        var candidate = dir.appendingPathComponent(base + ".mp4")
        var i = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) (\(i)).mp4")
            i += 1
        }
        return candidate
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

    @Published var urlText = ""
    @Published var phase: Phase = .idle
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

        phase = .working("Finding video…")
        Task {
            do {
                let video = try await TweetVideoExtractor.extract(from: input)
                phase = .downloading(0)

                let destination = DownloadLocation.unique(for: video)
                let dl = VideoDownloader()
                downloader = dl

                let saved = try await dl.download(from: video.url, to: destination) { fraction in
                    Task { @MainActor in
                        if case .downloading = self.phase {
                            self.phase = .downloading(fraction)
                        }
                    }
                }
                downloader = nil
                phase = .success(saved)
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

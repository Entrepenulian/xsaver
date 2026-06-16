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
    // The last link we auto-filled, persisted so a link you've already seen (and
    // maybe cleared) never comes back until you copy a different one.
    private let autoFilledKey = "xsaver.lastAutoFilledLink"

    var isBusy: Bool {
        switch phase {
        case .working, .downloading: return true
        default: return false
        }
    }

    /// Called every time the panel opens. A finished (or failed) download is cleared
    /// so reopening always starts fresh, then we offer the clipboard link.
    func onPanelAppear() {
        switch phase {
        case .success, .failure:
            reset()
        default:
            break
        }
        loadClipboardIfLink()
    }

    /// Pre-fill the field if the clipboard holds an X link — but only a link we
    /// haven't auto-filled before. Once you clear a link, it won't come back until
    /// you copy a different one.
    private func loadClipboardIfLink() {
        guard case .idle = phase, urlText.isEmpty else { return }
        guard let s = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              TweetVideoExtractor.tweetID(from: s) != nil else { return }

        if UserDefaults.standard.string(forKey: autoFilledKey) == s { return }
        urlText = s
        UserDefaults.standard.set(s, forKey: autoFilledKey)
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

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
    // The pasteboard change count we last auto-filled from, so clearing the field
    // and reopening the panel doesn't keep re-inserting the same link.
    private var lastPasteboardChangeCount = -1

    var isBusy: Bool {
        switch phase {
        case .working, .downloading: return true
        default: return false
        }
    }

    /// When the panel opens, pre-fill the field if the clipboard holds an X link —
    /// but only when the clipboard changed since we last filled. That way, once you
    /// clear the field, reopening the panel leaves it empty until you copy a new link.
    func loadClipboardIfLink() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = pasteboard.changeCount

        guard case .idle = phase, urlText.isEmpty else { return }
        if let s = pasteboard.string(forType: .string),
           TweetVideoExtractor.tweetID(from: s) != nil {
            urlText = s.trimmingCharacters(in: .whitespacesAndNewlines)
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

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

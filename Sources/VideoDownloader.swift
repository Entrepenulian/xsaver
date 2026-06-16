import Foundation

enum DownloadError: LocalizedError {
    case httpError(Int)
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "Download failed (HTTP \(code))."
        case .writeFailed: return "Couldn't save the file to Downloads."
        }
    }
}

/// Downloads a resolved video to its destination with progress reporting.
/// Uses URLSessionDownloadTask so large files stream to disk efficiently.
final class VideoDownloader: NSObject, URLSessionDownloadDelegate {
    private var progressHandler: ((Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private var destination: URL!
    private var session: URLSession?

    /// Download `url` and move the result to `destination`. `progress` is called
    /// (on an arbitrary thread) with a value in 0...1.
    func download(from url: URL,
                  to destination: URL,
                  progress: @escaping (Double) -> Void) async throws -> URL {
        self.progressHandler = progress
        self.destination = destination

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session

        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            session.downloadTask(with: req).resume()
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // `location` is a temp file that is deleted as soon as this method returns,
        // so move it to the final destination synchronously here.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(.failure(DownloadError.httpError(http.statusCode)))
            return
        }
        do {
            let fm = FileManager.default
            try? fm.createDirectory(at: destination.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(DownloadError.writeFailed))
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error = error {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        continuation?.resume(with: result)
        continuation = nil
        session?.finishTasksAndInvalidate()
        session = nil
    }
}

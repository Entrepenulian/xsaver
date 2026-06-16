import AVFoundation

enum AudioExtractionError: LocalizedError {
    case noAudioTrack
    case exportUnavailable
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "That video has no audio track."
        case .exportUnavailable: return "Couldn't start audio extraction."
        case .exportFailed(let m): return "Audio extraction failed: \(m)"
        }
    }
}

/// Pulls the audio track out of a downloaded MP4 into an .m4a, with no re-encoding
/// (the AAC audio is copied straight through via AVFoundation). Fully local, no
/// external tools.
enum AudioExtractor {
    static func extractM4A(from videoURL: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: videoURL)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw AudioExtractionError.noAudioTrack }

        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioExtractionError.exportUnavailable
        }

        try? FileManager.default.removeItem(at: destination)
        do {
            try await session.export(to: destination, as: .m4a)
        } catch {
            throw AudioExtractionError.exportFailed(error.localizedDescription)
        }
    }
}

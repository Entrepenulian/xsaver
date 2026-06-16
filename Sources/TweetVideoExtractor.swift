import Foundation

/// A single downloadable video resolved from an X/Twitter post.
struct ExtractedVideo {
    let url: URL
    let bitrate: Int
    let tweetID: String
    let authorHandle: String?
}

enum ExtractionError: LocalizedError {
    case noTweetID
    case requestFailed(Int)
    case tweetUnavailable
    case noVideoFound
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .noTweetID:
            return "That doesn't look like an X post link."
        case .requestFailed(let code):
            return "X returned an error (HTTP \(code))."
        case .tweetUnavailable:
            return "This post is unavailable — it may be deleted, private, or age-restricted."
        case .noVideoFound:
            return "No video found in that post."
        case .decodeFailed:
            return "Couldn't read the response from X."
        }
    }
}

/// Resolves the best-quality MP4 for an X post using X's public syndication
/// endpoint (the same no-login API that powers embedded tweets). Every request
/// goes only to X/Twitter's own CDN.
enum TweetVideoExtractor {

    /// Pull the numeric tweet ID out of an x.com / twitter.com URL, or accept a raw ID.
    static func tweetID(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = trimmed.range(of: #"status(?:es)?/(\d+)"#, options: .regularExpression) {
            let digits = trimmed[r].drop { !$0.isNumber }
            return digits.isEmpty ? nil : String(digits)
        }
        if trimmed.range(of: #"^\d{5,25}$"#, options: .regularExpression) != nil {
            return trimmed
        }
        return nil
    }

    /// The syndication endpoint requires a non-empty `token` but does not validate
    /// its value (verified empirically), so a cheap deterministic token suffices.
    static func token(for id: String) -> String {
        guard let n = Double(id) else { return "x" }
        let value = Int64((n / 1e15) * Double.pi)
        let s = String(value, radix: 36)
        return s.isEmpty ? "x" : s
    }

    static func extract(from raw: String) async throws -> ExtractedVideo {
        guard let id = tweetID(from: raw) else { throw ExtractionError.noTweetID }

        var comps = URLComponents(string: "https://cdn.syndication.twimg.com/tweet-result")!
        comps.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "token", value: token(for: id)),
            URLQueryItem(name: "lang", value: "en"),
        ]

        var req = URLRequest(url: comps.url!)
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ExtractionError.requestFailed(-1) }
        guard http.statusCode == 200 else {
            if http.statusCode == 404 { throw ExtractionError.tweetUnavailable }
            throw ExtractionError.requestFailed(http.statusCode)
        }

        let result: TweetResult
        do {
            result = try JSONDecoder().decode(TweetResult.self, from: data)
        } catch {
            throw ExtractionError.decodeFailed
        }

        if result.typename == "TweetTombstone" { throw ExtractionError.tweetUnavailable }

        let videoMedia = (result.mediaDetails ?? []).filter {
            $0.type == "video" || $0.type == "animated_gif"
        }
        guard !videoMedia.isEmpty else { throw ExtractionError.noVideoFound }

        var best: (bitrate: Int, url: String)?
        for media in videoMedia {
            for variant in media.videoInfo?.variants ?? [] {
                guard variant.contentType == "video/mp4" else { continue }
                let br = variant.bitrate ?? 0
                if best == nil || br > best!.bitrate {
                    best = (br, variant.url)
                }
            }
        }

        guard let chosen = best, let url = URL(string: chosen.url) else {
            throw ExtractionError.noVideoFound
        }

        return ExtractedVideo(
            url: url,
            bitrate: chosen.bitrate,
            tweetID: id,
            authorHandle: result.user?.screenName)
    }
}

// MARK: - Syndication JSON shape

private struct TweetResult: Decodable {
    let typename: String?
    let user: User?
    let mediaDetails: [Media]?

    enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case user
        case mediaDetails
    }

    struct User: Decodable {
        let screenName: String?
        enum CodingKeys: String, CodingKey { case screenName = "screen_name" }
    }

    struct Media: Decodable {
        let type: String?
        let videoInfo: VideoInfo?
        enum CodingKeys: String, CodingKey {
            case type
            case videoInfo = "video_info"
        }
    }

    struct VideoInfo: Decodable {
        let variants: [Variant]?
    }

    struct Variant: Decodable {
        let bitrate: Int?
        let contentType: String?
        let url: String
        enum CodingKeys: String, CodingKey {
            case bitrate
            case contentType = "content_type"
            case url
        }
    }
}

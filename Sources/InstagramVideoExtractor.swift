import Foundation

enum InstagramExtractionError: LocalizedError {
    case badLink
    case notLoggedIn
    case requestFailed(Int)
    case noVideoFound
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .badLink: return "Couldn't read that Instagram link."
        case .notLoggedIn: return "Log in to Instagram, then press Download again."
        case .requestFailed(let code): return "Instagram returned an error (HTTP \(code))."
        case .noVideoFound: return "No video found in that post (it may be a photo, or private)."
        case .decodeFailed: return "Couldn't read the response from Instagram."
        }
    }
}

/// Resolves the best MP4 for an Instagram reel/post using Instagram's private web
/// API. Needs the user's Instagram session cookies (Instagram blocks logged-out
/// access), supplied by InstagramAuth.
enum InstagramVideoExtractor {
    private static let appID = "936619743392459"
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// Pull the shortcode out of a reel/post/tv link.
    static func shortcode(from raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"instagram\.com/(?:reels?|p|tv)/([A-Za-z0-9_-]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let r = Range(m.range(at: 1), in: t) else { return nil }
        return String(t[r])
    }

    /// Decode an Instagram shortcode (base64 over a custom alphabet) into the numeric
    /// media id. Uses big-integer decimal arithmetic since 11-char codes exceed 64 bits.
    static func mediaID(from shortcode: String) -> String? {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        var lut = [Character: Int]()
        for (i, c) in alphabet.enumerated() { lut[c] = i }

        var digits = [0] // big-endian decimal digits
        for ch in shortcode {
            guard let value = lut[ch] else { return nil }
            var carry = value
            for i in stride(from: digits.count - 1, through: 0, by: -1) {
                let cur = digits[i] * 64 + carry
                digits[i] = cur % 10
                carry = cur / 10
            }
            while carry > 0 {
                digits.insert(carry % 10, at: 0)
                carry /= 10
            }
        }
        return digits.map(String.init).joined()
    }

    static func extract(shortcode: String, cookieHeader: String) async throws -> ExtractedVideo {
        guard let id = mediaID(from: shortcode) else { throw InstagramExtractionError.badLink }

        let url = URL(string: "https://www.instagram.com/api/v1/media/\(id)/info/")!
        var req = URLRequest(url: url)
        req.setValue(appID, forHTTPHeaderField: "X-IG-App-ID")
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.instagram.com/reel/\(shortcode)/", forHTTPHeaderField: "Referer")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw InstagramExtractionError.requestFailed(-1) }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 { throw InstagramExtractionError.notLoggedIn }
            throw InstagramExtractionError.requestFailed(http.statusCode)
        }

        let result: MediaInfo
        do { result = try JSONDecoder().decode(MediaInfo.self, from: data) }
        catch { throw InstagramExtractionError.decodeFailed }

        guard let item = result.items?.first else { throw InstagramExtractionError.noVideoFound }

        // A reel has video_versions directly; a carousel nests them in carousel_media.
        let candidates = item.videoVersions
            ?? item.carouselMedia?.compactMap { $0.videoVersions }.flatMap { $0 }
        guard let best = pickBest(candidates) else { throw InstagramExtractionError.noVideoFound }

        return ExtractedVideo(
            url: best,
            bitrate: 0,
            tweetID: shortcode,
            authorHandle: item.user?.username ?? "instagram")
    }

    private static func pickBest(_ versions: [MediaInfo.VideoVersion]?) -> URL? {
        guard let versions, !versions.isEmpty else { return nil }
        let best = versions.max { ($0.width ?? 0) * ($0.height ?? 0) < ($1.width ?? 0) * ($1.height ?? 0) }
        return (best?.url).flatMap(URL.init(string:))
    }
}

// MARK: - Instagram media JSON (only the fields we need)

private struct MediaInfo: Decodable {
    let items: [Item]?

    struct Item: Decodable {
        let user: User?
        let videoVersions: [VideoVersion]?
        let carouselMedia: [Item]?
        enum CodingKeys: String, CodingKey {
            case user
            case videoVersions = "video_versions"
            case carouselMedia = "carousel_media"
        }
    }

    struct User: Decodable { let username: String? }

    struct VideoVersion: Decodable {
        let url: String?
        let width: Int?
        let height: Int?
    }
}

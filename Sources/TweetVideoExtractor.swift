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
            return "That doesn't look like an X or Instagram link."
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
        do {
            return try await extractViaSyndication(id: id)
        } catch {
            // The public embed API tombstones sensitive / age-restricted posts. Fall
            // back to X's real GraphQL API (via a guest token), which returns more.
            if let viaAPI = try? await extractViaGraphQL(id: id) { return viaAPI }
            throw error
        }
    }

    private static func extractViaSyndication(id: String) async throws -> ExtractedVideo {
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

    // MARK: - GraphQL fallback (X's real API via a guest token)

    private static let bearer =
        "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs=1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"
    private static let webUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    private static let tweetResultQueryID = "0hWvDhmW8YQ-S_ib3azIrw"

    private static func guestToken() async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.twitter.com/1.1/guest/activate.json")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["guest_token"] as? String else {
            throw ExtractionError.requestFailed(-1)
        }
        return token
    }

    /// How to authorize a GraphQL request: a guest token, or the user's X session.
    enum GraphQLAuth {
        case guest(String)
        case user(cookie: String, csrf: String)
    }

    private static func extractViaGraphQL(id: String) async throws -> ExtractedVideo {
        try await extractViaGraphQL(id: id, auth: .guest(try await guestToken()))
    }

    /// Authenticated variant — uses the user's X login so it can see gated content
    /// (graphic-content interstitials, age-restricted, protected accounts).
    static func extractAuthenticated(id: String, cookie: String, csrf: String) async throws -> ExtractedVideo {
        try await extractViaGraphQL(id: id, auth: .user(cookie: cookie, csrf: csrf))
    }

    private static func extractViaGraphQL(id: String, auth: GraphQLAuth) async throws -> ExtractedVideo {
        let variables = "{\"tweetId\":\"\(id)\",\"withCommunity\":false,\"includePromotedContent\":false,\"withVoice\":false}"
        var comps = URLComponents(
            string: "https://api.x.com/graphql/\(tweetResultQueryID)/TweetResultByRestId")!
        comps.queryItems = [
            URLQueryItem(name: "variables", value: variables),
            URLQueryItem(name: "features", value: graphQLFeatures.trimmingCharacters(in: .whitespacesAndNewlines)),
        ]

        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        switch auth {
        case .guest(let token):
            req.setValue(token, forHTTPHeaderField: "x-guest-token")
        case .user(let cookie, let csrf):
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
            req.setValue(csrf, forHTTPHeaderField: "x-csrf-token")
            req.setValue("OAuth2Session", forHTTPHeaderField: "x-twitter-auth-type")
            req.setValue("yes", forHTTPHeaderField: "x-twitter-active-user")
            req.setValue("en", forHTTPHeaderField: "x-twitter-client-language")
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw ExtractionError.requestFailed((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let json = try JSONSerialization.jsonObject(with: data)

        // Recursively collect every mp4 variant, regardless of Tweet vs
        // TweetWithVisibilityResults nesting, and take the highest bitrate.
        let variants = Self.collectVariants(json)
            .filter { ($0["content_type"] as? String) == "video/mp4" }
        guard let best = variants.max(by: { (($0["bitrate"] as? Int) ?? 0) < (($1["bitrate"] as? Int) ?? 0) }),
              let urlString = best["url"] as? String,
              let url = URL(string: urlString) else {
            throw ExtractionError.tweetUnavailable
        }

        return ExtractedVideo(
            url: url,
            bitrate: (best["bitrate"] as? Int) ?? 0,
            tweetID: id,
            authorHandle: Self.firstString(json, key: "screen_name"))
    }

    /// Depth-first search for every `video_info.variants` array in a JSON tree.
    private static func collectVariants(_ obj: Any) -> [[String: Any]] {
        var out: [[String: Any]] = []
        if let dict = obj as? [String: Any] {
            if let info = dict["video_info"] as? [String: Any],
               let variants = info["variants"] as? [[String: Any]] {
                out += variants
            }
            for value in dict.values { out += collectVariants(value) }
        } else if let arr = obj as? [Any] {
            for value in arr { out += collectVariants(value) }
        }
        return out
    }

    private static func firstString(_ obj: Any, key: String) -> String? {
        if let dict = obj as? [String: Any] {
            if let value = dict[key] as? String { return value }
            for value in dict.values {
                if let found = firstString(value, key: key) { return found }
            }
        } else if let arr = obj as? [Any] {
            for value in arr {
                if let found = firstString(value, key: key) { return found }
            }
        }
        return nil
    }

    private static let graphQLFeatures = """
    {"creator_subscriptions_tweet_preview_api_enabled":true,"communities_web_enable_tweet_community_results_fetch":true,"c9s_tweet_anatomy_moderator_badge_enabled":true,"articles_preview_enabled":true,"tweetypie_unmention_optimization_enabled":true,"responsive_web_edit_tweet_api_enabled":true,"graphql_is_translatable_rweb_tweet_is_translatable_enabled":true,"view_counts_everywhere_api_enabled":true,"longform_notetweets_consumption_enabled":true,"responsive_web_twitter_article_tweet_consumption_enabled":true,"tweet_awards_web_tipping_enabled":false,"creator_subscriptions_quote_tweet_preview_enabled":false,"freedom_of_speech_not_reach_fetch_enabled":true,"standardized_nudges_misinfo":true,"tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled":true,"rweb_video_timestamps_enabled":true,"longform_notetweets_rich_text_read_enabled":true,"longform_notetweets_inline_media_enabled":true,"responsive_web_graphql_exclude_directive_enabled":true,"verified_phone_label_enabled":false,"responsive_web_graphql_skip_user_profile_image_extensions_enabled":false,"responsive_web_graphql_timeline_navigation_enabled":true,"responsive_web_enhance_cards_enabled":false}
    """
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

import Foundation

/// Where a pasted link points.
enum MediaSource {
    case x(id: String)
    case instagram(shortcode: String)
}

/// Detects which platform a link belongs to. Instagram is checked first because its
/// links are unambiguous; X falls through (and also accepts a raw numeric tweet id).
enum MediaExtractor {
    static func detect(_ raw: String) -> MediaSource? {
        if let code = InstagramVideoExtractor.shortcode(from: raw) {
            return .instagram(shortcode: code)
        }
        if let id = TweetVideoExtractor.tweetID(from: raw) {
            return .x(id: id)
        }
        return nil
    }

    static func isSupportedLink(_ raw: String) -> Bool {
        detect(raw) != nil
    }
}

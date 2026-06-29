import AppKit
import WebKit

/// Thrown when an X post is gated and we have no X login to retry with.
struct NeedsXLogin: Error {}

/// Holds the user's X (Twitter) session and shows a one-time login window. Needed for
/// gated posts (graphic-content interstitials, age-restricted, protected accounts) that
/// X only serves to a logged-in account. Cookies live in WKWebView's persistent store.
@MainActor
final class XAuth: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var isLoggedIn = false

    private var window: NSWindow?
    private var webView: WKWebView?

    override init() {
        super.init()
        Task { await refresh() }
    }

    private func xCookies() async -> [HTTPCookie] {
        let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return all.filter { $0.domain.contains("x.com") || $0.domain.contains("twitter.com") }
    }

    /// Cookie header + csrf token (ct0) if logged in, else nil.
    func graphQLAuth() async -> (cookie: String, csrf: String)? {
        let cookies = await xCookies()
        guard cookies.contains(where: { $0.name == "auth_token" && !$0.value.isEmpty }),
              let ct0 = cookies.first(where: { $0.name == "ct0" })?.value, !ct0.isEmpty else {
            return nil
        }
        let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return (header, ct0)
    }

    func refresh() async {
        isLoggedIn = await graphQLAuth() != nil
    }

    func presentLogin() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let frame = NSRect(x: 0, y: 0, width: 460, height: 700)
        let wv = WKWebView(frame: frame, configuration: config)
        wv.navigationDelegate = self
        wv.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        wv.load(URLRequest(url: URL(string: "https://x.com/login")!))

        let win = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.title = "Log in to X"
        win.contentView = wv
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = win
        self.webView = wv
    }

    private func closeLogin() {
        window?.close()
        window = nil
        webView = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task {
            if await graphQLAuth() != nil {
                isLoggedIn = true
                closeLogin()
            }
        }
    }
}

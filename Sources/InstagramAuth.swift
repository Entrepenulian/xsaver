import AppKit
import WebKit

/// Holds the user's Instagram session and shows a one-time login window. Cookies
/// live in WKWebView's default (persistent) data store, so the login survives
/// relaunches; we read them back out to authorize API requests.
@MainActor
final class InstagramAuth: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var isLoggedIn = false

    private var window: NSWindow?
    private var webView: WKWebView?

    override init() {
        super.init()
        Task { await refresh() }
    }

    /// "name=value; name=value" for all Instagram cookies, or nil if not logged in.
    func cookieHeader() async -> String? {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let ig = cookies.filter { $0.domain.contains("instagram.com") }
        guard ig.contains(where: { $0.name == "sessionid" && !$0.value.isEmpty }) else { return nil }
        return ig.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    func refresh() async {
        isLoggedIn = await cookieHeader() != nil
    }

    /// Show (or focus) the Instagram login window.
    func presentLogin() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let frame = NSRect(x: 0, y: 0, width: 440, height: 680)
        let wv = WKWebView(frame: frame, configuration: config)
        wv.navigationDelegate = self
        wv.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        wv.load(URLRequest(url: URL(string: "https://www.instagram.com/accounts/login/")!))

        let win = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.title = "Log in to Instagram"
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

    // Once a session cookie appears after login, close the window.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task {
            if await cookieHeader() != nil {
                isLoggedIn = true
                closeLogin()
            }
        }
    }
}

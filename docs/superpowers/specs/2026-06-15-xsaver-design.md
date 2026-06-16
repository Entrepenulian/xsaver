# xsaver — macOS menu-bar X.com video downloader

**Date:** 2026-06-15
**Status:** Approved (form factor + autonomy delegated by user)

## Problem

Third-party X/Twitter video downloader websites are untrustworthy: they see every
URL you paste, run ad/tracker-heavy pages, and process everything server-side where
you have no visibility. We want our own tool that never sends data to anyone but X.

## Solution

A small **native macOS menu-bar app** ("xsaver"). Click the menu-bar icon → a panel
drops down with a URL field and a **Download** button → the video is saved straight
to `~/Downloads`. No dock icon, no window, no third-party server.

## How it fetches the video

Native Swift, **zero external dependencies**. Uses X's public *syndication* endpoint
(`cdn.syndication.twimg.com/tweet-result`) — the same no-login API that powers
embedded tweets:

1. Parse the tweet ID out of the pasted URL (`…/status/<id>`).
2. GET the syndication endpoint with the id + a token (verified: token is not
   validated by the endpoint — any non-empty value works, so we generate a trivial one).
3. Parse `mediaDetails[].video_info.variants[]`, pick the highest-bitrate `video/mp4`.
4. Download that MP4 directly from `video.twimg.com` to `~/Downloads`.

Every network call goes only to X/Twitter's own CDN. The whole extractor is ~1 file.

**Tradeoff:** if X changes the syndication API, we update one file
(`TweetVideoExtractor.swift`). If it ever proves unreliable, swapping in a bundled
`yt-dlp` is a contained change.

## Architecture

- `xsaverApp.swift` — `MenuBarExtra` app entry (LSUIElement, no dock icon).
- `DownloadPanel.swift` — SwiftUI panel: field, button, progress, success/error states.
- `AppState.swift` — `@MainActor ObservableObject` orchestrating extract → download.
- `TweetVideoExtractor.swift` — URL → tweet ID → syndication API → best MP4. *(the one
  file that knows X's quirks)*
- `VideoDownloader.swift` — `URLSessionDownloadTask` with progress → moves file to `~/Downloads`.
- Built as a real Xcode project (generated via `xcodegen` from `project.yml`).

## Scope

**v1 (this build):** single video tweets, best quality auto-selected, save to
`~/Downloads`, live progress, "Show in Finder", auto-read an X link from the clipboard
when the panel opens, clear error messages (deleted/private/no-video).

**Not in v1 (easy follow-ups):** quality picker, GIF/image/thread download, batch
queue, custom save folder, multiple videos in one tweet.

## Targets

macOS 14+ (modern `MenuBarExtra`). Unsandboxed local tool (needs outbound network +
write to `~/Downloads`).

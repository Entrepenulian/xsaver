# xsaver

A tiny **native macOS menu-bar app** for downloading videos from X.com (Twitter)
posts — built so you never have to paste links into a sketchy third-party website.
It runs entirely on your Mac and only ever talks to X/Twitter's own servers.

## What it does

Click the menu-bar icon → paste an X post link → hit **Download**. The
highest-quality MP4 is saved straight to `~/Downloads`. No dock icon, no window,
no third-party server, no ads, no tracking.

- Auto-fills the field if an X link is already on your clipboard.
- Picks the best available quality automatically.
- Live download progress + "Show in Finder".

## How it works

It uses X's public *syndication* endpoint (`cdn.syndication.twimg.com`) — the same
no-login API that powers embedded tweets — to resolve a post's video, then downloads
the MP4 directly. The extraction logic lives entirely in
[`Sources/TweetVideoExtractor.swift`](Sources/TweetVideoExtractor.swift) (~one file
you can read top to bottom).

## Build & run

Requires macOS 14+ and Xcode command-line tools. `xcodegen` generates the project.

```sh
./build.sh           # generates the project, builds, and opens xsaver.app
```

Or manually:

```sh
xcodegen generate
xcodebuild -project xsaver.xcodeproj -scheme xsaver -configuration Release \
  -derivedDataPath build build
open build/Build/Products/Release/xsaver.app
```

The icon appears in your menu bar (top-right). To launch it automatically, add
`xsaver.app` to **System Settings → General → Login Items**.

## Scope

**v1:** single-video posts, best quality, save to Downloads, progress, Show in Finder.

**Not yet (easy follow-ups):** quality picker, GIF/image/thread/multi-video download,
batch queue, custom save folder. If X ever changes the syndication API, only
`TweetVideoExtractor.swift` needs updating.

## Note

For downloading your own clips and content you're permitted to save. Respect X's
terms and others' copyright.

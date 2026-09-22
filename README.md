# AlbumArtWallpaper

A macOS menu bar app that sets your desktop wallpaper to the album art of
whatever's currently playing in Music.app.

## Features

- Watches Music.app and swaps the wallpaper on every track/album change
- Looks up high-resolution art via the iTunes Search API, falling back to the
  art embedded in your library if nothing is found
- Caches one image per album at
  `~/Library/Application Support/AlbumArtWallpaper/Cache/`, and never
  overwrites a cached file once it exists — so any edits you make stick
- Lets you edit the current art in Preview, or pixelate it, right from the
  menu
- Toggle "Fill Screen" to crop-to-fit vs. letterbox
- Updates itself in the background via [Sparkle](https://sparkle-project.org/),
  checking [GitHub Releases](https://github.com/semanticart/album-wallpaper/releases)
  once a day (toggle this, or manual "Check for Updates…", from the menu)

## Requirements

- macOS 13 (Ventura) or later
- Xcode Command Line Tools (provides `swift` and `codesign`)

The only external dependency is [Sparkle](https://sparkle-project.org/), for
self-updating; otherwise the app only uses `AppKit`, `Foundation`, and
`CoreImage`.

## Build

```sh
make run
```

This runs `swift build -c release`, assembles `.build/AlbumArtWallpaper.app`,
codesigns it (with a Developer ID identity if one is in your keychain,
otherwise ad-hoc), and opens it. `make install` does the same but installs to
`/Applications` instead.

The first time it talks to Music.app, macOS will prompt you to grant
Automation permission — accept it, since that's how the app reads the
current track.

## Releasing

Releases are published by GitHub Actions from a pushed version tag and
installed copies update themselves through Sparkle — see
[RELEASING.md](RELEASING.md).

## Regenerating icons

`Resources/AppIcon.icns` and `Resources/MenuBarIcon.png` are checked in and
generated from the SVGs in `Resources/`. To regenerate them after editing the
SVGs:

```sh
Resources/make-icon.sh
```

import AppKit
import Foundation

// MARK: - Track

struct Track: Equatable {
    let name: String
    let artist: String       // album artist when available, so compilations share one image
    let album: String

    /// Human-readable cache filename stem, e.g. "Radiohead - OK Computer".
    var cacheKey: String {
        let raw = "\(artist) - \(album)"
        let cleaned = raw.map { "/:\\".contains($0) ? "_" : $0 }
        return String(String(cleaned).prefix(150))
    }
}

// MARK: - Cache
//
// One image per album at ~/Library/Application Support/AlbumArtWallpaper/Cache/<Artist - Album>.jpg
// Files are never overwritten once they exist, so anything you edit stays edited.

enum ArtCache {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AlbumArtWallpaper", isDirectory: true)
    }()
    static let dir = root.appendingPathComponent("Cache", isDirectory: true)
    /// Copies of the chosen image live here; see `Wallpaper.apply`.
    static let live = root.appendingPathComponent("Live", isDirectory: true)

    static let extensions = ["jpg", "jpeg", "png", "heic"]

    static func prepare() {
        for d in [dir, live] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    /// The cached file for a track, whatever format you saved your edit in.
    static func existing(for track: Track) -> URL? {
        for ext in extensions {
            let url = dir.appendingPathComponent("\(track.cacheKey).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    static func save(_ jpeg: Data, for track: Track) -> URL? {
        let url = dir.appendingPathComponent("\(track.cacheKey).jpg")
        do { try jpeg.write(to: url, options: .atomic); return url } catch {
            NSLog("cache write failed: \(error)")
            return nil
        }
    }

    static func remove(for track: Track) {
        while let url = existing(for: track) { try? FileManager.default.removeItem(at: url) }
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

// MARK: - Artwork lookup

enum Artwork {
    private struct SearchResponse: Decodable {
        struct Item: Decodable {
            let collectionName: String?
            let artistName: String?
            let artworkUrl100: String?
        }
        let results: [Item]
    }

    /// Strips edition noise like "(Deluxe Edition)" or "- Single", plus punctuation, so titles compare
    /// loosely. Other qualifiers — "(Live From Webster Hall)", "(Instrumental)" — are kept, because
    /// those are different releases with different art.
    private static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        let edition = #"deluxe|edition|remaster|expanded|version|bonus|anniversary|explicit|clean|special|collector"#
        t = t.replacingOccurrences(of: #"[\(\[][^\)\]]*(?:"# + edition + #")[^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s-\s(single|ep)$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Asks the iTunes Search API for the album, then rewrites the 100px artwork URL to request the
    /// largest size Apple's CDN will give us. Returns image data, or nil if nothing matched.
    static func fetchHighRes(for track: Track) async -> Data? {
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            .init(name: "term", value: "\(track.artist) \(track.album)"),
            .init(name: "entity", value: "album"),
            .init(name: "limit", value: "15"),
        ]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(SearchResponse.self, from: data)
        else { return nil }

        let wantAlbum = normalize(track.album)
        let wantArtist = normalize(track.artist)

        let scored: [(score: Int, art: String)] = response.results.compactMap { item in
            guard let art = item.artworkUrl100, let name = item.collectionName else { return nil }
            let n = normalize(name)
            // Exact only: a fuzzy "contains" would let "Album (Live)" match the studio "Album".
            guard n == wantAlbum else { return nil }
            var score = 4
            let a = normalize(item.artistName ?? "")
            if a == wantArtist { score += 2 } else if a.contains(wantArtist) || wantArtist.contains(a) { score += 1 }
            return (score, art)
        }
        guard let best = scored.max(by: { $0.score < $1.score }) else { return nil }

        // Apple's CDN serves any size up to the original master; ask big, fall back gracefully.
        for size in ["3000x3000bb", "1400x1400bb", "600x600bb"] {
            let hi = best.art.replacingOccurrences(of: "100x100bb", with: size)
            guard let u = URL(string: hi),
                  let (img, resp) = try? await URLSession.shared.data(from: u),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  NSImage(data: img) != nil
            else { continue }
            return img
        }
        return nil
    }

    /// Re-encodes anything NSImage can read as a high-quality JPEG.
    static func jpeg(from data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95])
    }
}

// MARK: - Music.app

enum Music {
    static let bundleID = "com.apple.Music"

    /// Never `tell application "Music"` unless it's running — that would launch it.
    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    @MainActor
    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("AppleScript error: \(error)") }
        return result
    }

    @MainActor
    static func currentTrack() -> Track? {
        guard isRunning, let d = run("""
            tell application "Music"
                if player state is stopped then return {}
                set t to current track
                return {name of t, artist of t, album of t, album artist of t}
            end tell
            """), d.numberOfItems == 4 else { return nil }
        let f = (1...4).map { d.atIndex($0)?.stringValue ?? "" }
        return Track(name: f[0], artist: f[3].isEmpty ? f[1] : f[3], album: f[2])
    }

    /// Artwork embedded in the file/library — used when the store lookup finds nothing.
    @MainActor
    static func embeddedArtwork() -> Data? {
        guard isRunning else { return nil }
        return run(#"tell application "Music" to return data of artwork 1 of current track"#)?.data
    }
}

// MARK: - Wallpaper

enum Wallpaper {
    /// macOS caches wallpapers by path, so re-using one path after you edit the image would show
    /// the stale version. Instead every apply copies to a fresh filename and deletes the old copy.
    @MainActor
    static func apply(_ source: URL, fill: Bool) {
        let fm = FileManager.default
        let dest = ArtCache.live.appendingPathComponent("\(UUID().uuidString).\(source.pathExtension)")
        do { try fm.copyItem(at: source, to: dest) } catch {
            NSLog("copy failed: \(error)")
            return
        }

        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: fill,
        ]
        if !fill { options[.fillColor] = NSColor.black }

        for screen in NSScreen.screens {
            do { try NSWorkspace.shared.setDesktopImageURL(dest, for: screen, options: options) } catch {
                NSLog("setDesktopImageURL failed: \(error)")
            }
        }

        let old = (try? fm.contentsOfDirectory(at: ArtCache.live, includingPropertiesForKeys: nil)) ?? []
        for url in old where url != dest { try? fm.removeItem(at: url) }
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let nowPlayingItem = NSMenuItem(title: "Nothing playing", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Set Wallpaper from Music", action: #selector(toggleEnabled), keyEquivalent: "")
    private let fillItem = NSMenuItem(title: "Fill Screen (crop to fit)", action: #selector(toggleFill), keyEquivalent: "")
    private let editItem = NSMenuItem(title: "Edit Current Art in Preview", action: #selector(editCurrent), keyEquivalent: "e")
    private let pixelateItem = NSMenuItem(title: "Pixelate Current Art…", action: #selector(pixelateCurrent), keyEquivalent: "")
    private let redownloadItem = NSMenuItem(title: "Re-download Current Art (discards edits)", action: #selector(redownload), keyEquivalent: "")

    private var current: Track?
    private var appliedFile: URL?
    private var appliedModDate: Date?
    private var editWatcher: Timer?

    private var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "enabled") }
    }
    private var fill: Bool {
        get { UserDefaults.standard.bool(forKey: "fill") }
        set { UserDefaults.standard.set(newValue, forKey: "fill") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ArtCache.prepare()
        buildMenu()

        // Music posts this on every play/pause/track change — no polling needed.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo ?? [:]
            let state = info["Player State"] as? String ?? ""
            let name = info["Name"] as? String ?? ""
            let artist = info["Artist"] as? String ?? ""
            let albumArtist = info["Album Artist"] as? String ?? ""
            let album = info["Album"] as? String ?? ""
            MainActor.assumeIsolated {
                guard state != "Stopped", !album.isEmpty else { return }
                self?.trackChanged(Track(name: name, artist: albumArtist.isEmpty ? artist : albumArtist, album: album))
            }
        }

        // Newly plugged-in monitors get the wallpaper too.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapply() }
        }

        // Re-apply when you save an edit to the current album's image.
        editWatcher = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForEdits() }
        }
        editWatcher?.tolerance = 1  // lets the system coalesce these wakeups with others

        // Pick up whatever is already playing.
        if let track = Music.currentTrack() { trackChanged(track) }
    }

    // MARK: Menu

    private func buildMenu() {
        if let button = statusItem.button {
            // MenuBarIcon.png is 36px black-on-clear, shown at 18pt; as a template it follows the menu bar's light/dark tint.
            let glyph = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png").flatMap(NSImage.init(contentsOf:))
            glyph?.size = NSSize(width: 18, height: 18)
            glyph?.isTemplate = true
            button.image = glyph ?? NSImage(systemSymbolName: "music.note.tv", accessibilityDescription: "Album Art Wallpaper")
            button.image?.accessibilityDescription = "Album Art Wallpaper"
        }
        let menu = NSMenu()
        nowPlayingItem.isEnabled = false
        for item in [enabledItem, fillItem, editItem, pixelateItem, redownloadItem] { item.target = self }
        menu.addItem(nowPlayingItem)
        menu.addItem(.separator())
        menu.addItem(enabledItem)
        menu.addItem(fillItem)
        menu.addItem(.separator())
        menu.addItem(editItem)
        menu.addItem(pixelateItem)
        menu.addItem(redownloadItem)
        let reveal = NSMenuItem(title: "Reveal Cache in Finder", action: #selector(revealCache), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        refreshMenu()
    }

    private func refreshMenu() {
        enabledItem.state = enabled ? .on : .off
        fillItem.state = fill ? .on : .off
        if let t = current {
            nowPlayingItem.title = "♪ \(t.name) — \(t.artist)"
        } else {
            nowPlayingItem.title = "Nothing playing"
        }
        editItem.isEnabled = appliedFile != nil
        pixelateItem.isEnabled = appliedFile != nil
        redownloadItem.isEnabled = current != nil
    }

    // MARK: Actions

    @objc private func toggleEnabled() {
        enabled.toggle()
        refreshMenu()
        if enabled { reapply(forceLookup: true) }
    }

    @objc private func toggleFill() {
        fill.toggle()
        refreshMenu()
        reapply()
    }

    @objc private func editCurrent() {
        guard let file = appliedFile else { return }
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        NSWorkspace.shared.open([file], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func pixelateCurrent() {
        guard let track = current, let file = appliedFile else { return }

        let alert = NSAlert()
        alert.messageText = "Pixelate this album art?"
        alert.informativeText = "This replaces the cached image for “\(track.album)” with a chunky pixelated version. "
            + "“Re-download Current Art” brings the original back."
        alert.addButton(withTitle: "Pixelate")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)  // menu bar apps aren't frontmost; otherwise the alert hides behind other windows
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let jpeg = Censor.pixelate(file), let saved = ArtCache.save(jpeg, for: track) else {
            NSLog("pixelate failed for \(track.cacheKey)")
            return
        }
        // If the edited file was a .png/.heic, drop it so the pixelated .jpg is the only copy.
        if file != saved { try? FileManager.default.removeItem(at: file) }
        display(saved)
    }

    @objc private func redownload() {
        guard let track = current else { return }
        ArtCache.remove(for: track)
        appliedFile = nil
        loadArt(for: track)
    }

    @objc private func revealCache() {
        if let file = appliedFile {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(ArtCache.dir)
        }
    }

    // MARK: Track handling

    private func trackChanged(_ track: Track) {
        guard track != current else { return }
        current = track
        appliedFile = nil
        refreshMenu()
        if enabled { loadArt(for: track) }
    }

    private func reapply(forceLookup: Bool = false) {
        if let file = appliedFile {
            display(file)
        } else if forceLookup, let track = current {
            loadArt(for: track)
        }
    }

    /// Cache hit → apply immediately. Miss → download high-res art, falling back to Music's embedded art.
    private func loadArt(for track: Track) {
        if let cached = ArtCache.existing(for: track) {
            display(cached)
            return
        }
        Task {
            var jpeg: Data?
            if let data = await Artwork.fetchHighRes(for: track) { jpeg = Artwork.jpeg(from: data) }
            if jpeg == nil, current == track, let data = Music.embeddedArtwork() { jpeg = Artwork.jpeg(from: data) }

            guard let jpeg, let file = ArtCache.save(jpeg, for: track) else {
                NSLog("no artwork found for \(track.cacheKey)")
                return
            }
            // The song may have changed while we were downloading; the file is cached either way.
            if current == track { display(file) }
        }
    }

    private func display(_ file: URL) {
        appliedFile = file
        appliedModDate = ArtCache.modificationDate(file)
        Wallpaper.apply(file, fill: fill)
        refreshMenu()
    }

    private func checkForEdits() {
        guard enabled, let track = current else { return }
        // Handles both in-place saves and an edit re-saved as a different format (e.g. .png).
        guard let file = ArtCache.existing(for: track) else { return }
        if file != appliedFile || ArtCache.modificationDate(file) != appliedModDate {
            display(file)
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

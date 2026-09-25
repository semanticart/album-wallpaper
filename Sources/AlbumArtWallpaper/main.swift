import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

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

// MARK: - Debug log
//
// Appends to ~/Library/Application Support/AlbumArtWallpaper/debug.log (also NSLog). Trimmed to
// its newest half whenever it passes 512 KB, so it can stay on forever.

enum DebugLog {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AlbumArtWallpaper/debug.log")
    private static let queue = DispatchQueue(label: "debuglog")
    private static let maxBytes = 512 * 1024
    nonisolated(unsafe) private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f
    }()

    static func log(_ message: String) {
        NSLog("%@", message)
        queue.async {
            let line = "\(stamp.string(from: Date())) \(message)\n"
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes,
               let data = try? Data(contentsOf: url) {
                let tail = data.suffix(maxBytes / 2)
                let start = tail.firstIndex(of: 0x0A).map { tail.index(after: $0) } ?? tail.startIndex
                try? Data(tail[start...]).write(to: url, options: .atomic)
            }
        }
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
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

    private struct DeezerResponse: Decodable {
        struct Album: Decodable {
            struct Artist: Decodable { let name: String }
            let title: String
            let artist: Artist
            let cover_xl: String?
            let cover_big: String?
        }
        let data: [Album]
    }

    private struct LookupFailure: Error { let reason: String }

    private enum Outcome {
        case hit(Data)
        case miss(String)
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

    /// Exact album match only: a fuzzy "contains" would let "Album (Live)" match the studio "Album".
    /// The artist must match too — same-titled albums/singles by unrelated artists are common
    /// (e.g. "Blinding Lights - Single" exists for The Weeknd, The Naked and Famous, etc.), and
    /// matching on title alone would happily hand back the wrong artist's cover.
    /// Returns 6 for an exact artist match, 5 for a partial one, nil for no match.
    private static func matchScore(album: String, artist: String, for track: Track) -> Int? {
        guard normalize(album) == normalize(track.album) else { return nil }
        let a = normalize(artist), want = normalize(track.artist)
        if a == want { return 6 }
        if a.contains(want) || want.contains(a) { return 5 }
        return nil
    }

    /// Tries each source in order and returns the first image, appending one entry per source tried
    /// to `chain` (e.g. "iTunes album ✗ no results", "Deezer ✓ 212345 bytes") for the debug log.
    static func fetchHighRes(for track: Track, chain: inout [String]) async -> Data? {
        let sources: [(name: String, fetch: (Track) async -> Outcome)] = [
            ("iTunes album", { await itunes(track: $0, entity: "album") }),
            ("iTunes song", { await itunes(track: $0, entity: "song") }),
            ("Deezer", { await deezer(track: $0) }),
        ]
        for source in sources {
            switch await source.fetch(track) {
            case .hit(let data):
                chain.append("\(source.name) ✓ \(data.count) bytes")
                return data
            case .miss(let why):
                chain.append("\(source.name) ✗ \(why)")
            }
        }
        return nil
    }

    private static func getJSON<T: Decodable>(_ url: URL, as type: T.Type) async -> Result<T, LookupFailure> {
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            DebugLog.log("GET \(url.absoluteString) → HTTP \(status), \(data.count) bytes")
            guard status == 200 else { return .failure(.init(reason: "HTTP \(status)")) }
            do { return .success(try JSONDecoder().decode(T.self, from: data)) } catch {
                DebugLog.log("decode failed: \(error); body: \(String(decoding: data.prefix(200), as: UTF8.self))")
                return .failure(.init(reason: "bad response"))
            }
        } catch {
            DebugLog.log("GET \(url.absoluteString) failed: \(error)")
            return .failure(.init(reason: "request failed (\(error.localizedDescription))"))
        }
    }

    /// Downloads the first candidate URL that returns a decodable image.
    private static func download(_ candidates: [String]) async -> Data? {
        for candidate in candidates {
            guard let u = URL(string: candidate) else { continue }
            do {
                let (img, resp) = try await URLSession.shared.data(from: u)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                guard status == 200, NSImage(data: img) != nil else {
                    DebugLog.log("image \(candidate) unusable: HTTP \(status), \(img.count) bytes")
                    continue
                }
                DebugLog.log("image \(candidate) downloaded: \(img.count) bytes")
                return img
            } catch {
                DebugLog.log("image \(candidate) request failed: \(error)")
            }
        }
        return nil
    }

    /// Asks the iTunes Search API (for albums, or for songs and reading the album off each hit — this
    /// finds releases the album search ranks poorly or misses), then rewrites the 100px artwork URL to
    /// request the largest size Apple's CDN will give us.
    private static func itunes(track: Track, entity: String) async -> Outcome {
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        let term = entity == "song" ? "\(track.artist) \(track.name)" : "\(track.artist) \(track.album)"
        comps.queryItems = [
            .init(name: "term", value: term),
            .init(name: "entity", value: entity),
            .init(name: "limit", value: entity == "song" ? "25" : "15"),
        ]
        guard let url = comps.url else { return .miss("bad URL") }
        let response: SearchResponse
        switch await getJSON(url, as: SearchResponse.self) {
        case .success(let r): response = r
        case .failure(let failure): return .miss(failure.reason)
        }
        if response.results.isEmpty { return .miss("no results") }

        let scored: [(score: Int, art: String)] = response.results.compactMap { item in
            guard let art = item.artworkUrl100, let name = item.collectionName,
                  let score = matchScore(album: name, artist: item.artistName ?? "", for: track)
            else { return nil }
            return (score, art)
        }
        guard let best = scored.max(by: { $0.score < $1.score }) else {
            let seen = response.results.prefix(3).map { "\($0.artistName ?? "?") — \($0.collectionName ?? "?")" }
            DebugLog.log("iTunes \(entity): none of \(response.results.count) results matched album=\"\(normalize(track.album))\" artist=\"\(normalize(track.artist))\"; first: \(seen)")
            return .miss("\(response.results.count) results, none matched")
        }

        // Apple's CDN serves any size up to the original master; ask big, fall back gracefully.
        let sizes = ["3000x3000bb", "1400x1400bb", "600x600bb"]
        if let img = await download(sizes.map { best.art.replacingOccurrences(of: "100x100bb", with: $0) }) {
            return .hit(img)
        }
        return .miss("matched but image download failed")
    }

    /// Deezer's public search needs no key and serves 1000px covers.
    private static func deezer(track: Track) async -> Outcome {
        var comps = URLComponents(string: "https://api.deezer.com/search/album")!
        comps.queryItems = [
            .init(name: "q", value: "artist:\"\(track.artist)\" album:\"\(track.album)\""),
            .init(name: "limit", value: "15"),
        ]
        guard let url = comps.url else { return .miss("bad URL") }
        let response: DeezerResponse
        switch await getJSON(url, as: DeezerResponse.self) {
        case .success(let r): response = r
        case .failure(let failure): return .miss(failure.reason)
        }
        if response.data.isEmpty { return .miss("no results") }

        let scored: [(score: Int, art: [String])] = response.data.compactMap { item in
            guard let score = matchScore(album: item.title, artist: item.artist.name, for: track) else { return nil }
            return (score, [item.cover_xl, item.cover_big].compactMap { $0 })
        }
        guard let best = scored.max(by: { $0.score < $1.score }) else {
            let seen = response.data.prefix(3).map { "\($0.artist.name) — \($0.title)" }
            DebugLog.log("Deezer: none of \(response.data.count) results matched; first: \(seen)")
            return .miss("\(response.data.count) results, none matched")
        }
        if let img = await download(best.art) { return .hit(img) }
        return .miss("matched but image download failed")
    }

    /// Re-encodes anything NSImage can read as a high-quality progressive JPEG.
    /// Progressive JFIF encoding runs noticeably smaller than baseline at the same
    /// quality with no visual cost, which adds up across a large art cache.
    static func jpeg(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true],
        ]
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
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
        if let error { DebugLog.log("AppleScript error: \(error)") }
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
        guard isRunning else {
            DebugLog.log("embedded artwork: Music not running")
            return nil
        }
        let data = run(#"tell application "Music" to return data of artwork 1 of current track"#)?.data
        DebugLog.log("embedded artwork: \(data.map { "\($0.count) bytes" } ?? "none")")
        return data
    }
}

// MARK: - Wallpaper

enum Wallpaper {
    /// macOS caches wallpapers by path, so re-using one path after you edit the image would show
    /// the stale version. Instead every apply copies to a fresh filename and deletes the old copy.
    @MainActor
    static func apply(_ source: URL, fill: Bool, to screens: [NSScreen]) {
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

        for screen in screens {
            do { try NSWorkspace.shared.setDesktopImageURL(dest, for: screen, options: options) } catch {
                NSLog("setDesktopImageURL failed: \(error)")
            }
        }

        // Excluded screens keep pointing at whatever Live/ file they were last set to, so it must
        // survive this cleanup — only reap files no screen (included or not) still references.
        let stillReferenced = Set(NSScreen.screens.compactMap { NSWorkspace.shared.desktopImageURL(for: $0) } + [dest])
        let old = (try? fm.contentsOfDirectory(at: ArtCache.live, includingPropertiesForKeys: nil)) ?? []
        for url in old where !stillReferenced.contains(url) { try? fm.removeItem(at: url) }
    }
}

// MARK: - Monitors

/// Which screens get the wallpaper. Screens are identified by `localizedName` — the closest thing
/// to a stable handle NSScreen offers across reconnects/reboots (displayID can reassign). Two
/// monitors that happen to share a name will opt out together; that's an acceptable rough edge.
enum Monitors {
    static var excluded: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "excludedScreens") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "excludedScreens") }
    }

    static func included(from screens: [NSScreen]) -> [NSScreen] {
        let excluded = excluded
        return screens.filter { !excluded.contains($0.localizedName) }
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let nowPlayingItem = NSMenuItem(title: "Nothing playing", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Set Wallpaper from Music", action: #selector(toggleEnabled), keyEquivalent: "")
    private let fillItem = NSMenuItem(title: "Fill Screen (crop to fit)", action: #selector(toggleFill), keyEquivalent: "")
    private let monitorsItem = NSMenuItem(title: "Monitors", action: nil, keyEquivalent: "")
    private let editItem = NSMenuItem(title: "Edit Current Art in Preview", action: #selector(editCurrent), keyEquivalent: "e")
    private let pixelateItem = NSMenuItem(title: "Pixelate Current Art…", action: #selector(pixelateCurrent), keyEquivalent: "")
    private let redownloadItem = NSMenuItem(title: "Re-download Current Art (discards edits)", action: #selector(redownload), keyEquivalent: "")
    private let updateAvailableItem = NSMenuItem(title: "Update Available", action: #selector(checkForUpdatesNow), keyEquivalent: "")
    private let checkForUpdatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesNow), keyEquivalent: "")
    private let checkForUpdatesToggleItem = NSMenuItem(title: "Automatically Check for Updates", action: #selector(toggleCheckForUpdates), keyEquivalent: "")
    private let installUpdatesAutomaticallyItem = NSMenuItem(title: "Install Updates Automatically", action: #selector(toggleInstallUpdatesAutomatically), keyEquivalent: "")

    private let updater = Updater()

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
    private var checkForUpdates: Bool {
        get { UserDefaults.standard.object(forKey: "checkForUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "checkForUpdates") }
    }
    private var installUpdatesAutomatically: Bool {
        get { UserDefaults.standard.object(forKey: "installUpdatesAutomatically") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "installUpdatesAutomatically") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ArtCache.prepare()
        DebugLog.log("launched version \(DebugLog.versionString), macOS \(ProcessInfo.processInfo.operatingSystemVersionString), enabled=\(enabled)")

        // Before the menu is built, so it can offer "Check for Updates".
        updater.start()
        updater.setAutomaticallyChecksForUpdates(checkForUpdates)
        updater.setAutomaticallyDownloadsUpdates(installUpdatesAutomatically)
        updater.onAvailableVersionChanged = { [weak self] in self?.refreshMenu() }

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
                DebugLog.log("playerInfo: state=\"\(state)\" name=\"\(name)\" artist=\"\(artist)\" albumArtist=\"\(albumArtist)\" album=\"\(album)\"")
                guard state != "Stopped", !album.isEmpty else {
                    DebugLog.log("playerInfo ignored (stopped or empty album)")
                    return
                }
                self?.trackChanged(Track(name: name, artist: albumArtist.isEmpty ? artist : albumArtist, album: album))
            }
        }

        // Newly plugged-in monitors get the wallpaper too, and show up in the Monitors submenu.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reapply()
                self?.refreshMenu()
            }
        }

        // Re-apply when you save an edit to the current album's image.
        editWatcher = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForEdits() }
        }
        editWatcher?.tolerance = 1  // lets the system coalesce these wakeups with others

        // Pick up whatever is already playing.
        if let track = Music.currentTrack() {
            trackChanged(track)
        } else {
            DebugLog.log("startup: no current track (Music not running, stopped, or Automation denied)")
        }
    }

    // MARK: Menu

    private func buildMenu() {
        if let button = statusItem.button {
            // MenuBarIcon.png is 36px black-on-clear, shown at 22pt; as a template it follows the menu bar's light/dark tint.
            let glyph = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png").flatMap(NSImage.init(contentsOf:))
            glyph?.size = NSSize(width: 22, height: 22)
            glyph?.isTemplate = true
            button.image = glyph ?? NSImage(systemSymbolName: "music.note.tv", accessibilityDescription: "Album Art Wallpaper")
            button.image?.accessibilityDescription = "Album Art Wallpaper"
        }
        let menu = NSMenu()
        nowPlayingItem.isEnabled = false
        let targeted = [
            enabledItem, fillItem, editItem, pixelateItem, redownloadItem,
            updateAvailableItem, checkForUpdatesItem, checkForUpdatesToggleItem, installUpdatesAutomaticallyItem,
        ]
        for item in targeted { item.target = self }
        menu.addItem(nowPlayingItem)
        menu.addItem(.separator())
        menu.addItem(enabledItem)
        menu.addItem(fillItem)
        monitorsItem.submenu = NSMenu()
        menu.addItem(monitorsItem)
        menu.addItem(.separator())
        menu.addItem(editItem)
        menu.addItem(pixelateItem)
        menu.addItem(redownloadItem)
        let reveal = NSMenuItem(title: "Reveal Cache in Finder", action: #selector(revealCache), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        let showLog = NSMenuItem(title: "Show Debug Log", action: #selector(showDebugLog), keyEquivalent: "")
        showLog.target = self
        menu.addItem(showLog)
        menu.addItem(.separator())
        menu.addItem(updateAvailableItem)
        menu.addItem(checkForUpdatesItem)
        menu.addItem(checkForUpdatesToggleItem)
        menu.addItem(installUpdatesAutomaticallyItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        refreshMenu()
    }

    private func refreshMenu() {
        enabledItem.state = enabled ? .on : .off
        fillItem.state = fill ? .on : .off
        rebuildMonitorsMenu()
        if let t = current {
            nowPlayingItem.title = "♪ \(t.name) — \(t.artist)"
        } else {
            nowPlayingItem.title = "Nothing playing"
        }
        editItem.isEnabled = appliedFile != nil
        pixelateItem.isEnabled = appliedFile != nil
        redownloadItem.isEnabled = current != nil

        if let version = updater.availableVersion {
            updateAvailableItem.title = "Update Available — \(version)…"
            updateAvailableItem.isHidden = false
        } else {
            updateAvailableItem.isHidden = true
        }
        checkForUpdatesItem.isHidden = !updater.isActive
        checkForUpdatesToggleItem.isHidden = !updater.isActive
        checkForUpdatesToggleItem.state = checkForUpdates ? .on : .off
        installUpdatesAutomaticallyItem.isHidden = !updater.isActive
        installUpdatesAutomaticallyItem.state = installUpdatesAutomatically ? .on : .off
        installUpdatesAutomaticallyItem.isEnabled = checkForUpdates
    }

    /// Every screen, checked by default; unchecking one opts it out of future wallpaper applies.
    private func rebuildMonitorsMenu() {
        let screens = NSScreen.screens
        let excluded = Monitors.excluded
        let submenu = NSMenu()
        for screen in screens {
            let item = NSMenuItem(title: screen.localizedName, action: #selector(toggleMonitor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = screen.localizedName
            item.state = excluded.contains(screen.localizedName) ? .off : .on
            submenu.addItem(item)
        }
        monitorsItem.submenu = submenu
        monitorsItem.isHidden = screens.count < 2
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

    @objc private func toggleMonitor(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var excluded = Monitors.excluded
        if excluded.contains(name) { excluded.remove(name) } else { excluded.insert(name) }
        Monitors.excluded = excluded
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

    @objc private func showDebugLog() {
        if !FileManager.default.fileExists(atPath: DebugLog.url.path) {
            try? Data().write(to: DebugLog.url)
        }
        NSWorkspace.shared.open(DebugLog.url)
    }

    @objc private func checkForUpdatesNow() {
        updater.checkForUpdates()
    }

    @objc private func toggleCheckForUpdates() {
        checkForUpdates.toggle()
        updater.setAutomaticallyChecksForUpdates(checkForUpdates)
        refreshMenu()
    }

    @objc private func toggleInstallUpdatesAutomatically() {
        installUpdatesAutomatically.toggle()
        updater.setAutomaticallyDownloadsUpdates(installUpdatesAutomatically)
        refreshMenu()
    }

    // MARK: Track handling

    private func trackChanged(_ track: Track) {
        guard track != current else { return }
        DebugLog.log("track changed: \(track.name) — \(track.cacheKey); enabled=\(enabled)")
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
            DebugLog.log("cache hit: \(cached.lastPathComponent)")
            display(cached)
            return
        }
        Task {
            var chain: [String] = []
            var jpeg: Data?
            if let data = await Artwork.fetchHighRes(for: track, chain: &chain) {
                jpeg = Artwork.jpeg(from: data)
                if jpeg == nil { chain.append("JPEG re-encode ✗") }
            }
            if jpeg == nil {
                if current != track {
                    chain.append("Music embedded ✗ skipped (track changed)")
                } else if let data = Music.embeddedArtwork() {
                    jpeg = Artwork.jpeg(from: data)
                    chain.append(jpeg == nil ? "Music embedded ✗ re-encode failed" : "Music embedded ✓ \(data.count) bytes")
                } else {
                    chain.append("Music embedded ✗ none")
                }
            }
            let summary = chain.joined(separator: " → ")

            guard let jpeg, let file = ArtCache.save(jpeg, for: track) else {
                DebugLog.log("art resolution for \(track.cacheKey): \(summary) — NOTHING FOUND")
                return
            }
            DebugLog.log("art resolution for \(track.cacheKey): \(summary)")
            // The song may have changed while we were downloading; the file is cached either way.
            if current == track { display(file) }
        }
    }

    private func display(_ file: URL) {
        appliedFile = file
        appliedModDate = ArtCache.modificationDate(file)
        Wallpaper.apply(file, fill: fill, to: Monitors.included(from: NSScreen.screens))
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

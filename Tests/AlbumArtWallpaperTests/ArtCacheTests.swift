import XCTest
@testable import AlbumArtWallpaper

final class ArtCacheTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func cache(_ artist: String, _ album: String, ext: String = "jpg") {
        let track = Track(name: "", artist: artist, album: album)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("\(track.cacheKey).\(ext)").path, contents: Data())
    }

    private func canonical(_ artist: String, _ album: String) -> Track {
        ArtCache.canonical(Track(name: "song", artist: artist, album: album), in: dir)
    }

    func testCollabTrackResolvesToPlainArtistEntry() {
        cache("WHIPPED CREAM", "HOME WAS ALWAYS ME")
        let t = canonical("WHIPPED CREAM & No/Me", "HOME WAS ALWAYS ME")
        XCTAssertEqual(t.artist, "WHIPPED CREAM")
        XCTAssertEqual(t.name, "song")
        XCTAssertEqual(ArtCache.existing(for: t, in: dir)?.lastPathComponent, "WHIPPED CREAM - HOME WAS ALWAYS ME.jpg")
    }

    func testPlainTrackResolvesToCollabEntry() {
        cache("WHIPPED CREAM & No/Me", "HOME WAS ALWAYS ME")
        XCTAssertEqual(canonical("WHIPPED CREAM", "HOME WAS ALWAYS ME").artist, "WHIPPED CREAM & No_Me")
    }

    func testExactMatchWins() {
        cache("WHIPPED CREAM", "HOME WAS ALWAYS ME")
        cache("WHIPPED CREAM & No/Me", "HOME WAS ALWAYS ME")
        XCTAssertEqual(canonical("WHIPPED CREAM & No/Me", "HOME WAS ALWAYS ME").artist, "WHIPPED CREAM & No/Me")
    }

    func testMatchIgnoresCaseAndKeepsCachedCasing() {
        cache("Whipped Cream", "Home Was Always Me")
        XCTAssertEqual(canonical("WHIPPED CREAM feat. Someone", "HOME WAS ALWAYS ME").artist, "Whipped Cream")
    }

    func testOtherSeparators() {
        for sep in [", ", " feat. ", " ft. ", " x ", " and ", " with "] {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            cache("Artist", "Album")
            XCTAssertEqual(canonical("Artist\(sep)Guest", "Album").artist, "Artist", "separator \(sep)")
        }
    }

    func testDifferentAlbumDoesNotMatch() {
        cache("WHIPPED CREAM", "OTHER ALBUM")
        XCTAssertEqual(canonical("WHIPPED CREAM & No/Me", "HOME WAS ALWAYS ME").artist, "WHIPPED CREAM & No/Me")
    }

    func testUnrelatedArtistSameAlbumDoesNotMatch() {
        cache("Metallica", "Greatest Hits")
        XCTAssertEqual(canonical("Abba", "Greatest Hits").artist, "Abba")
    }

    func testArtistThatMerelyStartsWithSameLettersDoesNotMatch() {
        cache("Sim", "Bookends")
        XCTAssertEqual(canonical("Simon & Garfunkel", "Bookends").artist, "Simon & Garfunkel")
    }

    func testAlbumSuffixOfLongerAlbumDoesNotMatch() {
        cache("Artist", "Live Album")
        XCTAssertEqual(canonical("Artist & Guest", "Album").artist, "Artist & Guest")
    }

    func testEditedFileInOtherFormatIsFound() {
        cache("WHIPPED CREAM", "HOME WAS ALWAYS ME", ext: "png")
        XCTAssertEqual(canonical("WHIPPED CREAM & No/Me", "HOME WAS ALWAYS ME").artist, "WHIPPED CREAM")
    }

    func testNoCacheLeavesTrackUnchanged() {
        let t = Track(name: "song", artist: "A & B", album: "C")
        XCTAssertEqual(ArtCache.canonical(t, in: dir), t)
    }

    func testSlashSeparatedCreditsMatch() {
        cache("Artist", "Album")
        XCTAssertEqual(canonical("Artist / Guest", "Album").artist, "Artist")
    }

    func testTwoCollabFormsOfSameArtistDoNotMatchEachOther() {
        // Known limitation: only prefix aliasing, so "A & B" and "A & C" stay separate.
        cache("A & B", "Album")
        XCTAssertEqual(canonical("A & C", "Album").artist, "A & C")
    }

    func testRealDuoNameAliasesOnlyWhenSoloEntryHasSameAlbum() {
        cache("Simon", "Bookends")
        XCTAssertEqual(canonical("Simon & Garfunkel", "Bookends").artist, "Simon")
        XCTAssertEqual(canonical("Simon & Garfunkel", "Sounds of Silence").artist, "Simon & Garfunkel")
    }

    func testAlbumContainingDashIsMatched() {
        cache("Artist", "Part 1 - The Beginning")
        XCTAssertEqual(canonical("Artist & Guest", "Part 1 - The Beginning").artist, "Artist")
    }

    func testAlbumWithSlashIsMatched() {
        cache("Artist", "AC/DC Tribute")
        XCTAssertEqual(canonical("Artist & Guest", "AC/DC Tribute").artist, "Artist")
    }
}

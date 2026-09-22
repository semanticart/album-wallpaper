// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AlbumArtWallpaper",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Sparkle drives in-app updates: it checks the appcast the Release
        // workflow publishes, verifies the DMG's EdDSA signature, and swaps
        // the bundle in place. Ships as a prebuilt xcframework.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")
    ],
    targets: [
        .executableTarget(
            name: "AlbumArtWallpaper",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/AlbumArtWallpaper",
            // Sparkle.framework lives in Contents/Frameworks of the .app that
            // `make app` assembles; this rpath is how the binary finds it
            // there. SwiftPM adds its own rpath to the downloaded artifact,
            // which keeps `swift run` and `swift test` working.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)

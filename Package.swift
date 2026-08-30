// swift-tools-version: 6.0
import PackageDescription

// One executable, and no package dependencies at all. The archived package declared an AppAuth
// dependency for Google sign-in; this app owns that flow instead (`GoogleOAuthRules` says why), so
// nothing is fetched to build it. AppKit is linked explicitly below; CoreBluetooth and CryptoKit
// come in through `import` alone, being system frameworks the toolchain resolves without help.
//
// `Archive/` holds the previous implementation and is deliberately outside every target path, so
// nothing in it is compiled while remaining readable and `git log --follow`-able.
let package = Package(
    name: "FacetApp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "FacetApp",
            targets: ["FacetApp"]
        )
    ],
    targets: [
        .executableTarget(
            name: "FacetApp",
            path: "Sources/FacetApp",
            exclude: [
                // Carried across with the icon itself: Swift Bundler copies AppIcon.icns into the
                // bundle from Bundler.toml, so processing it here as well would ship two copies.
                // (The archived package excluded it for exactly this reason.)
                "Resources/AppIcon.icns",
                // Documentation living beside the schema it describes, not something to ship inside
                // the app. `database/` at the repository root is a symlink to this directory, which
                // is why the docs are here at all: one set of files, reachable by the short path
                // every script and doc already uses.
                "Resources/Database/CLAUDE.md",
                "Resources/Database/ER-diagram.md"
            ],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                // The menu bar item lives in AppKit. Linked from the step that introduced it, not
                // carried forward from the archived package on the assumption it would be needed.
                .linkedFramework("AppKit")
            ]
        ),
        .testTarget(
            name: "FacetAppTests",
            dependencies: ["FacetApp"]
        )
    ]
)

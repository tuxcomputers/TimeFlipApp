// swift-tools-version: 6.0
import PackageDescription

// Pared back to what the rebuild currently is: one executable that brings the database up and
// exits. The archived package declared an AppAuth dependency and linked AppKit and CoreBluetooth;
// each of those comes back with the module that needs it (Google integration, the menu bar, the
// device), rather than being carried forward on the assumption that it will.
//
// `Archive/` holds the previous implementation and is deliberately outside every target path, so
// nothing in it is compiled while remaining readable and `git log --follow`-able.
let package = Package(
    name: "TimeFlipApp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "TimeFlipApp",
            targets: ["TimeFlipApp"]
        )
    ],
    targets: [
        .executableTarget(
            name: "TimeFlipApp",
            path: "Sources/TimeFlipApp",
            exclude: [
                // Documentation living beside the schema it describes, not something to ship inside
                // the app. `database/` at the repository root is a symlink to this directory, which
                // is why the docs are here at all: one set of files, reachable by the short path
                // every script and doc already uses.
                "Resources/Database/CLAUDE.md",
                "Resources/Database/ER-diagram.md"
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "TimeFlipAppTests",
            dependencies: ["TimeFlipApp"]
        )
    ]
)

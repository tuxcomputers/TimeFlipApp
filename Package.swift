// swift-tools-version: 6.0
import PackageDescription

// One executable, and no package dependencies at all. The archived package declared an AppAuth
// dependency for Google sign-in; this app owns that flow instead (`GoogleOAuthRules` says why), so
// nothing is fetched to build it. AppKit is linked explicitly below; CoreBluetooth and CryptoKit
// come in through `import` alone, being system frameworks the toolchain resolves without help.
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
        // The half that does not know what a window is: the stores, the rules, the database and the
        // device protocol. It links no UI framework, which is the property worth protecting -- adding
        // an `import AppKit` to a file in here stops compiling on Linux, and the compiler says so at
        // the point somebody does it rather than at the port.
        .target(
            name: "FacetCore",
            path: "Sources/FacetCore",
            exclude: [
                // Documentation living beside the schema it describes, not something to ship inside
                // the app. `Resources/Database` is a symlink to `database/` at the repository root,
                // which is the real directory: the schema is shared and neither platform owns it,
                // and SwiftPM requires a target's resources to sit inside the target.
                "Resources/Database/CLAUDE.md",
                "Resources/Database/ER-diagram.md"
            ],
            resources: [
                // The DDL travels with `DatabaseBootstrap`, which reads it through `Bundle.module`.
                // That accessor is per-target, so leaving the schema behind in FacetApp would have it
                // resolve to a bundle the DDL is not in.
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "FacetApp",
            dependencies: ["FacetCore"],
            path: "Sources/FacetApp",
            exclude: [
                // Carried across with the icon itself: Swift Bundler copies AppIcon.icns into the
                // bundle from Bundler.toml, so processing it here as well would ship two copies.
                // (The archived package excluded it for exactly this reason.)
                "Resources/AppIcon.icns"
            ],
            resources: [
                // The icons `ActivityIcon` draws and the Google client `GoogleOAuthClient` reads.
                // Both are read by files that stay on this side, so they stay with them.
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
            dependencies: ["FacetApp", "FacetCore"]
        )
    ]
)

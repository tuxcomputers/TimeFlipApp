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
        // **The system SQLite, for Linux only.** Darwin ships `SQLite3` as an SDK module and this target
        // is deliberately kept out of the build graph there -- `FacetCore` and the test target depend on
        // it `.when(platforms: [.linux])`, so a macOS build resolves `import SQLite3` exactly as it
        // always has and never has two modules of one name to choose between.
        //
        // **Named after the module it stands in for, so no source file branches on the platform.** The
        // four files in `FacetCore` that talk to sqlite, and the four test files that do, all say
        // `import SQLite3` on both platforms. A shim under a different name would have meant a
        // `#if canImport` at the top of eight files to buy nothing.
        //
        // `libsqlite3-dev` is what provides the header and the unversioned `.so`; `providers` says so, so
        // a machine without it is told what to install rather than left with a header error. Installing it
        // is **not** on its own enough, which is the thing worth knowing here: the Swift toolchain ships
        // no `SQLite3` module for Linux, so the modulemap is required whether or not the package is there
        // (measured 2026-09-07 -- `import SQLite3` failed identically before and after installing it).
        .systemLibrary(
            name: "SQLite3",
            path: "Sources/SQLite3",
            pkgConfig: "sqlite3",
            providers: [
                .apt(["libsqlite3-dev"])
            ]
        ),
        // The half that does not know what a window is: the stores, the rules, the database and the
        // device protocol. It links no UI framework, which is the property worth protecting -- adding
        // an `import AppKit` to a file in here stops compiling on Linux, and the compiler says so at
        // the point somebody does it rather than at the port.
        .target(
            name: "FacetCore",
            dependencies: [
                .target(name: "SQLite3", condition: .when(platforms: [.linux]))
            ],
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
            dependencies: [
                "FacetApp",
                "FacetCore",
                // Four test files open a database with the C API directly. A Swift module is not
                // re-exported by the module that depends on it, so importing `FacetCore` does not hand
                // them `SQLite3` -- the test target needs it in its own right, on the same condition.
                .target(name: "SQLite3", condition: .when(platforms: [.linux]))
            ]
        )
    ]
)

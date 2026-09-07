// swift-tools-version: 6.0
import PackageDescription

// One executable, and no package dependencies at all. The archived package declared an AppAuth
// dependency for Google sign-in; this app owns that flow instead (`GoogleOAuthRules` says why), so
// nothing is fetched to build it. AppKit is linked explicitly below; CoreBluetooth comes in through
// `import` alone, being a system framework the toolchain resolves without help.

// MARK: - what each platform builds

// **The two platforms get different graphs, and the host decides which**, rather than every difference
// being a `.when(platforms:)` condition. That is not a stylistic preference: SwiftPM resolves a target
// dependency by *name* before it applies any condition, so naming a target this platform does not
// declare makes it hunt for sources that are not there and fail the whole manifest. Choosing the lists
// wholesale means each platform mentions only what it has.
//
// **The macOS side of every pair below is exactly what this manifest said before Linux existed in it**:
// `FacetCore` with no dependencies, the tests against `FacetApp` and `FacetCore`, the executable
// product, and no `SQLite3` target anywhere.
#if os(Linux)
let coreDependencies: [Target.Dependency] = ["SQLite3"]
// Four test files open a database with the C API directly, and a Swift module is not re-exported by
// whatever depends on it -- so importing `FacetCore` does not hand them `SQLite3`, and they need it in
// their own right.
let testDependencies: [Target.Dependency] = ["FacetCore", "SQLite3"]
#else
let coreDependencies: [Target.Dependency] = []
let testDependencies: [Target.Dependency] = ["FacetApp", "FacetCore"]
#endif

// MARK: - the test files Linux cannot run yet

// **A record of what the port has not reached, not a design.** It is meant to shrink, and the day it is
// empty it goes away along with the `exclude:` that reads it. Empty on macOS, where the whole suite runs.
//
// **Why a list rather than a `#if` inside each file.** On Linux SwiftPM builds one test executable for
// the whole package, so a file that will not compile takes every other test down with it -- and an
// `@MainActor` XCTestCase does worse, aborting the run at load time however well everything else
// behaves. A file that cannot run has to be absent from the build rather than inert within it.

// **Needs AppKit, CoreBluetooth or a `FacetApp` type**, so it waits on items 9, 10 and 11 of
// `docs/linux-port.md`: the OAuth listener, the BlueZ radio, and a UI. 48 files.
let platformBoundTests = [
    "ActivityIconTests.swift",
    "AppSettingsPaneTests.swift",
    "AutoPauseSettlesBeforeItIsSentTests.swift",
    "BLETraceTests.swift",
    "CategoryCreateControlTests.swift",
    "CategoryListViewTests.swift",
    "CategoryTableTests.swift",
    "ClickLandsOnTheCubesFaceTests.swift",
    "CollapsibleSectionTests.swift",
    "ColourListTests.swift",
    "CreateStartsTimingTests.swift",
    "CubeFirstReadingTests.swift",
    "CubeNotFoundOfferTests.swift",
    "DeviceEventRecorderTests.swift",
    "DeviceLoginRulesTests.swift",
    "DevicePaneTests.swift",
    "DeviceReconnectRulesTests.swift",
    "DeviceReconnectorOfferTests.swift",
    "DeviceSettingsSyncTests.swift",
    "EditableNameCellTests.swift",
    "FaceColourSyncTests.swift",
    "FacesPaneTests.swift",
    "GoogleOAuthRulesTests.swift",
    "GoogleSectionTests.swift",
    "IconGridTests.swift",
    "LowBatteryWatchTests.swift",
    "MainMenuTests.swift",
    "MenuBarControllerTests.swift",
    "OffscreenWindow.swift",
    "PairingIsWhatTheAppFollowsTests.swift",
    "PortableSHA256Tests.swift",
    "QuitSequenceTests.swift",
    "RenamingTheCubeReachesItFirstTests.swift",
    "ReportCalendarTests.swift",
    "ReportCategoryGroupTests.swift",
    "ReportPaneTests.swift",
    "ReportSortRulesTests.swift",
    "ReportTabAddsUpThePickedRangeTests.swift",
    "ReportTotalsTests.swift",
    "RetiredCategoryTableTests.swift",
    "SettingsMetricsTests.swift",
    "SettingsTabTests.swift",
    "SettingsWindowControllerTests.swift",
    "StatusItemTitleTests.swift",
    "SteppedNumberFieldTests.swift",
    "TimeEntryRecorderTests.swift",
    "TimingViewTests.swift",
    "WriteDebounceTests.swift",
]

// **Portable, but an `@MainActor` XCTestCase, which on Linux is fatal rather than awkward.** Linux
// discovers tests through a generated list and cannot cast an isolated method, so one such class aborts
// the entire run with SIGABRT. These come back as item 6 migrates them to swift-testing, which handles
// isolation properly -- 17 files, and the list to work through.
//
// **An isolated *helper* is not affected and is not listed.** `TemporaryDatabase` is `@MainActor` in
// places and is needed by files that do run; only an XCTestCase subclass is the problem.
let mainActorTests = [
    "DebugTraceFileTests.swift",
    "DevicePINSourceTests.swift",
    "HistoryTimerTests.swift",
]

#if os(Linux)
let testsThatCannotRunOnLinuxYet = platformBoundTests + mainActorTests
#else
let testsThatCannotRunOnLinuxYet: [String] = []
#endif

// MARK: - the targets

// **The system SQLite, for Linux only.** Darwin ships `SQLite3` as an SDK module, and this target is
// kept out of the graph there entirely -- it is not even in `allTargets` -- so a macOS build resolves
// `import SQLite3` exactly as it always has and never has two modules of one name to choose between.
//
// **Named after the module it stands in for, so no source file branches on the platform.** The four
// files in `FacetCore` that talk to sqlite, and the four test files that do, all say `import SQLite3` on
// both platforms. A shim under another name would have cost a `#if canImport` at the top of eight files
// to buy nothing.
//
// `libsqlite3-dev` provides the header and the unversioned `.so`, and `providers` says so, so a machine
// without it is told what to install rather than left with a header error. Installing it is **not** on
// its own enough, which is the thing worth knowing: the Swift toolchain ships no `SQLite3` module for
// Linux, so the modulemap is required whether or not the package is there (measured 2026-09-07 --
// `import SQLite3` failed identically before and after installing it).
let sqliteTarget: Target = .systemLibrary(
    name: "SQLite3",
    path: "Sources/SQLite3",
    pkgConfig: "sqlite3",
    providers: [
        .apt(["libsqlite3-dev"])
    ]
)

// The half that does not know what a window is: the stores, the rules, the database and the device
// protocol. It links no UI framework, which is the property worth protecting -- adding an
// `import AppKit` to a file in here stops compiling on Linux, and the compiler says so at the point
// somebody does it rather than at the port.
let coreTarget: Target = .target(
    name: "FacetCore",
    dependencies: coreDependencies,
    path: "Sources/FacetCore",
    exclude: [
        // Documentation living beside the schema it describes, not something to ship inside the app.
        // `Resources/Database` is a symlink to `database/` at the repository root, which is the real
        // directory: the schema is shared and neither platform owns it, and SwiftPM requires a target's
        // resources to sit inside the target.
        "Resources/Database/CLAUDE.md",
        "Resources/Database/ER-diagram.md"
    ],
    resources: [
        // The DDL travels with `DatabaseBootstrap`, which reads it through `Bundle.module`. That
        // accessor is per-target, so leaving the schema behind in FacetApp would have it resolve to a
        // bundle the DDL is not in.
        .process("Resources")
    ]
)

let appTarget: Target = .executableTarget(
    name: "FacetApp",
    dependencies: ["FacetCore"],
    path: "Sources/FacetApp",
    exclude: [
        // Carried across with the icon itself: Swift Bundler copies AppIcon.icns into the bundle from
        // Bundler.toml, so processing it here as well would ship two copies. (The archived package
        // excluded it for exactly this reason.)
        "Resources/AppIcon.icns"
    ],
    resources: [
        // The icons `ActivityIcon` draws and the Google client `GoogleOAuthClient` reads. Both are read
        // by files that stay on this side, so they stay with them.
        .process("Resources")
    ],
    linkerSettings: [
        // The menu bar item lives in AppKit. Linked from the step that introduced it, not carried
        // forward from the archived package on the assumption it would be needed.
        .linkedFramework("AppKit")
    ]
)

let testsTarget: Target = .testTarget(
    name: "FacetAppTests",
    dependencies: testDependencies,
    exclude: testsThatCannotRunOnLinuxYet
)

// MARK: - the package

// **The app is only in the package where AppKit exists.** `swift test` builds every target rather than
// only what the tests depend on, so leaving the executable in on Linux means every run dies on
// `main.swift` importing AppKit however portable the tests are. Only *dependencies* take a platform
// condition, never targets -- which is also why the four targets above are named values rather than
// literals inside the call, `#if` not being allowed inside an array literal.
#if os(Linux)
let allProducts: [Product] = []
let allTargets: [Target] = [sqliteTarget, coreTarget, testsTarget]
#else
let allProducts: [Product] = [
    .executable(
        name: "FacetApp",
        targets: ["FacetApp"]
    )
]
let allTargets: [Target] = [coreTarget, appTarget, testsTarget]
#endif

let package = Package(
    name: "FacetApp",
    platforms: [
        .macOS(.v14)
    ],
    products: allProducts,
    targets: allTargets
)

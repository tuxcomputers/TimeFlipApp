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
// `FacetCore` with no dependencies, the tests against `FacetMac` and `FacetCore`, the executable
// product, and no `SQLite3` target anywhere.
#if os(Linux)
let coreDependencies: [Target.Dependency] = ["SQLite3", "CDBus"]
// Four test files open a database with the C API directly, and a Swift module is not re-exported by
// whatever depends on it -- so importing `FacetCore` does not hand them `SQLite3`, and they need it in
// their own right.
// `FacetLinux` among them since 2026-09-10: the BlueZ transport moved out of the core into that target, so
// the suites covering it have to reach the module they now live beside. Testing an executable target is what
// the macOS half already does with `FacetMac`.
let testDependencies: [Target.Dependency] = ["FacetCore", "FacetLinux", "SQLite3", "CDBus"]
#else
let coreDependencies: [Target.Dependency] = []
let testDependencies: [Target.Dependency] = ["FacetMac", "FacetCore"]
#endif

// MARK: - the test files Linux cannot run yet

// **A record of what the port has not reached, not a design.** It is meant to shrink, and the day it is
// empty it goes away along with the `exclude:` that reads it. Empty on macOS, where the whole suite runs.
//
// **Why a list rather than a `#if` inside each file.** On Linux SwiftPM builds one test executable for
// the whole package, so a file that will not compile takes every other test down with it -- and an
// `@MainActor` XCTestCase does worse, aborting the run at load time however well everything else
// behaves. A file that cannot run has to be absent from the build rather than inert within it.

// **Needs AppKit, CoreBluetooth or a `FacetMac` type**, so it waits on items 9, 10 and 11 of
// `docs/linux-port.md`: the OAuth listener, the BlueZ radio, and a UI. 36 files, counted rather than carried.
//
// **It said 48 until 2026-09-09, and ten of those needed none of the three.** Each carried a
// `@testable import FacetMac` it never used a type from, which is enough on its own to keep a file out of
// a build that has no such module -- so the import was what excluded them, not the reason written here.
// Four turned out to be portable outright and have gone; the other six became the `mainRunLoopTests` list
// below, which is a different blocker and now says so -- and four of those six have since migrated off it,
// leaving the two the run loop really does block. The two that cost the most to find were
// `DeviceEventRecorderTests` and `TimeEntryRecorderTests`: 854 lines of database behaviour whose only
// mention of a `FacetMac` type in either file was a comment citing `SettingsWindowController.startTiming`
// as prior art for an ordering.
//
// **The lesson is about the two lists rather than the ten files.** A file sitting here was never a
// candidate for the swift-testing migration, because this list is where things go that cannot run at all
// -- so the migration emptied its own queue while six migratable suites sat hidden on this one. A list of
// exclusions has to say which of two reasons it is, or it absorbs the other.
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
    "CubeNotFoundOfferTests.swift",
    "DevicePaneTests.swift",
    "EditableNameCellTests.swift",
    "FacesPaneTests.swift",
    "GoogleOAuthRulesTests.swift",
    "GoogleSectionTests.swift",
    "IconGridTests.swift",
    "MainMenuTests.swift",
    "MenuBarControllerTests.swift",
    "OffscreenWindow.swift",
    "PairingIsWhatTheAppFollowsTests.swift",
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
    "SteppedNumberFieldTests.swift",
    "TimingViewTests.swift",
]

// **The second list is gone, and this is what it was.** From 2026-09-09 a `mainRunLoopTests` list sat here
// holding files whose subjects schedule on `RunLoop.main`: on Linux a `@MainActor` swift-testing test does not
// run on the main thread, so such a timer never fires and the tests failed silently rather than being merely
// excluded. It emptied on 2026-09-09 as well. `WriteDebounce` and `LowBatteryWatch` grew a `fire()` -- the
// timeout body as a method the tests call -- so they stop touching a run loop at all instead of needing one
// that behaves, which is the bargain `HistoryTimer` had already made. That was worth 17 tests.
//
// **So there is one list again, and one reason.** The measurement behind the vanished one is in
// `docs/linux-port.md` under *`@MainActor` is not the main thread*, because it is a fact about the platform
// rather than about these files, and the next module to reach for `RunLoop.main` will meet it too: five
// `FacetCore` modules do, and `DailyLimitWatch` and `DeviceReconnector` have no `fire()`.

#if os(Linux)
let testsThatCannotRunOnLinuxYet = platformBoundTests
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

// **libdbus, for Linux only.** The radio reaches the cube through BlueZ, which is a D-Bus service, where
// Darwin reaches the same hardware through CoreBluetooth and needs no D-Bus at all -- so this target is
// not in `allTargets` on that platform any more than `SQLite3` is.
//
// **`pkgConfig` is doing real work here rather than being tidy.** libdbus needs *two* include
// directories: the arch-dependent `dbus-arch-deps.h` lives under `/usr/lib/<triple>/dbus-1.0/include`
// while everything else is in `/usr/include/dbus-1.0`. A modulemap naming a path would have to name both
// and would be wrong on any machine that moved either.
//
// **The whole of what this app needs from it is non-variadic**, which is why it can be reached at all:
// `dbus_message_append_args` is variadic and so uncallable from Swift, exactly as libsecret's simple API
// turned out to be (item 7), but the `dbus_message_iter_*` family that replaces it is not.
// **GTK3 and the app indicator, for Linux only.** The third of these, after `SQLite3` and `CDBus`, and
// for the same reason as both: a C library the platform already has, named as a module so Swift can call
// it, rather than a Swift binding to keep in step with somebody else's release schedule.
//
// **One `pkgConfig`, not two.** `ayatana-appindicator3-0.1` declares GTK as a dependency, so asking
// pkg-config for it yields GTK's include directories as well -- which matters because there are four of
// them and two are arch-dependent.
let cgtkTarget: Target = .systemLibrary(
    name: "CGtk",
    path: "Sources/CGtk",
    pkgConfig: "ayatana-appindicator3-0.1",
    providers: [
        .apt(["libgtk-3-dev", "libayatana-appindicator3-dev"])
    ]
)

let cdbusTarget: Target = .systemLibrary(
    name: "CDBus",
    path: "Sources/CDBus",
    pkgConfig: "dbus-1",
    providers: [
        .apt(["libdbus-1-dev"])
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
        // accessor is per-target, so leaving the schema behind in FacetMac would have it resolve to a
        // bundle the DDL is not in.
        .process("Resources")
    ]
)

let appTarget: Target = .executableTarget(
    name: "FacetMac",
    dependencies: ["FacetCore"],
    path: "Sources/FacetMac",
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

// **The Linux app, which is the boot and nothing else yet.** It exists so this platform has a product at
// all: without one `swift build` has nothing to build, and `Tests/Scripted/` cannot build and launch the
// app the way it does on the Mac. Every line in it is `FacetCore`; the window and the radio are items 11
// and 10 of `docs/linux-port.md`.
//
// **Named `FacetLinux` rather than `FacetMac`** because the two cannot share `Sources/FacetMac`, which is
// the AppKit one, and a target pointed at a directory it is not named after reads as a mistake for as
// long as it takes to check. `Tests/Scripted/platform.sh` holds the name in one place.
let linuxAppTarget: Target = .executableTarget(
    name: "FacetLinux",
    dependencies: ["FacetCore", "CGtk"],
    path: "Sources/FacetLinux",
    resources: [
        // The logo the menu bar draws, derived from `Facet.small.svg` at the repository root by
        // `scripts/update_app_icon.sh` -- the same script and the same relationship as `AppIcon.icns`.
        //
        // **A copy rather than a symlink, and that is measured.** A symlinked file was tried first:
        // SwiftPM copies it into the resource bundle *as a symlink*, whose relative target no longer
        // resolves from where it lands, so the icon silently fell back to a stock one. A symlinked
        // *directory* is followed, which is why the DDL can do it (`Sources/FacetCore/Resources/Database`)
        // and a single file cannot.
        .process("Resources")
    ]
)

let testsTarget: Target = .testTarget(
    name: "FacetTests",
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
let allProducts: [Product] = [
    .executable(
        name: "FacetLinux",
        targets: ["FacetLinux"]
    )
]
let allTargets: [Target] = [sqliteTarget, cdbusTarget, cgtkTarget, coreTarget, linuxAppTarget, testsTarget]
#else
let allProducts: [Product] = [
    .executable(
        name: "FacetMac",
        targets: ["FacetMac"]
    )
]
let allTargets: [Target] = [coreTarget, appTarget, testsTarget]
#endif

let package = Package(
    // **`Facet`, not the name of either platform's app.** This is the project, and it holds three targets
    // that are peers: `FacetCore` which both platforms share, `FacetMac`, and `FacetLinux`. It was called
    // `FacetApp` while there was only one app, which quietly made the macOS one the default and the other
    // an addition to it -- and the name leaked, `Bundle.module` deriving `FacetApp_FacetCore.resources`
    // from it on both platforms.
    name: "Facet",
    platforms: [
        .macOS(.v14)
    ],
    products: allProducts,
    targets: allTargets
)

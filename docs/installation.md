# Installation

[← Back to README](../README.md) · [Configuration →](configuration.md)

## System Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon or Intel Mac with Bluetooth 4.0+
- TimeFlip2 device
- Swift 6.0+ (for building from source)

## Building from Source

### Option 1: `scripts/run.sh` (recommended)

This is the one to use. It builds the bundle and runs it, and it **finds a codesigning identity and
signs with it** where there is one -- which is what stops macOS asking for Keychain access after every
rebuild, and therefore what keeps Google sync working across builds (see
[google-oauth-setup.md](google-oauth-setup.md)). With no certificate it falls back to an ad-hoc
signature and says so.

```bash
# Install Mint package manager (if not already installed)
brew install mint

# Clone the repository
git clone https://github.com/tuxcomputers/TimeFlipApp.git
cd TimeFlipApp

scripts/run.sh
```

Two flags, and one of them destroys data:

- `--rebuild` deletes `.build` first, for when an incremental build is suspect.
- `--clean` deletes the local databases -- the `appdata.sqlite` symlink, `production.sqlite`,
  `test.sqlite` and the `debug.sqlite` trace. **It asks before it does it**, and there is no undo:
  `production.sqlite` is every hour you have ever recorded.

`FACET_CODESIGN_IDENTITY` overrides the identity search, for anyone holding more than one.

### Option 2: Swift Bundler directly

`scripts/run.sh` wraps [swift-bundler](https://github.com/stackotter/swift-bundler), so the underlying
commands work on their own -- at the cost of the signing above.

```bash
# Build the application bundle
mint run stackotter/swift-bundler@main bundle Facet

# The app is created at .build/bundler/apps/Facet/Facet.app
open .build/bundler/apps/Facet/Facet.app

# or run it through bundler
mint run stackotter/swift-bundler@main run Facet
```

You can then drag `Facet.app` to your Applications folder for easy access. The `Makefile` has the same
two as `make build` and `make run`, for a `swift-bundler` already on `PATH`.

### Option 3: Direct Swift build

`swift build` produces the executable but **not an application bundle**, so there is no `Info.plist` --
which means no Bluetooth usage description and no `LSUIElement`, and the Google client id the bundle
carries is absent too. Useful for compiling and for `swift test`, not for running the app.

```bash
swift build -c release
.build/release/FacetApp
```

## Building and Testing

```bash
# Build and run the app bundle (recommended for testing full app behaviour)
scripts/run.sh

# Build in debug mode without running
swift build

# The hermetic suite: 1502 tests, no window and no radio
swift test

# Lint (requires SwiftLint)
swiftlint lint --quiet
swiftlint --fix

# Everything CI runs, locally
scripts/ci-local.sh
```

**`swift test` passing does not mean it works.** It never opens a window and never touches a radio, so
a feature can be entirely green there and broken the moment it runs. What says it works is
[`Tests/Scripted/`](../Tests/Scripted/README.md), which drives the real app against the real database,
and some of it needs a TimeFlip in range and a person to turn it:

```bash
scripts/switch-database.sh test     # it refuses to run against your real data
Tests/Scripted/run.sh
```

See [Contributing](../CONTRIBUTING.md) for what to do if you have no device.

## Next Steps

Once the app is running, head over to the [Configuration guide](configuration.md) to set up Google Calendar integration and pair your TimeFlip device.

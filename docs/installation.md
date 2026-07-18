# Installation

[← Back to README](../README.md) · [Configuration →](configuration.md)

## System Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon or Intel Mac with Bluetooth 4.0+
- TimeFlip2 device
- Swift 6.0+ (for building from source)

## Building from Source

### Option 1: Using Swift Bundler (Recommended)

The project includes configuration for [swift-bundler](https://github.com/stackotter/swift-bundler), which creates a proper macOS application bundle.

```bash
# Install Mint package manager (if not already installed)
brew install mint

# Clone the repository
git clone https://github.com/growler/TimeFlipApp.git
cd TimeFlipApp 

# Build the application bundle (runs swift-bundler via mint, no PATH changes needed)
mint run stackotter/swift-bundler@main bundle TimeFlip

# The app will be created at .build/bundler/apps/TimeFlip/TimeFlip.app
# Open the app
open .build/bundler/apps/TimeFlip/TimeFlip.app

# or run using bundler
mint run stackotter/swift-bundler@main run TimeFlip
```

You can then drag `TimeFlip.app` to your Applications folder for easy access.

### Option 2: Direct Swift Build

```bash
# Clone the repository
git clone https://github.com/growler/TimeFlipApp.git
cd TimeFlipApp 

# Build the application
swift build -c release

# Run the application
.build/release/TimeFlipApp
```

The app will appear in your menu bar with the TimeFlip icon.

## Building and Testing

```bash
# Build and run the app bundle (recommended for testing full app behavior)
mint run stackotter/swift-bundler@main run TimeFlip

# The app bundle is left at .build/bundler/apps/TimeFlip/TimeFlip.app
open .build/bundler/apps/TimeFlip/TimeFlip.app

# Or build in debug mode directly
swift build

# Run tests
swift test

# Run with verbose logging (direct execution)
swift run

# Format code (requires SwiftLint)
swiftlint --fix
```

## Next Steps

Once the app is running, head over to the [Configuration guide](configuration.md) to set up Google
Calendar integration and pair your TimeFlip device.

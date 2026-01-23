.PHONY: setup build run test lint

setup:
	@echo "Nothing to install yet. Ensure Xcode 15+, Swift 6, and SwiftLint are available."

build:
	swift-bundler bundle TimeFlip

run:
	swift-bundler run TimeFlip

test:
	swift test

lint:
	@command -v swiftlint >/dev/null 2>&1 || { echo "swiftlint not installed; please install to run lint."; exit 1; }
	swiftlint lint --quiet

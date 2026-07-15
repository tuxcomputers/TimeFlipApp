#!/bin/sh
set -e

cd "$(dirname "$0")/.."

mint run stackotter/swift-bundler@main run TimeFlip

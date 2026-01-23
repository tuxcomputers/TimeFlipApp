// swift-tools-version: 6.0
import PackageDescription

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
    dependencies: [
        .package(url: "https://github.com/openid/AppAuth-iOS.git", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "TimeFlipApp",
            dependencies: [
                .product(name: "AppAuth", package: "AppAuth-iOS")
            ],
            path: "Sources/TimeFlipApp",
            exclude: [
                // App icon is provided separately to Swift Bundler to avoid duplicate copies.
                "Resources/AppIcon.icns"
            ],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreBluetooth")
            ]
        ),
        .testTarget(
            name: "TimeFlipAppTests",
            dependencies: ["TimeFlipApp"]
        )
    ]
)

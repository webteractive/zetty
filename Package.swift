// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "zetty",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZettyCore", targets: ["ZettyCore"]),
        // The `quertty` control CLI (talks to the app over ~/.quertty/quertty.sock).
        .executable(name: "zetty", targets: ["ZettyCLI"]),
    ],
    dependencies: [
        // Required: only Command Line Tools are installed (no full Xcode), so the
        // toolchain's XCTest / bundled Testing module aren't available to `swift test`.
        // The self-contained swift-testing package is the only headless-runnable option.
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.0.0"),
    ],
    targets: [
        .target(name: "ZettyCore"),
        .executableTarget(name: "ZettyCLI", dependencies: ["ZettyCore"]),
        .testTarget(
            name: "ZettyCoreTests",
            dependencies: [
                "ZettyCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)

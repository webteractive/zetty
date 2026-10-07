// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "zetty",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZettyCore", targets: ["ZettyCore"]),
        // The `zetty` control CLI (talks to the app over ~/.zetty/zetty.sock).
        .executable(name: "zetty", targets: ["ZettyCLI"]),
    ],
    targets: [
        .target(name: "ZettyCore"),
        .executableTarget(name: "ZettyCLI", dependencies: ["ZettyCore"]),
        .testTarget(
            name: "ZettyCoreTests",
            dependencies: ["ZettyCore"],
            // Captured terminal screens, read as bytes (see PromptBoxTests).
            resources: [.copy("Fixtures")]
        ),
    ]
)

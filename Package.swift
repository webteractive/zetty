// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "quertty",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QuerttyCore", targets: ["QuerttyCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.0.0"),
    ],
    targets: [
        .target(name: "QuerttyCore"),
        .testTarget(
            name: "QuerttyCoreTests",
            dependencies: [
                "QuerttyCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)

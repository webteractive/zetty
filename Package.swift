// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "zetty",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZettyCore", targets: ["ZettyCore"]),
        // Lua scripting for ~/.config/zetty/init.lua.
        .library(name: "ZettyLua", targets: ["ZettyLua"]),
        // The `zetty` control CLI (talks to the app over ~/.zetty/zetty.sock).
        .executable(name: "zetty", targets: ["ZettyCLI"]),
    ],
    targets: [
        .target(name: "ZettyCore"),
        // The Lua 5.4.7 interpreter, vendored from lua.org (licenses/lua-MIT.txt).
        .target(
            name: "CLua",
            cSettings: [.define("LUA_USE_MACOSX")]
        ),
        .target(name: "ZettyLua", dependencies: ["CLua"]),
        .executableTarget(name: "ZettyCLI", dependencies: ["ZettyCore"]),
        .testTarget(
            name: "ZettyCoreTests",
            dependencies: ["ZettyCore", "ZettyLua"],
            // Captured terminal screens, read as bytes (see PromptBoxTests).
            resources: [.copy("Fixtures")]
        ),
    ]
)

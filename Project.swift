import ProjectDescription

// External SPM package: prebuilt libghostty-spm (ships xcframework, no zig/submodule build)
let libghosttyPackage: Package = .remote(
    url: "https://github.com/Lakr233/libghostty-spm.git",
    requirement: .upToNextMinor(from: "1.2.7")
)

let project = Project(
    name: "zetty",
    packages: [
        libghosttyPackage,
        // Local QuerttyCore SPM package (Tasks 1-4)
        .local(path: "."),
    ],
    targets: [
        // ── App target ─────────────────────────────────────────────
        .target(
            name: "zetty",
            destinations: .macOS,
            product: .app,
            bundleId: "dev.more.zetty",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                "LSUIElement": false,
                "NSPrincipalClass": "NSApplication",
                // Brand: the app/binary/CLI are "zetty"; internal module names
                // (QuerttyCore/QuerttyGhostty) are renamed in the repo layer.
                "CFBundleName": "Zetty",
                "CFBundleDisplayName": "Zetty",
                "CFBundleIconFile": "AppIcon",
            ]),
            sources: ["App/Sources/App/**"],
            resources: ["App/Resources/**/*.svg", "App/Resources/*.icns"],
            dependencies: [
                // GhosttyKit (static) is linked transitively via QuerttyGhostty;
                // linking it here too triggers a static-double-link warning.
                .package(product: "GhosttyTerminal"),
                .package(product: "QuerttyCore"),
                .target(name: "QuerttyGhostty"),
            ]
        ),

        // ── QuerttyGhostty framework ────────────────────────────────
        // Named "QuerttyGhostty" (not "GhosttyKit") to avoid a module-name
        // clash with the libghostty-spm product also called "GhosttyKit".
        //
        // libghostty.a (the prebuilt xcframework) embeds a Metal/IOSurface
        // rendering backend, so we must explicitly declare those system
        // frameworks to satisfy the static-archive linker symbols when this
        // dynamic framework is built.
        .target(
            name: "QuerttyGhostty",
            destinations: .macOS,
            product: .framework,
            bundleId: "dev.more.quertty.QuerttyGhostty",
            deploymentTargets: .macOS("14.0"),
            sources: ["App/Sources/QuerttyGhostty/**"],
            dependencies: [
                .package(product: "GhosttyKit"),
                .package(product: "GhosttyTerminal"),
                .package(product: "QuerttyCore"),
                .sdk(name: "Carbon", type: .framework),
                .sdk(name: "CoreVideo", type: .framework),
                .sdk(name: "IOSurface", type: .framework),
                .sdk(name: "Metal", type: .framework),
                .sdk(name: "QuartzCore", type: .framework),
                .sdk(name: "c++", type: .library),
            ]
        ),

        // ── Smoke-test target ───────────────────────────────────────
        .target(
            name: "QuerttyGhosttyTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "dev.more.quertty.QuerttyGhosttyTests",
            deploymentTargets: .macOS("14.0"),
            sources: ["App/Tests/QuerttyGhosttyTests/**"],
            dependencies: [
                .target(name: "QuerttyGhostty"),
            ]
        ),
    ],
    schemes: [
        // Explicit scheme so `tuist test` discovers and runs the unit tests
        // (Tuist's auto-generated schemes weren't attaching the test target).
        .scheme(
            name: "QuerttyGhosttyTests",
            shared: true,
            buildAction: .buildAction(targets: ["QuerttyGhostty"]),
            testAction: .targets(["QuerttyGhosttyTests"])
        ),
    ]
)

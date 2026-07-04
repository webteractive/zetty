import ProjectDescription

// External SPM package: prebuilt libghostty-spm (ships xcframework, no zig/submodule build)
let libghosttyPackage: Package = .remote(
    url: "https://github.com/Lakr233/libghostty-spm.git",
    requirement: .upToNextMinor(from: "1.2.7")
)

// Stamps the built app's Info.plist with the short git commit ("*" suffix when
// the working tree is dirty) so the status bar can show which build is running.
// The processed Info.plist is declared as a script input so the build system
// orders the stamp AFTER ProcessInfoPlistFile — without it the script can run
// first and plist processing then wipes the stamp.
let stampBuildCommit = """
PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
COMMIT=$(git -C "${SRCROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)
if [ -n "$(git -C "${SRCROOT}" status --porcelain 2>/dev/null)" ]; then COMMIT="${COMMIT}*"; fi
/usr/libexec/PlistBuddy -c "Set :ZettyBuildCommit ${COMMIT}" "${PLIST}" 2>/dev/null \\
  || /usr/libexec/PlistBuddy -c "Add :ZettyBuildCommit string ${COMMIT}" "${PLIST}"
"""

let project = Project(
    name: "zetty",
    packages: [
        libghosttyPackage,
        // Local ZettyCore SPM package (Tasks 1-4)
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
                // (ZettyCore/ZettyGhostty) are renamed in the repo layer.
                "CFBundleName": "Zetty",
                "CFBundleDisplayName": "Zetty",
                "CFBundleIconFile": "AppIcon",
                "CFBundleShortVersionString": "0.1.4",
            ]),
            sources: ["App/Sources/App/**"],
            resources: ["App/Resources/**/*.svg", "App/Resources/*.icns",
                        "App/Resources/Fonts/**"],
            scripts: [
                .post(script: stampBuildCommit,
                      name: "Stamp build commit",
                      inputPaths: ["$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)"],
                      basedOnDependencyAnalysis: false),
            ],
            dependencies: [
                // GhosttyKit (static) is linked transitively via ZettyGhostty;
                // linking it here too triggers a static-double-link warning.
                .package(product: "GhosttyTerminal"),
                .package(product: "ZettyCore"),
                .target(name: "ZettyGhostty"),
            ]
        ),

        // ── ZettyGhostty framework ────────────────────────────────
        // Named "ZettyGhostty" (not "GhosttyKit") to avoid a module-name
        // clash with the libghostty-spm product also called "GhosttyKit".
        //
        // libghostty.a (the prebuilt xcframework) embeds a Metal/IOSurface
        // rendering backend, so we must explicitly declare those system
        // frameworks to satisfy the static-archive linker symbols when this
        // dynamic framework is built.
        .target(
            name: "ZettyGhostty",
            destinations: .macOS,
            product: .framework,
            bundleId: "dev.more.zetty.ZettyGhostty",
            deploymentTargets: .macOS("14.0"),
            sources: ["App/Sources/ZettyGhostty/**"],
            dependencies: [
                .package(product: "GhosttyKit"),
                .package(product: "GhosttyTerminal"),
                .package(product: "ZettyCore"),
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
            name: "ZettyGhosttyTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "dev.more.zetty.ZettyGhosttyTests",
            deploymentTargets: .macOS("14.0"),
            sources: ["App/Tests/ZettyGhosttyTests/**"],
            dependencies: [
                .target(name: "ZettyGhostty"),
            ]
        ),
    ],
    schemes: [
        // Explicit scheme so `tuist test` discovers and runs the unit tests
        // (Tuist's auto-generated schemes weren't attaching the test target).
        .scheme(
            name: "ZettyGhosttyTests",
            shared: true,
            buildAction: .buildAction(targets: ["ZettyGhostty"]),
            testAction: .targets(["ZettyGhosttyTests"])
        ),
    ]
)

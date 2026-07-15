import ProjectDescription

// External SPM package: prebuilt libghostty-spm (ships xcframework, no zig/submodule build)
let libghosttyPackage: Package = .remote(
    url: "https://github.com/Lakr233/libghostty-spm.git",
    requirement: .upToNextMinor(from: "1.2.7")
)

// Stamps the built app's Info.plist with the short git commit ("*" suffix when
// the working tree is dirty) so the status bar can show which build is running,
// and with a monotonic CFBundleVersion (git commit count): Launch Services picks
// the HIGHEST CFBundleVersion among registered copies when routing ssh:// opens,
// so without this every build ties at the default "1.0" and a stale
// DerivedData/build stray can win over /Applications.
// The processed Info.plist is declared as a script input so the build system
// orders the stamp AFTER ProcessInfoPlistFile — without it the script can run
// first and plist processing then wipes the stamp.
let stampBuildCommit = """
PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
COMMIT=$(git -C "${SRCROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)
if [ -n "$(git -C "${SRCROOT}" status --porcelain 2>/dev/null)" ]; then COMMIT="${COMMIT}*"; fi
/usr/libexec/PlistBuddy -c "Set :ZettyBuildCommit ${COMMIT}" "${PLIST}" 2>/dev/null \\
  || /usr/libexec/PlistBuddy -c "Add :ZettyBuildCommit string ${COMMIT}" "${PLIST}"
BUILDNUM=$(git -C "${SRCROOT}" rev-list --count HEAD 2>/dev/null || echo 1)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILDNUM}" "${PLIST}" 2>/dev/null \\
  || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${BUILDNUM}" "${PLIST}"
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
            bundleId: "co.webteractive.zetty",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                "LSUIElement": false,
                "NSPrincipalClass": "NSApplication",
                // Only one Zetty instance at a time — launching again (e.g. after
                // an update while the old copy still runs) activates the existing
                // window instead of spawning a second "double" window.
                "LSMultipleInstancesProhibited": true,
                // Register Zetty as a handler for ssh:// URLs so a handover from
                // another app (Terminal, a browser, `open ssh://…`) opens an ssh
                // session in a new Home tab (see AppDelegate.application(_:open:)).
                "CFBundleURLTypes": [
                    [
                        "CFBundleURLName": "co.webteractive.zetty.ssh",
                        "CFBundleTypeRole": "Viewer",
                        "CFBundleURLSchemes": ["ssh"],
                    ],
                ],
                // Brand: the app/binary/CLI are "zetty"; internal module names
                // (ZettyCore/ZettyGhostty) are renamed in the repo layer.
                "CFBundleName": "Zetty",
                "CFBundleDisplayName": "Zetty",
                "CFBundleIconFile": "AppIcon",
                "CFBundleShortVersionString": "0.1.22",
                // Folder-access (TCC) prompt copy: terminals launched in a pane
                // touch these protected folders, so macOS asks once per folder
                // until the user grants Full Disk Access. These strings just
                // make the prompt say why — they don't remove it.
                "NSDesktopFolderUsageDescription":
                    "Zetty needs access so terminals you open in it can read and write files on your Desktop.",
                "NSDocumentsFolderUsageDescription":
                    "Zetty needs access so terminals you open in it can read and write files in your Documents.",
                "NSDownloadsFolderUsageDescription":
                    "Zetty needs access so terminals you open in it can read and write files in your Downloads.",
                "NSRemovableVolumesUsageDescription":
                    "Zetty needs access so terminals you open in it can read and write files on removable volumes.",
                "NSNetworkVolumesUsageDescription":
                    "Zetty needs access so terminals you open in it can read and write files on network volumes.",
            ]),
            sources: ["App/Sources/App/**"],
            resources: [
                "App/Resources/**/*.svg", "App/Resources/*.icns",
                "App/Resources/Fonts/**",
                // Bundled ghostty shell-integration + terminfo (folder reference
                // so the tree, dotfiles, and terminfo hash dirs copy verbatim).
                // GHOSTTY_RESOURCES_DIR (main.swift) points here; terminfo keeps
                // xterm-ghostty resolvable so keys (backspace) don't break.
                .folderReference(path: "App/Resources/ghostty"),
            ],
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
            bundleId: "co.webteractive.zetty.ZettyGhostty",
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
            bundleId: "co.webteractive.zetty.ZettyGhosttyTests",
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

import AppKit
import ZettyCore

// CLI mode: the app binary doubles as the `Zetty` CLI when invoked with a
// recognized command (Settings installs a symlink into ~/.local/bin).
let cliArguments = Array(CommandLine.arguments.dropFirst())
if ControlCLI.recognizes(cliArguments) {
    exit(ControlCLI.run(cliArguments))
}
// An UNRECOGNIZED command (typo, or something like `zetty open`) is still a CLI
// attempt — report it and exit. Never fall through to a GUI launch: running the
// binary directly bypasses the single-instance guard and its socket setup would
// `unlink` the live instance's control socket, spawning a rogue window and
// breaking the CLI. (This is what happened when a session ran `zetty open`.)
if !cliArguments.isEmpty {
    exit(ControlCLI.run(cliArguments))   // hits the unknown-command path → usage, exit 1
}
// Bare `zetty` from a terminal is a help request, not a GUI launch. Only a
// no-argument launch with no controlling terminal (Finder / `open` /
// LaunchServices) proceeds to the GUI below.
if isatty(STDIN_FILENO) != 0 {
    print(ControlCLI.usage)
    exit(0)
}

// Point libghostty at our bundled resources (shell-integration scripts +
// terminfo) so spawned shells get working-directory reports (for the status
// bar) and prompt marks. The bundled terminfo keeps `xterm-ghostty` resolvable
// once resources are present — without it ghostty switches TERM to
// xterm-ghostty but can't find its terminfo, breaking keys like backspace.
// Set before the first `ghostty_init` (lazy, on the first terminal surface).
if let ghosttyResources = Bundle.main.resourceURL?
    .appendingPathComponent("ghostty", isDirectory: true).path {
    setenv("GHOSTTY_RESOURCES_DIR", ghosttyResources, 1)
    // Ghostty sets TERM=xterm-ghostty but the embedded lib doesn't install that
    // terminfo, so shells can't resolve it (breaking keys like backspace). Point
    // them at our bundled copy; a trailing empty entry keeps the system default
    // (so xterm-256color etc. still resolve).
    let terminfo = ghosttyResources + "/terminfo"
    let existing = ProcessInfo.processInfo.environment["TERMINFO_DIRS"]
    setenv("TERMINFO_DIRS", existing.map { "\(terminfo):\($0)" } ?? "\(terminfo):", 1)
}
PaneCwdStore.ensureDirectory()

// Programmatic AppKit entry point. We deliberately avoid `@main` /
// NSApplicationMain (see AppDelegate) because Tuist's default Info.plist
// declares NSMainStoryboardFile = "Main"; NSApplicationMain would try to load
// that nonexistent storyboard and crash. Bootstrapping NSApplication directly
// bypasses the storyboard lookup entirely — our AppDelegate builds the window.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()

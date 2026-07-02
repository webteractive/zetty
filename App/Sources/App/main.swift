import AppKit
import ZettyCore

// CLI mode: the app binary doubles as the `Zetty` CLI when invoked with a
// recognized command (Settings installs a symlink into ~/.local/bin). Finder
// launches pass no such arguments, so the GUI path is unaffected.
let cliArguments = Array(CommandLine.arguments.dropFirst())
if ControlCLI.recognizes(cliArguments) {
    exit(ControlCLI.run(cliArguments))
}

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

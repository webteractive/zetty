import AppKit

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

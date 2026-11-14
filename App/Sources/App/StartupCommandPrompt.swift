import AppKit
import ZettyCore

/// Asks whether a repo's startup commands may run, in a window of its own.
///
/// Not a sheet and not `runModal`: AppKit refuses `NSApp.terminate` while a
/// sheet is up, before `applicationShouldTerminate` is even asked, and this
/// prompt can appear with nobody at the Mac (`zetty add-project` from a
/// script, an agent, the other Mac). A sheet would then stall `zetty quit`,
/// the updater and a shutdown or restart. A plain window does not; quitting
/// with it open leaves the commands unrun, which is the safe answer.
final class StartupCommandPrompt: NSObject {
    /// Open prompts, kept alive until answered.
    private static var open: Set<StartupCommandPrompt> = []

    private let alert = NSAlert()
    private let decide: (Bool) -> Void

    /// `decide(true)` when the user picks Run Commands, `false` otherwise.
    static func present(projectName: String, commands: [TemplateCommand],
                        over parent: NSWindow?, decide: @escaping (Bool) -> Void) {
        let prompt = StartupCommandPrompt(projectName: projectName, commands: commands, decide: decide)
        open.insert(prompt)
        prompt.show(over: parent)
    }

    private init(projectName: String, commands: [TemplateCommand], decide: @escaping (Bool) -> Void) {
        self.decide = decide
        super.init()
        alert.messageText = "Run \(projectName)'s startup commands?"
        alert.informativeText =
            "This folder's .zetty/project.json types "
            + (commands.count == 1 ? "this command into its pane" : "these commands into its panes")
            + ". They come from whoever wrote the repo and run as you, with your files and "
            + "accounts. Run them only if you trust it; Zetty asks again if they change."
        alert.accessoryView = Self.commandList(StartupCommandDisplay.lines(commands))
        // The safe answer is the default button, so Return never runs them.
        let skip = alert.addButton(withTitle: "Open Without Running")
        let run = alert.addButton(withTitle: "Run Commands")
        skip.keyEquivalent = "\r"
        run.keyEquivalent = ""
        skip.target = self
        skip.action = #selector(openWithoutRunning)
        run.target = self
        run.action = #selector(runCommands)
    }

    private func show(over parent: NSWindow?) {
        alert.layout()
        let window = alert.window
        if let parent {
            let frame = parent.frame
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2,
                                          y: frame.midY - window.frame.height / 2))
        } else {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: false)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func openWithoutRunning() { finish(false) }
    @objc private func runCommands() { finish(true) }

    private func finish(_ run: Bool) {
        alert.window.orderOut(nil)
        Self.open.remove(self)
        decide(run)
    }

    /// The commands, selectable and scrollable so a long list or line is read
    /// in full rather than cut off.
    private static func commandList(_ text: String) -> NSView {
        let width: CGFloat = 420
        let font = ZTheme.chromeFont(size: 12)
        let lineCount = CGFloat(text.split(separator: "\n", omittingEmptySubsequences: false).count)
        let height = min(max(lineCount * (font.boundingRectForFont.height + 2) + 12, 44), 200)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = font
        textView.textColor = ZTheme.current.fgColor
        textView.backgroundColor = ZTheme.current.bg1Color
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        scroll.documentView = textView
        return scroll
    }
}

import AppKit
import GhosttyTerminal
import ZettyCore
import ZettyGhostty

/// Makes file paths in terminal output clickable: ⌘-hover underlines a path
/// that resolves to a real file, and ⌘-click peeks it in the overlay.
///
/// libghostty exposes no text under the mouse, so the text comes from the
/// pane's zmx capture — the same source copy mode's word motions use. Two
/// consequences, both deliberate:
///
/// - **Preserved sessions only.** No zmx session, no detection.
/// - **Rows are approximate.** Wrapped lines can shift which line we believe
///   is under the cursor. It fails closed: a drifted row almost never yields a
///   token that both parses and resolves, so the normal failure is no
///   underline rather than a wrong one.
@MainActor
final class PathHoverTracker {

    /// The terminal view under a window point, with its surface id.
    var terminalViewAndSurface: ((NSPoint) -> (view: AppTerminalView, surfaceID: UUID)?)?
    var gridMetrics: ((UUID) -> TerminalGridMetrics?)?
    var captureLines: ((UUID, Int) -> [String]?)?
    var paneCwd: ((UUID) -> String?)?
    var projectRoot: ((UUID) -> String?)?
    /// Called with a resolved absolute path when a ⌘-click lands.
    var onOpen: ((String, Int?, Int?) -> Void)?

    private var monitor: Any?
    private var underline: UnderlineView?
    /// Capture is a subprocess, so hovering reuses a recent snapshot rather
    /// than shelling out per mouse move.
    private var cache: (surfaceID: UUID, lines: [String], at: TimeInterval)?
    private static let cacheTTL: TimeInterval = 0.25

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .flagsChanged, .leftMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .mouseMoved, .flagsChanged:
                // Mouse-moved events only arrive if the window opts in, and the
                // window may not exist yet at install time. `flagsChanged` is a
                // key event that arrives regardless, so ⌘ bootstraps tracking.
                if let window = event.window, !window.acceptsMouseMovedEvents {
                    window.acceptsMouseMovedEvents = true
                }
                self.updateHover(event)
                return event
            case .leftMouseDown:
                // Consume the click only when it actually opens something, so
                // an ordinary ⌘-click still reaches the terminal.
                return self.handleClick(event) ? nil : event
            default:
                return event
            }
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        clearUnderline()
    }

    /// Clears the hover state — called when the workspace changes shape under
    /// the mouse (pane closed, project switched).
    func reset() {
        cache = nil
        underline?.removeFromSuperview()
        underline = nil
    }

    // MARK: - Hover

    private func updateHover(_ event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return clearUnderline() }
        guard let hit = resolve(event) else { return clearUnderline() }
        showUnderline(in: hit.view, row: hit.row,
                      colStart: hit.match.startColumn, colEnd: hit.match.endColumn,
                      cellW: hit.cellW, cellH: hit.cellH)
    }

    private func handleClick(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let hit = resolve(event) else { return false }
        clearUnderline()
        onOpen?(hit.path, hit.match.token.line, hit.match.token.column)
        return true
    }

    // MARK: - Resolution

    private struct Hit {
        let view: AppTerminalView
        let row: Int
        let match: PathMatch
        let path: String
        let cellW: CGFloat
        let cellH: CGFloat
    }

    /// Mouse point → cell → captured line text → path token → existing file.
    private func resolve(_ event: NSEvent) -> Hit? {
        guard let window = event.window else { return nil }
        let windowPoint = event.locationInWindow
        guard let target = terminalViewAndSurface?(windowPoint) else { return nil }
        guard let metrics = gridMetrics?(target.surfaceID) else { return nil }

        let scale = window.backingScaleFactor
        let cellW = CGFloat(metrics.cellWidthPixels) / scale
        let cellH = CGFloat(metrics.cellHeightPixels) / scale
        let viewPoint = target.view.convert(windowPoint, from: nil)
        guard let cell = TerminalCellGeometry.cell(atViewPoint: viewPoint,
                                                   viewHeight: target.view.bounds.height,
                                                   cellW: cellW, cellH: cellH) else { return nil }

        let rows = Int(metrics.rows)
        guard let lines = lines(for: target.surfaceID, rows: rows),
              cell.row < lines.count else { return nil }
        guard let match = FilePathToken.match(in: lines[cell.row], column: cell.col) else { return nil }

        let candidates = PathResolution.candidates(for: match.token,
                                                    paneCwd: paneCwd?(target.surfaceID),
                                                    projectRoot: projectRoot?(target.surfaceID))
        guard let path = candidates.first(where: isReadableFile) else { return nil }
        return Hit(view: target.view, row: cell.row, match: match,
                   path: path, cellW: cellW, cellH: cellH)
    }

    private func isReadableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        return !isDirectory.boolValue
    }

    private func lines(for surfaceID: UUID, rows: Int) -> [String]? {
        let now = ProcessInfo.processInfo.systemUptime
        if let cache, cache.surfaceID == surfaceID, now - cache.at < Self.cacheTTL {
            return cache.lines
        }
        guard let lines = captureLines?(surfaceID, rows) else { return nil }
        cache = (surfaceID, lines, now)
        return lines
    }

    // MARK: - Underline

    private func showUnderline(in view: AppTerminalView, row: Int,
                               colStart: Int, colEnd: Int,
                               cellW: CGFloat, cellH: CGFloat) {
        let rect = TerminalCellGeometry.cellSpanRect(row: row, colStart: colStart, colEnd: colEnd,
                                                     viewHeight: view.bounds.height,
                                                     cellW: cellW, cellH: cellH)
        let underline = self.underline ?? UnderlineView()
        if underline.superview !== view {
            underline.removeFromSuperview()
            view.addSubview(underline)
        }
        underline.frame = rect
        underline.isHidden = false
        self.underline = underline
        NSCursor.pointingHand.set()
    }

    private func clearUnderline() {
        guard let underline, !underline.isHidden else { return }
        underline.isHidden = true
        NSCursor.arrow.set()
    }
}

// MARK: - UnderlineView

/// Draws the hover underline over a terminal surface. libghostty owns the text
/// rendering, so the affordance has to be drawn on top of it rather than into
/// it. Hit-testing is disabled so it can never swallow a click.
private final class UnderlineView: NSView {

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        ZTheme.current.accentColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

import AppKit
import GhosttyTerminal
import ZettyCore
import ZettyGhostty

// MARK: - CopyModeController

/// Drives copy mode on one pane. The keyboard cursor is represented as a
/// **Ghostty-native selection**: cell motions re-place a one-cell selection
/// (or extend from the anchor once `v`/`V` starts one) by synthesizing mouse
/// press/drag/release into the `AppTerminalView` at computed cell centers, so
/// Ghostty renders the highlight and Zetty draws nothing. Scrolling and
/// copy/paste ride `performBindingAction`. Cursor math is pure
/// (`CopyModeCursor` in ZettyCore); this class only translates cells into
/// pixels and events.
///
/// Known v1 limitations (documented in the design doc): word motions need
/// line text, which comes from the pane's zmx capture — without a preserved
/// session they fall back to coarse 8-column jumps; panes running
/// mouse-capturing TUIs may swallow the synthetic clicks.
@MainActor
final class CopyModeController {

    /// Supplies the visible tail of the pane's output (row-indexed lines) for
    /// word motions. Nil when unavailable (no zmx session).
    var captureLines: ((_ surfaceID: UUID, _ rows: Int) -> [String]?)?

    /// Looks up the live terminal view for a surface.
    var terminalView: ((_ surfaceID: UUID) -> AppTerminalView?)?

    /// Looks up the surface's grid metrics (columns/rows + cell pixel size).
    var gridMetrics: ((_ surfaceID: UUID) -> TerminalGridMetrics?)?

    /// The pane copy mode is active on, or nil.
    private(set) var activeSurfaceID: UUID?

    private var cursor = CopyModeCursor(row: 0, col: 0)
    /// Selection anchor once `v` (charwise) or `V` (linewise) was pressed.
    private var anchor: CopyModeCursor?
    private var linewise = false

    // MARK: - Lifecycle

    /// Enters copy mode on `surfaceID`. False when the pane has no live view
    /// or metrics yet (nothing to navigate).
    @discardableResult
    func enter(surfaceID: UUID) -> Bool {
        guard let view = terminalView?(surfaceID),
              let metrics = gridMetrics?(surfaceID),
              metrics.rows > 0, metrics.columns > 0 else { return false }
        activeSurfaceID = surfaceID
        anchor = nil
        linewise = false
        // Start at the bottom-left of the viewport — where the eye is.
        cursor = CopyModeCursor(row: Int(metrics.rows) - 1, col: 0)
        placeSelection(in: view, metrics: metrics)
        return true
    }

    /// Leaves copy mode: clears the selection highlight and rejoins the live
    /// tail of the terminal.
    func exit() {
        defer { activeSurfaceID = nil }
        guard let id = activeSurfaceID, let view = terminalView?(id) else { return }
        clearSelection(in: view)
        view.performBindingAction("scroll_to_bottom")
    }

    // MARK: - Commands

    /// Handles one copy-mode command from the key layer. `copyExit`/`copyYank`
    /// end the session (the engine already left copy mode).
    func perform(_ command: BindingCommand) {
        guard let id = activeSurfaceID,
              let view = terminalView?(id),
              let metrics = gridMetrics?(id) else { return }

        switch command {
        case .copyCursorLeft: move(.left, view: view, metrics: metrics)
        case .copyCursorRight: move(.right, view: view, metrics: metrics)
        case .copyCursorUp: move(.up, view: view, metrics: metrics)
        case .copyCursorDown: move(.down, view: view, metrics: metrics)
        case .copyWordForward: move(.wordForward, view: view, metrics: metrics)
        case .copyWordBackward: move(.wordBackward, view: view, metrics: metrics)
        case .copyWordEnd: move(.wordEnd, view: view, metrics: metrics)
        case .copyLineStart: move(.lineStart, view: view, metrics: metrics)
        case .copyLineEnd: move(.lineEnd, view: view, metrics: metrics)

        case .copyScrollTop:
            view.performBindingAction("scroll_to_top")
            replaceSelectionAfterScroll(view: view, metrics: metrics)
        case .copyScrollBottom:
            view.performBindingAction("scroll_to_bottom")
            replaceSelectionAfterScroll(view: view, metrics: metrics)
        case .copyHalfPageUp:
            view.performBindingAction("scroll_page_fractional:-0.5")
            replaceSelectionAfterScroll(view: view, metrics: metrics)
        case .copyHalfPageDown:
            view.performBindingAction("scroll_page_fractional:0.5")
            replaceSelectionAfterScroll(view: view, metrics: metrics)
        case .copyPageUp:
            view.performBindingAction("scroll_page_up")
            replaceSelectionAfterScroll(view: view, metrics: metrics)
        case .copyPageDown:
            view.performBindingAction("scroll_page_down")
            replaceSelectionAfterScroll(view: view, metrics: metrics)

        case .copyBeginSelection:
            anchor = cursor
            linewise = false
            placeSelection(in: view, metrics: metrics)
        case .copyBeginLineSelection:
            anchor = cursor
            linewise = true
            placeSelection(in: view, metrics: metrics)

        case .copyYank:
            view.performBindingAction("copy_to_clipboard")
            exit()
        case .copyExit:
            exit()

        default:
            break   // not a copy-mode command
        }
    }

    // MARK: - Motions

    private func move(_ motion: CopyMotion, view: AppTerminalView, metrics: TerminalGridMetrics) {
        let rows = Int(metrics.rows)
        let cols = Int(metrics.columns)
        let needsText: Bool
        switch motion {
        case .wordForward, .wordBackward, .wordEnd, .lineEnd: needsText = true
        default: needsText = false
        }
        let lines = needsText ? (captureLines?(activeSurfaceID!, rows) ?? []) : []
        cursor = cursor.moved(motion, rows: rows, cols: cols, lines: lines)
        placeSelection(in: view, metrics: metrics)
    }

    /// After a viewport scroll the cursor keeps its viewport cell; the
    /// selection must be re-placed over the new content.
    private func replaceSelectionAfterScroll(view: AppTerminalView, metrics: TerminalGridMetrics) {
        placeSelection(in: view, metrics: metrics)
    }

    // MARK: - Selection via synthetic mouse

    /// Renders the current cursor/anchor as a Ghostty selection: a drag from
    /// the anchor (or across the single cursor cell) to the cursor.
    private func placeSelection(in view: AppTerminalView, metrics: TerminalGridMetrics) {
        let scale = view.window?.backingScaleFactor ?? 2
        let cellW = CGFloat(metrics.cellWidthPixels) / scale
        let cellH = CGFloat(metrics.cellHeightPixels) / scale
        let cols = Int(metrics.columns)

        // Drag endpoints in ghostty's top-left-origin point space.
        let from: NSPoint
        let to: NSPoint
        if let anchor {
            let start = linewise ? CopyModeCursor(row: anchor.row, col: 0) : anchor
            let end = linewise ? CopyModeCursor(row: cursor.row, col: cols - 1) : cursor
            from = cellCenter(start, cellW: cellW, cellH: cellH)
            to = cellCenter(end, cellW: cellW, cellH: cellH)
        } else {
            // One-cell selection: drag across the cursor cell's interior.
            let base = cellCenter(cursor, cellW: cellW, cellH: cellH)
            from = NSPoint(x: base.x - cellW * 0.35, y: base.y)
            to = NSPoint(x: base.x + cellW * 0.35, y: base.y)
        }
        drag(in: view, from: from, to: to)
    }

    /// A plain click collapses any selection without starting a new one.
    private func clearSelection(in view: AppTerminalView) {
        guard let metrics = activeSurfaceID.flatMap({ gridMetrics?($0) }) else { return }
        let scale = view.window?.backingScaleFactor ?? 2
        let cellW = CGFloat(metrics.cellWidthPixels) / scale
        let cellH = CGFloat(metrics.cellHeightPixels) / scale
        let point = cellCenter(cursor, cellW: cellW, cellH: cellH)
        send(.leftMouseDown, at: point, in: view)
        send(.leftMouseUp, at: point, in: view)
    }

    private func cellCenter(_ cell: CopyModeCursor, cellW: CGFloat, cellH: CGFloat) -> NSPoint {
        NSPoint(x: (CGFloat(cell.col) + 0.5) * cellW, y: (CGFloat(cell.row) + 0.5) * cellH)
    }

    private func drag(in view: AppTerminalView, from: NSPoint, to: NSPoint) {
        send(.leftMouseDown, at: from, in: view)
        // A midpoint sample makes the drag unambiguous for ghostty's
        // selection threshold before the endpoint lands.
        let mid = NSPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        send(.leftMouseDragged, at: mid, in: view)
        send(.leftMouseDragged, at: to, in: view)
        send(.leftMouseUp, at: to, in: view)
    }

    /// Synthesizes one mouse event at a ghostty-space point (top-left origin,
    /// view points) and delivers it straight to the view's responder methods —
    /// in-process, no OS event injection. The view flips y itself
    /// (`mousePoint(from:)` uses `bounds.height - y`), so convert back to
    /// AppKit's bottom-left origin here.
    private func send(_ type: NSEvent.EventType, at ghosttyPoint: NSPoint, in view: AppTerminalView) {
        guard let window = view.window else { return }
        let viewPoint = NSPoint(x: ghosttyPoint.x, y: view.bounds.height - ghosttyPoint.y)
        let windowPoint = view.convert(viewPoint, to: nil)
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else { return }
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        default: break
        }
    }
}

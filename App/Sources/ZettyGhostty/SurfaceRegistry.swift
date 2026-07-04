// SurfaceRegistry.swift — Task 2 / Task 3
//
// Maps each `Surface.id` (UUID) to a persistent pair of (TerminalController,
// TerminalView) so that re-renders never recreate a live terminal.
//
// Session ownership: the PTY session lives inside `TerminalView`
// (AppTerminalView), specifically in its embedded `TerminalSurfaceCoordinator`
// which holds the `TerminalSurface` (real libghostty surface + PTY).
// `TerminalController` only owns the ghostty app/config lifecycle; it does NOT
// hold the PTY.  Therefore both the view AND the controller must be persisted
// — the registry stores a `TerminalViewPair` keyed by `Surface.id`.
//
// Design note — protocol seam:
//   `TerminalController` (from GhosttyTerminal) is @MainActor and calls
//   `ghostty_init` during `init`, which requires a display/PTY context.
//   Instantiating it in a headless test process would crash.  Rather than
//   force-wrapping the concrete type, `SurfaceRegistry` is parameterised over
//   the `TerminalControlling` protocol, so tests can inject a lightweight mock
//   via `controllerFactory`.  Production code uses the default factory, which
//   creates a real `TerminalController`.
//
//   Because `TerminalController` is @MainActor, `SurfaceRegistry` is also
//   @MainActor so that the default factory closure runs on the main actor and
//   Swift's strict concurrency checks are satisfied.

import AppKit
import Combine
import Foundation
import GhosttyTerminal
import ZettyCore

// MARK: - Protocol seam

/// The minimal interface `SurfaceRegistry` requires of a terminal controller.
///
/// `TerminalController` (from GhosttyTerminal) conforms to this protocol via
/// a retroactive conformance below, so callers that already hold a
/// `TerminalController` can use it anywhere a `TerminalControlling` is expected
/// without casting.
public protocol TerminalControlling: AnyObject {}

extension TerminalController: TerminalControlling {}

// MARK: - TerminalViewPair

/// A retained pair of controller + view (+ observable state) for one logical surface.
///
/// The **view** is the persistent unit: it owns the `TerminalSurfaceCoordinator`
/// which holds the live `TerminalSurface` (PTY).  The controller is stored here
/// so callers that only need the controller (e.g. tests) can access it without
/// the view.  `viewState` is the `ObservableObject` delegate that receives live
/// title/workingDirectory callbacks from the terminal and publishes them via
/// Combine.
public struct TerminalViewPair {
    public let controller: any TerminalControlling
    /// The persistent `NSView` that renders this terminal (AppTerminalView).
    public let view: NSView
    /// Observable state bound to this surface's terminal via its delegate.
    /// `nil` only in tests that inject a non-`TerminalController` mock.
    ///
    /// IMPORTANT: this field is the SOLE strong owner of the state — the
    /// terminal view's `delegate` slot (where it's also set) is `weak`. If this
    /// reference is dropped, the live title/workingDirectory subscription dies
    /// silently. Keep the pair (and thus `viewState`) retained for the surface's lifetime.
    public let viewState: TerminalViewState?
}

// MARK: - SurfaceRegistry

/// Stores a `TerminalViewPair` for every live `Surface`, keyed by
/// `Surface.id`.  Callers obtain the view for a surface via
/// `terminalView(for:)` — if one already exists it is returned unchanged;
/// otherwise a new one is created via the factories and stored.
///
/// The `controller(for:)` method is kept for backward-compatibility with
/// existing tests and callers that only need the controller.
///
/// Call `prune(keeping:)` after each layout pass to tear down pairs whose
/// surfaces have been removed.
///
/// `SurfaceRegistry` is `@MainActor` because the default factories create a
/// `TerminalController` and a `TerminalView`, which are themselves `@MainActor`.
@MainActor
public final class SurfaceRegistry {

    // MARK: - Storage

    private var pairs: [UUID: TerminalViewPair] = [:]
    /// Combine cancellables keyed by surface ID — one per retained surface title subscription.
    private var cancellables: [UUID: AnyCancellable] = [:]

    // MARK: - Change callback

    /// Called on the main actor whenever any live surface's title or working
    /// directory changes.  The `UUID` is the surface ID that changed.
    /// `TerminalViewController` installs this closure to trigger a tab-bar refresh.
    public var onTitleChange: ((UUID) -> Void)?

    /// The terminal color theme applied to every controller as it is created.
    /// Set by the app layer from the active `ZTheme` so the terminal surface
    /// matches the app chrome.  Must be assigned before the first
    /// `terminalView(for:)` call to take effect on the initial panes.
    public var terminalTheme: TerminalTheme?

    /// Per-session ghostty configuration overrides (from the user's
    /// `ghostty.*` passthrough directives), applied to every controller as it is
    /// created.  Assign before the first `terminalView(for:)` call.
    public var terminalConfiguration: TerminalConfiguration?

    /// When set, supplies the ghostty `command` a surface's pane should launch
    /// instead of the default shell (e.g. `zmx attach zetty-xxxx` for session
    /// preservation). Consulted once, at surface creation; nil → default shell.
    public var surfaceCommand: ((Surface) -> String?)?

    /// When set, supplies environment variables for a surface's pane (e.g.
    /// per-project env). Injected as repeated ghostty `env` directives at
    /// surface creation; nil/empty → nothing added.
    public var surfaceEnvironment: ((Surface) -> [String: String]?)?

    /// Called with the surface IDs removed by `prune(keeping:)` — the app layer
    /// uses this to kill those surfaces' persistent sessions on explicit close
    /// (app quit never prunes, so quit leaves sessions running).
    public var onSurfacesRemoved: (([UUID]) -> Void)?

    // MARK: - Factories

    /// Closure used to create a new controller for a surface that has no
    /// entry yet.  Defaults to `TerminalController()` (the real ghostty
    /// implementation).  Override in tests to inject a mock.
    private let controllerFactory: @MainActor (Surface) -> any TerminalControlling

    /// Closure used to create a new `NSView` (AppTerminalView) for a surface.
    /// Receives the controller so it can be wired up immediately.
    /// Defaults to creating a properly-configured `TerminalView` with `.exec` backend.
    private let viewFactory: @MainActor (Surface, any TerminalControlling) -> (NSView, TerminalViewState?)

    // MARK: - Init

    public init(
        controllerFactory: @escaping @MainActor (Surface) -> any TerminalControlling = { _ in
            TerminalController()
        },
        viewFactory: @escaping @MainActor (Surface, any TerminalControlling) -> (NSView, TerminalViewState?) = { surface, ctrl in
            let v = TerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
            // The default controllerFactory always produces a real `TerminalController`,
            // so this cast succeeds in production.  A test that injects a non-
            // TerminalController mock will hit the else-branch and leave `v.controller`
            // unconfigured — that is intentional and acceptable for headless tests
            // (the mock never calls into libghostty, so the unconfigured view is fine).
            // Do NOT replace this with a fatalError; the no-op path is relied upon by
            // tests that only care about view identity, not controller wiring.
            var state: TerminalViewState? = nil
            if let tc = ctrl as? TerminalController {
                v.controller = tc
                // Create a TerminalViewState backed by the same controller and wire
                // it as the view's delegate so it receives title/workingDirectory callbacks.
                let s = TerminalViewState(controller: tc)
                v.delegate = s
                state = s
            }
            // Spawn the shell in the surface's working directory (e.g. the project
            // folder) — without this, .exec always starts in the app's cwd.
            v.configuration = TerminalSurfaceOptions(backend: .exec, workingDirectory: surface.workingDir)
            v.translatesAutoresizingMaskIntoConstraints = false
            return (v, state)
        }
    ) {
        self.controllerFactory = controllerFactory
        self.viewFactory = viewFactory
    }

    // MARK: - Public API

    /// Returns the persistent controller for `surface`, creating a pair if
    /// this is the first call for that `surface.id`.
    @discardableResult
    public func controller(for surface: Surface) -> any TerminalControlling {
        pair(for: surface).controller
    }

    /// Returns the persistent `NSView` (AppTerminalView) for `surface`,
    /// creating a pair if this is the first call for that `surface.id`.
    ///
    /// The returned view must be embedded directly into the view hierarchy;
    /// it must not be recreated on subsequent calls — the PTY session lives
    /// inside it and must be preserved across re-renders.
    public func terminalView(for surface: Surface) -> NSView {
        pair(for: surface).view
    }

    /// Injects raw UTF-8 into a surface's pty as synthetic input (control
    /// socket / CLI `send`). Returns false when the surface has no live
    /// terminal view yet (e.g. a background tab whose pane never spawned).
    ///
    /// Delivered via ghostty's `text:` binding action (raw pty write) — NOT
    /// `sendText`/`ghostty_surface_text`, whose paste semantics wrap the
    /// payload in bracketed-paste framing whenever the foreground program
    /// enables it (zsh prompts, TUIs), turning `\r` and control keys into
    /// inert pasted characters instead of input.
    @discardableResult
    public func sendText(_ text: String, to surface: Surface) -> Bool {
        guard let view = pairs[surface.id]?.view as? AppTerminalView else { return false }
        return view.performBindingAction(GhosttyTextAction.encode(text))
    }

    /// Returns the live terminal title for a surface's focused pane, or `nil`
    /// if the surface has no entry yet, no state was created for it, or the
    /// terminal hasn't reported a title (the state's initial value is "", not
    /// nil — callers rely on nil to fall back to the persisted title).
    public func title(for surface: Surface) -> String? {
        guard let title = pairs[surface.id]?.viewState?.title, !title.isEmpty else { return nil }
        return title
    }

    /// Returns the live working directory for a surface's focused pane, or `nil`
    /// if the surface has no entry yet or no state was created for it.
    public func workingDirectory(for surface: Surface) -> String? {
        pairs[surface.id]?.viewState?.workingDirectory
    }

    /// The live `AppTerminalView` for a surface ID, or nil when the pane has
    /// no entry yet. Used by the copy-mode controller to drive binding
    /// actions and synthetic selection on the focused pane.
    public func appTerminalView(for id: UUID) -> AppTerminalView? {
        pairs[id]?.view as? AppTerminalView
    }

    /// The observable view state (grid metrics, focus, title) for a surface
    /// ID, or nil when no state was created (mock-injected tests).
    public func viewState(for id: UUID) -> TerminalViewState? {
        pairs[id]?.viewState
    }

    /// Re-applies `theme` to every LIVE terminal controller and stores it as the
    /// theme for future surfaces. Called when the color scheme changes at runtime
    /// (e.g. the OS toggled appearance in `system` mode) so open panes recolor in
    /// place without being recreated.
    public func reapplyTerminalTheme(_ theme: TerminalTheme) {
        terminalTheme = theme
        for pair in pairs.values {
            if let tc = pair.controller as? TerminalController {
                tc.setTheme(theme)
            }
        }
    }

    /// Re-applies `config` (ghostty passthrough overrides) to every LIVE
    /// controller and stores it for future surfaces. Called on config reload.
    /// A `nil` config clears overrides (empty configuration).
    public func reapplyTerminalConfiguration(_ config: TerminalConfiguration?) {
        terminalConfiguration = config
        let applied = config ?? TerminalConfiguration()
        for pair in pairs.values {
            if let tc = pair.controller as? TerminalController {
                tc.setTerminalConfiguration(applied)
            }
        }
    }

    /// Removes every pair whose id is not in `ids`, allowing them to be
    /// deallocated (which tears down the PTY and ghostty surface).
    public func prune(keeping ids: Set<UUID>) {
        let removed = pairs.keys.filter { !ids.contains($0) }
        guard !removed.isEmpty else { return }
        for id in removed { cancellables[id] = nil }
        pairs = pairs.filter { ids.contains($0.key) }
        onSurfacesRemoved?(removed)
    }

    /// The set of surface IDs that currently have a live pair.
    public var liveIDs: Set<UUID> {
        Set(pairs.keys)
    }

    /// Walks `view`'s superview chain and returns the surface UUID whose
    /// persistent terminal view is `view` or an ancestor of `view`.
    ///
    /// Used by `TerminalViewController` to map a first-responder change back to
    /// a `Surface.id` without relying on `AppTerminalView.onFocusChange` (which
    /// is `internal` to the GhosttyTerminal module).
    public func surfaceID(containing view: NSView) -> UUID? {
        var current: NSView? = view
        while let v = current {
            if let id = pairs.first(where: { $0.value.view === v })?.key {
                return id
            }
            current = v.superview
        }
        return nil
    }

    // MARK: - Private

    private func pair(for surface: Surface) -> TerminalViewPair {
        if let existing = pairs[surface.id] {
            return existing
        }
        let ctrl = controllerFactory(surface)
        // Apply the app's terminal theme before the surface renders so the very
        // first frame is already in-palette (no flash of default colors).
        if let tc = ctrl as? TerminalController {
            if let theme = terminalTheme { tc.setTheme(theme) }
            // Merge the shared passthrough config with this surface's launch
            // command (session preservation) and env vars (per-project
            // settings), when any is present.
            let command = surfaceCommand?(surface)
            let environment = surfaceEnvironment?(surface) ?? [:]
            if terminalConfiguration != nil || command != nil || !environment.isEmpty {
                var config = terminalConfiguration ?? TerminalConfiguration()
                if let command { config = config.custom("command", command) }
                // Sorted for deterministic config; ghostty's `env` directive
                // repeats, one KEY=VALUE per line.
                for key in environment.keys.sorted() {
                    config = config.custom("env", "\(key)=\(environment[key]!)")
                }
                tc.setTerminalConfiguration(config)
            }
        }
        let (view, state) = viewFactory(surface, ctrl)
        let pair = TerminalViewPair(controller: ctrl, view: view, viewState: state)
        pairs[surface.id] = pair

        // Notify on title + workingDirectory changes ONLY (not every @Published
        // property on the state — bell/focus/exit-code changes shouldn't trigger a
        // tab-bar refresh). combineLatest fires once on subscribe, then on either change.
        if let state {
            let id = surface.id
            cancellables[id] = state.$title
                .combineLatest(state.$workingDirectory)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.onTitleChange?(id)
                }
        }

        return pair
    }
}

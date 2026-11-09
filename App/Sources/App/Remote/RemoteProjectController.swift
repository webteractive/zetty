import AppKit
import ZettyCore
import ZettyGhostty

/// Shows one of another Mac's projects in this window: the active tab's
/// splits, each pane a `zetty attach` relay to that Mac.
///
/// It owns a registry of its own, so a remote pane never enters the
/// workspace, the session reconcile or zmx: nothing here can end a session on
/// the other Mac, only the relays. The tab strip is the window's own, fed
/// `tabTitles` and `selectedTabIndex` read-only.
///
/// What the viewer looks at — tab and focused pane — is remembered per
/// project, in memory, and never sent: the other Mac's window doesn't move.
///
/// A project left behind keeps its panes connected for a while
/// (`RemotePaneRetention`), so coming back shows them as they are instead of
/// dialling every pane again and replaying its scrollback.
@MainActor
final class RemoteProjectController {
    let view = NSView()

    /// The window refreshes its tab strip and status bar on this: the tab
    /// titles, the selection or the focused pane changed.
    var onChange: (() -> Void)?

    private let registry = SurfaceRegistry()
    private let zettyExecutable: String
    private var ids = RemoteSurfaceIDs()

    private(set) var machine: RemoteMachine?
    private(set) var projectID: String?
    /// The project's name as last seen, for the "isn't open" placeholder.
    private var projectName: String?

    private struct ViewerState {
        var tab: Int
        var pane: String?
    }
    private var viewerStates: [String: ViewerState] = [:]

    /// What the pane view was built from; an update rebuilds it only when
    /// this changes, so a title tick never re-parents a terminal.
    private struct Shown: Equatable {
        let machine: String
        let project: String
        let tab: Int
        let layout: PaneLayout?
        let panes: [String]
    }
    private var shown: Shown?
    private var tree: Layout?
    private var nodeView: SurfaceNodeView?
    private var placeholder: NSView?

    /// Remote pane per local surface, for the relay command and the status bar.
    private var paneBySurface: [UUID: StatusSnapshot.Pane] = [:]
    /// What each surface's relay was started with; teardown kills by this.
    private var relayTargets = RelayTargets()
    /// When each surface's relay command was built (`announceFocus`).
    private var startedAt: [UUID: Date] = [:]
    /// Until the relay sets raw mode, the pane's tty is cooked and echoes a
    /// focus marker as `^[_zetty-focus^[\`. A refusal leaves that on screen.
    /// A new relay's first attach takes the size by itself anyway.
    private static let focusQuietPeriod: TimeInterval = 2
    private var focusedSurfaceID: UUID?
    /// Surfaces whose relay is being ended; freed after the drain.
    private var awaitingTeardown: Set<UUID> = []

    /// Projects left recently whose panes are still connected, out of view.
    private var kept: [RemotePaneRetention.Kept] = []
    private var keptIDs: Set<UUID> { Set(kept.flatMap(\.surfaces.values)) }
    /// The other Macs as last reported, which decide what stays kept.
    private var machines: [RemoteMachine] = []
    private var pruneTimer: Timer?

    private(set) var tabTitles: [String] = []
    private(set) var selectedTabIndex = 0

    init(zettyExecutable: String, terminalConfiguration: TerminalConfiguration?) {
        self.zettyExecutable = zettyExecutable
        view.wantsLayer = true
        view.layer?.backgroundColor = ZTheme.current.bg1Color.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        registry.terminalTheme = ZTheme.current.terminalTheme()
        registry.terminalConfiguration = terminalConfiguration
        // Never nil: a surface with no command gets this Mac's login shell.
        registry.surfaceCommand = { [weak self] surface in self?.command(for: surface) ?? "/usr/bin/false" }
        registry.surfaceEnvironment = { [weak self] _ in
            // The relay dials this app's port, moved or not, even if the
            // pane's login shell would not pass the variable on.
            self?.machine.map {
                ["ZETTY_REMOTE_MACHINE": $0.name, RemoteProtocol.portVariable: String(RemoteProtocol.port)]
            }
        }
        // `onSurfacesRemoved` stays nil: freeing a remote surface ends only
        // its relay, never a session.
    }

    /// The command line can't quote, so the machine's name (which may have
    /// spaces) travels in the environment and only the target is an argument.
    private func command(for surface: Surface) -> String? {
        guard let address = machine?.address, let pane = paneBySurface[surface.id] else { return nil }
        relayTargets.record(surface.id, address: address, pane: pane.id)
        startedAt[surface.id] = Date()
        return RemoteAttachTarget.paneCommand(executable: zettyExecutable, address: address, pane: pane.id)
    }

    var focusedPane: StatusSnapshot.Pane? {
        focusedSurfaceID.flatMap { paneBySurface[$0] }
    }

    /// What `zetty remote list` says about this view, nil when nothing shows.
    var report: RemoteMachinesReport.Shown? {
        guard let machine, let projectID else { return nil }
        let project = machine.workspace?.projects.first { ($0.id ?? $0.name) == projectID }
        let message = placeholder?.subviews.compactMap { $0 as? NSTextField }.first?.stringValue
        return .init(machineID: machine.stableID, machine: machine.name, projectID: projectID,
                     project: project?.name ?? projectName, tab: selectedTabIndex,
                     panes: message == nil ? shown?.panes ?? [] : [], placeholder: message)
    }

    // MARK: - Showing

    func show(_ machine: RemoteMachine, projectID: String) {
        if self.machine?.stableID != machine.stableID || self.projectID != projectID {
            keepShown()
            projectName = nil
            if let at = kept.firstIndex(where: { $0.machine == machine.stableID && $0.project == projectID }) {
                let back = kept.remove(at: at)
                // Its relays can't follow the Mac to a new address.
                if back.address != machine.address { release(Set(back.surfaces.values)) }
                schedulePrune()
            }
        }
        self.machine = machine
        self.projectID = projectID
        render()
    }

    func update(_ machine: RemoteMachine) {
        guard machine.stableID == self.machine?.stableID, machine != self.machine else { return }
        self.machine = machine
        render()
    }

    /// Leaves the view. Its panes stay connected out of view while
    /// `RemotePaneRetention` allows; remembered tabs and focus stay too.
    func close() {
        keepShown()
        machine = nil
        projectID = nil
        projectName = nil
        tabTitles = []
    }

    /// The other Macs changed: drops kept panes they no longer allow.
    func noteMachines(_ machines: [RemoteMachine]) {
        self.machines = machines
        prune()
    }

    private var stateKey: String? {
        guard let machine, let projectID else { return nil }
        return "\(machine.stableID)/\(projectID)"
    }

    private func render() {
        guard let machine, let projectID else { return }
        // Only while its feed is live: the address is the one that feed
        // reached, so a relay never dials a stale one.
        guard machine.state == .online, machine.address != nil else {
            showPlaceholder("\(machine.name) is offline. Its panes open here when it's back.")
            return
        }
        let project = machine.workspace?.projects.first { ($0.id ?? $0.name) == projectID }
        if let project { projectName = project.name }
        guard let project, !project.hibernated, !project.tabs.isEmpty else {
            showPlaceholder("\(projectName ?? "That project") isn't open on \(machine.name) any more")
            return
        }

        let key = "\(machine.stableID)/\(projectID)"
        var state = viewerStates[key]
            ?? ViewerState(tab: project.tabs.firstIndex(where: \.isActive) ?? 0, pane: nil)
        state.tab = min(max(state.tab, 0), project.tabs.count - 1)
        viewerStates[key] = state
        let tab = project.tabs[state.tab]

        tabTitles = project.tabs.map(\.title)
        selectedTabIndex = state.tab

        // Every pane of the project keeps its relay while the project shows,
        // so switching back to a tab doesn't replay its scrollback.
        var keep: Set<UUID> = []
        for each in project.tabs {
            for pane in each.panes {
                let id = ids.id(machine: machine.stableID, pane: pane.id)
                paneBySurface[id] = pane
                keep.insert(id)
            }
        }
        release(registry.liveIDs.subtracting(keep).subtracting(keptIDs))

        let next = Shown(machine: machine.stableID, project: projectID, tab: state.tab,
                         layout: tab.layout, panes: tab.panes.map(\.id))
        if next != shown || nodeView == nil {
            rebuild(tab: tab, state: state, shown: next)
        } else {
            // Same panes; only titles or directories moved. The tab strip and
            // status bar no-op on unchanged input.
            onChange?()
        }
    }

    private func rebuild(tab: StatusSnapshot.Tab, state: ViewerState, shown next: Shown) {
        guard let machine,
              let root = PaneLayout.surfaceTree(for: tab, ids: &ids, machine: machine.stableID) else {
            showPlaceholder("\(projectName ?? "That project") isn't open on \(machine?.name ?? "that Mac") any more")
            return
        }
        let layout = Layout(root: root)
        let surfaces = layout.surfaces.map(\.id)
        let remembered = state.pane.map { ids.id(machine: machine.stableID, pane: $0) }
        let theirs = tab.panes.first(where: \.isFocused).map { ids.id(machine: machine.stableID, pane: $0.id) }
        focusedSurfaceID = [remembered, theirs].compactMap { $0 }.first(where: surfaces.contains) ?? surfaces.first

        clearContent()
        let node = SurfaceNodeView(node: root, registry: registry, focusedSurfaceID: focusedSurfaceID,
                                   showsClose: false)
        pin(node)
        nodeView = node
        tree = layout
        shown = next
        rememberFocus()
        onChange?()
        focusTerminal()
    }

    private func showPlaceholder(_ message: String) {
        if let label = placeholder?.subviews.compactMap({ $0 as? NSTextField }).first,
           label.stringValue == message {
            return
        }
        releaseAll()
        tabTitles = []
        let placeholder = Self.makePlaceholder(message)
        pin(placeholder)
        self.placeholder = placeholder
        onChange?()
    }

    private func clearContent() {
        nodeView?.removeFromSuperview()
        nodeView = nil
        placeholder?.removeFromSuperview()
        placeholder = nil
        shown = nil
        tree = nil
    }

    private func pin(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    /// Centred like the hibernation placeholder, from `ZTheme` only.
    private static func makePlaceholder(_ message: String) -> NSView {
        let box = NSView()
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = ZTheme.chromeFont(size: 14, weight: .semibold)
        label.textColor = ZTheme.current.fg3Color
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: box.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -24),
        ])
        return box
    }

    // MARK: - Focus and navigation

    /// The terminal that should take the keyboard, if a pane view is up.
    var focusedTerminalView: NSView? {
        guard nodeView != nil, let id = focusedSurfaceID,
              let surface = tree?.surfaces.first(where: { $0.id == id }) else { return nil }
        return registry.terminalView(for: surface)
    }

    private func focusTerminal() {
        guard let terminal = focusedTerminalView else { return }
        view.window?.makeFirstResponder(terminal)
    }

    /// A click moved the window's first responder. True when it landed in one
    /// of these panes, which then takes the focus.
    func noteFirstResponder(_ responder: NSView) -> Bool {
        guard let id = registry.surfaceID(containing: responder) else { return false }
        guard tree?.surfaces.contains(where: { $0.id == id }) == true else { return true }
        if id != focusedSurfaceID { setFocus(id, moveResponder: false) }
        return true
    }

    func isRemoteSurface(_ responder: NSView) -> Bool {
        registry.surfaceID(containing: responder) != nil
    }

    /// Tells the relay in the pane holding `responder` that the user came to
    /// it, so it takes the session's size (`RelaySizeDriver`).
    func announceFocus(_ responder: NSView) {
        guard let id = registry.surfaceID(containing: responder),
              let surface = tree?.surfaces.first(where: { $0.id == id }),
              startedAt[id].map({ Date().timeIntervalSince($0) >= Self.focusQuietPeriod }) ?? true
        else { return }
        registry.sendText(RemoteSizeHandoff.focusMarker, to: surface)
    }

    private func setFocus(_ id: UUID, moveResponder: Bool) {
        focusedSurfaceID = id
        nodeView?.updateFocus(id)
        rememberFocus()
        if moveResponder { focusTerminal() }
        onChange?()
    }

    private func rememberFocus() {
        guard let key = stateKey else { return }
        viewerStates[key]?.pane = focusedPane?.id
    }

    func selectTab(at index: Int) {
        guard let key = stateKey, tabTitles.indices.contains(index), index != selectedTabIndex else { return }
        viewerStates[key]?.tab = index
        viewerStates[key]?.pane = nil
        render()
    }

    func perform(_ effect: RemoteModeBindings.Effect) {
        switch effect {
        case .focus(let direction):
            guard let tree, let current = focusedSurfaceID,
                  let next = tree.neighbor(of: current, direction: direction) else { return }
            setFocus(next, moveResponder: true)
        case .cycleFocus:
            guard let surfaces = tree?.surfaces.map(\.id), surfaces.count > 1,
                  let current = focusedSurfaceID, let at = surfaces.firstIndex(of: current) else { return }
            setFocus(surfaces[(at + 1) % surfaces.count], moveResponder: true)
        case .nextTab:
            guard !tabTitles.isEmpty else { return }
            selectTab(at: (selectedTabIndex + 1) % tabTitles.count)
        case .previousTab:
            guard !tabTitles.isEmpty else { return }
            selectTab(at: (selectedTabIndex - 1 + tabTitles.count) % tabTitles.count)
        case .selectTab(let number):
            selectTab(at: number - 1)
        case .passThrough, .unavailable:
            break
        }
    }

    /// Types `text` into the focused remote pane, as if typed there.
    func sendText(_ text: String) {
        guard let id = focusedSurfaceID, let surface = tree?.surfaces.first(where: { $0.id == id }) else { return }
        registry.sendText(text, to: surface)
    }

    // MARK: - Theme and configuration

    func applyTheme() {
        view.layer?.backgroundColor = ZTheme.current.bg1Color.cgColor
        registry.reapplyTerminalTheme(ZTheme.current.terminalTheme())
        if let label = placeholder?.subviews.compactMap({ $0 as? NSTextField }).first {
            label.textColor = ZTheme.current.fg3Color
        }
    }

    func reloadConfiguration(_ config: TerminalConfiguration?) {
        registry.reapplyTerminalConfiguration(config)
    }

    // MARK: - Teardown

    /// Frees the shown project's relays; kept projects stay.
    private func releaseAll() {
        clearContent()
        focusedSurfaceID = nil
        release(registry.liveIDs.subtracting(keptIDs))
    }

    /// Takes the shown project out of view with its panes still connected.
    private func keepShown() {
        let shownIDs = registry.liveIDs.subtracting(keptIDs).subtracting(awaitingTeardown)
        clearContent()
        focusedSurfaceID = nil
        guard let machine, let projectID, let address = machine.address else {
            release(shownIDs)
            return
        }
        var surfaces: [String: UUID] = [:]
        for id in shownIDs {
            if let pane = paneBySurface[id] { surfaces[pane.id] = id }
        }
        release(shownIDs.subtracting(surfaces.values))
        if !surfaces.isEmpty {
            kept.append(.init(machine: machine.stableID, project: projectID, address: address,
                              leftAt: Date(), surfaces: surfaces))
        }
        prune()
    }

    private func prune() {
        let result = RemotePaneRetention.prune(kept, machines: machines, now: Date())
        kept = result.kept
        release(result.free)
        schedulePrune()
    }

    /// Ages kept projects out while there are any.
    private func schedulePrune() {
        guard !kept.isEmpty else {
            pruneTimer?.invalidate()
            pruneTimer = nil
            return
        }
        guard pruneTimer == nil else { return }
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
    }

    /// Ends each surface's relay, drains its mailbox, then frees it — the
    /// order `surfaces-and-memory.md` requires, since freeing a surface whose
    /// child is still writing joins its io thread on main for good.
    private func release(_ gone: Set<UUID>) {
        let gone = gone.subtracting(awaitingTeardown)
        guard !gone.isEmpty else { return }
        awaitingTeardown.formUnion(gone)
        let targets = relayTargets.take(gone)
        for id in gone { startedAt[id] = nil }
        let root = getpid()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for pid in RelayProcesses.pids(relaying: targets, under: root, psOutput: ZmxRunner.psSnapshot(timeout: 2) ?? "") {
                kill(pid, SIGTERM)
            }
            DispatchQueue.main.async {
                self?.drainThenFree(gone, until: Date().addingTimeInterval(SurfaceTeardownGate.drainDuration))
            }
        }
    }

    private func drainThenFree(_ ids: Set<UUID>, until deadline: Date) {
        registry.drainMailboxes(of: ids)
        guard Date() >= deadline else {
            DispatchQueue.main.asyncAfter(deadline: .now() + SurfaceTeardownGate.drainInterval) { [weak self] in
                self?.drainThenFree(ids, until: deadline)
            }
            return
        }
        awaitingTeardown.subtract(ids)
        registry.prune(keeping: registry.liveIDs.subtracting(ids))
        // A pane that came back on screen during the drain was showing its
        // dying relay; build it again on a fresh one.
        if let tree, !ids.isDisjoint(with: Set(tree.surfaces.map(\.id))) {
            shown = nil
            render()
        }
    }
}

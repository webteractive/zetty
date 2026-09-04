import Foundation

/// Wire protocol between the `Zetty` CLI and the app's control socket
/// (`~/.zetty/zetty.sock`): one JSON object per line, one request →
/// one response per connection. Pure and shared by both sides.

// MARK: - Requests

public enum ControlRequest: Equatable, Sendable {
    case status
    /// List the configured agent accounts. `probe` additionally asks each one
    /// who it is signed in as — a separate process per account, so it is
    /// opt-in rather than the default.
    case accounts(probe: Bool)
    case reload
    /// Open a project-less, ephemeral "scratch" terminal (plain shell, not
    /// persisted) in the Scratch sidebar section. Background by default; `focus`
    /// switches to it. Response `.pane` with the new pane's short id.
    case scratch(focus: Bool)
    /// Close and clear every scratch terminal at once. Response `.ok`.
    case scratchClear
    /// Inject input into a pane: `text` first (verbatim), then each key in
    /// `keys` (see `KeyNotation`), then a carriage return when `enter` is set.
    case send(target: PaneSelector, text: String?, enter: Bool, keys: [String])
    /// Open a new tab in the named project (nil → the active project). Background
    /// by default — the active project/tab and keyboard focus stay put; `focus`
    /// switches to the new tab. Response `.pane` with the new pane's short id.
    /// `account` names the agent account the new pane runs under (nil → the
    /// project's default). An unknown name is an ERROR, never a silent fallback
    /// to the default login — landing on the wrong account is the one mistake
    /// this feature exists to prevent.
    case newTab(project: String?, focus: Bool, account: String?)
    /// Add the directory at `path` (absolute — the CLI resolves relative paths
    /// against its own cwd) as a new project named `name` (nil → the
    /// directory's last path component). Added in the background by default;
    /// `focus` switches to it and spawns its pane. `space` files the project
    /// into an EXISTING Space; an unknown name is an error rather than an
    /// implicit create, so a typo cannot silently produce a second
    /// near-identical Space. The response is `.pane` with its first pane's
    /// short id.
    case addProject(path: String, name: String?, space: String?, focus: Bool)
    /// Clone the named project (nil → the active project) into an isolated
    /// APFS copy-on-write copy under ~/.zetty/clones, on its own git branch.
    /// `name` is the clone name (nil → next free "fork-N"). Background by
    /// default; `focus` switches to it. Response `.pane` with the clone's
    /// first pane's short id.
    case cloneProject(project: String?, name: String?, focus: Bool)
    /// Merge the named clone's SOURCE branch into the clone (update the clone;
    /// leave conflicts in the clone to resolve). Response `.text` with a
    /// summary, or `.error` for a refusal/failure.
    case updateClone(name: String)
    /// Remove the named project (case-insensitive), closing all of its
    /// tabs/panes and ending their zmx sessions (no confirmation dialog —
    /// the CLI call IS the confirmation). The last project can't be removed.
    /// For clones: `fetch` lands the clone's branch in the source repo before
    /// deleting, `discard` skips that; a clone with unsaved work refuses
    /// removal unless one of the two is passed.
    case removeProject(name: String, fetch: Bool, discard: Bool)
    /// Create a new directory at `path` (which must NOT already exist) and add
    /// it as a project named `name` (nil → the last path component); `gitInit`
    /// runs `git init` in the new folder. Added in the background by default;
    /// `focus` switches to it. The response is `.pane` with the first pane's
    /// short id.
    case newProject(path: String, name: String?, gitInit: Bool, focus: Bool)
    /// Hibernate the named project (case-insensitive): free its sessions,
    /// processes, and panes, keeping its layout. Response `.ok`.
    case hibernateProject(name: String)
    /// Wake the named hibernated project — fresh shells, layout intact. `.ok`.
    case wakeProject(name: String)
    /// Create a Space (a user-defined sidebar section). `colorID` is a curated
    /// palette id and `glyph` an SF Symbol; both optional. Errors when the name
    /// is blank or already taken (case-insensitively). Response `.ok`.
    case newSpace(name: String, colorID: String?, glyph: String?)
    /// Rename a Space (case-insensitive lookup). `.ok`, or an error on a
    /// collision.
    case renameSpace(name: String, newName: String)
    /// Delete a Space. Its projects are KEPT — they fall back to
    /// Pinned/Projects. `.ok`.
    case removeSpace(name: String)
    /// Move a project into a Space, or out of every Space when `space` is nil
    /// (`--none`). Errors for Home, Scratch, and clones. `.ok`.
    case moveToSpace(project: String, space: String?)
    /// Hibernate every project in the named Space (`hibernate --space`). `.ok`.
    case hibernateSpace(name: String)
    /// Wake every hibernated project in the named Space (`wake --space`). `.ok`.
    case wakeSpace(name: String)
    /// Close the targeted pane (its tab when it's the last pane), or the
    /// whole tab containing it when `wholeTab` is set.
    case close(target: PaneSelector, wholeTab: Bool)
    /// Quit the app (bypasses the quit confirmation — the CLI call IS the
    /// confirmation). With `killSessions`, every preserved zmx session is
    /// killed first: a full shutdown, nothing survives to reattach. With
    /// `simulateRestart`, the power-off path runs first — snapshot, recovery
    /// manifest, then every session killed as a real restart would — so
    /// restart recovery can be verified without rebooting.
    case quit(killSessions: Bool, simulateRestart: Bool)
    /// Split the targeted pane (vertical = side by side). Background by default —
    /// the split appears but keyboard focus stays on the current pane; `focus`
    /// moves focus to the new pane. Response `.pane` with the new pane's short id.
    case split(target: PaneSelector, vertical: Bool, focus: Bool, account: String?)
    /// Break the targeted pane out into a new tab inserted right after the
    /// current one. Background by default — the new tab is not selected; `focus`
    /// switches to it. The response is `.pane` with the moved pane's short id.
    /// Fails when the pane is the only one in its tab.
    case breakPane(target: PaneSelector, focus: Bool)
    /// Focus the targeted pane (selecting its project/tab).
    case focus(target: PaneSelector)
    /// The targeted pane's recent output (`lines` from the end; nil → all
    /// retained scrollback). Requires the pane's preserved zmx session.
    case capture(target: PaneSelector, lines: Int?)
    /// Peek a text file in the read-only overlay, scrolled to `line`. The path
    /// is absolute (the CLI resolves relative paths against its own cwd). The
    /// overlay belongs to the window, so there's no pane target — it presents
    /// over whatever project and tab are active. Response `.ok`.
    case viewFile(path: String, line: Int?, column: Int?)
}

extension ControlRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case command, target, text, enter, keys, project, wholeTab, killSessions, simulateRestart, vertical, lines, path, name, gitInit, focus, fetch, discard, line, column, space, newName, color, icon, account, probe
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .command) {
        case "status": self = .status
        case "accounts":
            self = .accounts(probe: try container.decodeIfPresent(Bool.self, forKey: .probe) ?? false)
        case "reload": self = .reload
        case "scratch": self = .scratch(focus: try container.decodeIfPresent(Bool.self, forKey: .focus) ?? false)
        case "scratch-clear": self = .scratchClear
        case "send":
            self = .send(
                target: try container.decodeIfPresent(PaneSelector.self, forKey: .target) ?? .focused,
                text: try container.decodeIfPresent(String.self, forKey: .text),
                enter: try container.decodeIfPresent(Bool.self, forKey: .enter) ?? false,
                keys: try container.decodeIfPresent([String].self, forKey: .keys) ?? []
            )
        case "new-tab":
            self = .newTab(
                project: try container.decodeIfPresent(String.self, forKey: .project),
                focus: try container.decodeIfPresent(Bool.self, forKey: .focus) ?? false,
                account: try container.decodeIfPresent(String.self, forKey: .account)
            )
        case "add-project":
            self = .addProject(
                path: try container.decode(String.self, forKey: .path),
                name: try container.decodeIfPresent(String.self, forKey: .name),
                space: try container.decodeIfPresent(String.self, forKey: .space),
                focus: try container.decodeIfPresent(Bool.self, forKey: .focus) ?? false
            )
        case "new-space":
            self = .newSpace(
                name: try container.decode(String.self, forKey: .name),
                colorID: try container.decodeIfPresent(String.self, forKey: .color),
                glyph: try container.decodeIfPresent(String.self, forKey: .icon)
            )
        case "rename-space":
            self = .renameSpace(
                name: try container.decode(String.self, forKey: .name),
                newName: try container.decode(String.self, forKey: .newName)
            )
        case "remove-space":
            self = .removeSpace(name: try container.decode(String.self, forKey: .name))
        case "move-to-space":
            self = .moveToSpace(
                project: try container.decode(String.self, forKey: .project),
                space: try container.decodeIfPresent(String.self, forKey: .space)
            )
        case "hibernate-space":
            self = .hibernateSpace(name: try container.decode(String.self, forKey: .name))
        case "wake-space":
            self = .wakeSpace(name: try container.decode(String.self, forKey: .name))
        case "clone":
            self = .cloneProject(
                project: try container.decodeIfPresent(String.self, forKey: .project),
                name: try container.decodeIfPresent(String.self, forKey: .name),
                focus: try container.decodeIfPresent(Bool.self, forKey: .focus) ?? false
            )
        case "update-clone":
            self = .updateClone(name: try container.decode(String.self, forKey: .project))
        case "remove-project":
            self = .removeProject(
                name: try container.decode(String.self, forKey: .project),
                fetch: try container.decodeIfPresent(Bool.self, forKey: .fetch) ?? false,
                discard: try container.decodeIfPresent(Bool.self, forKey: .discard) ?? false
            )
        case "hibernate":
            self = .hibernateProject(name: try container.decode(String.self, forKey: .project))
        case "wake":
            self = .wakeProject(name: try container.decode(String.self, forKey: .project))
        case "new-project":
            self = .newProject(
                path: try container.decode(String.self, forKey: .path),
                name: try container.decodeIfPresent(String.self, forKey: .name),
                gitInit: try container.decodeIfPresent(Bool.self, forKey: .gitInit) ?? false,
                focus: try container.decodeIfPresent(Bool.self, forKey: .focus) ?? false
            )
        case "close":
            self = .close(
                target: try container.decode(PaneSelector.self, forKey: .target),
                wholeTab: try container.decodeIfPresent(Bool.self, forKey: .wholeTab) ?? false
            )
        case "quit":
            self = .quit(
                killSessions: try container.decodeIfPresent(Bool.self, forKey: .killSessions) ?? false,
                simulateRestart: try container.decodeIfPresent(Bool.self, forKey: .simulateRestart) ?? false)
        case "split":
            self = .split(
                target: try container.decodeIfPresent(PaneSelector.self, forKey: .target) ?? .focused,
                vertical: try container.decodeIfPresent(Bool.self, forKey: .vertical) ?? true,
                focus: try container.decodeIfPresent(Bool.self, forKey: .focus) ?? false,
                account: try container.decodeIfPresent(String.self, forKey: .account)
            )
        case "break":
            self = .breakPane(
                target: try container.decodeIfPresent(PaneSelector.self, forKey: .target) ?? .focused,
                focus: try container.decodeIfPresent(Bool.self, forKey: .focus) ?? false
            )
        case "focus":
            self = .focus(target: try container.decode(PaneSelector.self, forKey: .target))
        case "capture":
            self = .capture(
                target: try container.decodeIfPresent(PaneSelector.self, forKey: .target) ?? .focused,
                lines: try container.decodeIfPresent(Int.self, forKey: .lines)
            )
        case "view":
            self = .viewFile(
                path: try container.decode(String.self, forKey: .path),
                line: try container.decodeIfPresent(Int.self, forKey: .line),
                column: try container.decodeIfPresent(Int.self, forKey: .column)
            )
        case let other:
            throw ControlError.protocolError("unknown command \"\(other)\"")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status:
            try container.encode("status", forKey: .command)
        case .accounts(let probe):
            try container.encode("accounts", forKey: .command)
            try container.encode(probe, forKey: .probe)
        case .reload:
            try container.encode("reload", forKey: .command)
        case .scratch(let focus):
            try container.encode("scratch", forKey: .command)
            try container.encode(focus, forKey: .focus)
        case .scratchClear:
            try container.encode("scratch-clear", forKey: .command)
        case .send(let target, let text, let enter, let keys):
            try container.encode("send", forKey: .command)
            try container.encode(target, forKey: .target)
            try container.encodeIfPresent(text, forKey: .text)
            try container.encode(enter, forKey: .enter)
            try container.encode(keys, forKey: .keys)
        case .newTab(let project, let focus, let account):
            try container.encode("new-tab", forKey: .command)
            try container.encodeIfPresent(project, forKey: .project)
            try container.encode(focus, forKey: .focus)
            try container.encodeIfPresent(account, forKey: .account)
        case .addProject(let path, let name, let space, let focus):
            try container.encode("add-project", forKey: .command)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encodeIfPresent(space, forKey: .space)
            try container.encode(focus, forKey: .focus)
        case .newSpace(let name, let colorID, let glyph):
            try container.encode("new-space", forKey: .command)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(colorID, forKey: .color)
            try container.encodeIfPresent(glyph, forKey: .icon)
        case .renameSpace(let name, let newName):
            try container.encode("rename-space", forKey: .command)
            try container.encode(name, forKey: .name)
            try container.encode(newName, forKey: .newName)
        case .removeSpace(let name):
            try container.encode("remove-space", forKey: .command)
            try container.encode(name, forKey: .name)
        case .moveToSpace(let project, let space):
            try container.encode("move-to-space", forKey: .command)
            try container.encode(project, forKey: .project)
            try container.encodeIfPresent(space, forKey: .space)
        case .hibernateSpace(let name):
            try container.encode("hibernate-space", forKey: .command)
            try container.encode(name, forKey: .name)
        case .wakeSpace(let name):
            try container.encode("wake-space", forKey: .command)
            try container.encode(name, forKey: .name)
        case .cloneProject(let project, let name, let focus):
            try container.encode("clone", forKey: .command)
            try container.encodeIfPresent(project, forKey: .project)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encode(focus, forKey: .focus)
        case .updateClone(let name):
            try container.encode("update-clone", forKey: .command)
            try container.encode(name, forKey: .project)
        case .removeProject(let name, let fetch, let discard):
            try container.encode("remove-project", forKey: .command)
            try container.encode(name, forKey: .project)
            try container.encode(fetch, forKey: .fetch)
            try container.encode(discard, forKey: .discard)
        case .hibernateProject(let name):
            try container.encode("hibernate", forKey: .command)
            try container.encode(name, forKey: .project)
        case .wakeProject(let name):
            try container.encode("wake", forKey: .command)
            try container.encode(name, forKey: .project)
        case .newProject(let path, let name, let gitInit, let focus):
            try container.encode("new-project", forKey: .command)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encode(gitInit, forKey: .gitInit)
            try container.encode(focus, forKey: .focus)
        case .close(let target, let wholeTab):
            try container.encode("close", forKey: .command)
            try container.encode(target, forKey: .target)
            try container.encode(wholeTab, forKey: .wholeTab)
        case .quit(let killSessions, let simulateRestart):
            try container.encode("quit", forKey: .command)
            try container.encode(killSessions, forKey: .killSessions)
            try container.encode(simulateRestart, forKey: .simulateRestart)
        case .split(let target, let vertical, let focus, let account):
            try container.encode("split", forKey: .command)
            try container.encode(target, forKey: .target)
            try container.encode(vertical, forKey: .vertical)
            try container.encode(focus, forKey: .focus)
            try container.encodeIfPresent(account, forKey: .account)
        case .breakPane(let target, let focus):
            try container.encode("break", forKey: .command)
            try container.encode(target, forKey: .target)
            try container.encode(focus, forKey: .focus)
        case .focus(let target):
            try container.encode("focus", forKey: .command)
            try container.encode(target, forKey: .target)
        case .capture(let target, let lines):
            try container.encode("capture", forKey: .command)
            try container.encode(target, forKey: .target)
            try container.encodeIfPresent(lines, forKey: .lines)
        case .viewFile(let path, let line, let column):
            try container.encode("view", forKey: .command)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(line, forKey: .line)
            try container.encodeIfPresent(column, forKey: .column)
        }
    }
}

// MARK: - Responses

public enum ControlResponse: Equatable, Sendable {
    case ok
    case status(StatusSnapshot)
    /// A pane short id (e.g. the pane created by `new-tab` or `split`).
    case pane(String)
    /// Captured pane output.
    case text(String)
    /// The configured agent accounts.
    case accounts(AccountsSnapshot)
    case error(String)
}

/// What `zetty accounts` reports.
///
/// Every field but `id`/`name` is decoded with `decodeIfPresent`, so an OLDER
/// standalone `zetty` binary talking to a newer app doesn't throw on fields it
/// has never heard of — the same tolerance `StatusSnapshot` relies on.
public struct AccountsSnapshot: Codable, Equatable, Sendable {
    public struct Account: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let directory: String
        public let agent: String?
        public let email: String?
        public let orgName: String?
        public let loggedIn: Bool?

        public init(id: String, name: String, directory: String, agent: String? = nil,
                    email: String? = nil, orgName: String? = nil, loggedIn: Bool? = nil) {
            self.id = id
            self.name = name
            self.directory = directory
            self.agent = agent
            self.email = email
            self.orgName = orgName
            self.loggedIn = loggedIn
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, directory, agent, email, orgName, loggedIn
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            directory = try c.decodeIfPresent(String.self, forKey: .directory) ?? ""
            agent = try c.decodeIfPresent(String.self, forKey: .agent)
            email = try c.decodeIfPresent(String.self, forKey: .email)
            orgName = try c.decodeIfPresent(String.self, forKey: .orgName)
            loggedIn = try c.decodeIfPresent(Bool.self, forKey: .loggedIn)
        }
    }

    public var accounts: [Account]
    /// Where the Default account's config lives, so the listing can show it.
    public var defaultDirectory: String?

    public init(accounts: [Account], defaultDirectory: String? = nil) {
        self.accounts = accounts
        self.defaultDirectory = defaultDirectory
    }

    private enum CodingKeys: String, CodingKey { case accounts, defaultDirectory }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        defaultDirectory = try c.decodeIfPresent(String.self, forKey: .defaultDirectory)
    }
}

extension ControlResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case ok, status, pane, text, error, accounts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let message = try container.decodeIfPresent(String.self, forKey: .error) {
            self = .error(message)
        } else if let snapshot = try container.decodeIfPresent(StatusSnapshot.self, forKey: .status) {
            self = .status(snapshot)
        } else if let pane = try container.decodeIfPresent(String.self, forKey: .pane) {
            self = .pane(pane)
        } else if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            self = .text(text)
        } else if let accounts = try container.decodeIfPresent(AccountsSnapshot.self, forKey: .accounts) {
            self = .accounts(accounts)
        } else {
            self = .ok
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok:
            try container.encode(true, forKey: .ok)
        case .status(let snapshot):
            try container.encode(true, forKey: .ok)
            try container.encode(snapshot, forKey: .status)
        case .pane(let id):
            try container.encode(true, forKey: .ok)
            try container.encode(id, forKey: .pane)
        case .text(let text):
            try container.encode(true, forKey: .ok)
            try container.encode(text, forKey: .text)
        case .accounts(let snapshot):
            try container.encode(true, forKey: .ok)
            try container.encode(snapshot, forKey: .accounts)
        case .error(let message):
            try container.encode(false, forKey: .ok)
            try container.encode(message, forKey: .error)
        }
    }
}

// MARK: - Status payload

public struct StatusSnapshot: Codable, Equatable, Sendable {
    public struct Pane: Codable, Equatable, Sendable {
        public let id: String            // 8-hex short surface id (zmx session suffix)
        public let title: String?        // last emitted terminal title
        public let cwd: String?
        public let tool: String?         // probed foreground command
        public let agentStatus: String?  // running / idle / needsAttention
        public let isFocused: Bool       // focused pane of the active tab
        /// Whether the pane has a live terminal behind it right now. False for a
        /// background pane whose shell hasn't spawned yet and for every pane of a
        /// hibernated project. `send` materializes a non-live pane on demand, so
        /// this is a description of the pane's current state, not of whether it
        /// can be driven — see `Project.hibernated` for the reason it is false.
        public let live: Bool
        /// The agent account this pane was spawned under, when it isn't the
        /// default login. nil keeps the field absent for anyone not using
        /// accounts.
        public let account: String?

        public init(id: String, title: String?, cwd: String?, tool: String?, agentStatus: String?,
                    isFocused: Bool, live: Bool, account: String? = nil) {
            self.id = id
            self.title = title
            self.cwd = cwd
            self.tool = tool
            self.agentStatus = agentStatus
            self.isFocused = isFocused
            self.live = live
            self.account = account
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, cwd, tool, agentStatus, isFocused, live, account
        }

        /// Hand-written so `live` defaults instead of throwing when an older
        /// payload omits it (a stale standalone `zetty` build talking to a newer
        /// app). The encode side stays synthesized.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
            tool = try c.decodeIfPresent(String.self, forKey: .tool)
            agentStatus = try c.decodeIfPresent(String.self, forKey: .agentStatus)
            isFocused = try c.decodeIfPresent(Bool.self, forKey: .isFocused) ?? false
            live = try c.decodeIfPresent(Bool.self, forKey: .live) ?? false
            account = try c.decodeIfPresent(String.self, forKey: .account)
        }
    }

    /// A user-defined sidebar section. Rendered as a header by
    /// `ControlCLI.statusLines`, including when it holds no projects.
    public struct Space: Codable, Equatable, Sendable {
        public let name: String
        public let collapsed: Bool

        public init(name: String, collapsed: Bool) {
            self.name = name
            self.collapsed = collapsed
        }

        private enum CodingKeys: String, CodingKey { case name, collapsed }

        /// Hand-written for the same reason as `Pane.init(from:)`: an older
        /// payload must default rather than throw.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        }
    }

    public struct Tab: Codable, Equatable, Sendable {
        public let title: String
        public let isActive: Bool
        public let panes: [Pane]

        public init(title: String, isActive: Bool, panes: [Pane]) {
            self.title = title
            self.isActive = isActive
            self.panes = panes
        }
    }

    public struct Project: Codable, Equatable, Sendable {
        public let name: String
        public let isActive: Bool
        /// Whether the project is hibernated — its sessions, processes and panes
        /// are freed and only its layout remains, so every pane below it reports
        /// `live: false`. The verbs that need a live pane wake it implicitly, so
        /// this is diagnostic rather than an obstacle; `zetty wake <name>` makes
        /// it explicit.
        public let hibernated: Bool
        /// The Space this project renders under, or nil for Pinned/Projects.
        public let space: String?
        public let tabs: [Tab]

        public init(name: String, isActive: Bool, hibernated: Bool, space: String? = nil, tabs: [Tab]) {
            self.name = name
            self.isActive = isActive
            self.hibernated = hibernated
            self.space = space
            self.tabs = tabs
        }

        private enum CodingKeys: String, CodingKey {
            case name, isActive, hibernated, space, tabs
        }

        /// Hand-written for the same reason as `Pane.init(from:)`: `hibernated`
        /// defaults rather than throwing on an older payload.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
            hibernated = try c.decodeIfPresent(Bool.self, forKey: .hibernated) ?? false
            space = try c.decodeIfPresent(String.self, forKey: .space)
            tabs = try c.decodeIfPresent([Tab].self, forKey: .tabs) ?? []
        }
    }

    public let projects: [Project]
    /// Every Space in sidebar order, including empty ones.
    public let spaces: [Space]

    public init(projects: [Project], spaces: [Space] = []) {
        self.projects = projects
        self.spaces = spaces
    }

    private enum CodingKeys: String, CodingKey { case projects, spaces }

    /// Hand-written so `spaces` defaults instead of throwing when an older app
    /// omits it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decode([Project].self, forKey: .projects)
        spaces = try c.decodeIfPresent([Space].self, forKey: .spaces) ?? []
    }

    /// Every pane across all projects/tabs, in display order.
    public var panes: [Pane] {
        projects.flatMap { $0.tabs.flatMap(\.panes) }
    }
}

// MARK: - Pane selection

public enum PaneSelector: Equatable, Sendable {
    /// The focused pane of the active tab (the default target).
    case focused
    /// A pane by unique short-id prefix (4+ hex chars recommended).
    case pane(String)
    /// The single pane whose working directory matches `path`.
    case cwd(String)

    public func resolve(in panes: [StatusSnapshot.Pane]) throws -> StatusSnapshot.Pane {
        switch self {
        case .focused:
            guard let pane = panes.first(where: \.isFocused) ?? panes.first else {
                throw ControlError.noSuchPane("no panes open")
            }
            return pane
        case .pane(let prefix):
            let needle = prefix.lowercased()
            let matches = panes.filter { $0.id.lowercased().hasPrefix(needle) }
            guard !matches.isEmpty else { throw ControlError.noSuchPane("no pane matches id \"\(prefix)\"") }
            guard matches.count == 1 else {
                throw ControlError.ambiguous("id \"\(prefix)\" matches \(matches.count) panes")
            }
            return matches[0]
        case .cwd(let path):
            let needle = Self.normalize(path)
            let matches = panes.filter { $0.cwd.map(Self.normalize) == needle }
            guard !matches.isEmpty else { throw ControlError.noSuchPane("no pane in \(path)") }
            guard matches.count == 1 else {
                throw ControlError.ambiguous("\(matches.count) panes are in \(path) — target by id")
            }
            return matches[0]
        }
    }

    private static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.count > 1 && expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded
    }
}

extension PaneSelector: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "focused": self = .focused
        case "pane": self = .pane(try container.decode(String.self, forKey: .value))
        case "cwd": self = .cwd(try container.decode(String.self, forKey: .value))
        case let other: throw ControlError.protocolError("unknown selector \"\(other)\"")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .focused:
            try container.encode("focused", forKey: .kind)
        case .pane(let id):
            try container.encode("pane", forKey: .kind)
            try container.encode(id, forKey: .value)
        case .cwd(let path):
            try container.encode("cwd", forKey: .kind)
            try container.encode(path, forKey: .value)
        }
    }
}

// MARK: - Errors + framing

public enum ControlError: Error, Equatable, LocalizedError {
    case protocolError(String)
    case noSuchPane(String)
    case ambiguous(String)

    public var errorDescription: String? {
        switch self {
        case .protocolError(let m), .noSuchPane(let m), .ambiguous(let m): return m
        }
    }
}

/// One-JSON-object-per-line framing helpers.
public enum ControlWire {
    public static func encodeLine(_ request: ControlRequest) throws -> String {
        String(data: try JSONEncoder().encode(request), encoding: .utf8)! + "\n"
    }

    public static func encodeLine(_ response: ControlResponse) throws -> String {
        String(data: try JSONEncoder().encode(response), encoding: .utf8)! + "\n"
    }

    public static func decodeRequest(_ line: String) throws -> ControlRequest {
        try JSONDecoder().decode(ControlRequest.self, from: Data(line.utf8))
    }

    public static func decodeResponse(_ line: String) throws -> ControlResponse {
        try JSONDecoder().decode(ControlResponse.self, from: Data(line.utf8))
    }
}

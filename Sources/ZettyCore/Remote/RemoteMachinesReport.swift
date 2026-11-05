import Foundation

/// What `zetty remote list` reports: the other Macs as this app mirrors them,
/// and which of their projects (if any) the window is showing. It is how a
/// script, `scripts/remote-e2e.sh` among them, checks the feature without
/// looking at the sidebar.
///
/// Every field but `machines` is decoded with `decodeIfPresent`, the same
/// tolerance `StatusSnapshot` and `AccountsSnapshot` give an older CLI.
public struct RemoteMachinesReport: Codable, Equatable, Sendable {
    public struct Machine: Codable, Equatable, Sendable {
        /// Tailscale's stable node ID.
        public let id: String
        public let name: String
        /// `connecting`, `online`, `offline`, `needs-update` or `refused`.
        public let state: String
        /// The sidebar header's text: "2 · 1 needs you", "offline · seen 2h ago".
        public let summary: String
        public let address: String?
        /// ISO 8601: the last snapshot while online, else when it dropped.
        public let lastSeen: String?
        public let workspace: StatusSnapshot?

        public init(id: String, name: String, state: String, summary: String,
                    address: String?, lastSeen: String?, workspace: StatusSnapshot?) {
            self.id = id
            self.name = name
            self.state = state
            self.summary = summary
            self.address = address
            self.lastSeen = lastSeen
            self.workspace = workspace
        }

        public init(_ machine: RemoteMachine, now: Date) {
            let state: String
            switch machine.state {
            case .connecting: state = "connecting"
            case .online: state = "online"
            case .offline: state = "offline"
            case .needsUpdate: state = "needs-update"
            case .refused: state = "refused"
            }
            self.init(id: machine.stableID, name: machine.name, state: state,
                      summary: RemoteMachineSummary.text(for: machine, now: now),
                      address: machine.address,
                      lastSeen: machine.lastSeen.map { ISO8601DateFormatter().string(from: $0) },
                      workspace: machine.workspace)
        }
    }

    /// The other Mac's project in the window.
    public struct Shown: Codable, Equatable, Sendable {
        public let machineID: String
        public let machine: String
        public let projectID: String
        public let project: String?
        /// 0-based, into that project's tabs.
        public let tab: Int
        /// That Mac's pane ids in the shown tab, one relay each.
        public let panes: [String]
        /// What the view says instead of panes ("<Mac> is offline. …"), if it does.
        public let placeholder: String?

        public init(machineID: String, machine: String, projectID: String, project: String?,
                    tab: Int, panes: [String], placeholder: String? = nil) {
            self.machineID = machineID
            self.machine = machine
            self.projectID = projectID
            self.project = project
            self.tab = tab
            self.panes = panes
            self.placeholder = placeholder
        }
    }

    /// `zetty-remote-machines`: whether this Mac lists other Macs at all.
    public var listing: Bool
    /// `zetty-serve`, and a server exists. Listening also needs Tailscale.
    public var serving: Bool
    /// The port served and dialled (`RemoteProtocol.port`).
    public var port: Int
    public var machines: [Machine]
    public var shown: Shown?

    public init(listing: Bool, serving: Bool, port: Int, machines: [Machine], shown: Shown? = nil) {
        self.listing = listing
        self.serving = serving
        self.port = port
        self.machines = machines
        self.shown = shown
    }

    private enum CodingKeys: String, CodingKey { case listing, serving, port, machines, shown }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        listing = try c.decodeIfPresent(Bool.self, forKey: .listing) ?? false
        serving = try c.decodeIfPresent(Bool.self, forKey: .serving) ?? false
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? Int(RemoteProtocol.defaultPort)
        machines = try c.decode([Machine].self, forKey: .machines)
        shown = try c.decodeIfPresent(Shown.self, forKey: .shown)
    }

    /// Finds `query` among the machines by name (case-insensitive) or id.
    public func machine(matching query: String) -> Machine? {
        machines.first { $0.id == query }
            ?? machines.first { $0.name.caseInsensitiveCompare(query) == .orderedSame }
    }
}

extension RemoteMachinesReport.Machine {
    /// Finds `query` among this Mac's awake projects by id or name
    /// (case-insensitive). A hibernated project can't be opened from here.
    public func project(matching query: String) -> StatusSnapshot.Project? {
        let awake = (workspace?.projects ?? []).filter { !$0.hibernated }
        return awake.first { $0.id == query }
            ?? awake.first { $0.name.caseInsensitiveCompare(query) == .orderedSame }
    }
}

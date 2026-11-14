/// When Zetty's node may start, and what Sign Out does. Kept apart from the
/// bridge so it can be tested.
///
/// A start that failed (a denied Keychain prompt, a locked Keychain, an
/// unreadable saved state) is not tried again on every config reload, which
/// would read the Keychain, and maybe ask, each time: only when the user
/// clicks Try Again, turns Other Macs off and on, or signs out.
public struct TailnetLifecycle: Equatable, Sendable {
    public enum SignOut: Equatable, Sendable {
        /// Sign the running node out (its machine key stays).
        case logOut
        /// The node couldn't start: forget the saved sign-in and start again
        /// fresh, as a new device that needs a sign-in.
        case forgetAndRestart(hostname: String)
        /// Other Macs is off.
        case nothing
    }

    public enum Retry: Equatable, Sendable {
        /// The node isn't running: start it, reading the Keychain again.
        case start(hostname: String)
        /// The node runs but reports an error: stop it and start it again.
        case restart(hostname: String)

        public var hostname: String {
            switch self {
            case .start(let name), .restart(let name): return name
            }
        }
    }

    /// The device name while either remote switch wants the node.
    public private(set) var wanted: String?
    public private(set) var running = false
    public private(set) var failed = false

    public init() {}

    /// True when the node should start now (and read the Keychain).
    public mutating func requestStart(hostname: String) -> Bool {
        wanted = hostname
        return !running && !failed
    }

    public mutating func started() { running = true }

    /// A new device name chosen while the node isn't running: the next start
    /// (including Sign Out's restart) uses it. A running node is renamed
    /// through the bridge instead.
    public mutating func rename(to hostname: String) {
        if wanted != nil { wanted = hostname }
    }

    public mutating func startFailed() {
        running = false
        failed = true
    }

    /// Try Again: start a node that failed to start, or restart one that runs
    /// but reports an error. Nil when Other Macs is off.
    public mutating func retry() -> Retry? {
        guard let wanted else { return nil }
        failed = false
        if running {
            running = false
            return .restart(hostname: wanted)
        }
        return .start(hostname: wanted)
    }

    /// True when a running node must be stopped.
    public mutating func requestStop() -> Bool {
        defer { wanted = nil; running = false; failed = false }
        return running
    }

    public mutating func signOut() -> SignOut {
        if running { return .logOut }
        guard let wanted else { return .nothing }
        failed = false
        return .forgetAndRestart(hostname: wanted)
    }
}

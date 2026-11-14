/// When Zetty's node may start, and what Sign Out does. Kept apart from the
/// bridge so it can be tested.
///
/// A Keychain read that failed (a denied prompt, a locked Keychain) is not
/// tried again on every config reload, which would ask again each time:
/// only when the user clicks Try Again, turns Other Macs off and on, or signs
/// out.
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

    /// The device name while either remote switch wants the node.
    public private(set) var wanted: String?
    public private(set) var running = false
    public private(set) var keychainRefused = false

    public init() {}

    /// True when the node should start now (and read the Keychain).
    public mutating func requestStart(hostname: String) -> Bool {
        wanted = hostname
        return !running && !keychainRefused
    }

    public mutating func started() { running = true }

    /// A new device name chosen while the node isn't running: the next start
    /// (including Sign Out's restart) uses it. A running node is renamed
    /// through the bridge instead.
    public mutating func rename(to hostname: String) {
        if wanted != nil { wanted = hostname }
    }

    public mutating func startFailed(keychain: Bool) {
        running = false
        if keychain { keychainRefused = true }
    }

    /// Try Again after a failed start: the device name to start now (reading
    /// the Keychain again), or nil when the node is running or Other Macs is
    /// off.
    public mutating func retry() -> String? {
        guard let wanted, !running else { return nil }
        keychainRefused = false
        return wanted
    }

    /// True when a running node must be stopped.
    public mutating func requestStop() -> Bool {
        defer { wanted = nil; running = false; keychainRefused = false }
        return running
    }

    public mutating func signOut() -> SignOut {
        if running { return .logOut }
        guard let wanted else { return .nothing }
        keychainRefused = false
        return .forgetAndRestart(hostname: wanted)
    }
}

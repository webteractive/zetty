import Foundation
import ZettyCore
import ZettyTailnet

/// Zetty's own Tailscale node (`Bridge/tailnet`, tsnet), one per app. Every
/// Other Macs connection goes through it: the server listens on it, the
/// client and the relays dial through it, and `whois` asks it who a peer is.
///
/// Every call into the bridge may block on the network, so they run on
/// `queue` (or the dial and accept threads); `onState` lands on main. Never
/// call `whois` on main.
final class Tailnet {
    /// The bridge has one node per process and calls back through C, so the
    /// callbacks find the instance here.
    fileprivate static weak var shared: Tailnet?

    private let home: String
    private let onState: (TailnetState) -> Void
    private let queue = DispatchQueue(label: "co.webteractive.zetty.tailnet", qos: .utility)
    private let persistQueue = DispatchQueue(label: "co.webteractive.zetty.tailnet.persist", qos: .utility)
    private let dialQueue = DispatchQueue(label: "co.webteractive.zetty.tailnet.dial", qos: .userInitiated,
                                          attributes: .concurrent)
    private let store: TailnetStateStore
    /// On `queue`: whether the node is wanted and runs, the last event, the
    /// last state.
    private var lifecycle = TailnetLifecycle()
    private var running: Bool { lifecycle.running }
    private var lastEvent = Data(#"{"state":"Starting"}"#.utf8)
    private var lastState: TailnetState?
    private var refresh: DispatchSourceTimer?
    /// The last status read, kept through one slow or failed read so a
    /// running node doesn't flicker to "starting" and tear everything down.
    private var lastStatus: TailscaleStatus?
    /// On `queue`: Sign In's wait for the page Tailscale sends back.
    private var pendingPage: (deadline: Date, open: (URL) -> Void)?

    /// The latest state, read on main.
    private(set) var latest: TailnetState = .off

    /// `ZETTY_TAILSCALE_AUTH_KEY_FILE`: an unattended test copy enrolls with
    /// that auth key as an ephemeral node whose state lives only in memory.
    static let authKeyFileVariable = "ZETTY_TAILSCALE_AUTH_KEY_FILE"

    init(home: String, onState: @escaping (TailnetState) -> Void) {
        self.home = home
        self.onState = onState
        store = TailnetStateStore(account: RemoteMachineID.stateAccount(home: home, hardware: MacHardware.uuid))
        Tailnet.shared = self
    }

    /// tsnet's working files (no keys: those are in the Keychain).
    private var workingDirectory: String {
        (home as NSString).appendingPathComponent("Library/Caches/co.webteractive.zetty/tailscale")
    }

    // MARK: - Lifecycle

    /// Safe to call on every config reload: a running node is left alone,
    /// and a failed start is tried again only after Try Again, `stop()` or
    /// Sign Out (`TailnetLifecycle`).
    func start(hostname: String) {
        queue.async { [self] in
            guard lifecycle.requestStart(hostname: hostname) else { return }
            startNow(hostname: hostname)
        }
    }

    /// On `queue`.
    private func startNow(hostname: String) {
        publish(.starting)
        let ephemeral: Bool
        var authKey: String?
        var blob = Data()
        if let path = ProcessInfo.processInfo.environment[Self.authKeyFileVariable] {
            guard let key = Self.readAuthKey(at: path) else {
                lifecycle.startFailed()
                return publish(.failed("The test auth key file can't be used: it must be a file only you can read"))
            }
            authKey = key
            ephemeral = true
        } else {
            ephemeral = false
            switch store.load() {
            case .empty: break
            case .blob(let data): blob = data
            case .unreadable(let status):
                ZettyLog.remote.error("tailnet: Keychain read failed (\(status))")
                lifecycle.startFailed()
                return publish(.failed("Zetty couldn't read its Tailscale sign-in from the Keychain "
                                       + "(error \(status)). Unlock the Keychain or allow access, then "
                                       + "click Try Again, or click Sign Out to sign in again."))
            }
        }
        try? FileManager.default.createDirectory(atPath: workingDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let failure = Self.bridgeCall { err in
            workingDirectory.withCString { dir in
                hostname.withCString { host in
                    withOptionalCString(authKey) { key in
                        blob.withUnsafeBytes { raw in
                            let bytes = raw.bindMemory(to: UInt8.self).baseAddress
                            return zt_start(UnsafeMutablePointer(mutating: dir),
                                            UnsafeMutablePointer(mutating: host),
                                            key.map { UnsafeMutablePointer(mutating: $0) }, ephemeral ? 1 : 0,
                                            UnsafeMutablePointer(mutating: bytes), blob.count,
                                            tailnetStateCallback, ephemeral ? nil : tailnetPersistCallback,
                                            tailnetLogCallback, err)
                        }
                    }
                }
            }
        }
        if let failure {
            lifecycle.startFailed()
            return publish(.failed(failure))
        }
        lifecycle.started()
        startRefresh()
    }

    /// Try Again in Settings: starts a node that failed to start (reading
    /// the Keychain again), or restarts one that runs but reports an error,
    /// without the user turning Other Macs off. Only while the state is
    /// failed: a second click queued behind the first one's Keychain prompt
    /// would otherwise ask again after a Deny.
    func retry() {
        queue.async { [self] in
            guard case .failed? = lastState, let action = lifecycle.retry() else { return }
            if case .restart = action {
                refresh?.cancel()
                refresh = nil
                zt_stop()
                lastEvent = Data(#"{"state":"Starting"}"#.utf8)
                lastStatus = nil
            }
            startNow(hostname: action.hostname)
        }
    }

    /// Both remote switches are off. Also a retry after a failed start: the
    /// next start reads the Keychain again.
    func stop() {
        queue.async { [self] in
            pendingPage = nil
            if lifecycle.requestStop() {
                refresh?.cancel()
                refresh = nil
                zt_stop()
            }
            publish(.off)
        }
    }

    /// On quit: stops the node, waiting at most 4s (an ephemeral test node
    /// signs out first, so it leaves the tailnet now). The one bounded wait
    /// on main, like `RemoteServer.stop`.
    func stopBeforeQuit() {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            if lifecycle.requestStop() {
                refresh?.cancel()
                refresh = nil
                zt_stop()
            }
            // Saves still queued land before the app goes.
            persistQueue.sync {}
            done.signal()
        }
        _ = done.wait(timeout: .now() + 4)
    }

    /// Asks Tailscale for a sign-in page and hands `open` (on main) the one
    /// it sends back: a fresh page, or one Tailscale knows is still valid.
    /// Never the URL cached in the state, which may have expired.
    func login(open: @escaping (URL) -> Void) {
        queue.async { [self] in
            guard running else { return }
            pendingPage = (Date().addingTimeInterval(60), open)
            if let failure = Self.bridgeCall({ zt_login($0) }) {
                pendingPage = nil
                ZettyLog.remote.error("tailnet: login failed: \(failure)")
            }
        }
    }

    /// Settings' Sign Out. A running node signs out (its machine key stays,
    /// so signing in again is the same machine). A node that couldn't start
    /// (an unreadable Keychain item) forgets its saved sign-in and starts
    /// over as a new device that needs a sign-in.
    func logout() {
        queue.async { [self] in
            switch lifecycle.signOut() {
            case .logOut:
                if let failure = Self.bridgeCall({ zt_logout($0) }) {
                    ZettyLog.remote.error("tailnet: logout failed: \(failure)")
                }
            case .forgetAndRestart(let hostname):
                let status = store.clear()
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    ZettyLog.remote.error("tailnet: couldn't forget the saved sign-in (\(status))")
                    lifecycle.startFailed()
                    return publish(.failed("Zetty couldn't remove its saved Tailscale sign-in from the Keychain "
                                           + "(error \(status)). Delete \"Zetty Tailscale sign-in\" in Keychain "
                                           + "Access, then click Try Again."))
                }
                ZettyLog.remote.log("tailnet: forgot the saved sign-in, starting over")
                guard lifecycle.requestStart(hostname: hostname) else { return }
                startNow(hostname: hostname)
            case .nothing:
                return
            }
        }
    }

    func rename(_ name: String) {
        queue.async { [self] in
            lifecycle.rename(to: name)
            guard running else { return }
            if let failure = Self.bridgeCall({ err in
                name.withCString { zt_set_hostname(UnsafeMutablePointer(mutating: $0), err) }
            }) {
                ZettyLog.remote.error("tailnet: rename failed: \(failure)")
            }
            refreshStatus()
        }
    }

    // MARK: - Connections

    /// Who `address` ("ip:port") is, or nil. Blocks: call only off main.
    func whois(_ address: String) -> TailscaleNode? {
        guard let json = address.withCString({ zt_whois_json(UnsafeMutablePointer(mutating: $0)) }) else { return nil }
        defer { zt_free(json) }
        return TailscaleWhois.parse(Data(String(cString: json).utf8))
    }

    /// Accepts connections on `port` until the listener is closed, handing
    /// each one's descriptor and "ip:port" to `onAccept` on its own thread.
    func listen(port: UInt16, onAccept: @escaping (Int32, String) -> Void) -> TailnetListener? {
        var failure: String?
        let id = Self.bridgeValue(&failure) { zt_listen(port, $0) }
        guard id > 0 else {
            ZettyLog.remote.error("tailnet: listen on \(port) failed: \(failure ?? "unknown error")")
            return nil
        }
        let listener = TailnetListener(id: id)
        let thread = Thread {
            var remote = [CChar](repeating: 0, count: 128)
            while true {
                let fd = zt_accept(id, &remote, remote.count)
                guard fd >= 0 else { return }
                onAccept(fd, String(cString: remote))
            }
        }
        thread.name = "co.webteractive.zetty.tailnet.accept"
        thread.start()
        return listener
    }

    /// Dials `ip:port` through the node; `completion` gets the descriptor or
    /// nil, on a background queue.
    func dial(_ ip: String, port: UInt16, timeout: TimeInterval, completion: @escaping (Int32?) -> Void) {
        dialQueue.async { [self] in
            completion(try? dialNow(ip, port: port, timeout: timeout).get())
        }
    }

    /// The same, blocking: for the control socket's own queue.
    func dialNow(_ ip: String, port: UInt16, timeout: TimeInterval) -> Result<Int32, TailnetError> {
        var failure: String?
        let fd = Self.bridgeValue(&failure) { err in
            ip.withCString { zt_dial(UnsafeMutablePointer(mutating: $0), port, Int32(timeout * 1000), err) }
        }
        return fd >= 0 ? .success(fd) : .failure(TailnetError(message: failure ?? "unknown error"))
    }

    // MARK: - State

    fileprivate func received(event json: String) {
        queue.async { [self] in
            lastEvent = Data(json.utf8)
            if let url = TailnetState.pageToOpen(event: lastEvent), let pending = pendingPage {
                pendingPage = nil
                if pending.deadline > Date() { DispatchQueue.main.async { pending.open(url) } }
            }
            refreshStatus()
        }
    }

    fileprivate func persist(_ blob: Data) {
        persistQueue.async { [store] in
            if !store.save(blob) { ZettyLog.remote.error("tailnet: couldn't save the sign-in to the Keychain") }
        }
    }

    /// On `queue`.
    private func refreshStatus() {
        guard running else { return }
        var status: TailscaleStatus?
        if let json = zt_status_json() {
            status = TailscaleStatus.parse(Data(String(cString: json).utf8))
            zt_free(json)
        }
        if status == nil, case .running? = lastState { status = lastStatus }
        lastStatus = status
        publish(TailnetState.from(event: lastEvent, status: status))
    }

    private func startRefresh() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.refreshStatus() }
        refresh = timer
        timer.resume()
    }

    /// On `queue`: reports only changes, on main.
    private func publish(_ state: TailnetState) {
        guard state != lastState else { return }
        lastState = state
        DispatchQueue.main.async { [weak self] in
            self?.latest = state
            self?.onState(state)
        }
    }

    /// Runs a bridge call that returns 0 or -1: nil, or that call's own error.
    private static func bridgeCall(_ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32) -> String? {
        var failure: String?
        return bridgeValue(&failure, body) == 0 ? nil : (failure ?? "unknown error")
    }

    /// Runs a bridge call, putting its own error text (if it set one) in
    /// `failure`.
    private static func bridgeValue(_ failure: inout String?,
                                    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32) -> Int32 {
        var err: UnsafeMutablePointer<CChar>?
        let value = body(&err)
        if let err {
            let text = String(cString: err)
            zt_free(err)
            failure = text.isEmpty ? nil : text
        }
        return value
    }

    /// A regular file owned by this user that no one else can read, and not a
    /// symlink. Env vars are trusted configuration, but a key others can read
    /// is a key others can enroll with.
    static func readAuthKey(at path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
}

/// A bridge call's own error text.
struct TailnetError: Error {
    let message: String
}

/// An open listener on the node; `close` ends its accept loop.
final class TailnetListener {
    private let id: Int32
    private var closed = false

    fileprivate init(id: Int32) { self.id = id }

    func close() {
        guard !closed else { return }
        closed = true
        zt_close_listener(id)
    }

    deinit { close() }
}

private func withOptionalCString<R>(_ text: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let text else { return body(nil) }
    return text.withCString { body($0) }
}

// The bridge's callbacks run on Go's threads.

private let tailnetStateCallback: zt_state_cb = { json in
    guard let json else { return }
    Tailnet.shared?.received(event: String(cString: json))
}

private let tailnetPersistCallback: zt_persist_cb = { blob, length in
    guard let blob, length > 0 else { return }
    Tailnet.shared?.persist(Data(bytes: blob, count: length))
}

/// Tailscale's lines for people go to Zetty's log with links blanked: a
/// sign-in link would enroll this Zetty in whoever's tailnet opens it, and
/// "Copy diagnostics" puts the log on the clipboard.
private let tailnetLogCallback: zt_log_cb = { line in
    guard let line else { return }
    let raw = String(cString: line)
    // tsnet repeats its sign-in hint every 5s while signed out; Settings and
    // the notification already say it.
    if raw.hasPrefix("To start this tsnet server") { return }
    let text = raw.replacingOccurrences(of: #"https?://\S+"#, with: "<link>",
                                                          options: .regularExpression)
    ZettyLog.remote.log("tailscale: \(text)")
}

/// A value read and written from any thread.
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A reference read and written from any thread.
final class LockedBox<Value: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

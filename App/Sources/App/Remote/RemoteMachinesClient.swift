import Darwin
import Foundation
import ZettyCore

/// Keeps a live, view-only mirror of each of the user's other Macs that
/// serve their workspace, plus the last known state of the ones that are away.
///
/// It dials other Zettys' own Tailscale devices through this Zetty's node
/// (`Tailnet`): only peers `PeerAdmission` admits, read from the node's own
/// status, and WireGuard guarantees the connection reaches that node. Links
/// are keyed by node; machines by the machine ID each hello carries, so a Mac
/// that signs in again (a new node) stays one group.
///
/// `update` and `stop` are called from main; connections run on one serial
/// queue; `onChange` and `machines` are delivered on main.
final class RemoteMachinesClient {
    private let cache: RemoteMachineCache
    private let machineName: String
    private let zettyVersion: String
    private let machineID: String
    private let tailnet: Tailnet
    private let onChange: ([RemoteMachine]) -> Void
    private let queue = DispatchQueue(label: "co.webteractive.zetty.remote-client")

    /// Main-thread copy, sorted by name.
    private(set) var machines: [RemoteMachine] = []
    /// Main-thread: set by `stop`, so an emit already queued for main can't
    /// put the machines back after the owner cleared them.
    private var stoppedOnMain = false

    // Everything below is confined to `queue`.
    /// By machine ID (or by node, for a Zetty that hasn't said hello).
    private var byID: [String: RemoteMachine] = [:]
    /// Online, admitted peers: the ones worth dialling, by node ID.
    private var candidates: [String: TailscaleNode] = [:]
    private var links: [String: Link] = [:]
    /// Dials in flight, by node ID.
    private var dialling: Set<String> = []
    private var retries: [String: Retry] = [:]
    /// The IPv4 each open link dialled; a snapshot over that link stamps it on
    /// the machine, so a viewer knows where to send `zetty attach`.
    private var dialled: [String: String] = [:]
    private var lastSave: Date?
    private var pendingSave: DispatchWorkItem?
    private var stopped = false

    private static let connectTimeout: TimeInterval = 3
    private static let backoff: [TimeInterval] = [5, 10, 30, 60]
    private static let saveInterval: TimeInterval = 5

    private struct Retry {
        var attempt: Int
        var work: DispatchWorkItem?
    }

    init(cache: RemoteMachineCache, machineName: String, zettyVersion: String, machineID: String,
         tailnet: Tailnet, onChange: @escaping ([RemoteMachine]) -> Void) {
        self.cache = cache
        self.machineName = machineName
        self.zettyVersion = zettyVersion
        self.machineID = machineID
        self.tailnet = tailnet
        self.onChange = onChange
        queue.async { [self] in
            for machine in cache.load() { byID[machine.stableID] = machine }
            emit()
        }
    }

    /// Opens and closes connections to match what the node says now.
    func update(_ state: TailnetState) {
        queue.async { [self] in
            guard !stopped else { return }
            guard let status = state.status, status.me != nil else {
                disconnectAll()
                return
            }
            candidates = Dictionary(PeerAdmission.candidates(in: status).map { ($0.stableID, $0) },
                                    uniquingKeysWith: { first, _ in first })
            // A candidate becomes a group when it answers (`received`), so a
            // Mac that runs no Zetty, or doesn't serve, never shows up.
            byID = RemoteRoster.reconcile(byID, with: status)
            // Gone from the tailnet's online, admitted set: hang up.
            for id in links.keys where candidates[id] == nil { drop(id, retry: false) }
            for id in retries.keys where candidates[id] == nil { cancelRetry(id) }
            // A retry that already fired keeps its entry (that is the backoff
            // count), so only a still-pending one means "wait".
            for id in candidates.keys where links[id] == nil && !dialling.contains(id) && retries[id]?.work == nil {
                connect(id)
            }
            emit()
        }
    }

    /// True when `ip` is where an online Mac's feed is connected now: the
    /// only address a relay may be dialled to (`remote-connect`). Safe off
    /// main; never call it on this client's queue.
    func isOnlineAddress(_ ip: String) -> Bool {
        queue.sync { byID.values.contains { $0.state == .online && $0.address == ip } }
    }

    /// A relay's connection to `ip`, dialled through this client's node.
    /// Blocks: for the control socket's queue, never main.
    func dialForRelay(_ ip: String) -> Result<Int32, TailnetError> {
        tailnet.dialNow(ip, port: RemoteProtocol.port, timeout: Self.connectTimeout)
    }

    func stop() {
        stoppedOnMain = true
        queue.sync { [self] in
            stopped = true
            disconnectAll()
            pendingSave?.cancel()
            cache.save(Array(byID.values))
        }
    }

    // MARK: - State

    private func disconnectAll() {
        for id in links.keys { drop(id, retry: false) }
        for id in retries.keys { cancelRetry(id) }
        candidates = [:]
        // Without the node no reason can be vouched for, so every Mac goes
        // offline, its last sighting stamped if it was online.
        let now = Date()
        for id in byID.keys {
            byID[id]?.markDisconnected(at: now)
            byID[id]?.state = .offline
        }
        emit()
    }

    private func emit() {
        let sorted = byID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stoppedOnMain else { return }
            self.machines = sorted
            self.onChange(sorted)
        }
    }

    /// At most one write per `saveInterval`; the last state always lands.
    private func scheduleSave() {
        guard pendingSave == nil else { return }
        let wait = lastSave.map { max(0, Self.saveInterval - Date().timeIntervalSince($0)) } ?? 0
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSave = nil
            self.lastSave = Date()
            self.cache.save(Array(self.byID.values))
        }
        pendingSave = work
        queue.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// The machine key for node `id`: the one a hello adopted, else the node.
    private func key(forNode id: String) -> String {
        byID.first(where: { $0.value.node == id })?.key ?? id
    }

    // MARK: - Connections

    private func connect(_ id: String) {
        guard let node = candidates[id],
              let address = node.addresses.first(where: { !$0.contains(":") }) else { return }
        dialling.insert(id)
        let key = key(forNode: id)
        if byID[key] != nil { byID[key]?.state = .connecting }
        tailnet.dial(address, port: RemoteProtocol.port, timeout: Self.connectTimeout) { [weak self] fd in
            guard let self else { if let fd { Darwin.close(fd) }; return }
            self.queue.async { self.dialFinished(id, address: address, fd: fd) }
        }
    }

    private func dialFinished(_ id: String, address: String, fd: Int32?) {
        dialling.remove(id)
        guard let fd else {
            if !stopped, candidates[id] != nil { drop(id, retry: true) }
            return
        }
        guard !stopped, candidates[id] != nil, links[id] == nil, let link = Link(fd: fd, queue: queue) else {
            Darwin.close(fd)
            return
        }
        links[id] = link
        dialled[id] = address
        // The server speaks first: its hello, then this side's.
        link.onMessages = { [weak self] messages in self?.received(messages, from: id) }
        link.onFailed = { [weak self] in self?.drop(id, retry: true) }
        link.startReading()
    }

    private func received(_ messages: [RemoteMessage], from id: String) {
        guard let link = links[id], let node = candidates[id] else { return }
        for message in messages {
            switch message {
            case .hello(let theirs):
                let name = RemoteText.displayable(theirs.machine, limit: 80)
                let machineKey = theirs.machineID.flatMap { RemoteMachineID.isValid($0) ? $0 : nil } ?? id
                RemoteRoster.adopt(&byID, machineID: machineKey, node: id,
                                   name: name.isEmpty ? node.hostName : name)
                guard theirs.protocolVersion == RemoteProtocol.version else {
                    byID[machineKey]?.state = .needsUpdate(theirs: theirs.protocolVersion)
                    continue
                }
                let hello = RemoteHello(machine: machineName, zettyVersion: zettyVersion,
                                        protocolVersion: RemoteProtocol.version, machineID: machineID)
                guard let frame = try? RemoteFrame.encode(.hello(hello)), link.send(frame) else {
                    return drop(id, retry: true)
                }
                link.greeted = true
            case .snapshot(let snapshot):
                guard link.greeted else { return drop(id, retry: true) }
                let machineKey = key(forNode: id)
                guard var machine = byID[machineKey] else { continue }
                machine.workspace = snapshot
                machine.address = dialled[id] ?? machine.address
                machine.lastSeen = Date()
                machine.state = .online
                byID[machineKey] = machine
                retries[id] = nil
                scheduleSave()
            case .refused(let reason):
                let machineKey = key(forNode: id)
                var machine = byID[machineKey]
                    ?? RemoteMachine(stableID: machineKey, name: node.hostName, state: .connecting,
                                     lastSeen: nil, workspace: nil, node: id)
                machine.state = .refused(RemoteText.displayable(reason))
                byID[machineKey] = machine
            case .attached:
                // Only a terminal connection gets this; a feed never asks.
                break
            }
        }
        emit()
    }

    /// Closes `id`'s connection. A dropped peer goes offline, unless it said
    /// why it won't talk to us; that reason stays on its header.
    private func drop(_ id: String, retry: Bool) {
        links.removeValue(forKey: id)?.close()
        let machineKey = key(forNode: id)
        byID[machineKey]?.markDisconnected(at: Date())
        if retry, !stopped { scheduleRetry(id) }
        emit()
    }

    private func scheduleRetry(_ id: String) {
        let attempt = retries[id]?.attempt ?? 0
        let delay = Self.backoff[min(attempt, Self.backoff.count - 1)]
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.retries[id]?.work = nil
            guard self.candidates[id] != nil, self.links[id] == nil, !self.dialling.contains(id) else { return }
            self.connect(id)
        }
        retries[id] = Retry(attempt: attempt + 1, work: work)
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelRetry(_ id: String) {
        retries.removeValue(forKey: id)?.work?.cancel()
    }
}

// MARK: - Link

/// One outgoing connection, already connected through the node: the
/// server's hello, this side's, then frames in.
private final class Link {
    private let fd: Int32
    private let readSource: DispatchSourceRead
    private var readResumed = false
    private var decoder = RemoteFrameDecoder()
    private var closed = false
    /// This side has answered the server's hello.
    var greeted = false

    var onMessages: (([RemoteMessage]) -> Void)?
    var onFailed: (() -> Void)?

    /// Takes `fd` over (non-blocking); nil when it can't be configured.
    init?(fd: Int32, queue: DispatchQueue) {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }
        RemoteProtocol.configureLink(fd)
        self.fd = fd
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setCancelHandler { Darwin.close(fd) }
        readSource.setEventHandler { [weak self] in self?.readAvailable() }
    }

    /// Writes a small frame whole, or reports failure. Only the hello goes
    /// this way, and it fits any fresh socket's send buffer.
    func send(_ frame: Data) -> Bool {
        let count = frame.withUnsafeBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return -1 }
            return write(fd, base, frame.count)
        }
        return count == frame.count
    }

    func startReading() {
        guard !readResumed, !closed else { return }
        readResumed = true
        readSource.resume()
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = read(fd, &buffer, buffer.count)
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        guard count > 0 else { onFailed?(); return }
        do {
            let messages = try decoder.push(Data(buffer[0..<count]))
            if !messages.isEmpty { onMessages?(messages) }
        } catch {
            onFailed?()
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        onMessages = nil
        onFailed = nil
        // A suspended source never runs its cancel handler, so resume first.
        if !readResumed { readResumed = true; readSource.resume() }
        readSource.cancel()
    }
}

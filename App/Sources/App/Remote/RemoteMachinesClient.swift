import Darwin
import Foundation
import ZettyCore

/// Keeps a live, view-only mirror of each of the user's other Macs that
/// serve their workspace, plus the last known state of the ones that are away.
///
/// `update` and `stop` are called from main; connections run on one serial
/// queue; `onChange` and `machines` are delivered on main.
final class RemoteMachinesClient {
    private let cache: RemoteMachineCache
    private let machineName: String
    private let zettyVersion: String
    private let onChange: ([RemoteMachine]) -> Void
    private let queue = DispatchQueue(label: "co.webteractive.zetty.remote-client")

    /// Main-thread copy, sorted by name.
    private(set) var machines: [RemoteMachine] = []
    /// Main-thread: set by `stop`, so an emit already queued for main can't
    /// put the machines back after the owner cleared them.
    private var stoppedOnMain = false

    // Everything below is confined to `queue`.
    private var byID: [String: RemoteMachine] = [:]
    /// Online, admitted peers: the ones worth dialling, by stable ID.
    private var candidates: [String: TailscaleNode] = [:]
    private var links: [String: Link] = [:]
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

    init(cache: RemoteMachineCache, machineName: String, zettyVersion: String,
         onChange: @escaping ([RemoteMachine]) -> Void) {
        self.cache = cache
        self.machineName = machineName
        self.zettyVersion = zettyVersion
        self.onChange = onChange
        queue.async { [self] in
            for machine in cache.load() { byID[machine.stableID] = machine }
            emit()
        }
    }

    /// Opens and closes connections to match what Tailscale says now.
    func update(_ state: TailscaleState) {
        queue.async { [self] in
            guard !stopped else { return }
            guard case .running(let status) = state, status.me != nil else {
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
            for id in candidates.keys where links[id] == nil && retries[id]?.work == nil { connect(id) }
            emit()
        }
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
        // Without Tailscale no reason can be vouched for, so every Mac goes
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

    // MARK: - Connections

    private func connect(_ id: String) {
        guard let node = candidates[id],
              let address = node.addresses.first(where: { !$0.contains(":") }) else { return }
        guard let link = Link.open(address, port: RemoteProtocol.port, queue: queue) else {
            scheduleRetry(id)
            return
        }
        links[id] = link
        dialled[id] = address
        byID[id]?.state = .connecting
        link.onConnected = { [weak self, weak link] in
            guard let self, let link else { return }
            let hello = RemoteHello(machine: self.machineName, zettyVersion: self.zettyVersion,
                                    protocolVersion: RemoteProtocol.version)
            guard let frame = try? RemoteFrame.encode(.hello(hello)), link.send(frame) else {
                self.drop(id, retry: true)
                return
            }
            link.startReading()
        }
        link.onMessages = { [weak self] messages in self?.received(messages, from: id) }
        link.onFailed = { [weak self] in self?.drop(id, retry: true) }
        queue.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak self, weak link] in
            guard let self, let link, !link.isConnected, self.links[id] === link else { return }
            self.drop(id, retry: true)
        }
    }

    private func received(_ messages: [RemoteMessage], from id: String) {
        guard var machine = byID[id]
            ?? candidates[id].map({ RemoteMachine(stableID: id, name: $0.hostName, state: .connecting,
                                                  lastSeen: nil, workspace: nil) }) else { return }
        for message in messages {
            switch message {
            case .hello(let theirs):
                machine.name = theirs.machine
                if theirs.protocolVersion != RemoteProtocol.version {
                    machine.state = .needsUpdate(theirs: theirs.protocolVersion)
                }
            case .snapshot(let snapshot):
                machine.workspace = snapshot
                machine.address = dialled[id] ?? machine.address
                machine.lastSeen = Date()
                machine.state = .online
                retries[id] = nil
                scheduleSave()
            case .refused(let reason):
                machine.state = .refused(reason)
            case .attached:
                // Only a terminal connection gets this; a feed never asks.
                break
            }
        }
        byID[id] = machine
        emit()
    }

    /// Closes `id`'s connection. A dropped peer goes offline, unless it said
    /// why it won't talk to us; that reason stays on its header.
    private func drop(_ id: String, retry: Bool) {
        links.removeValue(forKey: id)?.close()
        byID[id]?.markDisconnected(at: Date())
        if retry, !stopped { scheduleRetry(id) }
        emit()
    }

    private func scheduleRetry(_ id: String) {
        let attempt = retries[id]?.attempt ?? 0
        let delay = Self.backoff[min(attempt, Self.backoff.count - 1)]
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.retries[id]?.work = nil
            guard self.candidates[id] != nil, self.links[id] == nil else { return }
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

/// One outgoing connection: a non-blocking connect, a hello, then frames in.
private final class Link {
    private let fd: Int32
    private let readSource: DispatchSourceRead
    private let writeSource: DispatchSourceWrite
    private var readResumed = false
    private var writeResumed = false
    private var decoder = RemoteFrameDecoder()
    private var closed = false
    private(set) var isConnected = false

    var onConnected: (() -> Void)?
    var onMessages: (([RemoteMessage]) -> Void)?
    var onFailed: (() -> Void)?

    private init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        let cancelled = DispatchGroup()
        cancelled.enter()
        cancelled.enter()
        readSource.setCancelHandler { cancelled.leave() }
        writeSource.setCancelHandler { cancelled.leave() }
        cancelled.notify(queue: queue) { Darwin.close(fd) }
        writeSource.setEventHandler { [weak self] in self?.connectFinished() }
        readSource.setEventHandler { [weak self] in self?.readAvailable() }
    }

    /// Starts a non-blocking connect to an IPv4 address; completion arrives
    /// as `onConnected` or `onFailed`.
    static func open(_ address: String, port: UInt16, queue: DispatchQueue) -> Link? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else { return nil }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, size)
        // A Mac that vanishes without a FIN (sleep, `tailscale down`) is
        // noticed in ~16s instead of the system's two hours.
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, size)
        var idle: Int32 = 10, interval: Int32 = 3, count: Int32 = 2
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle, size)
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &interval, size)
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &count, size)
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { Darwin.close(fd); return nil }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 || errno == EINPROGRESS else { Darwin.close(fd); return nil }
        let link = Link(fd: fd, queue: queue)
        link.writeResumed = true
        link.writeSource.resume()   // writable = the connect finished, one way or the other
        return link
    }

    private func connectFinished() {
        guard !isConnected, !closed else { return }
        writeSource.suspend()
        writeResumed = false
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
            onFailed?()
            return
        }
        isConnected = true
        onConnected?()
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
        onConnected = nil
        onMessages = nil
        onFailed = nil
        // A suspended source never runs its cancel handler, so resume first.
        if !readResumed { readResumed = true; readSource.resume() }
        if !writeResumed { writeResumed = true; writeSource.resume() }
        readSource.cancel()
        writeSource.cancel()
    }
}

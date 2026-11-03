import Darwin
import Foundation
import ZettyCore

/// How the serving Mac runs one remote pane: the process to put on a pty, and
/// the zmx session it attaches to.
struct RemoteAttachPlan {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    /// `zetty-<id>`, handed back in `detached(session:)`.
    let session: String
}

/// Why a pane can't be opened, in plain words for the other Mac's pane.
struct RemoteAttachRefusal: Error {
    let message: String
}

/// The serving Zetty's side of a terminal connection. Both methods may be
/// called on any queue and must not block it.
protocol RemoteTerminalHosting: AnyObject {
    /// Makes the pane live (without moving this Mac's screen) and says what to
    /// run. Never creates a zmx session.
    func plan(for request: RemoteAttachRequest,
              completion: @escaping (Result<RemoteAttachPlan, RemoteAttachRefusal>) -> Void)
    /// A remote client let go of `session`.
    func detached(session: String)
}

/// Serves this Mac's workspace to the user's other Macs on the tailnet.
///
/// Binds only to this Mac's own Tailscale addresses, never `INADDR_ANY`. Every
/// connection is checked with `tailscale whois` and `PeerAdmission` before
/// anything is read from it. A connection's hello decides what it is: a
/// workspace feed (hellos and snapshots; anything the client sends after its
/// hello is ignored), or, with `attach`, one pane's terminal, piped through a
/// pty the server runs (`PaneStream`).
///
/// The public methods are called from main. All socket work happens on one
/// serial queue.
final class RemoteServer {
    private let machineName: String
    private let zettyVersion: String
    private let whois: (String) -> TailscaleNode?
    private let terminalHost: RemoteTerminalHosting?
    private let queue = DispatchQueue(label: "co.webteractive.zetty.remote-server")
    /// `whois` shells out and can take a while, so it never runs on `queue`.
    private let whoisQueue = DispatchQueue(label: "co.webteractive.zetty.remote-server.whois",
                                           qos: .utility, attributes: .concurrent)

    // Everything below is confined to `queue`.
    private var me: TailscaleNode?
    private var listeners: [String: Listener] = [:]
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var latestFrame: Data?

    /// More pending snapshots than this means the peer isn't reading. Drop it
    /// rather than buffer without bound.
    /// Terminal connections are exempt: they pause the pane's output instead.
    private static let maxPendingFrames = 8
    /// Every open remote pane is its own connection.
    private static let maxConnections = 64
    /// A terminal connection stops reading its pty above this many queued
    /// bytes, and starts again below `resumeBelow`. Nothing is dropped.
    private static let pauseAbove = 512 * 1024
    private static let resumeBelow = 128 * 1024

    /// With no `terminalHost`, every attach is refused.
    init(machineName: String, zettyVersion: String, terminalHost: RemoteTerminalHosting? = nil,
         whois: @escaping (String) -> TailscaleNode? = { TailscaleCLI.whois($0) }) {
        self.machineName = machineName
        self.zettyVersion = zettyVersion
        self.terminalHost = terminalHost
        self.whois = whois
    }

    /// Binds one listener per address on `RemoteProtocol.port`, closes the
    /// listeners whose address went away, and retries any that failed to bind
    /// before. An empty list stops listening and drops every connection.
    func listen(on addresses: [String], me: TailscaleNode) {
        queue.async { [self] in
            self.me = me
            let wanted = Set(addresses)
            for (address, listener) in listeners where !wanted.contains(address) {
                listener.close()
                listeners[address] = nil
            }
            for address in wanted where listeners[address] == nil {
                listeners[address] = Listener.bind(address, queue: queue) { [weak self] fd in
                    self?.accepted(fd)
                }
            }
            if wanted.isEmpty { closeAllConnections() }
        }
    }

    /// Stores the latest snapshot and sends it to every streaming peer.
    func publish(_ snapshot: StatusSnapshot) {
        queue.async { [self] in
            guard let frame = try? RemoteFrame.encode(.snapshot(snapshot)) else { return }
            latestFrame = frame
            for connection in connections.values where connection.phase == .streaming {
                send(frame, on: connection)
            }
        }
    }

    /// Returns once the listening sockets are closed, so a server started
    /// right after (serving switched off and on) can bind the same addresses.
    func stop() {
        let closing: [DispatchGroup] = queue.sync { [self] in
            let groups = listeners.values.map { $0.close() }
            listeners.removeAll()
            closeAllConnections()
            latestFrame = nil
            return groups
        }
        // The cancel handlers that close the fds run on `queue`, after the sync.
        for group in closing { _ = group.wait(timeout: .now() + 1) }
    }

    // MARK: - Connections

    private func accepted(_ fd: Int32) {
        // Each connection costs a `whois` process, so a peer that opens
        // connections in a loop can't fork without bound.
        guard connections.count < Self.maxConnections,
              let ip = Socket.peerAddress(fd) else { Darwin.close(fd); return }
        let connection = Connection(fd: fd, queue: queue)
        connections[ObjectIdentifier(connection)] = connection
        connection.onReadable = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.readAvailable(on: connection)
        }
        connection.onClosed = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.connections[ObjectIdentifier(connection)] = nil
            // The relay let go (or the pane ended): end its pty child, then
            // tell the host, which may need to restore this Mac's own size.
            if let stream = connection.stream {
                connection.stream = nil
                let host = self.terminalHost
                stream.stop { host?.detached(session: stream.session) }
            }
        }
        whoisQueue.async { [weak self] in
            guard let self else { return }
            let peer = self.whois(ip)
            self.queue.async { self.admit(connection, peer: peer, ip: ip) }
        }
    }

    private func admit(_ connection: Connection, peer: TailscaleNode?, ip: String) {
        guard connection.phase == .admitting, let me else { connection.close(); return }
        if case .refuse(let reason) = PeerAdmission.decide(me: me, peer: peer) {
            if let frame = try? RemoteFrame.encode(.refused(reason.message(machine: peer?.hostName ?? ip))) {
                connection.closeAfterFlush = true
                send(frame, on: connection)
            } else {
                connection.close()
            }
            return
        }
        let hello = RemoteHello(machine: machineName, zettyVersion: zettyVersion,
                                protocolVersion: RemoteProtocol.version)
        guard let frame = try? RemoteFrame.encode(.hello(hello)) else { connection.close(); return }
        connection.phase = .awaitingHello
        send(frame, on: connection)
        connection.startReading()
        queue.asyncAfter(deadline: .now() + RemoteProtocol.helloTimeout) { [weak connection] in
            guard let connection, connection.phase == .awaitingHello else { return }
            connection.close()
        }
    }

    private func readAvailable(on connection: Connection) {
        guard let bytes = connection.readChunk() else { connection.close(); return }
        switch connection.phase {
        case .terminal:
            guard let frames = try? connection.terminalDecoder.push(bytes) else { connection.close(); return }
            for frame in frames {
                switch frame {
                case .data(let input): connection.stream?.write(input)
                case .resize(let rows, let cols): connection.stream?.pty.resize(rows: rows, cols: cols)
                case .ended: break // only the server ends a pane
                }
            }
        case .attaching:
            // A relay waits for `attached` before it sends anything.
            if !bytes.isEmpty { connection.close() }
        case .awaitingHello:
            // One message only: a relay's hello may be all there is for now,
            // and nothing after it is JSON once it is attached.
            let messages: [RemoteMessage]
            do { messages = try connection.decoder.push(bytes, stopAfter: 1) } catch { connection.close(); return }
            guard let message = messages.first else { return }
            guard case .hello(let theirs) = message else { connection.close(); return }
            guard theirs.protocolVersion == RemoteProtocol.version else {
                // Kept open so their side can say "needs update" rather
                // than "offline"; it just never gets a snapshot.
                connection.phase = .mismatched
                return
            }
            if let request = theirs.attach {
                beginAttach(request, on: connection)
                return
            }
            connection.phase = .streaming
            if let latestFrame { send(latestFrame, on: connection) }
            // Whatever followed the hello is checked like any later bytes.
            do { _ = try connection.decoder.push(Data()) } catch { connection.close() }
        default:
            do { _ = try connection.decoder.push(bytes) } catch { connection.close() }
        }
    }

    // MARK: - Terminal connections

    private func beginAttach(_ request: RemoteAttachRequest, on connection: Connection) {
        guard request.isValidPane else { refuse(connection, "that isn't a pane id"); return }
        guard let terminalHost else { refuse(connection, "\(machineName) isn't set up to open panes"); return }
        connection.phase = .attaching
        terminalHost.plan(for: request) { [weak self, weak connection] result in
            self?.queue.async {
                guard let self, let connection else { return }
                self.planned(result, request: request, on: connection)
            }
        }
    }

    private func planned(_ result: Result<RemoteAttachPlan, RemoteAttachRefusal>,
                         request: RemoteAttachRequest, on connection: Connection) {
        // The relay may have gone while the host was planning.
        guard connection.phase == .attaching else { return }
        let plan: RemoteAttachPlan
        switch result {
        case .failure(let refusal):
            refuse(connection, refusal.message)
            return
        case .success(let success):
            plan = success
        }
        guard let pty = try? PTYProcess.spawn(executable: plan.executable, arguments: plan.arguments,
                                              environment: plan.environment,
                                              rows: max(request.rows, 1), cols: max(request.cols, 1)),
              let attached = try? RemoteFrame.encode(.attached) else {
            refuse(connection, "couldn't start that pane on \(machineName)")
            return
        }
        let stream = PaneStream(pty: pty, session: plan.session, queue: queue)
        connection.stream = stream
        connection.enqueue(attached)
        connection.terminalDecoder = TerminalFrameDecoder(seed: connection.decoder.takeRemainder())
        connection.phase = .terminal

        stream.onOutput = { [weak connection, weak stream] output in
            guard let connection, let stream else { return }
            connection.enqueue(TerminalFrame.data(output).encode())
            if connection.pendingBytes > Self.pauseAbove { stream.pauseOutput() }
        }
        stream.onEnded = { [weak self, weak connection] in
            guard let self, let connection, connection.phase == .terminal else { return }
            connection.closeAfterFlush = true
            connection.enqueue(TerminalFrame.ended("that pane closed on \(self.machineName)").encode())
        }
        connection.onFlushed = { [weak connection] in
            guard let connection, connection.pendingBytes < Self.resumeBelow else { return }
            connection.stream?.resumeOutput()
        }
        stream.start()
    }

    /// Sends a plain-words refusal, then closes once it is written.
    private func refuse(_ connection: Connection, _ reason: String) {
        guard let frame = try? RemoteFrame.encode(.refused(reason)) else { connection.close(); return }
        connection.closeAfterFlush = true
        connection.enqueue(frame)
    }

    private func send(_ frame: Data, on connection: Connection) {
        guard connection.pendingFrames < Self.maxPendingFrames else { connection.close(); return }
        connection.enqueue(frame)
    }

    private func closeAllConnections() {
        for connection in connections.values { connection.close() }
        connections.removeAll()
    }
}

// MARK: - Listener

private final class Listener {
    private let source: DispatchSourceRead
    private let closed: DispatchGroup

    private init(source: DispatchSourceRead, closed: DispatchGroup) {
        self.source = source
        self.closed = closed
    }

    /// A listening socket on exactly `address`, or nil if it can't be bound
    /// (Tailscale down, address gone). Accepted sockets go to `onAccept`.
    static func bind(_ address: String, queue: DispatchQueue,
                     onAccept: @escaping (Int32) -> Void) -> Listener? {
        let isV6 = address.contains(":")
        let fd = socket(isV6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        if isV6 { setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size)) }
        guard Socket.bind(fd, address: address, port: RemoteProtocol.port, isV6: isV6),
              Darwin.listen(fd, 16) == 0,
              Socket.setNonBlocking(fd) else {
            Darwin.close(fd)
            return nil
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                guard Socket.setNonBlocking(client) else { Darwin.close(client); continue }
                onAccept(client)
            }
        }
        let closed = DispatchGroup()
        closed.enter()
        source.setCancelHandler {
            Darwin.close(fd)
            closed.leave()
        }
        source.resume()
        return Listener(source: source, closed: closed)
    }

    /// Cancels the listener. The returned group finishes once its fd is closed.
    @discardableResult
    func close() -> DispatchGroup {
        source.cancel()
        return closed
    }
}

// MARK: - Connection

private final class Connection {
    enum Phase { case admitting, awaitingHello, streaming, mismatched, attaching, terminal, closed }

    let fd: Int32
    var phase = Phase.admitting
    var decoder = RemoteFrameDecoder()
    /// Takes over from `decoder` once a terminal connection is attached.
    var terminalDecoder = TerminalFrameDecoder()
    /// The pane's pty, on a terminal connection.
    var stream: PaneStream?
    /// After each write, so a paused pane can resume.
    var onFlushed: (() -> Void)?
    /// Close once everything queued has been written (a refusal).
    var closeAfterFlush = false
    var onReadable: (() -> Void)?
    var onClosed: (() -> Void)?

    private let readSource: DispatchSourceRead
    private let writeSource: DispatchSourceWrite
    private var readResumed = false
    private var writeResumed = false
    private var outbox: [Data] = []
    /// Bytes of `outbox[0]` already written.
    private var written = 0
    private var queued = 0

    var pendingFrames: Int { outbox.count }
    /// Bytes queued and not yet written.
    var pendingBytes: Int { queued }

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        // Both sources watch the fd, so it closes only after both cancel.
        let cancelled = DispatchGroup()
        cancelled.enter()
        cancelled.enter()
        readSource.setCancelHandler { cancelled.leave() }
        writeSource.setCancelHandler { cancelled.leave() }
        cancelled.notify(queue: queue) { Darwin.close(fd) }
        readSource.setEventHandler { [weak self] in self?.onReadable?() }
        writeSource.setEventHandler { [weak self] in self?.flush() }
    }

    func startReading() {
        guard !readResumed, phase != .closed else { return }
        readResumed = true
        readSource.resume()
    }

    /// Up to 64 KB, or nil at EOF or on a read error.
    func readChunk() -> Data? {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = read(fd, &buffer, buffer.count)
        if count > 0 { return Data(buffer[0..<count]) }
        if count < 0, errno == EAGAIN || errno == EINTR { return Data() }
        return nil
    }

    func enqueue(_ frame: Data) {
        guard phase != .closed else { return }
        outbox.append(frame)
        queued += frame.count
        flush()
    }

    private func flush() {
        while let head = outbox.first {
            let result = head.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                return write(fd, base + written, head.count - written)
            }
            if result < 0 {
                if errno == EAGAIN || errno == EINTR { break }
                close()
                return
            }
            written += result
            queued -= result
            if written == head.count {
                outbox.removeFirst()
                written = 0
            }
        }
        if outbox.isEmpty {
            if writeResumed { writeSource.suspend(); writeResumed = false }
            if closeAfterFlush { close(); return }
        } else if !writeResumed {
            writeResumed = true
            writeSource.resume()
        }
        onFlushed?()
    }

    func close() {
        guard phase != .closed else { return }
        phase = .closed
        outbox.removeAll()
        queued = 0
        onFlushed = nil
        // A suspended source never runs its cancel handler, so resume first.
        if !readResumed { readResumed = true; readSource.resume() }
        if !writeResumed { writeResumed = true; writeSource.resume() }
        readSource.cancel()
        writeSource.cancel()
        onClosed?()
    }
}

// MARK: - Pane stream

/// One remote pane's pty on the serving side: its output goes to the
/// connection, the relay's input comes back. All on the server's queue.
private final class PaneStream {
    let pty: PTYProcess
    let session: String
    var onOutput: ((Data) -> Void)?
    var onEnded: (() -> Void)?

    private let readSource: DispatchSourceRead
    private let writeSource: DispatchSourceWrite
    private let cancelled = DispatchGroup()
    private var reading = false
    private var writing = false
    private var stopped = false
    private var inbox = Data()

    init(pty: PTYProcess, session: String, queue: DispatchQueue) {
        self.pty = pty
        self.session = session
        readSource = DispatchSource.makeReadSource(fileDescriptor: pty.masterFD, queue: queue)
        writeSource = DispatchSource.makeWriteSource(fileDescriptor: pty.masterFD, queue: queue)
        cancelled.enter()
        cancelled.enter()
        readSource.setCancelHandler { [cancelled] in cancelled.leave() }
        writeSource.setCancelHandler { [cancelled] in cancelled.leave() }
        readSource.setEventHandler { [weak self] in self?.readOutput() }
        writeSource.setEventHandler { [weak self] in self?.flushInput() }
    }

    func start() { resumeOutput() }

    func pauseOutput() {
        guard reading, !stopped else { return }
        reading = false
        readSource.suspend()
    }

    func resumeOutput() {
        guard !reading, !stopped else { return }
        reading = true
        readSource.resume()
    }

    func write(_ input: Data) {
        guard !stopped else { return }
        inbox.append(input)
        flushInput()
    }

    /// Cancels both sources, then ends the child (which closes the master)
    /// off the queue, since that can take a second. `then` runs after.
    func stop(then: @escaping () -> Void) {
        guard !stopped else { return }
        stopped = true
        inbox = Data()
        // A suspended source never runs its cancel handler.
        if !reading { reading = true; readSource.resume() }
        if !writing { writing = true; writeSource.resume() }
        readSource.cancel()
        writeSource.cancel()
        let pty = self.pty
        cancelled.notify(queue: .global(qos: .utility)) {
            pty.terminate()
            then()
        }
    }

    private func readOutput() {
        guard !stopped else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = read(pty.masterFD, &buffer, buffer.count)
        if count > 0 {
            onOutput?(Data(buffer[0 ..< count]))
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            // EOF, or EIO once the child and its pty are gone.
            pauseOutput()
            onEnded?()
        }
    }

    private func flushInput() {
        guard !stopped else { return }
        while !inbox.isEmpty {
            let count = inbox.withUnsafeBytes { Darwin.write(pty.masterFD, $0.baseAddress, $0.count) }
            if count > 0 {
                inbox.removeFirst(count)
            } else {
                break // EAGAIN: the child is behind; the write source says when
            }
        }
        if inbox.isEmpty, writing {
            writing = false
            writeSource.suspend()
        } else if !inbox.isEmpty, !writing {
            writing = true
            writeSource.resume()
        }
    }
}

// MARK: - Socket helpers

private enum Socket {
    static func setNonBlocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    static func bind(_ fd: Int32, address: String, port: UInt16, isV6: Bool) -> Bool {
        if isV6 {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            guard inet_pton(AF_INET6, address, &addr.sin6_addr) == 1 else { return false }
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
                }
            }
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else { return false }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// The connected peer's address as text, the form `tailscale whois` takes.
    static func peerAddress(_ fd: Int32) -> String? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let got = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &length) }
        }
        guard got == 0 else { return nil }
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        switch Int32(storage.ss_family) {
        case AF_INET:
            var addr = withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            }
            guard inet_ntop(AF_INET, &addr, &text, socklen_t(text.count)) != nil else { return nil }
        case AF_INET6:
            var addr = withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            }
            guard inet_ntop(AF_INET6, &addr, &text, socklen_t(text.count)) != nil else { return nil }
        default:
            return nil
        }
        return String(cString: text)
    }
}

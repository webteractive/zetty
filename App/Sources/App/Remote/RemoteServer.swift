import Darwin
import Foundation
import ZettyCore

/// Serves this Mac's workspace to the user's other Macs on the tailnet.
///
/// Binds only to this Mac's own Tailscale addresses, never `INADDR_ANY`. Every
/// connection is checked with `tailscale whois` and `PeerAdmission` before
/// anything is read from it. View-only: the server sends hellos and snapshots
/// and ignores anything a client sends after its hello.
///
/// The public methods are called from main. All socket work happens on one
/// serial queue.
final class RemoteServer {
    private let machineName: String
    private let zettyVersion: String
    private let whois: (String) -> TailscaleNode?
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
    private static let maxPendingFrames = 8
    private static let maxConnections = 32

    init(machineName: String, zettyVersion: String,
         whois: @escaping (String) -> TailscaleNode? = { TailscaleCLI.whois($0) }) {
        self.machineName = machineName
        self.zettyVersion = zettyVersion
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

    func stop() {
        queue.sync { [self] in
            for listener in listeners.values { listener.close() }
            listeners.removeAll()
            closeAllConnections()
            latestFrame = nil
        }
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
        let messages: [RemoteMessage]
        do { messages = try connection.decoder.push(bytes) } catch { connection.close(); return }
        for message in messages where connection.phase == .awaitingHello {
            guard case .hello(let theirs) = message else { connection.close(); return }
            guard theirs.protocolVersion == RemoteProtocol.version else {
                // Kept open so their side can say "needs update" rather
                // than "offline"; it just never gets a snapshot.
                connection.phase = .mismatched
                return
            }
            connection.phase = .streaming
            if let latestFrame { send(latestFrame, on: connection) }
        }
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
    private let fd: Int32
    private let source: DispatchSourceRead

    private init(fd: Int32, source: DispatchSourceRead) {
        self.fd = fd
        self.source = source
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
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        return Listener(fd: fd, source: source)
    }

    func close() { source.cancel() }
}

// MARK: - Connection

private final class Connection {
    enum Phase { case admitting, awaitingHello, streaming, mismatched, closed }

    let fd: Int32
    var phase = Phase.admitting
    var decoder = RemoteFrameDecoder()
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

    var pendingFrames: Int { outbox.count }

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
            if written == head.count {
                outbox.removeFirst()
                written = 0
            }
        }
        if outbox.isEmpty {
            if writeResumed { writeSource.suspend(); writeResumed = false }
            if closeAfterFlush { close() }
        } else if !writeResumed {
            writeResumed = true
            writeSource.resume()
        }
    }

    func close() {
        guard phase != .closed else { return }
        phase = .closed
        outbox.removeAll()
        // A suspended source never runs its cancel handler, so resume first.
        if !readResumed { readResumed = true; readSource.resume() }
        if !writeResumed { writeResumed = true; writeSource.resume() }
        readSource.cancel()
        writeSource.cancel()
        onClosed?()
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

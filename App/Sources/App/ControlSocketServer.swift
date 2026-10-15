import Foundation
import ZettyCore
import ZettyGhostty

/// The app end of the `Zetty` CLI: a Unix-domain socket at
/// `~/.zetty/zetty.sock` speaking one JSON object per line
/// (`ControlWire`), one request → one response per connection.
///
/// Socket IO runs on a private queue and the request handler is invoked on
/// that queue — NOT the main thread — so slow work (zmx subprocesses for
/// `capture`) can't freeze the UI. Handlers hop to main themselves for
/// anything that reads UI/workspace state. Same-user only (0600 socket).
final class ControlSocketServer {

    static var defaultSocketURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".zetty", isDirectory: true)
            .appendingPathComponent("zetty.sock")
    }

    private let socketURL: URL
    private let handler: (ControlRequest) -> ControlResponse
    private let queue = DispatchQueue(label: "co.webteractive.zetty.control-socket")
    private var listenerFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    /// Seconds a client gets to send its request line, and to take the reply.
    private static let exchangeTimeout: TimeInterval = 10

    init(
        socketURL: URL = ControlSocketServer.defaultSocketURL,
        handler: @escaping (ControlRequest) -> ControlResponse
    ) {
        self.socketURL = socketURL
        self.handler = handler
    }

    func start() {
        queue.async { [self] in listen() }
    }

    func stop() {
        queue.sync { [self] in
            acceptSource?.cancel()
            acceptSource = nil
            if listenerFD >= 0 { close(listenerFD) }
            listenerFD = -1
            unlink(socketURL.path)
        }
    }

    // MARK: - Listener

    /// True if a server is currently accepting connections at `path` — used to
    /// avoid unlinking a live instance's socket.
    private static func socketIsLive(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyMemory(from: UnsafeRawBufferPointer(start: source.baseAddress, count: source.count))
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0
    }

    private func listen() {
        let path = socketURL.path
        try? FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Don't steal a LIVE socket: if another instance is already listening,
        // leave its socket alone (unlinking it would break the running app's
        // CLI). Only remove a stale/dead socket before binding our own.
        if Self.socketIsLive(at: path) { return }
        unlink(path)   // stale socket from a previous run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString   // NUL-terminated
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyMemory(from: UnsafeRawBufferPointer(start: source.baseAddress, count: source.count))
            }
        }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            close(fd)
            return
        }
        chmod(path, 0o600)

        listenerFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.resume()
        acceptSource = source
    }

    // MARK: - Connections

    private func acceptOne() {
        let clientFD = accept(listenerFD, nil, nil)
        guard clientFD >= 0 else { return }
        defer { close(clientFD) }

        // A client that vanished mid-exchange must not take the app with it:
        // without SO_NOSIGPIPE, writing to its closed socket raises SIGPIPE,
        // whose default disposition terminates the process.
        var on: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // And a client that connects but never completes a line must not wedge
        // the (serial) accept queue forever — bound both directions. The socket
        // timeouts bound one blocking call; `ControlSocketIO` bounds the whole
        // exchange, including retries after EINTR/EAGAIN.
        var timeout = timeval(tv_sec: __darwin_time_t(Self.exchangeTimeout), tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let response: ControlResponse
        if let line = ControlSocketIO.readLine(from: clientFD, timeout: Self.exchangeTimeout),
           let request = try? ControlWire.decodeRequest(line) {
            response = handler(request)
        } else {
            response = .error("malformed request")
        }

        guard let out = try? ControlWire.encodeLine(response) else { return }
        ControlSocketIO.writeAll(Array(out.utf8), to: clientFD, timeout: Self.exchangeTimeout)
    }
}

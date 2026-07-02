import Foundation
import QuerttyCore

/// The app end of the `quertty` CLI: a Unix-domain socket at
/// `~/.quertty/quertty.sock` speaking one JSON object per line
/// (`ControlWire`), one request → one response per connection.
///
/// Socket IO runs on a private queue; the request handler is invoked on the
/// main thread (it reads UI/workspace state). Same-user only (0600 socket).
final class ControlSocketServer {

    static var defaultSocketURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".quertty", isDirectory: true)
            .appendingPathComponent("quertty.sock")
    }

    private let socketURL: URL
    private let handler: (ControlRequest) -> ControlResponse
    private let queue = DispatchQueue(label: "dev.more.quertty.control-socket")
    private var listenerFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

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

    private func listen() {
        let path = socketURL.path
        try? FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
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

        let response: ControlResponse
        if let line = readLine(from: clientFD),
           let request = try? ControlWire.decodeRequest(line) {
            response = DispatchQueue.main.sync { handler(request) }
        } else {
            response = .error("malformed request")
        }

        guard let out = try? ControlWire.encodeLine(response) else { return }
        let data = Array(out.utf8)
        _ = data.withUnsafeBufferPointer { write(clientFD, $0.baseAddress, $0.count) }
    }

    /// Reads until the first newline (cap 1 MB); nil on EOF-before-data.
    private func readLine(from fd: Int32) -> String? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !buffer.contains(0x0A), buffer.count < 1_048_576 {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { break }
            buffer.append(contentsOf: chunk[0..<count])
        }
        guard !buffer.isEmpty else { return nil }
        return String(data: buffer, encoding: .utf8)
    }
}

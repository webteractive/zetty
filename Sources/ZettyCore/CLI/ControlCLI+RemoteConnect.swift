import Darwin
import Foundation

extension ControlCLI {
    public enum RemoteConnectResult: Equatable {
        case connected(Int32)
        case failure(String)
    }

    /// For the `zetty attach` relay: asks this Mac's Zetty to dial `address`
    /// through its own Tailscale node, and takes the connected descriptor it
    /// sends back (`FDPassing`). The app dials only an admitted Mac's
    /// current address.
    public static func remoteConnect(address: String, socketPath: String? = nil) -> RemoteConnectResult {
        let path = socketPath ?? (NSHomeDirectory() as NSString).appendingPathComponent(".zetty/zetty.sock")
        guard let out = try? ControlWire.encodeLine(ControlRequest.remoteConnect(address: address)) else {
            return .failure("cannot encode request")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure("cannot create socket") }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var socketAddress = sockaddr_un()
        socketAddress.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: socketAddress.sun_path) else {
            return .failure("socket path too long")
        }
        withUnsafeMutableBytes(of: &socketAddress.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyMemory(from: UnsafeRawBufferPointer(start: source.baseAddress, count: source.count))
            }
        }
        let connected = withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return .failure("Zetty isn't running on this Mac") }
        guard ControlSocketIO.writeAll(Array(out.utf8), to: fd, timeout: 5) else {
            return .failure("Zetty on this Mac didn't take the request")
        }
        // The app's dial is bounded well inside this.
        guard let reply = FDPassing.receive(from: fd, timeout: 15) else {
            return .failure("Zetty on this Mac didn't answer")
        }
        let response = try? ControlWire.decodeResponse(String(decoding: reply.line, as: UTF8.self))
        switch response {
        case .ok? where reply.fd != nil:
            return .connected(reply.fd!)
        case .error(let message)?:
            if let passed = reply.fd { close(passed) }
            return .failure(message)
        default:
            if let passed = reply.fd { close(passed) }
            return .failure("Zetty on this Mac sent no connection")
        }
    }
}

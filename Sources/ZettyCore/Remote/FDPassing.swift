import Darwin
import Foundation

/// Hands an open descriptor across a Unix socket with a one-line reply
/// (`SCM_RIGHTS`). The app dials another Mac through its own Tailscale node,
/// which a `zetty attach` relay can't reach from its process, and gives the
/// relay the connected descriptor this way (`remote-connect`).
public enum FDPassing {
    /// `cmsghdr` is three 32-bit fields; Darwin aligns control data to 4.
    private static let headerSize = MemoryLayout<cmsghdr>.size
    private static let controlSize = headerSize + MemoryLayout<Int32>.size

    /// Sends `line` (newline-terminated) with `fd` riding on its first byte.
    public static func send(fd: Int32, over socket: Int32, line: Data) -> Bool {
        guard !line.isEmpty else { return false }
        var control = [UInt8](repeating: 0, count: controlSize)
        control.withUnsafeMutableBytes { raw in
            let header = raw.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
            header.pointee.cmsg_len = socklen_t(controlSize)
            header.pointee.cmsg_level = SOL_SOCKET
            header.pointee.cmsg_type = SCM_RIGHTS
            raw.storeBytes(of: fd, toByteOffset: headerSize, as: Int32.self)
        }
        var bytes = [UInt8](line)
        let sent = bytes.withUnsafeMutableBytes { buffer -> Int in
            var iov = iovec(iov_base: buffer.baseAddress, iov_len: buffer.count)
            return control.withUnsafeMutableBytes { controlBuffer -> Int in
                withUnsafeMutablePointer(to: &iov) { iovPointer in
                    var message = msghdr()
                    message.msg_iov = iovPointer
                    message.msg_iovlen = 1
                    message.msg_control = controlBuffer.baseAddress
                    message.msg_controllen = socklen_t(controlSize)
                    return sendmsg(socket, &message, 0)
                }
            }
        }
        guard sent > 0 else { return false }
        return sent == bytes.count || ControlSocketIO.writeAll(Array(bytes[sent...]), to: socket, timeout: 5)
    }

    /// Sends `fd` with `line`, then keeps this side's copy open until the
    /// receiver closes `socket` (it has taken the descriptor by then), or
    /// `waitUpTo` seconds pass, and only then closes `fd`. Closing it at once
    /// can end the connection while the descriptor is still in flight: the
    /// relay's first attempt, made while its process was still starting,
    /// got a dead socket every time over a relayed link (2026-11-10).
    public static func handOver(fd: Int32, over socket: Int32, line: Data, waitUpTo: TimeInterval) {
        defer { Darwin.close(fd) }
        guard send(fd: fd, over: socket, line: line) else { return }
        let deadline = Date().addingTimeInterval(waitUpTo)
        var scratch = [UInt8](repeating: 0, count: 64)
        while deadline.timeIntervalSinceNow > 0 {
            var poller = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(max(1, deadline.timeIntervalSinceNow * 1000)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return }
            let n = read(socket, &scratch, scratch.count)
            if n < 0, errno == EINTR || errno == EAGAIN { continue }
            if n <= 0 { return }   // closed: the receiver has it
        }
    }

    /// One reply line (without its newline) and the descriptor sent with it,
    /// if any. Nil on timeout or a closed socket.
    public static func receive(from socket: Int32, timeout: TimeInterval) -> (line: Data, fd: Int32?)? {
        let deadline = Date().addingTimeInterval(timeout)
        var line = Data()
        var received: Int32?
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { break }
            var poller = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(max(1, left * 1000)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { break }
            var control = [UInt8](repeating: 0, count: controlSize)
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                var iov = iovec(iov_base: raw.baseAddress, iov_len: raw.count)
                return control.withUnsafeMutableBytes { controlBuffer -> Int in
                    withUnsafeMutablePointer(to: &iov) { iovPointer in
                        var message = msghdr()
                        message.msg_iov = iovPointer
                        message.msg_iovlen = 1
                        message.msg_control = controlBuffer.baseAddress
                        message.msg_controllen = socklen_t(controlSize)
                        let n = recvmsg(socket, &message, 0)
                        if n > 0, message.msg_controllen >= socklen_t(controlSize) {
                            let header = controlBuffer.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
                            if header.pointee.cmsg_level == SOL_SOCKET, header.pointee.cmsg_type == SCM_RIGHTS {
                                let fd = controlBuffer.load(fromByteOffset: headerSize, as: Int32.self)
                                if received == nil { received = fd } else { Darwin.close(fd) }
                            }
                        }
                        return n
                    }
                }
            }
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { break }
            line.append(contentsOf: buffer[0..<count])
            if let newline = line.firstIndex(of: UInt8(ascii: "\n")) {
                return (line[line.startIndex..<newline], received)
            }
        }
        if let received { Darwin.close(received) }
        return nil
    }
}

import Foundation

/// Line IO over the control socket, shared by the app's `ControlSocketServer`
/// and the CLI.
///
/// Both ends used to treat any `read`/`write` result <= 0 as the end of the
/// exchange. A healthy blocking socket only returns that on EOF or when its
/// SO_RCVTIMEO/SO_SNDTIMEO runs out, but an interrupted call (EINTR) or a
/// socket that turns up non-blocking (EAGAIN — an accepted socket inherits its
/// listener's O_NONBLOCK) fails at once. The app then answered "malformed
/// request" ~0.1ms after `accept`, before the CLI — which writes a few ms after
/// connecting — had sent a byte, and every command failed. So: retry EINTR,
/// wait out EAGAIN with `poll`, and stop only on EOF, a hard error, or the
/// overall deadline.
public enum ControlSocketIO {

    /// The most a request line may grow to before the server gives up on it.
    public static let maxRequestBytes = 1_048_576

    /// Reads until the first newline, `limit` bytes, EOF, a hard error, or
    /// `timeout`; nil when nothing arrived.
    public static func readLine(
        from fd: Int32, timeout: TimeInterval, limit: Int = maxRequestBytes
    ) -> String? {
        let deadline = deadline(after: timeout)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !buffer.contains(0x0A), buffer.count < limit {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
            } else if count == 0 || !shouldRetry(after: errno, on: fd, waitingFor: POLLIN, until: deadline) {
                break   // EOF, hard error, or out of time
            }
        }
        guard !buffer.isEmpty else { return nil }
        return String(data: buffer, encoding: .utf8)
    }

    /// Writes the whole buffer, resuming after short writes (full socket
    /// buffers on large `status --json`/`capture` responses); false if the
    /// peer went away, a hard error hit, or `timeout` ran out first.
    @discardableResult
    public static func writeAll(_ bytes: [UInt8], to fd: Int32, timeout: TimeInterval) -> Bool {
        let deadline = deadline(after: timeout)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBufferPointer { buffer in
                write(fd, buffer.baseAddress, buffer.count)
            }
            if written > 0 {
                offset += written
            } else if written == 0 || !shouldRetry(after: errno, on: fd, waitingFor: POLLOUT, until: deadline) {
                return false
            }
        }
        return true
    }

    // MARK: - Retry policy

    /// After a failed call: true to try it again — at once for EINTR, once
    /// `poll` reports the socket ready for EAGAIN — while time remains.
    /// EAGAIN is also what a blocking socket's SO_RCVTIMEO/SO_SNDTIMEO expiry
    /// returns; the deadline, not that timeout, decides when to stop.
    private static func shouldRetry(
        after error: Int32, on fd: Int32, waitingFor events: Int32, until deadline: UInt64
    ) -> Bool {
        let remaining = millisecondsLeft(until: deadline)
        guard remaining > 0 else { return false }
        switch error {
        case EINTR:
            return true
        case EAGAIN:   // == EWOULDBLOCK on Darwin
            var ready = pollfd(fd: fd, events: Int16(events), revents: 0)
            let count = poll(&ready, 1, remaining)
            return count > 0 || (count < 0 && errno == EINTR)
        default:
            return false
        }
    }

    private static func deadline(after timeout: TimeInterval) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeout) * 1_000_000_000)
    }

    private static func millisecondsLeft(until deadline: UInt64) -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline > now else { return 0 }
        return Int32(clamping: (deadline - now + 999_999) / 1_000_000)
    }
}

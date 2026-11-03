import Darwin
import Foundation

/// `<machine>:<pane>`, the argument of `zetty attach`.
public struct RemoteAttachTarget: Equatable, Sendable {
    public let host: String
    public let pane: String

    public init(host: String, pane: String) {
        self.host = host
        self.pane = pane
    }

    /// Splits on the LAST colon, so a host with colons in it still parses; the
    /// pane must be a valid short id.
    public static func parse(_ text: String) -> RemoteAttachTarget? {
        guard let colon = text.lastIndex(of: ":") else { return nil }
        let host = String(text[..<colon])
        let pane = String(text[text.index(after: colon)...])
        guard !host.isEmpty,
              RemoteAttachRequest(pane: pane, rows: 0, cols: 0, scrollback: false).isValidPane else { return nil }
        return RemoteAttachTarget(host: host, pane: pane)
    }
}

/// When the relay retries, and what it says in the pane. Pure, so the timing
/// and the wording are testable without a network.
public struct RelayPolicy: Sendable {
    public enum Event: Equatable, Sendable {
        case connectFailed, attached, dropped, versionMismatch
        case refused(String)
    }

    public enum Action: Equatable, Sendable {
        case retry(after: TimeInterval, scrollback: Bool)
        /// Attached: start piping.
        case proceed
        /// Give up: the pane stays open and shows the last message.
        case stop
    }

    static let backoff: [TimeInterval] = [1, 2, 5, 10]

    public let machine: String
    /// Ask for full scrollback: only until the first attach, so a reconnect
    /// doesn't print it twice.
    public private(set) var scrollback = true
    private var attempt = 0
    /// A "can't reach" or "disconnected" line is on screen for this outage.
    private var announced = false

    public init(machine: String) {
        self.machine = machine
    }

    public mutating func next(_ event: Event) -> (message: String?, action: Action) {
        switch event {
        case .attached:
            attempt = 0
            scrollback = false
            announced = false
            return (nil, .proceed)
        case .connectFailed:
            return retry(saying: "[can't reach \(machine), retrying…]")
        case .dropped:
            return retry(saying: "[disconnected from \(machine), reconnecting…]")
        case .refused(let reason):
            return ("[\(reason)]", .stop)
        case .versionMismatch:
            return ("[\(machine) runs a different version of Zetty. Update both Macs.]", .stop)
        }
    }

    private mutating func retry(saying message: String) -> (message: String?, action: Action) {
        let delay = Self.backoff[min(attempt, Self.backoff.count - 1)]
        attempt += 1
        defer { announced = true }
        return (announced ? nil : message, .retry(after: delay, scrollback: scrollback))
    }
}

/// `zetty attach`: the process inside a remote pane on this Mac. It connects
/// to the other Mac's Zetty, asks for one pane, and pipes bytes and window
/// sizes both ways until the pane is closed here.
public enum RemoteRelay {
    private static let pollMillis: Int32 = 250
    private static let connectTimeout: TimeInterval = 3
    private static let readSize = 64 * 1024

    private enum Attempt {
        case attached(fd: Int32, decoder: TerminalFrameDecoder)
        case failed(RelayPolicy.Event)
    }

    private enum PipeEnd {
        case dropped, stdinClosed
        case ended(String)
    }

    /// Runs until stdin closes (the pane was closed here). Never exits on its
    /// own after a refusal: the pane keeps the reason on screen.
    public static func run(target: RemoteAttachTarget, machineName: String) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        let restore = enterRawMode()
        defer { restore() }

        var policy = RelayPolicy(machine: machineName)
        while true {
            switch attach(target, scrollback: policy.scrollback) {
            case .failed(let event):
                let step = policy.next(event)
                guard proceed(step) else { return 0 }
            case .attached(let fd, let decoder):
                _ = policy.next(.attached)
                let end = pipe(fd, decoder: decoder)
                Darwin.close(fd)
                switch end {
                case .stdinClosed:
                    return 0
                case .ended(let reason):
                    guard proceed(policy.next(.refused(reason))) else { return 0 }
                case .dropped:
                    guard proceed(policy.next(.dropped)) else { return 0 }
                }
            }
        }
    }

    /// Prints the step's message and waits it out. False once stdin closes.
    private static func proceed(_ step: (message: String?, action: RelayPolicy.Action)) -> Bool {
        if let message = step.message {
            writeAll(1, Data("\r\n\u{1B}[2m\(message)\u{1B}[0m\r\n".utf8))
        }
        switch step.action {
        case .retry(let delay, _):
            return discardInput(for: delay)
        case .stop:
            return discardInput(for: nil)
        case .proceed:
            return true
        }
    }

    /// Reads and drops keystrokes for `seconds` (forever when nil). False when
    /// stdin closes.
    private static func discardInput(for seconds: TimeInterval?) -> Bool {
        let deadline = seconds.map { Date().addingTimeInterval($0) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while deadline.map({ Date() < $0 }) ?? true {
            var fds = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
            guard poll(&fds, 1, pollMillis) > 0 else { continue }
            let n = read(0, &buffer, buffer.count)
            if n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN) { return false }
        }
        return true
    }

    // MARK: - Connecting

    private static func attach(_ target: RemoteAttachTarget, scrollback: Bool) -> Attempt {
        guard let fd = connect(host: target.host) else { return .failed(.connectFailed) }
        let deadline = Date().addingTimeInterval(RemoteProtocol.attachTimeout)
        var decoder = RemoteFrameDecoder()

        // The server speaks first: its hello, or a refusal of this Mac.
        switch readMessage(fd, &decoder, until: deadline) {
        case .hello(let theirs)?:
            guard theirs.protocolVersion == RemoteProtocol.version else {
                Darwin.close(fd)
                return .failed(.versionMismatch)
            }
        case .refused(let reason)?:
            Darwin.close(fd)
            return .failed(.refused(reason))
        default:
            Darwin.close(fd)
            return .failed(.connectFailed)
        }

        let size = windowSize()
        let request = RemoteAttachRequest(pane: target.pane, rows: size.rows, cols: size.cols, scrollback: scrollback)
        let hello = RemoteHello(machine: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
                                zettyVersion: ControlCLI.versionInfo?.version ?? "dev",
                                protocolVersion: RemoteProtocol.version, attach: request)
        guard let frame = try? RemoteFrame.encode(.hello(hello)), writeAll(fd, frame) else {
            Darwin.close(fd)
            return .failed(.dropped)
        }

        switch readMessage(fd, &decoder, until: deadline) {
        case .attached?:
            return .attached(fd: fd, decoder: TerminalFrameDecoder(seed: decoder.takeRemainder()))
        case .refused(let reason)?:
            Darwin.close(fd)
            return .failed(.refused(reason))
        default:
            Darwin.close(fd)
            return .failed(.dropped)
        }
    }

    /// Reads exactly one JSON message, leaving anything after it buffered.
    private static func readMessage(_ fd: Int32, _ decoder: inout RemoteFrameDecoder, until deadline: Date) -> RemoteMessage? {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        do {
            if let message = try decoder.push(Data(), stopAfter: 1).first { return message }
            while Date() < deadline {
                var fds = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&fds, 1, pollMillis) > 0 else { continue }
                let n = read(fd, &buffer, buffer.count)
                if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard n > 0 else { return nil }
                if let message = try decoder.push(Data(buffer[0 ..< n]), stopAfter: 1).first { return message }
            }
        } catch {
            return nil
        }
        return nil
    }

    /// Resolves `host` (a MagicDNS name works) and connects to the first
    /// address that answers within 3s, with the feed's keepalive so a sleeping
    /// Mac is noticed in about 16s.
    private static func connect(host: String) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(RemoteProtocol.port), &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(list) }

        var entry: UnsafeMutablePointer<addrinfo>? = first
        while let info = entry {
            entry = info.pointee.ai_next
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            configure(fd)
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            if Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 { return fd }
            guard errno == EINPROGRESS else { Darwin.close(fd); continue }
            var fds = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            if poll(&fds, 1, Int32(connectTimeout * 1000)) > 0,
               getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 {
                return fd
            }
            Darwin.close(fd)
        }
        return nil
    }

    private static func configure(_ fd: Int32) {
        var on: Int32 = 1, idle: Int32 = 10, interval: Int32 = 3, count: Int32 = 2
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, size)
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, size)
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle, size)
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &interval, size)
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &count, size)
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, size)
    }

    // MARK: - Piping

    private static func pipe(_ fd: Int32, decoder: TerminalFrameDecoder) -> PipeEnd {
        var decoder = decoder
        var sent = windowSize()
        var buffer = [UInt8](repeating: 0, count: readSize)

        // Bytes that arrived with the `attached` frame.
        if let end = deliver(try? decoder.push(Data())) { return end }

        while true {
            let now = windowSize()
            if now != sent {
                sent = now
                guard writeAll(fd, TerminalFrame.resize(rows: now.rows, cols: now.cols).encode()) else { return .dropped }
            }
            var fds = [pollfd(fd: 0, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
            guard poll(&fds, 2, pollMillis) > 0 else { continue }

            if fds[0].revents != 0 {
                let n = read(0, &buffer, buffer.count)
                if n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN) { return .stdinClosed }
                if n > 0, !writeAll(fd, TerminalFrame.data(Data(buffer[0 ..< n])).encode()) { return .dropped }
            }
            if fds[1].revents != 0 {
                let n = read(fd, &buffer, buffer.count)
                if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard n > 0 else { return .dropped }
                guard let frames = try? decoder.push(Data(buffer[0 ..< n])) else { return .dropped }
                if let end = deliver(frames) { return end }
            }
        }
    }

    /// Writes data frames to the pane. nil means keep going.
    private static func deliver(_ frames: [TerminalFrame]?) -> PipeEnd? {
        guard let frames else { return .dropped }
        for frame in frames {
            switch frame {
            case .data(let bytes):
                writeAll(1, bytes)
            case .ended(let reason):
                return .ended(reason)
            case .resize:
                break // only the relay sends sizes
            }
        }
        return nil
    }

    // MARK: - Terminal

    private struct Size: Equatable {
        let rows: UInt16
        let cols: UInt16
    }

    private static func windowSize() -> Size {
        var size = winsize()
        guard ioctl(0, TIOCGWINSZ, &size) == 0, size.ws_row > 0, size.ws_col > 0 else { return Size(rows: 24, cols: 80) }
        return Size(rows: size.ws_row, cols: size.ws_col)
    }

    /// Raw mode, so keys reach the other Mac exactly as typed. Returns the
    /// restore, which every return path runs.
    private static func enterRawMode() -> () -> Void {
        var saved = termios()
        guard isatty(0) == 1, tcgetattr(0, &saved) == 0 else { return {} }
        var raw = saved
        cfmakeraw(&raw)
        tcsetattr(0, TCSANOW, &raw)
        return { tcsetattr(0, TCSANOW, &saved) }
    }

    /// Blocks (in 250ms polls) until everything is written. False on error.
    @discardableResult
    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = write(fd, pointer, left)
                if n > 0 {
                    pointer += n
                    left -= n
                } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                    var fds = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&fds, 1, pollMillis)
                } else {
                    return false
                }
            }
            return true
        }
    }
}

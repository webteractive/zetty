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

    /// The command a viewer's pane runs to relay `pane` from `address`. The
    /// pane id and address arrive in the other Mac's feed and the line runs
    /// through a shell, so it is built only from a hex pane id, a numeric
    /// tailnet address and an executable path without spaces; anything else
    /// is nil and the pane never starts.
    /// The command for a remote pane's surface: its relay, or `/usr/bin/false`
    /// for a target `relayCommand` refuses. Never nil, because a surface with
    /// no command gets ghostty's default, this Mac's own login shell.
    public static func paneCommand(executable: String, address: String, pane: String) -> String {
        relayCommand(executable: executable, address: address, pane: pane) ?? "/usr/bin/false"
    }

    public static func relayCommand(executable: String, address: String, pane: String) -> String? {
        guard RemoteAttachRequest(pane: pane, rows: 0, cols: 0, scrollback: false).isValidPane,
              TailnetAddress.isAllowed(address), !address.contains(":"),
              !executable.isEmpty, !executable.contains(where: \.isWhitespace) else { return nil }
        return "\(executable) attach \(address):\(pane)"
    }
}

/// Where a relay may connect: Tailscale's own ranges, and loopback for local
/// testing. A name that resolves anywhere else (plain DNS, a LAN, the
/// internet) is refused, so keystrokes never leave the tailnet.
public enum TailnetAddress {
    public static func isAllowed(_ ip: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 {
            let a = UInt32(bigEndian: v4.s_addr)
            return a & 0xFFC0_0000 == 0x6440_0000 // 100.64.0.0/10
                || a >> 24 == 127
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, ip, &v6) == 1 else { return false }
        let b = withUnsafeBytes(of: &v6) { Array($0) }
        if b[0 ..< 15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true } // ::1
        return b[0 ..< 6] == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0] // fd7a:115c:a1e0::/48
    }

    /// The numeric form of a resolved address.
    static func text(of address: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: host)
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
        let fd: Int32
        switch connect(host: target.host) {
        case .connected(let socket): fd = socket
        case .unreachable: return .failed(.connectFailed)
        case .outsideTailnet:
            return .failed(.refused("\(target.host) isn't on your tailnet, so Zetty won't connect to it"))
        }
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
    private enum Dial { case connected(Int32), unreachable, outsideTailnet }

    private static func connect(host: String) -> Dial {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(RemoteProtocol.port), &hints, &list) == 0, let first = list else { return .unreachable }
        defer { freeaddrinfo(list) }

        var sawTailnet = false
        var entry: UnsafeMutablePointer<addrinfo>? = first
        while let info = entry {
            entry = info.pointee.ai_next
            guard let address = info.pointee.ai_addr, let ip = TailnetAddress.text(of: address),
                  TailnetAddress.isAllowed(ip) else { continue }
            sawTailnet = true
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            configure(fd)
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            if Darwin.connect(fd, address, info.pointee.ai_addrlen) == 0 { return .connected(fd) }
            guard errno == EINPROGRESS else { Darwin.close(fd); continue }
            var fds = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            if poll(&fds, 1, Int32(connectTimeout * 1000)) > 0,
               getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 {
                return .connected(fd)
            }
            Darwin.close(fd)
        }
        return sawTailnet ? .unreachable : .outsideTailnet
    }

    private static func configure(_ fd: Int32) {
        RemoteProtocol.configureLink(fd)
        var on: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
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

/// What the serving Mac runs under a viewer's pty: the scrollback replay on a
/// first attach, then `zmx attach`, which CREATES a missing session. The
/// session is checked again right before the attach, because the pane can be
/// closed or hibernated here while a long replay drains to a slow viewer; a
/// remote attach must never start a fresh shell in its place. When it's gone
/// the script just ends, and the viewer is told the pane closed.
public enum RemoteServedAttach {
    static let script = """
    unset ZMX_SESSION
    [ "$3" = 1 ] && "$1" history "$2" --vt 2>/dev/null
    "$1" list 2>/dev/null | grep -Fq "name=$2\t" || exit 0
    exec "$1" attach "$2"
    """

    /// Arguments for `/bin/sh`.
    public static func arguments(zmx: String, session: String, scrollback: Bool) -> [String] {
        ["-c", script, "zetty-attach", zmx, session, scrollback ? "1" : "0"]
    }
}

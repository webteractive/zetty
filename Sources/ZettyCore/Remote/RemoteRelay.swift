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
    /// The first attach is still to come. The relay takes the pane's size
    /// then, and that takeover's repaint replays the full scrollback, so no
    /// attach asks for it in its hello. A reconnect never prints it twice.
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
    private static let readSize = 64 * 1024

    private enum Attempt {
        case attached(fd: Int32, decoder: TerminalFrameDecoder, marksAttach: Bool)
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
        var driver = RelaySizeDriver()
        while true {
            switch attach(target, scrollback: false) {
            case .failed(let event):
                let step = policy.next(event)
                guard proceed(step) else { return 0 }
            case .attached(let fd, let decoder, let marksAttach):
                let first = policy.scrollback
                _ = policy.next(.attached)
                driver.expectsAttachMarker = marksAttach
                let end = pipe(fd, decoder: decoder, driver: &driver, first: first)
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
        guard TailnetAddress.isAllowed(target.host) else {
            return .failed(.refused("\(target.host) isn't on your tailnet, so Zetty won't connect to it"))
        }
        // This process can't reach Zetty's own Tailscale node, so this Mac's
        // Zetty dials for it and hands over the connection.
        let fd: Int32
        switch ControlCLI.remoteConnect(address: target.host) {
        case .connected(let socket):
            fd = socket
            configure(fd)
        case .failure(let message) where message.hasPrefix(RemoteConnectReply.unreachablePrefix):
            return .failed(.connectFailed)
        case .failure(let message):
            return .failed(.refused(message))
        }
        let deadline = Date().addingTimeInterval(RemoteProtocol.attachTimeout)
        var decoder = RemoteFrameDecoder()
        var marksAttach = false

        // The server speaks first: its hello, or a refusal of this Mac.
        switch readMessage(fd, &decoder, until: deadline) {
        case .hello(let theirs)?:
            guard theirs.protocolVersion == RemoteProtocol.version else {
                Darwin.close(fd)
                return .failed(.versionMismatch)
            }
            marksAttach = theirs.offers(RemoteFeature.attachMarker)
        case .refused(let reason)?:
            Darwin.close(fd)
            return .failed(.refused(RemoteText.displayable(reason)))
        default:
            Darwin.close(fd)
            return .failed(.connectFailed)
        }

        // This Mac's Zetty dialled through its own Tailscale node and
        // checked the server's identity there (`PeerAdmission`), so nothing
        // more is proved here.
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
            return .attached(fd: fd, decoder: TerminalFrameDecoder(seed: decoder.takeRemainder()),
                             marksAttach: marksAttach)
        case .refused(let reason)?:
            Darwin.close(fd)
            return .failed(.refused(RemoteText.displayable(reason)))
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

    private static func configure(_ fd: Int32) {
        RemoteProtocol.configureLink(fd)
    }

    // MARK: - Piping

    /// `driver` decides when this screen takes the session's size
    /// (`RelaySizeDriver`); `first` is the relay's first attach.
    private static func pipe(_ fd: Int32, decoder: TerminalFrameDecoder,
                             driver: inout RelaySizeDriver, first: Bool) -> PipeEnd {
        var decoder = decoder
        var sent = windowSize()
        var buffer = [UInt8](repeating: 0, count: readSize)

        func send(_ frames: [TerminalFrame]) -> Bool {
            frames.allSatisfy { writeAll(fd, $0.encode()) }
        }

        // Bytes that arrived with the `attached` frame.
        driver.connectionStarted()
        if let end = deliver(try? decoder.push(Data()), driver: &driver) { return end }
        guard send(driver.attached(first: first, now: Date())) else { return .dropped }

        while true {
            let now = windowSize()
            if now != sent {
                sent = now
                guard writeAll(fd, TerminalFrame.resize(rows: now.rows, cols: now.cols).encode()) else { return .dropped }
            }
            guard send(driver.due(now: Date())) else { return .dropped }
            var fds = [pollfd(fd: 0, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
            guard poll(&fds, 2, pollMillis) > 0 else { continue }

            if fds[0].revents != 0 {
                let n = read(0, &buffer, buffer.count)
                if n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN) { return .stdinClosed }
                if n > 0, !send(driver.input(Data(buffer[0 ..< n]), now: Date())) { return .dropped }
            }
            if fds[1].revents != 0 {
                let n = read(fd, &buffer, buffer.count)
                if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard n > 0 else { return .dropped }
                guard let frames = try? decoder.push(Data(buffer[0 ..< n])) else { return .dropped }
                if let end = deliver(frames, driver: &driver) { return end }
            }
        }
    }

    /// Writes data frames to the pane. nil means keep going.
    private static func deliver(_ frames: [TerminalFrame]?, driver: inout RelaySizeDriver) -> PipeEnd? {
        guard let frames else { return .dropped }
        for frame in frames {
            switch frame {
            case .data(let bytes):
                let (output, started) = RemoteSizeHandoff.splitAttach(bytes)
                if started { driver.attachStarted(now: Date()) }
                guard !output.isEmpty else { continue }
                writeAll(1, output)
                driver.output(now: Date())
            case .ended(let reason):
                return .ended(reason)
            case .sizeMoved:
                driver.sizeMoved()
            case .resize, .repaint:
                break // only the relay sends these
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
    /// The attach marker (`RemoteSizeHandoff.attachMarker`) goes out just
    /// before the attach, so the viewer knows the replay is over.
    /// `$3`: 0 attaches only, 1 replays the scrollback first, 2 is a repaint,
    /// which also clears the screen, once the replay is in hand
    /// (`SessionPersistence.fetchReplay`, which also checks the session).
    static let script = """
    unset ZMX_SESSION
    export \(SessionPersistence.noDetachKey)
    if replay=\(SessionPersistence.fetchReplay); then
      [ "$3" = 2 ] && printf '\(SessionPersistence.clearScreenEscaped)'
      [ "$3" = 0 ] || printf '%s' "${replay%x}"
    else
      "$1" list 2>/dev/null | grep -Fq "name=$2\t" || exit 0
      [ "$3" = 2 ] && printf '\(SessionPersistence.clearScreenEscaped)'
    fi
    printf '\(RemoteSizeHandoff.attachMarkerEscaped)'
    exec "$1" attach "$2"
    """

    /// Arguments for `/bin/sh`. `clearing`: a repaint, which clears the
    /// screen just before the replay (and implies `scrollback`).
    public static func arguments(zmx: String, session: String, scrollback: Bool, clearing: Bool = false) -> [String] {
        ["-c", script, "zetty-attach", zmx, session, clearing ? "2" : scrollback ? "1" : "0"]
    }
}

/// How the app answers a relay's `remote-connect` when it can't dial: a
/// message with this prefix is a failed connection, retried like a drop;
/// any other message is a refusal, shown and not retried.
public enum RemoteConnectReply {
    public static let unreachablePrefix = "couldn't reach "
}

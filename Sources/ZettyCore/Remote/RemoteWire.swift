import Foundation

/// Constants both ends of a remote-machines connection agree on.
public enum RemoteProtocol {
    /// Bump when a message changes incompatibly. A peer on another version is
    /// shown as "needs update" rather than dropped.
    /// 3: the pairing-key challenge-response (`RemoteAuth`).
    public static let version = 3
    public static let defaultPort: UInt16 = 47_391
    /// `ZETTY_REMOTE_PORT` names the environment variable that moves serving,
    /// dialling and relays to another port, read once at launch. It exists
    /// so a test pair (`scripts/remote-e2e.sh`) can run beside the real
    /// pair, which keeps the default port. Only the port moves: binding
    /// still takes this Mac's Tailscale addresses and nothing else.
    public static let portVariable = "ZETTY_REMOTE_PORT"
    public static let port: UInt16 = port(in: ProcessInfo.processInfo.environment)

    /// The port `environment` asks for. Anything but a whole number from
    /// 1024 to 65535 is ignored, so a typo falls back to the default
    /// instead of serving on a privileged or random port.
    public static func port(in environment: [String: String]) -> UInt16 {
        guard let raw = environment[portVariable], let value = UInt16(raw), value >= 1_024 else {
            return defaultPort
        }
        return value
    }
    /// A frame larger than this ends the connection before its body is read,
    /// so a broken or hostile peer can't make Zetty buffer without bound.
    public static let maxFrameBytes = 8 * 1_048_576
    public static let helloTimeout: TimeInterval = 5
    /// The largest terminal frame payload either side accepts.
    public static let maxTerminalChunk = 1_048_576
    /// How long a relay waits for `attached` or `refused` after its hello.
    public static let attachTimeout: TimeInterval = 10

    /// Socket options every remote-machines connection uses, on both ends: no
    /// SIGPIPE, and keepalive so a peer that vanishes without a FIN (sleep,
    /// power loss, `tailscale down`) is noticed in ~16s instead of the
    /// system's two hours. The serving side needs it most: a dead viewer
    /// otherwise holds its connection, pty and `zmx attach` until the
    /// connection cap refuses everyone.
    public static func configureLink(_ fd: Int32) {
        var on: Int32 = 1, idle: Int32 = 10, interval: Int32 = 3, count: Int32 = 2
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, size)
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, size)
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle, size)
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &interval, size)
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &count, size)
    }
}

/// What a relay asks for in its hello: one pane, at its own window size.
public struct RemoteAttachRequest: Codable, Equatable, Sendable {
    /// The pane's 8-hex short id (`SessionPersistence.shortID`).
    public let pane: String
    public let rows: UInt16
    public let cols: UInt16
    /// Replay full scrollback first. True only on a relay's first attach, so a
    /// reconnect doesn't print it twice.
    public let scrollback: Bool

    public init(pane: String, rows: UInt16, cols: UInt16, scrollback: Bool) {
        self.pane = pane
        self.rows = rows
        self.cols = cols
        self.scrollback = scrollback
    }

    /// 1 to 8 lowercase hex characters: the id ends up in a zmx session name,
    /// so nothing else gets that far.
    public var isValidPane: Bool {
        (1...8).contains(pane.count) && pane.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

/// The first message each side sends.
public struct RemoteHello: Codable, Equatable, Sendable {
    public let machine: String
    public let zettyVersion: String
    public let protocolVersion: Int
    /// Set by a relay: this connection carries one pane's terminal, not the
    /// workspace feed.
    public let attach: RemoteAttachRequest?
    /// A fresh random challenge for the other end to prove the pairing key
    /// over (`RemoteAuth`). Both hellos carry one.
    public let challenge: String?
    /// The client's proof, over the server's challenge and its own. Only the
    /// client's hello has one: it is the second hello sent.
    public let proof: String?

    public init(machine: String, zettyVersion: String, protocolVersion: Int, attach: RemoteAttachRequest? = nil,
                challenge: String? = nil, proof: String? = nil) {
        self.machine = machine
        self.zettyVersion = zettyVersion
        self.protocolVersion = protocolVersion
        self.attach = attach
        self.challenge = challenge
        self.proof = proof
    }

    private enum CodingKeys: String, CodingKey { case machine, zettyVersion, protocolVersion, attach, challenge, proof }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machine = try c.decode(String.self, forKey: .machine)
        zettyVersion = try c.decode(String.self, forKey: .zettyVersion)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        attach = try c.decodeIfPresent(RemoteAttachRequest.self, forKey: .attach)
        challenge = try c.decodeIfPresent(String.self, forKey: .challenge)
        proof = try c.decodeIfPresent(String.self, forKey: .proof)
    }
}

/// Everything that crosses a remote-machines connection.
public enum RemoteMessage: Codable, Equatable, Sendable {
    case hello(RemoteHello)
    case snapshot(StatusSnapshot)
    /// A plain-words reason, sent just before the server closes.
    case refused(String)
    /// The server accepted an attach. Binary `TerminalFrame`s follow.
    case attached
    /// The server's proof of the pairing key, sent once it has checked the
    /// client's and before anything else (`RemoteAuth`).
    case proof(String)

    private enum CodingKeys: String, CodingKey { case type, hello, snapshot, reason, proof }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "hello": self = .hello(try c.decode(RemoteHello.self, forKey: .hello))
        case "snapshot": self = .snapshot(try c.decode(StatusSnapshot.self, forKey: .snapshot))
        case "refused": self = .refused(try c.decode(String.self, forKey: .reason))
        case "attached": self = .attached
        case "proof": self = .proof(try c.decode(String.self, forKey: .proof))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                                                   debugDescription: "unknown message type \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let hello):
            try c.encode("hello", forKey: .type)
            try c.encode(hello, forKey: .hello)
        case .snapshot(let snapshot):
            try c.encode("snapshot", forKey: .type)
            try c.encode(snapshot, forKey: .snapshot)
        case .refused(let reason):
            try c.encode("refused", forKey: .type)
            try c.encode(reason, forKey: .reason)
        case .attached:
            try c.encode("attached", forKey: .type)
        case .proof(let proof):
            try c.encode("proof", forKey: .type)
            try c.encode(proof, forKey: .proof)
        }
    }
}

/// A frame is a 4-byte big-endian length, then that many bytes of JSON.
public enum RemoteFrame {
    public static func encode(_ message: RemoteMessage) throws -> Data {
        let body = try JSONEncoder().encode(message)
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }
}

/// Reassembles frames from bytes as they arrive, in any chunking.
public struct RemoteFrameDecoder {
    public enum Failure: Error, Equatable { case tooLarge(Int), malformed }

    private var buffer = Data()

    public init() {}

    /// Appends `bytes` and returns every message now complete, up to
    /// `stopAfter` of them; the rest stays buffered. Throws on the first bad
    /// frame; the connection should then be closed.
    ///
    /// A terminal connection switches to binary frames after its handshake, so
    /// its reader decodes one message at a time and hands what follows to a
    /// `TerminalFrameDecoder` with `takeRemainder()`.
    public mutating func push(_ bytes: Data, stopAfter: Int = .max) throws -> [RemoteMessage] {
        buffer.append(bytes)
        var messages: [RemoteMessage] = []
        while messages.count < stopAfter, buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length <= RemoteProtocol.maxFrameBytes else { throw Failure.tooLarge(length) }
            guard buffer.count >= 4 + length else { break }
            let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + length)
            buffer = Data(buffer.dropFirst(4 + length))
            do {
                messages.append(try JSONDecoder().decode(RemoteMessage.self, from: body))
            } catch {
                throw Failure.malformed
            }
        }
        return messages
    }

    /// The bytes buffered past the last decoded frame. Empties the buffer.
    public mutating func takeRemainder() -> Data {
        defer { buffer = Data() }
        return buffer
    }
}

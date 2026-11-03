import Foundation

/// Constants both ends of a remote-machines connection agree on.
public enum RemoteProtocol {
    /// Bump when a message changes incompatibly. A peer on another version is
    /// shown as "needs update" rather than dropped.
    public static let version = 1
    public static let port: UInt16 = 47_391
    /// A frame larger than this ends the connection before its body is read,
    /// so a broken or hostile peer can't make Zetty buffer without bound.
    public static let maxFrameBytes = 8 * 1_048_576
    public static let helloTimeout: TimeInterval = 5
}

/// The first message each side sends.
public struct RemoteHello: Codable, Equatable, Sendable {
    public let machine: String
    public let zettyVersion: String
    public let protocolVersion: Int

    public init(machine: String, zettyVersion: String, protocolVersion: Int) {
        self.machine = machine
        self.zettyVersion = zettyVersion
        self.protocolVersion = protocolVersion
    }
}

/// Everything that crosses a remote-machines connection.
public enum RemoteMessage: Codable, Equatable, Sendable {
    case hello(RemoteHello)
    case snapshot(StatusSnapshot)
    /// A plain-words reason, sent just before the server closes.
    case refused(String)

    private enum CodingKeys: String, CodingKey { case type, hello, snapshot, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "hello": self = .hello(try c.decode(RemoteHello.self, forKey: .hello))
        case "snapshot": self = .snapshot(try c.decode(StatusSnapshot.self, forKey: .snapshot))
        case "refused": self = .refused(try c.decode(String.self, forKey: .reason))
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

    /// Appends `bytes` and returns every message now complete. Throws on the
    /// first bad frame; the connection should then be closed.
    public mutating func push(_ bytes: Data) throws -> [RemoteMessage] {
        buffer.append(bytes)
        var messages: [RemoteMessage] = []
        while buffer.count >= 4 {
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
}

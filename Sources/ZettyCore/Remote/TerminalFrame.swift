import Foundation

/// What crosses a terminal connection once the server has sent `attached`.
///
/// One kind byte (0 data, 1 resize, 2 ended), a 4-byte big-endian length,
/// then the payload. Resize is rows then cols, each a big-endian `UInt16`;
/// ended is a plain-words UTF-8 reason.
public enum TerminalFrame: Equatable, Sendable {
    /// Bytes for the pty: keystrokes one way, output the other.
    case data(Data)
    /// The relay's window size changed.
    case resize(rows: UInt16, cols: UInt16)
    /// The pane went away on the serving Mac; the connection closes after.
    case ended(String)

    public func encode() -> Data {
        let kind: UInt8
        let payload: Data
        switch self {
        case .data(let bytes):
            kind = 0
            payload = bytes
        case .resize(let rows, let cols):
            kind = 1
            payload = Data([UInt8(rows >> 8), UInt8(rows & 0xFF), UInt8(cols >> 8), UInt8(cols & 0xFF)])
        case .ended(let reason):
            kind = 2
            payload = Data(reason.utf8)
        }
        var length = UInt32(payload.count).bigEndian
        return Data([kind]) + Data(bytes: &length, count: 4) + payload
    }
}

/// Reassembles terminal frames from bytes as they arrive, in any chunking.
public struct TerminalFrameDecoder {
    public enum Failure: Error, Equatable { case tooLarge(Int), malformed }

    private static let headerSize = 5
    private var buffer = Data()

    /// `seed` is what the JSON decoder buffered past the handshake.
    public init(seed: Data = Data()) {
        buffer = seed
    }

    /// Appends `bytes` and returns every frame now complete. Throws on the
    /// first bad frame; the connection should then be closed.
    public mutating func push(_ bytes: Data) throws -> [TerminalFrame] {
        buffer.append(bytes)
        var frames: [TerminalFrame] = []
        while buffer.count >= Self.headerSize {
            let start = buffer.startIndex
            let kind = buffer[start]
            let length = buffer[start + 1 ..< start + 5].reduce(0) { $0 << 8 | Int($1) }
            guard kind <= 2 else { throw Failure.malformed }
            guard length <= RemoteProtocol.maxTerminalChunk else { throw Failure.tooLarge(length) }
            guard buffer.count >= Self.headerSize + length else { break }
            let payload = buffer.subdata(in: start + 5 ..< start + 5 + length)
            buffer = Data(buffer.dropFirst(Self.headerSize + length))
            switch kind {
            case 0:
                frames.append(.data(payload))
            case 1:
                guard payload.count == 4 else { throw Failure.malformed }
                let p = [UInt8](payload)
                frames.append(.resize(rows: UInt16(p[0]) << 8 | UInt16(p[1]),
                                      cols: UInt16(p[2]) << 8 | UInt16(p[3])))
            default:
                guard let reason = String(data: payload, encoding: .utf8) else { throw Failure.malformed }
                frames.append(.ended(reason))
            }
        }
        return frames
    }
}

import Foundation
import Testing
@testable import ZettyCore

private func header(kind: UInt8, length: UInt32) -> Data {
    var n = length.bigEndian
    return Data([kind]) + Data(bytes: &n, count: 4)
}

@Test func framesRoundTripInAnyChunking() throws {
    let frames: [TerminalFrame] = [.data(Data("hello\r\n".utf8)), .resize(rows: 40, cols: 100),
                                   .data(Data()), .ended("that pane closed on Mac mini")]
    let bytes = frames.map { $0.encode() }.reduce(Data(), +)
    var decoder = TerminalFrameDecoder()
    var got: [TerminalFrame] = []
    for byte in bytes { got += try decoder.push(Data([byte])) }
    #expect(got == frames)
}

@Test func resizeIsRowsThenColsBigEndian() {
    let data = TerminalFrame.resize(rows: 0x0102, cols: 0x0304).encode()
    #expect(data == header(kind: 1, length: 4) + Data([1, 2, 3, 4]))
}

@Test func chunkOverTheLimitIsRefusedBeforeItsBody() {
    var decoder = TerminalFrameDecoder()
    let size = RemoteProtocol.maxTerminalChunk + 1
    #expect(throws: TerminalFrameDecoder.Failure.tooLarge(size)) {
        try decoder.push(header(kind: 0, length: UInt32(size)))
    }
}

@Test func unknownKindIsMalformed() {
    var decoder = TerminalFrameDecoder()
    #expect(throws: TerminalFrameDecoder.Failure.malformed) {
        try decoder.push(header(kind: 9, length: 0))
    }
}

@Test func resizeWithWrongLengthIsMalformed() {
    var decoder = TerminalFrameDecoder()
    #expect(throws: TerminalFrameDecoder.Failure.malformed) {
        try decoder.push(header(kind: 1, length: 3) + Data([0, 1, 2]))
    }
}

@Test func endedReasonMustBeUTF8() {
    var decoder = TerminalFrameDecoder()
    #expect(throws: TerminalFrameDecoder.Failure.malformed) {
        try decoder.push(header(kind: 2, length: 2) + Data([0xFF, 0xFE]))
    }
}

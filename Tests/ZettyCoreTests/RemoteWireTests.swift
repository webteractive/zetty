import Foundation
import Testing
@testable import ZettyCore

private func header(_ length: UInt32) -> Data {
    var n = length.bigEndian
    return Data(bytes: &n, count: 4)
}

@Test func framesRoundTripAcrossArbitraryChunking() throws {
    let a = RemoteMessage.hello(.init(machine: "Mac mini", zettyVersion: "0.1.60", protocolVersion: 1))
    let b = RemoteMessage.snapshot(StatusSnapshot(projects: [
        .init(name: "homelab", isActive: true, hibernated: false, id: "A", tabs: []),
    ]))
    let c = RemoteMessage.refused("Studio isn't a Mac")
    let bytes = try RemoteFrame.encode(a) + RemoteFrame.encode(b) + RemoteFrame.encode(c)
    var decoder = RemoteFrameDecoder()
    var got: [RemoteMessage] = []
    for i in stride(from: 0, to: bytes.count, by: 3) {
        got += try decoder.push(bytes.subdata(in: i..<min(i + 3, bytes.count)))
    }
    #expect(got == [a, b, c])
}

@Test func aFrameIsALengthThenJSON() throws {
    let data = try RemoteFrame.encode(.refused("no"))
    let length = data.prefix(4).reduce(0) { $0 << 8 | Int($1) }
    #expect(length == data.count - 4)
    let json = try #require(String(data: data.dropFirst(4), encoding: .utf8))
    #expect(json.contains(#""type":"refused""#))
}

@Test func oversizedFrameIsRefusedBeforeItsBodyArrives() {
    var decoder = RemoteFrameDecoder()
    let size = RemoteProtocol.maxFrameBytes + 1
    #expect(throws: RemoteFrameDecoder.Failure.tooLarge(size)) {
        try decoder.push(header(UInt32(size)))
    }
}

@Test func garbageBodyIsMalformed() {
    var decoder = RemoteFrameDecoder()
    #expect(throws: RemoteFrameDecoder.Failure.malformed) {
        try decoder.push(header(3) + Data("{x}".utf8))
    }
}

@Test func unknownMessageTypeIsMalformedNotACrash() {
    var decoder = RemoteFrameDecoder()
    let body = Data(#"{"type":"teleport"}"#.utf8)
    #expect(throws: RemoteFrameDecoder.Failure.malformed) {
        try decoder.push(header(UInt32(body.count)) + body)
    }
}

@Test func aPartialFrameYieldsNothingYet() throws {
    var decoder = RemoteFrameDecoder()
    let data = try RemoteFrame.encode(.refused("later"))
    #expect(try decoder.push(data.prefix(6)).isEmpty)
    #expect(try decoder.push(data.dropFirst(6)) == [.refused("later")])
}

@Test func statusSnapshotProjectDecodesWithoutId() throws {
    let json = #"{"projects":[{"name":"p","isActive":true,"hibernated":false,"tabs":[]}]}"#
    let snapshot = try JSONDecoder().decode(StatusSnapshot.self, from: Data(json.utf8))
    #expect(snapshot.projects[0].id == nil)
}

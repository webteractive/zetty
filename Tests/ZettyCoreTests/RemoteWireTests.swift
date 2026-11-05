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

// MARK: - Terminal connections (phase 2)

private let attachRequest = RemoteAttachRequest(pane: "ab12cd34", rows: 30, cols: 90, scrollback: true)

@Test func helloCarriesAnAttachRequest() throws {
    let hello = RemoteMessage.hello(.init(machine: "MacBook", zettyVersion: "0.1.60",
                                          protocolVersion: RemoteProtocol.version, attach: attachRequest))
    var decoder = RemoteFrameDecoder()
    let got = try decoder.push(RemoteFrame.encode(hello))
    #expect(got == [hello])
    guard case .hello(let back) = got.first else { Issue.record("not a hello"); return }
    #expect(back.attach == attachRequest)
}

@Test func phaseOneHelloDecodesWithoutAttach() throws {
    let json = #"{"machine":"m","zettyVersion":"0.1.59","protocolVersion":1}"#
    let hello = try JSONDecoder().decode(RemoteHello.self, from: Data(json.utf8))
    #expect(hello.attach == nil)
    #expect(hello.protocolVersion == 1)
}

@Test func attachedRoundTrips() throws {
    let data = try RemoteFrame.encode(.attached)
    #expect(String(data: data.dropFirst(4), encoding: .utf8) == #"{"type":"attached"}"#)
    var decoder = RemoteFrameDecoder()
    #expect(try decoder.push(data) == [.attached])
}

@Test func remainderHandsOverBytesAfterTheHello() throws {
    var decoder = RemoteFrameDecoder()
    let hello = RemoteMessage.hello(.init(machine: "m", zettyVersion: "v", protocolVersion: RemoteProtocol.version))
    let got = try decoder.push(RemoteFrame.encode(hello) + Data([1, 2, 3]))
    #expect(got == [hello])
    #expect(decoder.takeRemainder() == Data([1, 2, 3]))
    #expect(decoder.takeRemainder().isEmpty)
}

@Test func decodingStopsAfterTheRequestedMessages() throws {
    var decoder = RemoteFrameDecoder()
    let hello = RemoteMessage.hello(.init(machine: "m", zettyVersion: "v", protocolVersion: RemoteProtocol.version))
    let terminal = TerminalFrame.data(Data(repeating: 0, count: 300)).encode()
    let bytes = try RemoteFrame.encode(hello) + RemoteFrame.encode(.attached) + terminal
    #expect(try decoder.push(bytes, stopAfter: 1) == [hello])
    #expect(try decoder.push(Data(), stopAfter: 1) == [.attached])
    #expect(decoder.takeRemainder() == terminal)
}

@Test func paneIDsAreValidatedStrictly() {
    func valid(_ pane: String) -> Bool {
        RemoteAttachRequest(pane: pane, rows: 1, cols: 1, scrollback: false).isValidPane
    }
    #expect(valid("ab12cd34"))
    #expect(valid("ab1"))
    for bad in ["", "AB12", "ab12cd34e", "../x", "ab 1"] {
        #expect(!valid(bad), "\(bad) should be refused")
    }
}

@Test func linkOptionsNoticeAPeerThatVanishes() {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #expect(fd >= 0)
    defer { close(fd) }
    RemoteProtocol.configureLink(fd)
    func option(_ level: Int32, _ name: Int32) -> Int32 {
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, level, name, &value, &length)
        return value
    }
    #expect(option(SOL_SOCKET, SO_KEEPALIVE) != 0)
    #expect(option(SOL_SOCKET, SO_NOSIGPIPE) != 0)
    #expect(option(IPPROTO_TCP, TCP_KEEPALIVE) == 10)
    #expect(option(IPPROTO_TCP, TCP_KEEPINTVL) == 3)
    #expect(option(IPPROTO_TCP, TCP_KEEPCNT) == 2)
}

@Test func portMovesOnlyForAWholeUnprivilegedNumber() {
    #expect(RemoteProtocol.port(in: [:]) == RemoteProtocol.defaultPort)
    #expect(RemoteProtocol.port(in: ["ZETTY_REMOTE_PORT": "47392"]) == 47_392)
    #expect(RemoteProtocol.port(in: ["ZETTY_REMOTE_PORT": "65535"]) == 65_535)
    for bad in ["", "22", "1023", "65536", "-1", "47392 ", "0x1000", "abc"] {
        #expect(RemoteProtocol.port(in: ["ZETTY_REMOTE_PORT": bad]) == RemoteProtocol.defaultPort, "\(bad)")
    }
}

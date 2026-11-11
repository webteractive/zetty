import Darwin
import Foundation
import Testing
@testable import ZettyCore

private func pair() -> (Int32, Int32) {
    var fds: [Int32] = [0, 0]
    _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
    return (fds[0], fds[1])
}

@Test func passesAWorkingDescriptorWithItsLine() throws {
    let (a, b) = pair()            // the connection being handed over
    let (control, relay) = pair()  // the control socket
    defer { close(b); close(control); close(relay) }
    #expect(FDPassing.send(fd: a, over: control, line: Data("{\"type\":\"ok\"}\n".utf8)))
    close(a)  // the sender's copy goes; the received one keeps the connection
    let got = try #require(FDPassing.receive(from: relay, timeout: 2))
    #expect(String(decoding: got.line, as: UTF8.self) == "{\"type\":\"ok\"}")
    let passed = try #require(got.fd)
    defer { close(passed) }
    #expect(write(passed, "hi", 2) == 2)
    var buffer = [UInt8](repeating: 0, count: 2)
    #expect(read(b, &buffer, 2) == 2)
    #expect(buffer == Array("hi".utf8))
}

@Test func aLineWithoutADescriptorStillArrives() throws {
    let (control, relay) = pair()
    defer { close(control); close(relay) }
    let line = Data("{\"type\":\"error\",\"message\":\"no\"}\n".utf8)
    #expect(line.withUnsafeBytes { write(control, $0.baseAddress, line.count) } == line.count)
    let got = try #require(FDPassing.receive(from: relay, timeout: 2))
    #expect(got.fd == nil)
    #expect(String(decoding: got.line, as: UTF8.self).contains("error"))
}

@Test func nothingArrivingTimesOut() {
    let (control, relay) = pair()
    defer { close(control); close(relay) }
    #expect(FDPassing.receive(from: relay, timeout: 0.2) == nil)
}

@Test func relayWithoutAppSaysSo() {
    let result = ControlCLI.remoteConnect(address: "100.64.0.9", socketPath: "/tmp/zetty-no-such-\(getpid()).sock")
    guard case .failure(let message) = result else { Issue.record("connected without an app"); return }
    #expect(message == "Zetty isn't running on this Mac")
}

@Test func theSenderKeepsItsCopyUntilTheReceiverHasIt() throws {
    // macOS can end a connection whose last open copy is closed while the
    // descriptor is still in flight. `handOver` keeps the sender's copy
    // until the receiver closes the control socket.
    let (a, b) = pair()
    let (control, relay) = pair()
    defer { close(b) }
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        FDPassing.handOver(fd: a, over: control, line: Data("{\"ok\":true}\n".utf8), waitUpTo: 5)
        close(control)
        done.signal()
    }
    Thread.sleep(forTimeInterval: 0.3)   // a receiver that is slow to start
    let got = try #require(FDPassing.receive(from: relay, timeout: 2))
    close(relay)                         // what the relay does once it has it
    #expect(done.wait(timeout: .now() + 2) == .success)
    let passed = try #require(got.fd)
    defer { close(passed) }
    #expect(write(passed, "ok", 2) == 2)
    var buffer = [UInt8](repeating: 0, count: 2)
    #expect(read(b, &buffer, 2) == 2)
}

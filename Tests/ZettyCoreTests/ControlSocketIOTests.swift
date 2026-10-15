import Testing
import Foundation
@testable import ZettyCore

// MARK: - Fixtures

/// A connected AF_UNIX pair made the way the app makes one: a listener in a
/// temp dir, a client `connect`, and the server end from `accept`.
private func acceptedPair() throws -> (server: Int32, client: Int32) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("zio-\(UUID().uuidString.prefix(8)).sock").path
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    try #require(pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path))
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        pathBytes.withUnsafeBytes { source in
            destination.copyMemory(from: UnsafeRawBufferPointer(start: source.baseAddress, count: source.count))
        }
    }
    let length = socklen_t(MemoryLayout<sockaddr_un>.size)

    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(listener >= 0)
    defer { close(listener); unlink(path) }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
    }
    try #require(bound == 0 && listen(listener, 1) == 0)

    let client = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(client >= 0)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, length) }
    }
    try #require(connected == 0)
    let server = accept(listener, nil, nil)
    try #require(server >= 0)
    return (server, client)
}

private func setNonBlocking(_ fd: Int32) {
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
}

private func writeString(_ text: String, to fd: Int32) {
    _ = Array(text.utf8).withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
}

/// Runs `body` on a thread of its own, so a test can signal exactly that
/// thread, and `join` waits for it before the test closes any descriptor.
private final class Worker<Result>: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private(set) var pthread: pthread_t?
    private var result: Result?

    init(_ body: @escaping @Sendable () -> Result) {
        Thread { [self] in
            pthread = pthread_self()
            started.signal()
            result = body()
            finished.signal()
        }.start()
        started.wait()
    }

    func join() -> Result? {
        finished.wait()
        return result
    }
}

private let statusLine = "{\"command\":\"status\"}\n"

/// Bumped by the SIGUSR2 handler in `readLineRetriesAnInterruptedRead`.
nonisolated(unsafe) private var interruptions = 0

// MARK: - Reads

/// The live failure: a socket whose reads fail at once instead of blocking
/// (here non-blocking, so EAGAIN) answered "malformed request" ~0.1ms after
/// `accept`, before a client that writes a few ms after connecting — as the CLI
/// does — had sent a byte.
@Test func readLineWaitsForAClientThatWritesLate() throws {
    let (server, client) = try acceptedPair()
    defer { close(server); close(client) }
    setNonBlocking(server)

    let writer = Worker {
        usleep(150_000)
        writeString(statusLine, to: client)
    }
    let line = ControlSocketIO.readLine(from: server, timeout: 5)
    _ = writer.join()

    #expect(line == statusLine)
    #expect(try ControlWire.decodeRequest(try #require(line)) == .status)
}

/// A signal landing on the socket queue's thread mid-read (EINTR) is not the
/// end of the request either.
@Test func readLineRetriesAnInterruptedRead() throws {
    let (server, client) = try acceptedPair()
    defer { close(server); close(client) }

    // A counting handler without SA_RESTART, so the blocked read fails with EINTR.
    var action = sigaction()
    action.__sigaction_u.__sa_handler = { _ in interruptions += 1 }
    action.sa_flags = 0
    sigemptyset(&action.sa_mask)
    var previous = sigaction()
    sigaction(SIGUSR2, &action, &previous)
    defer { sigaction(SIGUSR2, &previous, nil) }
    interruptions = 0

    let reader = Worker { () -> String? in
        var usr2 = sigset_t()
        sigemptyset(&usr2)
        sigaddset(&usr2, SIGUSR2)
        pthread_sigmask(SIG_UNBLOCK, &usr2, nil)
        return ControlSocketIO.readLine(from: server, timeout: 5)
    }
    usleep(50_000)
    pthread_kill(try #require(reader.pthread), SIGUSR2)
    usleep(100_000)
    writeString(statusLine, to: client)

    #expect(reader.join() == statusLine)
    #expect(interruptions == 1)   // the signal really landed mid-read
}

@Test func readLineGivesUpAtTheDeadlineWhenNothingArrives() throws {
    let (server, client) = try acceptedPair()
    defer { close(server); close(client) }
    setNonBlocking(server)

    let start = Date()
    #expect(ControlSocketIO.readLine(from: server, timeout: 0.3) == nil)
    let elapsed = Date().timeIntervalSince(start)
    #expect(elapsed >= 0.25 && elapsed < 3)
}

@Test func readLineStopsAtEndOfInputWithoutWaitingForTheDeadline() throws {
    let (server, client) = try acceptedPair()
    defer { close(server) }
    setNonBlocking(server)
    close(client)

    let start = Date()
    #expect(ControlSocketIO.readLine(from: server, timeout: 5) == nil)
    #expect(Date().timeIntervalSince(start) < 1)
}

@Test func readLineStopsAtTheCap() throws {
    let (server, client) = try acceptedPair()
    defer { close(server); close(client) }
    writeString(String(repeating: "x", count: 6_000), to: client)   // fits the 8 KB socket buffer

    let line = try #require(ControlSocketIO.readLine(from: server, timeout: 5, limit: 4096))
    #expect(line.count >= 4096 && !line.contains("\n"))
}

// MARK: - Writes

/// A response larger than the socket buffer (a big `status --json` or
/// `capture`) must arrive whole even when the socket is non-blocking and the
/// reader is slow: the partial write that follows is EAGAIN, not the end.
@Test func writeAllDeliversEverythingToASlowReader() throws {
    let (server, client) = try acceptedPair()
    defer { close(server); close(client) }
    setNonBlocking(server)

    let payload = [UInt8](repeating: 0x61, count: 512 * 1024)
    let reader = Worker { () -> Int in
        usleep(100_000)
        var total = 0
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(client, &chunk, chunk.count)
            guard count > 0 else { break }
            total += count
        }
        return total
    }
    let delivered = ControlSocketIO.writeAll(payload, to: server, timeout: 5)
    shutdown(server, SHUT_WR)

    #expect(delivered)
    #expect(reader.join() == payload.count)
}

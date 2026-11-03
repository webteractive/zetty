import Darwin
import Foundation
import Testing
@testable import ZettyCore

/// Reads the master until `until` shows up, the child closes it, or `timeout`.
private func read(_ process: PTYProcess, until needle: String? = nil, timeout: TimeInterval = 3) -> String {
    var out = Data()
    let deadline = Date().addingTimeInterval(timeout)
    var buffer = [UInt8](repeating: 0, count: 4096)
    while Date() < deadline {
        var fds = pollfd(fd: process.masterFD, events: Int16(POLLIN), revents: 0)
        guard poll(&fds, 1, 100) > 0 else { continue }
        let n = Darwin.read(process.masterFD, &buffer, buffer.count)
        if n <= 0 { break } // EOF, or EIO once the child is gone
        out.append(contentsOf: buffer[0 ..< n])
        if let needle, String(decoding: out, as: UTF8.self).contains(needle) { break }
    }
    return String(decoding: out, as: UTF8.self)
}

@Test func childSeesTheRequestedSize() throws {
    let p = try PTYProcess.spawn(executable: "/bin/sh", arguments: ["-c", "stty size"],
                                 environment: [:], rows: 30, cols: 90)
    defer { p.terminate() }
    #expect(read(p, until: "30 90").contains("30 90"))
}

@Test func resizeReachesTheChild() throws {
    let p = try PTYProcess.spawn(executable: "/bin/sh",
                                 arguments: ["-c", #"trap "stty size" WINCH; echo ready; while :; do sleep 0.1; done"#],
                                 environment: [:], rows: 24, cols: 80)
    defer { p.terminate() }
    #expect(read(p, until: "ready").contains("ready"))
    p.resize(rows: 40, cols: 100)
    #expect(read(p, until: "40 100", timeout: 2).contains("40 100"))
}

@Test func childOnlyGetsTheGivenEnvironment() throws {
    let p = try PTYProcess.spawn(executable: "/usr/bin/env", arguments: [],
                                 environment: ["A": "1"], rows: 24, cols: 80)
    defer { p.terminate() }
    let out = read(p)
    #expect(out.contains("A=1"))
    // Nothing of the parent's leaks in: not even PATH, so never ZMX_SESSION.
    #expect(!out.contains("PATH="))
    #expect(!out.contains("ZMX_SESSION"))
}

@Test func terminateEndsTheChild() throws {
    let p = try PTYProcess.spawn(executable: "/bin/sleep", arguments: ["60"],
                                 environment: [:], rows: 24, cols: 80)
    #expect(kill(p.pid, 0) == 0)
    p.terminate()
    #expect(kill(p.pid, 0) == -1 && errno == ESRCH)
    p.terminate() // idempotent
}

@Test func masterWritesReachTheChild() throws {
    let p = try PTYProcess.spawn(executable: "/bin/cat", arguments: [],
                                 environment: [:], rows: 24, cols: 80)
    defer { p.terminate() }
    _ = "hi\n".withCString { Darwin.write(p.masterFD, $0, 3) }
    #expect(read(p, until: "hi").contains("hi"))
}

@Test func missingExecutableThrows() {
    #expect(throws: (any Error).self) {
        try PTYProcess.spawn(executable: "/nonexistent/zmx", arguments: [], environment: [:], rows: 24, cols: 80)
    }
}

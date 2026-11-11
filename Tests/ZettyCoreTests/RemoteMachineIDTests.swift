import Foundation
import Testing
@testable import ZettyCore

private func scratchURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("machine-id-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("machine-id")
}

@Test func machineIDIsMadeOnceAndKept() throws {
    let url = scratchURL()
    let first = RemoteMachineID.loadOrCreate(at: url)
    #expect(RemoteMachineID.isValid(first))
    #expect(RemoteMachineID.loadOrCreate(at: url) == first)
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
}

@Test func garbageMachineIDIsReplaced() throws {
    let url = scratchURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "not an id\n".write(to: url, atomically: true, encoding: .utf8)
    let id = RemoteMachineID.loadOrCreate(at: url)
    #expect(RemoteMachineID.isValid(id))
    #expect(RemoteMachineID.loadOrCreate(at: url) == id)
}

@Test func machineIDIsBoundToTheMacItWasMadeOn() {
    // Migration Assistant or a restore onto another Mac copies ~/.zetty:
    // that Mac must not become a second copy of this one.
    let url = scratchURL()
    let here = RemoteMachineID.loadOrCreate(at: url, hardware: "HW-A")
    #expect(RemoteMachineID.loadOrCreate(at: url, hardware: "HW-A") == here)
    let moved = RemoteMachineID.loadOrCreate(at: url, hardware: "HW-B")
    #expect(moved != here)
    #expect(RemoteMachineID.isValid(moved))
    #expect(RemoteMachineID.loadOrCreate(at: url, hardware: "HW-B") == moved)
}

@Test func anIDFromBeforeTheBindingIsKeptAndBound() throws {
    let url = scratchURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let old = UUID().uuidString
    try (old + "\n").write(to: url, atomically: true, encoding: .utf8)
    #expect(RemoteMachineID.loadOrCreate(at: url, hardware: "HW-A") == old)
    #expect(RemoteMachineID.loadOrCreate(at: url, hardware: "HW-B") != old)
}

@Test func withoutAHardwareIDTheIDIsStillKept() {
    let url = scratchURL()
    let id = RemoteMachineID.loadOrCreate(at: url, hardware: nil)
    #expect(RemoteMachineID.loadOrCreate(at: url, hardware: nil) == id)
}

@Test func theSavedSignInIsPerMacAndHome() {
    #expect(RemoteMachineID.stateAccount(home: "/Users/glen", hardware: "HW-A") == "/Users/glen @ HW-A")
    #expect(RemoteMachineID.stateAccount(home: "/Users/glen", hardware: "HW-A")
            != RemoteMachineID.stateAccount(home: "/Users/glen", hardware: "HW-B"))
    #expect(RemoteMachineID.stateAccount(home: "/Users/glen", hardware: nil) == "/Users/glen")
}

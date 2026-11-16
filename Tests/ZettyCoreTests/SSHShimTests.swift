import Foundation
import Testing
@testable import ZettyCore

/// Runs the `ssh` stand-in with `/bin/sh` in front of a fake `ssh` that
/// prints the TERM it got, whether the wrapper marker reached it, and its
/// arguments. `shimDirs` are the folders holding a copy of the stand-in, in
/// PATH order, before the fake's folder.
private func runShim(env extra: [String: String], args: [String],
                     shimDirs: Int = 1, withFake: Bool = true) throws -> (out: String, err: String, status: Int32) {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("zetty-ssh-shim-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    var path: [String] = []
    for index in 0..<shimDirs {
        let dir = root.appendingPathComponent("shim\(index)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("ssh")
        try SSHShim.contents.write(to: file, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        path.append(dir.path)
    }
    if withFake {
        let dir = root.appendingPathComponent("real")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let fake = dir.appendingPathComponent("ssh")
        try """
        #!/bin/sh
        printf '%s\\n' "TERM=$TERM" "WRAPPED=${ZETTY_SSH_WRAPPED-unset}" "$@"

        """.write(to: fake, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        path.append(dir.path)
    }
    path += ["/usr/bin", "/bin"]

    let process = Process()
    process.executableURL = URL(fileURLWithPath: path[0] + "/ssh")
    process.arguments = args
    var env = ["PATH": path.joined(separator: ":"), "HOME": root.path]
    for (key, value) in extra { env[key] = value }
    process.environment = env
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    process.waitUntilExit()
    let read = { (pipe: Pipe) in
        String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
    return (read(out), read(err), process.terminationStatus)
}

private let pane = ["ZETTY_SURFACE": "5F0C2A1E-0000-4000-8000-000000000001"]

@Test func sshFromAPaneSendsATermEveryServerKnows() throws {
    let run = try runShim(env: pane.merging(["TERM": "xterm-ghostty"]) { $1 },
                          args: ["-p", "2222", "host name"])
    #expect(run.out == "TERM=xterm-256color\nWRAPPED=unset\n-p\n2222\nhost name\n")
}

@Test func sshOutsideZettyKeepsItsTerm() throws {
    let run = try runShim(env: ["TERM": "xterm-ghostty"], args: ["host"])
    #expect(run.out == "TERM=xterm-ghostty\nWRAPPED=unset\nhost\n")
}

@Test func sshKeepsTheTermTheShellWrapperChose() throws {
    // The zsh wrapper installed the terminfo on this host, so xterm-ghostty
    // stays; the marker itself isn't passed on.
    let run = try runShim(env: pane.merging(["TERM": "xterm-ghostty", "ZETTY_SSH_WRAPPED": "1"]) { $1 },
                          args: ["host"])
    #expect(run.out == "TERM=xterm-ghostty\nWRAPPED=unset\nhost\n")
}

@Test func sshLeavesAnyOtherTermAlone() throws {
    let run = try runShim(env: pane.merging(["TERM": "screen-256color"]) { $1 }, args: ["host"])
    #expect(run.out == "TERM=screen-256color\nWRAPPED=unset\nhost\n")
}

@Test func twoCopiesOnThePathDoNotLoop() throws {
    let run = try runShim(env: pane.merging(["TERM": "xterm-ghostty"]) { $1 }, args: ["host"], shimDirs: 2)
    #expect(run.out == "TERM=xterm-256color\nWRAPPED=unset\nhost\n")
}

@Test func withNoOtherSSHOnThePathItRunsTheSystemOne() throws {
    let run = try runShim(env: pane, args: ["-V"], withFake: false)
    #expect(run.status == 0)
    #expect(run.err.contains("OpenSSH"))
}

@Test func theStandInIsOnWithZettysDefaultFeatures() {
    #expect(SSHShim.isEnabled(featureValues: ["ssh-env,ssh-terminfo"]))
}

@Test func aDirectiveCanTurnTheStandInOff() {
    #expect(!SSHShim.isEnabled(featureValues: ["ssh-env,ssh-terminfo", "no-ssh-env, no-ssh-terminfo"]))
    #expect(!SSHShim.isEnabled(featureValues: ["ssh-env,ssh-terminfo", "false"]))
    #expect(SSHShim.isEnabled(featureValues: ["ssh-env,ssh-terminfo", "no-ssh-env"]))
    #expect(SSHShim.isEnabled(featureValues: ["false", "true"]))
}

@Test func anUnrelatedFeatureLineKeepsTheStandIn() {
    #expect(SSHShim.isEnabled(featureValues: ["ssh-env,ssh-terminfo", "no-cursor"]))
}

@Test func theInstallerNeverTouchesSomeoneElsesSSH() {
    let theirs = "#!/bin/sh\nexec /opt/ssh \"$@\"\n"
    #expect(SSHShim.action(enabled: true, existing: theirs) == .leave)
    #expect(SSHShim.action(enabled: false, existing: theirs) == .leave)
}

@Test func theInstallerWritesRefreshesAndRemovesItsOwn() {
    let stale = "#!/bin/sh\n\(SSHShim.marker)\nexec /usr/bin/ssh \"$@\"\n"
    #expect(SSHShim.action(enabled: true, existing: nil) == .write)
    #expect(SSHShim.action(enabled: true, existing: stale) == .write)
    #expect(SSHShim.action(enabled: true, existing: SSHShim.contents) == .leave)
    #expect(SSHShim.action(enabled: false, existing: stale) == .remove)
    #expect(SSHShim.action(enabled: false, existing: nil) == .leave)
}

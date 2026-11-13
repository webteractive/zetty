import Testing
@testable import ZettyCore

@Test func findsEachSessionsDaemonAndShell() {
    let ps = """
        9     1     9 Ss   ??    0:00.01  1200 /opt/homebrew/bin/zmx attach zetty-ab12cd34
       10     9    10 Ss+  s001  0:00.01  1200 -zsh
       11   500    11 S    ??    0:00.01  1200 /opt/homebrew/bin/zmx attach zetty-ab12cd34
       20     1    20 Ss   ??    0:00.01  1200 /Users/me/.zetty/zmx/1.0.1/zmx attach zetty-ff00ee11
       21    20    21 Ss+  s002  0:00.01  1200 -bash
       30     1    30 Ss   ??    0:00.01  1200 /opt/homebrew/bin/zmx attach build
       31     1    31 Ss   ??    0:00.01  1200 vim zetty-99887766
    """
    let daemons = ZmxDaemons.daemons(psOutput: ps)
    // 11 is a client (its parent is a pane); `build` is not ours; 31 isn't zmx.
    #expect(Set(daemons.keys) == ["zetty-ab12cd34", "zetty-ff00ee11"])
    #expect(daemons["zetty-ab12cd34"] == ZmxDaemon(pid: 9, executable: "/opt/homebrew/bin/zmx", shellPID: 10))
    #expect(daemons["zetty-ff00ee11"] == ZmxDaemon(pid: 20, executable: "/Users/me/.zetty/zmx/1.0.1/zmx", shellPID: 21))
}

@Test func daemonNameMatchIsExact() {
    let ps = """
        9     1     9 Ss   ??    0:00.01  1200 zmx attach zetty-ab12
    """
    let daemons = ZmxDaemons.daemons(psOutput: ps)
    #expect(daemons["zetty-ab12"]?.pid == 9)
    #expect(daemons["zetty-ab12cd34"] == nil)
    // No shell child seen (yet): still a daemon, without a shell pid.
    #expect(daemons["zetty-ab12"]?.shellPID == nil)
}

@Test func daemonWithLabelsStillMatches() {
    let ps = """
        9     1     9 Ss   ??    0:00.01  1200 /usr/local/bin/zmx attach --labels a=b zetty-ab12cd34
    """
    #expect(ZmxDaemons.daemons(psOutput: ps)["zetty-ab12cd34"]?.pid == 9)
}

@Test func parsesZmxVersionOutput() {
    #expect(ZmxVersion.parse(versionOutput: "zmx\t\t1.0.1\nghostty_vt\tghostty-1.4.1\nsocket_dir\t/tmp/x\n") == "1.0.1")
    #expect(ZmxVersion.parse(versionOutput: "zmx\t\t0.6.0\nghostty_vt\tx\n") == "0.6.0")
    #expect(ZmxVersion.parse(versionOutput: "garbage") == nil)
    // A version is used as a directory name, so nothing path-like gets through.
    #expect(ZmxVersion.parse(versionOutput: "zmx\t../../x\n") == nil)
}

@Test func parsesThePin() {
    let pin = ZmxPin.parse("""
    # comment
    version=1.0.1
    sha256-aarch64=aaaa
    sha256-x86_64=bbbb
    """)
    #expect(pin == ZmxPin(version: "1.0.1", sha256: ["aarch64": "aaaa", "x86_64": "bbbb"]))
    #expect(ZmxPin.parse("version=1.0.1\nsha256-aarch64=aaaa\n") == nil)
    #expect(ZmxPin.parse("sha256-aarch64=a\nsha256-x86_64=b\n") == nil)
}

@Test func unreachableSessionsComeFromErrorLines() {
    let list = """
      name=zetty-0a0a0a0a\terr=Unexpected\tstatus=unreachable
      name=zetty-1b1b1b1b\tpid=81140\tclients=0\tcreated=1794538956
      name=build\terr=Timeout\tstatus=unreachable
    """
    #expect(SessionPersistence.unreachableSessions(fromList: list) == ["zetty-0a0a0a0a"])
}

@Test func zmxSubcommandTargetsASession() {
    #expect(ZmxCommand.targetSessions(["history", "zetty-ab12cd34", "--vt"]) == ["zetty-ab12cd34"])
    #expect(ZmxCommand.targetSessions(["kill", "zetty-a", "zetty-b", "--force"]) == ["zetty-a", "zetty-b"])
    #expect(ZmxCommand.targetSessions(["attach", "--labels", "a=b", "zetty-a"]) == ["zetty-a"])
    #expect(ZmxCommand.targetSessions(["send", "zetty-a", "ls -la"]) == ["zetty-a"])
    #expect(ZmxCommand.targetSessions(["list", "--short"]) == [])
    #expect(ZmxCommand.targetSessions(["version"]) == [])
    #expect(ZmxCommand.targetSessions([]) == [])
}

@Test func listNamesIncludeUnreachableSessions() {
    // zmx 1.0's `list --short` leaves out sessions of other versions entirely;
    // the full list names them with err=, so Zetty lists from that.
    let list = """
      name=zetty-0a0a0a0a\terr=Unexpected\tstatus=unreachable
      name=zetty-1b1b1b1b\tpid=81140\tclients=0\tcreated=1794538956
      name=build\tpid=12\tclients=0
    """
    #expect(SessionPersistence.sessionNames(fromList: list) == ["zetty-0a0a0a0a", "zetty-1b1b1b1b"])
}

@Test func duplicateDaemonRowsPreferTheOneWithAShell() {
    // Seen on the laptop: two launchd-parented `zmx attach zetty-47ef188b`
    // rows, one of them a stale client from an earlier Zetty.
    let ps = """
       15     1    15 Ss   ??    0:00.01  1200 /opt/homebrew/bin/zmx attach zetty-47ef188b
       16     1    16 Ss   ??    0:00.01  1200 /Users/me/.zetty/bin/zmx attach zetty-47ef188b
       17    16    17 Ss+  s003  0:00.01  1200 -zsh
    """
    #expect(ZmxDaemons.daemons(psOutput: ps)["zetty-47ef188b"] == ZmxDaemon(pid: 16, executable: "/Users/me/.zetty/bin/zmx", shellPID: 17))
}

@Test func parsesTheSocketDirectory() {
    let output = "zmx\t\t1.0.1\nghostty_vt\tghostty-1.4.1\nsocket_dir\t/tmp/zti/zmx\nlog_dir\t\t/tmp/zti/zmx/logs\n"
    #expect(ZmxVersion.socketDirectory(versionOutput: output) == "/tmp/zti/zmx")
    #expect(ZmxVersion.socketDirectory(versionOutput: "zmx\t\t0.6.0\n") == nil)
}

@Test func routingDropsUnreachableSessionsFromTheCommandItRuns() {
    // A kill naming a reachable and an unreachable session must not hand the
    // unreachable one to the reachable one's binary: another version's client
    // hangs against its daemon (final review, 2026-11-13).
    let binaries = ["zetty-a": "/z/1.0.1/zmx", "zetty-b": "/z/1.0.1/zmx"]
    let lookup: (String) -> String? = { binaries[$0] }
    #expect(ZmxCommand.route(["kill", "zetty-a", "zetty-u", "zetty-b"], binaryFor: lookup)
        == [ZmxCommand.Run(binary: "/z/1.0.1/zmx", arguments: ["kill", "zetty-a", "zetty-b"])])
    #expect(ZmxCommand.route(["history", "zetty-u", "--vt"], binaryFor: lookup) == [])
    #expect(ZmxCommand.route(["kill", "zetty-u"], binaryFor: lookup) == [])
}

@Test func routingSplitsAKillAcrossVersionsAndKeepsFlags() {
    let binaries = ["zetty-a": "/z/1.0.1/zmx", "zetty-o": "/z/0.8.1/zmx"]
    let runs = ZmxCommand.route(["kill", "zetty-a", "zetty-o", "--force"], binaryFor: { binaries[$0] })
    #expect(runs == [
        ZmxCommand.Run(binary: "/z/1.0.1/zmx", arguments: ["kill", "zetty-a", "--force"]),
        ZmxCommand.Run(binary: "/z/0.8.1/zmx", arguments: ["kill", "zetty-o", "--force"]),
    ])
    // Unchanged when every session shares one binary.
    #expect(ZmxCommand.route(["send", "zetty-a", "ls -la"], binaryFor: { binaries[$0] })
        == [ZmxCommand.Run(binary: "/z/1.0.1/zmx", arguments: ["send", "zetty-a", "ls -la"])])
    // Names no session: nil, the caller runs it as asked.
    #expect(ZmxCommand.route(["list"], binaryFor: { binaries[$0] }) == nil)
}

@Test func patternsAreSpotted() {
    #expect(ZmxCommand.usesPattern(["kill", "zetty-*"]))
    #expect(ZmxCommand.usesPattern(["kill", "*"]))
    #expect(!ZmxCommand.usesPattern(["kill", "zetty-a"]))
    #expect(!ZmxCommand.usesPattern(["list"]))
}

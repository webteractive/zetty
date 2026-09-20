import Testing
@testable import ZettyCore

// Trimmed real `ps -axo` output in `ProcessTable.psFormat`: a codex TUI in the
// foreground of ttys026, MCP helpers in background groups, root shell idle.
private let psSample = """
64617 1 64617 S+ ttys026 0:01.00 1024 codex
64685 1 64685 S ttys026 0:01.00 1024 npm exec @playwright/mcp@latest
64687 1 64687 S ttys026 0:01.00 1024 ./SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient
94059 1 94059 Ss ttys026 0:01.00 1024 -zsh
11111 1 11111 S+ ttys027 0:01.00 1024 vim
22222 1 22222 Ss ttys027 0:01.00 1024 -zsh
33333 1 33333 Ss+ ttys028 0:01.00 1024 -zsh
44444 1 44444 S ?? 0:01.00 1024 some-daemon
"""

@Test func foregroundResolvesTheForegroundGroupLeader() {
    #expect(ForegroundProcess.command(forSessionPID: 94059, psOutput: psSample) == "codex")
    #expect(ForegroundProcess.command(forSessionPID: 22222, psOutput: psSample) == "vim")
}

@Test func foregroundIgnoresIdleShellInForeground() {
    // ttys028: the shell itself is the foreground group — an idle prompt.
    #expect(ForegroundProcess.command(forSessionPID: 33333, psOutput: psSample) == nil)
}

@Test func foregroundReturnsNilForUnknownPIDOrNoTTY() {
    #expect(ForegroundProcess.command(forSessionPID: 99999, psOutput: psSample) == nil)
    #expect(ForegroundProcess.command(forSessionPID: 44444, psOutput: psSample) == nil)
}

@Test func foregroundResolvesInterpreterScriptsToTheScriptName() {
    // Python/node CLIs report the interpreter as the process; the tool
    // identity is the script (hermes here), skipping any flags.
    let sample = """
    300 1 300 S+ ttys031 0:01.00 1024 /Users/x/.hermes/venv/bin/python3 /Users/x/.hermes/venv/bin/hermes
    400 1 400 Ss ttys031 0:01.00 1024 -zsh
    500 1 500 S+ ttys032 0:01.00 1024 /usr/local/bin/node --max-old-space-size=4096 /opt/tools/mytool
    600 1 600 Ss ttys032 0:01.00 1024 -zsh
    700 1 700 S+ ttys033 0:01.00 1024 python3 -m hermes
    800 1 800 Ss ttys033 0:01.00 1024 -zsh
    """
    #expect(ForegroundProcess.command(forSessionPID: 400, psOutput: sample) == "hermes")
    #expect(ForegroundProcess.command(forSessionPID: 600, psOutput: sample) == "mytool")
    #expect(ForegroundProcess.command(forSessionPID: 800, psOutput: sample) == "hermes")
}

@Test func foregroundBareInterpreterKeepsItsOwnName() {
    // An interactive `python3` REPL has no script — it IS the tool.
    let sample = """
    100 1 100 S+ ttys034 0:01.00 1024 /usr/bin/python3
    200 1 200 Ss ttys034 0:01.00 1024 -zsh
    """
    #expect(ForegroundProcess.command(forSessionPID: 200, psOutput: sample) == "python3")
}

@Test func foregroundStripsPathsToBasenames() {
    let sample = """
    100 1 100 S+ ttys030 0:01.00 1024 /opt/homebrew/bin/htop
    200 1 200 Ss ttys030 0:01.00 1024 -zsh
    """
    #expect(ForegroundProcess.command(forSessionPID: 200, psOutput: sample) == "htop")
}

@Test func zmxListPIDsParse() {
    let list = "  name=zetty-abc\tpid=123\tclients=1\tcreated=1782977929\tstart_dir=/x\n"
        + "  name=supa-zzz\tpid=456\tclients=1\tcreated=1\tstart_dir=/y\tcmd=/usr/bin/login -flp u\n"
    let pids = SessionPersistence.sessionPIDs(fromList: list)
    #expect(pids["zetty-abc"] == 123)
    #expect(pids["supa-zzz"] == 456)
}

import Testing
@testable import ZettyCore

@Test func findsOnlyThatSessionsClients() {
    let ps = """
        9     1     9 Ss   ??    0:00.01  1200 /opt/homebrew/bin/zmx attach zetty-ab12cd34
       10   500    10 S    ??    0:00.01  1200 /opt/homebrew/bin/zmx attach zetty-ab12cd34
       11   500    11 S    ??    0:00.01  1200 /bin/sh /Users/me/.zetty/scrollback-restore.sh /opt/homebrew/bin/zmx zetty-ab12cd34
       12   500    12 S    ??    0:00.01  1200 zmx attach zetty-ab12cd34ff
       13   500    13 S    ??    0:00.01  1200 zmx attach zetty-ab12
       14   500    14 S    ??    0:00.01  1200 vim zetty-ab12cd34
       15   500    15 S    ??    0:00.01  1200 grep attach zetty-ab12cd34
    """
    // 9 is the session's own daemon: zmx forks it from the first attach, it
    // keeps that command line, and launchd is its parent.
    #expect(ZmxAttachProcesses.pids(attaching: "zetty-ab12cd34", psOutput: ps) == [10])
    #expect(ZmxAttachProcesses.pids(attaching: "zetty-ab12", psOutput: ps) == [13])
}

@Test func onlyTheWrappersOwnAttachMayBeRepainted() {
    let ps = """
       20     1    20 Ss   ??    0:00.01  1200 /opt/homebrew/bin/zmx attach zetty-ab12cd34
       21   500    21 S    ??    0:00.01  1200 /bin/sh /Users/me/.zetty/scrollback-restore.sh /opt/homebrew/bin/zmx zetty-ab12cd34
       22    21    21 S    ??    0:00.01  1200 /opt/homebrew/bin/zmx attach zetty-ab12cd34
       23    22    23 Ss   ??    0:00.01  1200 /opt/homebrew/bin/zmx attach zetty-ab12cd34
       24   700    24 S    ??    0:00.01  1200 /opt/homebrew/bin/zmx attach zetty-ab12cd34
    """
    // 22 runs under the wrapper. 23 is the session's daemon while its first
    // attach is alive (signalling it ends the session); 24 is a served
    // relay's attach, whose parent is Zetty itself.
    #expect(ZmxAttachProcesses.repaintablePIDs(attaching: "zetty-ab12cd34", psOutput: ps) == [22])
}

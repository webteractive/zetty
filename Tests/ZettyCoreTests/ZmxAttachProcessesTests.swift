import Testing
@testable import ZettyCore

@Test func findsOnlyThatSessionsClients() {
    let ps = """
       10     1    10 S    ??    0:00.01  1200 /opt/homebrew/bin/zmx attach zetty-ab12cd34
       11     1    11 S    ??    0:00.01  1200 /bin/sh /Users/me/.zetty/scrollback-restore.sh /opt/homebrew/bin/zmx zetty-ab12cd34
       12     1    12 S    ??    0:00.01  1200 zmx attach zetty-ab12cd34ff
       13     1    13 S    ??    0:00.01  1200 zmx attach zetty-ab12
       14     1    14 S    ??    0:00.01  1200 vim zetty-ab12cd34
       15     1    15 S    ??    0:00.01  1200 grep attach zetty-ab12cd34
    """
    #expect(ZmxAttachProcesses.pids(attaching: "zetty-ab12cd34", psOutput: ps) == [10])
    #expect(ZmxAttachProcesses.pids(attaching: "zetty-ab12", psOutput: ps) == [13])
}

import Foundation
import Testing
@testable import ZettyCore

@Test func findsOnlyThisAppsRelaysForTheGivenPanes() {
    // 500 is the app; 600 a pane's login wrapper under it; 700 another app.
    let ps = """
      600   500   600 Ss   ??    0:00.01  1200 /usr/bin/login -flp me /bin/bash -c /Applications/zetty.app/Contents/MacOS/zetty attach 100.64.0.5:ab12cd34
      601   600   600 S    ??    0:00.01  1200 /Applications/zetty.app/Contents/MacOS/zetty attach 100.64.0.5:ab12cd34
      602   600   600 S    ??    0:00.01  1200 /Applications/zetty.app/Contents/MacOS/zetty attach 100.64.0.5:ffff0000
      603   600   600 S    ??    0:00.01  1200 /Applications/zetty.app/Contents/MacOS/zetty attach 100.64.0.5:ab12cd34ff
      701   700   700 S    ??    0:00.01  1200 /Applications/zetty.app/Contents/MacOS/zetty attach 100.64.0.5:ab12cd34
      604   600   600 S    ??    0:00.01  1200 grep attach 100.64.0.5:ab12cd34
    """
    #expect(RelayProcesses.pids(relaying: ["100.64.0.5:ab12cd34"], under: 500, psOutput: ps) == [601])
    #expect(RelayProcesses.pids(relaying: ["100.64.0.5:ab12cd34", "100.64.0.5:ffff0000"],
                                under: 500, psOutput: ps) == [601, 602])
    #expect(RelayProcesses.pids(relaying: [], under: 500, psOutput: ps).isEmpty)
}

@Test func relayTargetsOutliveTheMachinesAddress() {
    // Teardown must find a relay by what it was started with: by the time a
    // Mac goes offline, its address is already gone (markDisconnected).
    let a = UUID(), b = UUID(), never = UUID()
    var targets = RelayTargets()
    targets.record(a, address: "100.64.0.5", pane: "ab12cd34")
    targets.record(b, address: "100.64.0.5", pane: "ef56")
    #expect(targets.take([a, never]) == ["100.64.0.5:ab12cd34"])
    #expect(targets.take([a]) == [])
    #expect(targets.take([b]) == ["100.64.0.5:ef56"])
}

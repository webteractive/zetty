import Foundation
import Testing
@testable import ZettyCore

private func workspace() -> StatusSnapshot {
    let pane = StatusSnapshot.Pane(id: "ab12cd34", title: "zsh", cwd: "/Users/me/zetty", tool: nil,
                                   agentStatus: nil, isFocused: true, live: true)
    return StatusSnapshot(projects: [
        .init(name: "zetty", isActive: true, hibernated: false, id: "P-1",
              tabs: [.init(title: "main", isActive: true, panes: [pane])]),
        .init(name: "Asleep", isActive: false, hibernated: true, id: "P-2", tabs: []),
    ])
}

private func mini(_ state: RemoteMachine.State = .online) -> RemoteMachine {
    RemoteMachine(stableID: "nMINI", name: "Mac mini", state: state,
                  lastSeen: Date(timeIntervalSince1970: 0), workspace: workspace(), address: "100.64.0.2")
}

@Test func reportFlattensEveryMachineState() {
    let now = Date(timeIntervalSince1970: 7_200)
    let cases: [(RemoteMachine.State, String)] = [
        (.connecting, "connecting"), (.online, "online"), (.offline, "offline"),
        (.needsUpdate(theirs: 9), "needs-update"), (.refused("it's tagged"), "refused"),
    ]
    for (state, word) in cases {
        let machine = RemoteMachinesReport.Machine(mini(state), now: now)
        #expect(machine.state == word)
        #expect(machine.summary == RemoteMachineSummary.text(for: mini(state), now: now))
    }
    #expect(RemoteMachinesReport.Machine(mini(), now: now).lastSeen == "1970-01-01T00:00:00Z")
}

@Test func reportFindsMachinesAndAwakeProjectsByNameOrID() {
    let report = RemoteMachinesReport(listing: true, serving: true, port: 47_391,
                                      machines: [.init(mini(), now: Date())])
    #expect(report.machine(matching: "mac MINI")?.id == "nMINI")
    #expect(report.machine(matching: "nMINI")?.name == "Mac mini")
    #expect(report.machine(matching: "laptop") == nil)
    let machine = report.machines[0]
    #expect(machine.project(matching: "ZETTY")?.id == "P-1")
    #expect(machine.project(matching: "P-1")?.name == "zetty")
    // A hibernated project can't be opened from another Mac.
    #expect(machine.project(matching: "Asleep") == nil)
}

@Test func remoteRequestsAndReportRoundTripTheWire() throws {
    for request in [ControlRequest.remoteList, .remoteOpen(machine: "Mac mini", project: "zetty"), .remoteClose] {
        let data = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(ControlRequest.self, from: data) == request)
    }
    let report = RemoteMachinesReport(
        listing: true, serving: false, port: 47_392, machines: [.init(mini(), now: Date())],
        shown: .init(machineID: "nMINI", machine: "Mac mini", projectID: "P-1", project: "zetty",
                     tab: 0, panes: ["ab12cd34"]))
    let data = try JSONEncoder().encode(ControlResponse.remote(report))
    #expect(try JSONDecoder().decode(ControlResponse.self, from: data) == .remote(report))
}

@Test func reportFromAnOlderAppStillDecodes() throws {
    let json = #"{"machines": []}"#
    let report = try JSONDecoder().decode(RemoteMachinesReport.self, from: Data(json.utf8))
    #expect(report == RemoteMachinesReport(listing: false, serving: false, port: 47_391, machines: []))
}

@Test func remoteLinesSayWhatEachMacIsAndWhatShows() {
    #expect(ControlCLI.remoteLines(.init(listing: false, serving: true, port: 47_391, machines: []))
        == ["Other Macs is off: turn on zetty-remote-machines (Settings → General → Other Macs)"])
    #expect(ControlCLI.remoteLines(.init(listing: true, serving: false, port: 47_391, machines: []))
        == ["no other Macs yet", "serving: off"])

    let online = RemoteMachinesReport.Machine(id: "nMINI", name: "Mac mini", state: "online", summary: "1",
                                              address: "100.64.0.2", lastSeen: nil, workspace: nil)
    let offline = RemoteMachinesReport.Machine(id: "nLAP", name: "Laptop", state: "offline",
                                               summary: "offline · seen 2h ago", address: nil,
                                               lastSeen: nil, workspace: nil)
    let shown = RemoteMachinesReport.Shown(machineID: "nMINI", machine: "Mac mini", projectID: "P-1",
                                           project: "zetty", tab: 1, panes: ["ab12cd34", "00ff00ff"])
    #expect(ControlCLI.remoteLines(.init(listing: true, serving: true, port: 47_392,
                                         machines: [online, offline], shown: shown)) == [
        "● Mac mini  1  100.64.0.2",
        "○ Laptop    offline · seen 2h ago",
        "showing Mac mini › zetty, tab 2: ab12cd34 00ff00ff",
        "serving: on, port 47392",
    ])
    let waiting = RemoteMachinesReport.Shown(machineID: "nMINI", machine: "Mac mini", projectID: "P-1",
                                             project: "zetty", tab: 0, panes: [],
                                             placeholder: "Mac mini is offline. Its panes open here when it's back.")
    #expect(ControlCLI.remoteLines(.init(listing: true, serving: false, port: 47_391,
                                         machines: [online], shown: waiting)).contains(
        "showing Mac mini › zetty, tab 1: Mac mini is offline. Its panes open here when it's back."))
}

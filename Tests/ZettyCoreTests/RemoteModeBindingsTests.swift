import Testing
@testable import ZettyCore

@Test func structuralCommandsAreUnavailable() {
    let structural: [BindingCommand] = [.closePane, .splitVertical, .splitHorizontal, .breakPane, .newTab, .renameTab,
                                        .toggleFileTree, .toggleTileMode, .zoomPane, .enterCopyMode, .paste,
                                        .broadcastToggle, .broadcastAgentsToggle, .broadcastCycle, .copyYank]
    for command in structural {
        #expect(RemoteModeBindings.effect(of: command) == .unavailable, "\(command)")
    }
}

@Test func navigationMapsToTheRemoteView() {
    #expect(RemoteModeBindings.effect(of: .focusLeft) == .focus(.left))
    #expect(RemoteModeBindings.effect(of: .focusRight) == .focus(.right))
    #expect(RemoteModeBindings.effect(of: .focusUp) == .focus(.up))
    #expect(RemoteModeBindings.effect(of: .focusDown) == .focus(.down))
    #expect(RemoteModeBindings.effect(of: .cyclePanes) == .cycleFocus)
    #expect(RemoteModeBindings.effect(of: .nextTab) == .nextTab)
    #expect(RemoteModeBindings.effect(of: .previousTab) == .previousTab)
    #expect(RemoteModeBindings.effect(of: .selectTab(3)) == .selectTab(3))
}

@Test func prefixControlPassesThrough() {
    #expect(RemoteModeBindings.effect(of: .cancelPrefix) == .passThrough)
    #expect(RemoteModeBindings.effect(of: .sendPrefixLiteral) == .passThrough)
}

@Test func remotePaletteOffersOnlyNavigationOfTheShownProject() {
    let entries = RemoteModeBindings.paletteEntries(tabTitles: ["api", "logs", "db"], selectedTab: 1)
    #expect(entries.map(\.label) == ["Next Tab", "Previous Tab", "Go to Tab: api", "Go to Tab: db",
                                     "Focus Pane Left", "Focus Pane Right", "Focus Pane Up", "Focus Pane Down",
                                     "Cycle Pane Focus"])
    #expect(entries.first { $0.label == "Go to Tab: api" }?.effect == .selectTab(1))
    #expect(entries.first { $0.label == "Go to Tab: db" }?.effect == .selectTab(3))
    #expect(!entries.contains { $0.effect == .unavailable || $0.effect == .passThrough })
}

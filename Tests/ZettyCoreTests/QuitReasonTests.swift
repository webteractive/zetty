import Testing
@testable import ZettyCore

private let core = QuitReason.fourCC("aevt")   // kCoreEventClass
private let quit = QuitReason.fourCC("quit")   // kAEQuitApplication

@Test func fourCCPacksBigEndianASCII() {
    #expect(QuitReason.fourCC("shut") == 0x7368_7574)
}

@Test func powerOffReasonsClassifyAsPowerOff() {
    for code in ["shut", "rest", "rlgo"] {   // kAEShutDown, kAERestart, kAEReallyLogOut
        #expect(QuitReason.classify(eventClass: core, eventID: quit, reason: QuitReason.fourCC(code)) == .powerOff)
    }
}

@Test func quitWithoutReasonIsOrdinary() {
    #expect(QuitReason.classify(eventClass: core, eventID: quit, reason: nil) == .ordinary)
}

@Test func nonQuitEventIsOrdinaryEvenWithAReasonAttribute() {
    #expect(QuitReason.classify(eventClass: core, eventID: QuitReason.fourCC("oapp"), reason: QuitReason.fourCC("shut")) == .ordinary)
}

@Test func noEventIsOrdinary() {
    #expect(QuitReason.classify(eventClass: nil, eventID: nil, reason: nil) == .ordinary)
}

@Test func quitAllIsOrdinary() {
    // kAEQuitAll ('quia') is a "quit every app" gesture, not a power-off; sessions survive.
    #expect(QuitReason.classify(eventClass: core, eventID: quit, reason: QuitReason.fourCC("quia")) == .ordinary)
}

@Test func aPowerOffReasonFromAnyoneButLoginwindowIsOrdinary() {
    // System Settings' "Quit & Reopen" after a privacy permission change sends
    // a quit with a restart reason; 2026-11-13 it was read as a power-off, ran
    // restart recovery on both Macs, and the laptop's recovery burst crashed.
    // A real restart, shutdown or logout comes from loginwindow.
    let rest = QuitReason.fourCC("rest")
    #expect(QuitReason.classify(eventClass: core, eventID: quit, reason: rest, sender: "System Settings") == .ordinary)
    #expect(QuitReason.classify(eventClass: core, eventID: quit, reason: rest, sender: "loginwindow") == .powerOff)
    // Sender unknown (the attribute was missing): the reason decides, as before.
    #expect(QuitReason.classify(eventClass: core, eventID: quit, reason: rest, sender: nil) == .powerOff)
}

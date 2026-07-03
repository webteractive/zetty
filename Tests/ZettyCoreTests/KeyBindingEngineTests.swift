import Foundation
import Testing
@testable import ZettyCore

private func makeEngine(prefix: String = "ctrl+b") -> KeyBindingEngine {
    KeyBindingEngine(
        prefix: KeyChord.parse(prefix)!,
        prefixTable: BindingCommand.defaultPrefixTable,
        copyTable: BindingCommand.defaultCopyTable
    )
}

private func makeCopyModeEngine() -> KeyBindingEngine {
    let engine = makeEngine()
    _ = engine.handle(chord("ctrl+b"))
    _ = engine.handle(chord("["))
    return engine
}

private func chord(_ text: String) -> KeyChord { KeyChord.parse(text)! }

// MARK: - Normal mode

@Test func engineNormalModePassesThroughOrdinaryKeys() {
    let engine = makeEngine()
    #expect(engine.handle(chord("a")) == .passthrough)
    #expect(engine.handle(chord("cmd+t")) == .passthrough)
    #expect(engine.mode == .normal)
}

@Test func enginePrefixArmsAndSwallows() {
    let engine = makeEngine()
    #expect(engine.handle(chord("ctrl+b")) == .consumeNoop)
    #expect(engine.mode == .prefixArmed)
}

// MARK: - Armed mode

@Test func engineArmedBoundKeyConsumesAndDisarms() {
    let engine = makeEngine()
    _ = engine.handle(chord("ctrl+b"))
    #expect(engine.handle(chord("%")) == .consume(.splitVertical))
    #expect(engine.mode == .normal)
}

@Test func engineArmedShiftedSymbolMatches() {
    // `%` arrives from AppKit as character "%" plus a shift modifier.
    let engine = makeEngine()
    _ = engine.handle(chord("ctrl+b"))
    let pressed = KeyChord(key: .character("%"), modifiers: [.shift])
    #expect(engine.handle(pressed) == .consume(.splitVertical))
}

@Test func engineArmedPrefixAgainSendsLiteralAndDisarms() {
    let engine = makeEngine()
    _ = engine.handle(chord("ctrl+b"))
    #expect(engine.handle(chord("ctrl+b")) == .consume(.sendPrefixLiteral))
    #expect(engine.mode == .normal)
}

@Test func engineArmedEscapeCancels() {
    let engine = makeEngine()
    _ = engine.handle(chord("ctrl+b"))
    #expect(engine.handle(chord("escape")) == .consume(.cancelPrefix))
    #expect(engine.mode == .normal)
}

@Test func engineArmedUnboundKeySwallowsAndDisarms() {
    let engine = makeEngine()
    _ = engine.handle(chord("ctrl+b"))
    #expect(engine.handle(chord("Q")) == .consumeNoop)
    #expect(engine.mode == .normal)
}

@Test func engineArmedSelectTab() {
    let engine = makeEngine()
    _ = engine.handle(chord("ctrl+b"))
    #expect(engine.handle(chord("3")) == .consume(.selectTab(3)))
}

@Test func engineArmedEnterCopyModeSwitchesMode() {
    let engine = makeEngine()
    _ = engine.handle(chord("ctrl+b"))
    #expect(engine.handle(chord("[")) == .consume(.enterCopyMode))
    #expect(engine.mode == .copyMode)
}

// MARK: - Copy mode

@Test func engineCopyModeDispatchesMotions() {
    let engine = makeCopyModeEngine()
    #expect(engine.handle(chord("j")) == .consume(.copyCursorDown))
    #expect(engine.handle(chord("w")) == .consume(.copyWordForward))
    #expect(engine.mode == .copyMode)
}

@Test func engineCopyModePrefixChordIsPageUpNotPrefix() {
    // Modal tables: in copy mode ctrl+b is vi page-up, not the prefix.
    let engine = makeCopyModeEngine()
    #expect(engine.handle(chord("ctrl+b")) == .consume(.copyPageUp))
    #expect(engine.mode == .copyMode)
}

@Test func engineCopyModeCaseSensitiveKeys() {
    let engine = makeCopyModeEngine()
    #expect(engine.handle(chord("g")) == .consume(.copyScrollTop))
    #expect(engine.handle(chord("G")) == .consume(.copyScrollBottom))
    #expect(engine.handle(KeyChord(key: .character("G"), modifiers: [.shift])) == .consume(.copyScrollBottom))
}

@Test func engineCopyModeSwallowsUnboundKeys() {
    let engine = makeCopyModeEngine()
    #expect(engine.handle(chord("z")) == .consumeNoop)
    #expect(engine.handle(chord("cmd+r")) == .consumeNoop)
    #expect(engine.mode == .copyMode)
}

@Test func engineCopyModeYankReturnsToNormal() {
    let engine = makeCopyModeEngine()
    #expect(engine.handle(chord("y")) == .consume(.copyYank))
    #expect(engine.mode == .normal)
}

@Test func engineCopyModeExitReturnsToNormal() {
    for exitKey in ["escape", "q"] {
        let engine = makeCopyModeEngine()
        #expect(engine.handle(chord(exitKey)) == .consume(.copyExit))
        #expect(engine.mode == .normal)
    }
}

// MARK: - Reset / external exits

@Test func engineResetFromEveryMode() {
    let armed = makeEngine()
    _ = armed.handle(chord("ctrl+b"))
    armed.reset()
    #expect(armed.mode == .normal)

    let copying = makeCopyModeEngine()
    copying.reset()
    #expect(copying.mode == .normal)
}

@Test func engineExitCopyModeOnlyLeavesCopyMode() {
    let engine = makeEngine()
    _ = engine.handle(chord("ctrl+b"))
    engine.exitCopyMode()                 // not in copy mode → no-op
    #expect(engine.mode == .prefixArmed)

    let copying = makeCopyModeEngine()
    copying.exitCopyMode()
    #expect(copying.mode == .normal)
}

// MARK: - Custom prefix

@Test func engineCustomPrefixWorks() {
    let engine = makeEngine(prefix: "ctrl+space")
    #expect(engine.handle(chord("ctrl+b")) == .passthrough)
    #expect(engine.handle(chord("ctrl+space")) == .consumeNoop)
    #expect(engine.handle(chord("c")) == .consume(.newTab))
}

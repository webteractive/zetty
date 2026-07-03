import Foundation
import Testing
@testable import ZettyCore

// MARK: - Parsing

@Test func chordParsesPlainLetter() {
    #expect(KeyChord.parse("x") == KeyChord(key: .character("x"), modifiers: []))
}

@Test func chordLetterCharactersAreCaseSensitive() {
    // `G` and `g` are different bindings (vi copy mode relies on this);
    // an uppercase letter means the shifted key.
    #expect(KeyChord.parse("X") == KeyChord(key: .character("X"), modifiers: []))
    #expect(KeyChord.parse("G") != KeyChord.parse("g"))
}

@Test func chordShiftPlusLetterNormalizesToUppercaseCharacter() {
    // `shift+g` and `G` are the same chord once normalized — and both
    // match a physical shift+g press (character "G" + shift modifier).
    let fromShift = KeyChord.parse("shift+g")!.normalized
    let fromUpper = KeyChord.parse("G")!.normalized
    #expect(fromShift == fromUpper)

    let pressed = KeyChord(key: .character("G"), modifiers: [.shift])
    #expect(fromUpper.matches(pressed))
}

@Test func chordParsesSymbolCharacters() {
    #expect(KeyChord.parse("%") == KeyChord(key: .character("%"), modifiers: []))
    #expect(KeyChord.parse("\"") == KeyChord(key: .character("\""), modifiers: []))
    #expect(KeyChord.parse("$") == KeyChord(key: .character("$"), modifiers: []))
    #expect(KeyChord.parse("[") == KeyChord(key: .character("["), modifiers: []))
}

@Test func chordParsesCtrlModifier() {
    #expect(KeyChord.parse("ctrl+b") == KeyChord(key: .character("b"), modifiers: [.ctrl]))
}

@Test func chordParsesMultipleModifiers() {
    #expect(KeyChord.parse("shift+cmd+x") == KeyChord(key: .character("x"), modifiers: [.shift, .cmd]))
}

@Test func chordParsesModifierAliases() {
    #expect(KeyChord.parse("control+b") == KeyChord(key: .character("b"), modifiers: [.ctrl]))
    #expect(KeyChord.parse("command+k") == KeyChord(key: .character("k"), modifiers: [.cmd]))
    #expect(KeyChord.parse("option+f") == KeyChord(key: .character("f"), modifiers: [.alt]))
    #expect(KeyChord.parse("opt+f") == KeyChord(key: .character("f"), modifiers: [.alt]))
    #expect(KeyChord.parse("alt+f") == KeyChord(key: .character("f"), modifiers: [.alt]))
}

@Test func chordParsesNamedKeys() {
    #expect(KeyChord.parse("escape") == KeyChord(key: .named(.escape), modifiers: []))
    #expect(KeyChord.parse("up") == KeyChord(key: .named(.up), modifiers: []))
    #expect(KeyChord.parse("shift+up") == KeyChord(key: .named(.up), modifiers: [.shift]))
    #expect(KeyChord.parse("ctrl+space") == KeyChord(key: .named(.space), modifiers: [.ctrl]))
    #expect(KeyChord.parse("enter") == KeyChord(key: .named(.enter), modifiers: []))
}

@Test func chordParsesDigits() {
    #expect(KeyChord.parse("cmd+1") == KeyChord(key: .character("1"), modifiers: [.cmd]))
    #expect(KeyChord.parse("9") == KeyChord(key: .character("9"), modifiers: []))
}

@Test func chordModifierAndNamedKeyWordsAreCaseInsensitiveAndTrimmed() {
    // Modifier words and named keys are case-insensitive; single
    // characters keep their case (uppercase = shifted).
    #expect(KeyChord.parse(" Ctrl+b ") == KeyChord(key: .character("b"), modifiers: [.ctrl]))
    #expect(KeyChord.parse("ESCAPE") == KeyChord(key: .named(.escape), modifiers: []))
    #expect(KeyChord.parse("Shift+Up") == KeyChord(key: .named(.up), modifiers: [.shift]))
}

@Test func chordParseRejectsJunk() {
    #expect(KeyChord.parse("") == nil)
    #expect(KeyChord.parse("ctrl+") == nil)
    #expect(KeyChord.parse("+b") == nil)
    #expect(KeyChord.parse("ctrl") == nil)          // a bare modifier is not a key
    #expect(KeyChord.parse("blorp") == nil)          // multi-char, not a named key
    #expect(KeyChord.parse("ctrl+blorp") == nil)
    #expect(KeyChord.parse("ctrl+ctrl+b") == nil)    // repeated modifier is malformed
}

// MARK: - Matching (shift rule)

@Test func chordCharacterMatchIgnoresShift() {
    // `%` is shift+5 on most layouts: the shift is baked into the character.
    let table = KeyChord(key: .character("%"), modifiers: [])
    let pressed = KeyChord(key: .character("%"), modifiers: [.shift])
    #expect(table.matches(pressed))
    #expect(pressed.matches(table))
}

@Test func chordCharacterMatchComparesOtherModifiers() {
    let plain = KeyChord(key: .character("b"), modifiers: [])
    let ctrl = KeyChord(key: .character("b"), modifiers: [.ctrl])
    #expect(!plain.matches(ctrl))
    // Shift folds into the letter: ctrl+shift+b is ctrl+B, not ctrl+b.
    #expect(!ctrl.matches(KeyChord(key: .character("b"), modifiers: [.ctrl, .shift])))
    #expect(KeyChord.parse("ctrl+B")!.matches(KeyChord(key: .character("B"), modifiers: [.ctrl, .shift])))
    #expect(!ctrl.matches(KeyChord(key: .character("b"), modifiers: [.ctrl, .alt])))
}

@Test func chordNamedKeyMatchIsShiftSensitive() {
    let up = KeyChord(key: .named(.up), modifiers: [])
    let shiftUp = KeyChord(key: .named(.up), modifiers: [.shift])
    #expect(!up.matches(shiftUp))
    #expect(shiftUp.matches(KeyChord(key: .named(.up), modifiers: [.shift])))
}

@Test func chordDifferentKeysNeverMatch() {
    #expect(!KeyChord(key: .character("a"), modifiers: []).matches(KeyChord(key: .character("b"), modifiers: [])))
    #expect(!KeyChord(key: .named(.up), modifiers: []).matches(KeyChord(key: .character("k"), modifiers: [])))
}

// MARK: - Config round-trip

@Test func chordConfigDescriptionRoundTrips() {
    let chords = ["ctrl+b", "%", "shift+up", "cmd+1", "ctrl+space", "escape", "shift+cmd+x"]
    for text in chords {
        let chord = try! #require(KeyChord.parse(text))
        #expect(KeyChord.parse(chord.configDescription) == chord, "round-trip failed for \(text)")
    }
}

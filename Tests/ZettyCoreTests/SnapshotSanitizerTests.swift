import Foundation
import Testing
@testable import ZettyCore

private let esc = "\u{1B}"

private func sanitize(_ s: String) -> String {
    String(decoding: SnapshotSanitizer.sanitized(snapshot: Data(s.utf8)), as: UTF8.self)
}

private func body(_ s: String) -> String {
    let out = sanitize(s)
    #expect(out.hasSuffix(SnapshotSanitizer.resetTrailer))
    return String(out.dropLast(SnapshotSanitizer.resetTrailer.count))
}

@Test func stripsTheModesAKilledAgentLeavesBehind() {
    // Exactly what a real agent snapshot carried: alt screen, every mouse
    // reporting mode, bracketed paste — all enabled, never reset.
    let captured = "\(esc)[?1049h\(esc)[?1000h\(esc)[?1002h\(esc)[?1003h\(esc)[?1006h\(esc)[?2004hhello"
    #expect(body(captured) == "hello")
}

@Test func stripsMultiParameterAndResetFormsToo() {
    #expect(body("\(esc)[?1000;1002;1006hx") == "x")
    #expect(body("a\(esc)[?25lb\(esc)[?7hc") == "abc")
}

@Test func stripsScrollRegionSoTheShellIsNotConfinedToPartOfTheScreen() {
    #expect(body("\(esc)[1;20rtop") == "top")
    #expect(body("\(esc)[rtop") == "top")
}

@Test func keepsTextColourAndCursorPositioning() {
    // The replay must still look like the pane did.
    let drawn = "\(esc)[32mgreen\(esc)[0m \(esc)[10;5Hmoved \(esc)[38;5;208mindexed\(esc)[m"
    #expect(body(drawn) == drawn)
}

@Test func appendsAResetTrailerThatTurnsMouseReportingOff() {
    let out = sanitize("plain")
    #expect(out.hasPrefix("plain"))
    for mode in ["1000", "1002", "1003", "1006", "2004"] {
        #expect(out.contains("\(esc)[?\(mode)l"))
    }
    #expect(out.contains("\(esc)[r"))      // margins
    #expect(out.contains("\(esc)[0m"))     // attributes
    #expect(out.contains("\(esc)[?25h"))   // cursor visible
}

@Test func aTruncatedEscapeAtTheEndSurvivesIntact() {
    // A capture cut off mid-sequence must not lose bytes or crash.
    #expect(body("text\(esc)[?104") == "text\(esc)[?104")
    #expect(body("text\(esc)[") == "text\(esc)[")
    #expect(body("text\(esc)") == "text\(esc)")
}

@Test func emptyInputYieldsOnlyTheTrailer() {
    #expect(sanitize("") == SnapshotSanitizer.resetTrailer)
}

@Test func binarySafeForNonUTF8Bytes() {
    // A VT stream is bytes, not text: arbitrary payloads must pass through.
    var data = Data([0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x68])   // ESC [ ? 1 0 4 9 h
    data.append(contentsOf: [0xFF, 0xFE, 0x41])
    let out = SnapshotSanitizer.sanitized(snapshot: data)
    #expect(out.prefix(3) == Data([0xFF, 0xFE, 0x41]))
    #expect(out.count == 3 + SnapshotSanitizer.resetTrailer.utf8.count)
}

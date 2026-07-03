import Testing
@testable import ZettyCore

// `zetty send` payloads are delivered through ghostty's `text:` binding
// action (a raw pty write). The action value is parsed as a Zig string
// literal, so the payload must be escaped: backslashes doubled, control
// bytes (and DEL) as \xNN, everything else verbatim.

@Test func textActionPassesPlainTextThrough() {
    #expect(GhosttyTextAction.encode("ls -la") == "text:ls -la")
}

@Test func textActionEscapesBackslashes() {
    #expect(GhosttyTextAction.encode(#"a\b"#) == #"text:a\\b"#)
}

@Test func textActionEscapesControlBytes() {
    #expect(GhosttyTextAction.encode("\r") == #"text:\x0d"#)          // Enter
    #expect(GhosttyTextAction.encode("\u{03}") == #"text:\x03"#)      // C-c
    #expect(GhosttyTextAction.encode("\u{1b}[A") == #"text:\x1b[A"#)  // Up arrow
    #expect(GhosttyTextAction.encode("\u{7f}") == #"text:\x7f"#)      // DEL/BSpace
}

@Test func textActionComposesTextKeysAndEnter() {
    // A full CLI payload: text, then a key sequence, then the carriage return.
    #expect(GhosttyTextAction.encode("ls\u{03}\r") == #"text:ls\x03\x0d"#)
}

@Test func textActionPreservesUnicodeVerbatim() {
    #expect(GhosttyTextAction.encode("héllo → 世界") == "text:héllo → 世界")
}

@Test func textActionEmptyPayload() {
    #expect(GhosttyTextAction.encode("") == "text:")
}

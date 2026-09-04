import Testing
@testable import ZettyCore

@Test func singleQuotedWrapsPlainText() {
    #expect(ShellQuote.singleQuoted("/Users/g/AI/zetty") == "'/Users/g/AI/zetty'")
}

@Test func singleQuotedEscapesEmbeddedSingleQuotes() {
    // POSIX: close, escaped quote, reopen.
    #expect(ShellQuote.singleQuoted("/Users/g/it's here") == #"'/Users/g/it'\''s here'"#)
}

@Test func singleQuotedLeavesShellMetacharactersInert() {
    #expect(ShellQuote.singleQuoted("$HOME; rm -rf ~") == #"'$HOME; rm -rf ~'"#)
}

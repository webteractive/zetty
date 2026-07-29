import Testing
@testable import ZettyCore

// MARK: - parse

@Test func parseTakesBarePath() {
    #expect(FilePathToken.parse("App/Sources/App/Theme.swift")
            == PathToken(path: "App/Sources/App/Theme.swift"))
}

@Test func parseTakesLineSuffix() {
    #expect(FilePathToken.parse("Theme.swift:412")
            == PathToken(path: "Theme.swift", line: 412))
}

@Test func parseTakesLineAndColumnSuffix() {
    #expect(FilePathToken.parse("Theme.swift:412:9")
            == PathToken(path: "Theme.swift", line: 412, column: 9))
}

@Test func parseStopsAtTwoNumericSegments() {
    // A third number is part of the path, not a position.
    #expect(FilePathToken.parse("logs/2026/07/29:12:30")
            == PathToken(path: "logs/2026/07/29", line: 12, column: 30))
}

@Test func parseRejectsPureNumber() {
    #expect(FilePathToken.parse("412") == nil)
}

@Test func parseRejectsEmpty() {
    #expect(FilePathToken.parse("") == nil)
}

@Test func parseKeepsExtensionlessName() {
    // Existence is the real filter, so `Makefile` must survive extraction.
    #expect(FilePathToken.parse("Makefile") == PathToken(path: "Makefile"))
}

// MARK: - match

@Test func matchFindsTokenAtClickColumn() {
    let line = "App/Sources/App/Theme.swift:412: error: bad"
    let match = FilePathToken.match(in: line, column: 5)
    #expect(match?.token == PathToken(path: "App/Sources/App/Theme.swift", line: 412))
    #expect(match?.startColumn == 0)
    // Trailing ":" is trimmed, so the span ends on the "2" of 412.
    #expect(match?.endColumn == 30)
}

@Test func matchWorksAtEitherEndOfTheToken() {
    let line = "  Theme.swift:412  "
    let first = FilePathToken.match(in: line, column: 2)
    let last = FilePathToken.match(in: line, column: 16)
    #expect(first?.token == PathToken(path: "Theme.swift", line: 412))
    #expect(first == last)
}

@Test func matchReturnsNilOnWhitespace() {
    #expect(FilePathToken.match(in: "a  b", column: 1) == nil)
}

@Test func matchReturnsNilOutOfBounds() {
    #expect(FilePathToken.match(in: "abc", column: 99) == nil)
    #expect(FilePathToken.match(in: "abc", column: -1) == nil)
}

@Test func matchStopsAtQuotesAndParens() {
    let line = "expected(\"Sources/x.swift\")"
    #expect(FilePathToken.match(in: line, column: 12)?.token
            == PathToken(path: "Sources/x.swift"))
}

@Test func matchTrimsTrailingSentencePunctuation() {
    #expect(FilePathToken.match(in: "see Sources/x.swift.", column: 6)?.token
            == PathToken(path: "Sources/x.swift"))
}

@Test func matchKeepsGitDiffPrefix() {
    // The prefix is stripped later, as a *candidate* — not here.
    #expect(FilePathToken.match(in: "--- a/Sources/x.swift", column: 8)?.token
            == PathToken(path: "a/Sources/x.swift"))
}

@Test func matchKeepsTildePath() {
    #expect(FilePathToken.match(in: "at ~/.zetty/config", column: 5)?.token
            == PathToken(path: "~/.zetty/config"))
}

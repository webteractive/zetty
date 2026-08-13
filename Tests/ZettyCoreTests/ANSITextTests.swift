import Testing
@testable import ZettyCore

private let esc = "\u{1B}"

@Test func parsePlainTextIsOneRun() {
    let runs = ANSIText.parse("hello")
    #expect(runs == [ANSIRun(text: "hello", style: ANSIStyle())])
}

@Test func parseEmptyStringIsNoRuns() {
    #expect(ANSIText.parse("").isEmpty)
}

/// Output that is nothing but escape sequences carries no printable text, so it
/// yields no runs — the state `FileViewerLoader` falls back to plain text on,
/// rather than handing the viewer an empty body.
@Test func parseEscapeOnlyOutputIsNoRuns() {
    #expect(ANSIText.parse("\(esc)[0m\(esc)[38;5;238m\(esc)[0m").isEmpty)
}

@Test func parseSplitsOnColourChange() {
    let runs = ANSIText.parse("a\(esc)[31mb\(esc)[0mc")
    #expect(runs.count == 3)
    #expect(runs[0].text == "a")
    #expect(runs[0].style.foreground == nil)
    #expect(runs[1].text == "b")
    #expect(runs[1].style.foreground == .indexed(1))
    #expect(runs[2].text == "c")
    #expect(runs[2].style.foreground == nil)
}

@Test func parseHandlesBrightForegrounds() {
    let runs = ANSIText.parse("\(esc)[92mx")
    #expect(runs[0].style.foreground == .indexed(10))
}

@Test func parseHandlesAttributesAndTheirResets() {
    let runs = ANSIText.parse("\(esc)[1;3;4mx\(esc)[22;23;24my")
    #expect(runs[0].style.bold)
    #expect(runs[0].style.italic)
    #expect(runs[0].style.underline)
    #expect(!runs[1].style.bold)
    #expect(!runs[1].style.italic)
    #expect(!runs[1].style.underline)
}

@Test func parse256ColourKeepsLowIndexesPaletteBound() {
    #expect(ANSIText.parse("\(esc)[38;5;9mx")[0].style.foreground == .indexed(9))
}

@Test func parse256ColourComputesTheCube() {
    // 196 = 16 + 36*5 → r level 5 (255), g 0, b 0.
    #expect(ANSIText.parse("\(esc)[38;5;196mx")[0].style.foreground == .rgb(r: 255, g: 0, b: 0))
}

@Test func parse256ColourComputesTheGreyRamp() {
    // 232 is the darkest grey: 8,8,8.
    #expect(ANSIText.parse("\(esc)[38;5;232mx")[0].style.foreground == .rgb(r: 8, g: 8, b: 8))
}

@Test func parseTruecolour() {
    #expect(ANSIText.parse("\(esc)[38;2;122;162;247mx")[0].style.foreground
            == .rgb(r: 122, g: 162, b: 247))
}

@Test func parseBareResetSequenceIsAFullReset() {
    // ESC[m == ESC[0m
    let runs = ANSIText.parse("\(esc)[1ma\(esc)[mb")
    #expect(runs[0].style.bold)
    #expect(!runs[1].style.bold)
}

@Test func parseDropsNonStyleCSISequences() {
    let runs = ANSIText.parse("a\(esc)[2Kb")
    #expect(runs == [ANSIRun(text: "ab", style: ANSIStyle())])
}

@Test func parseKeepsUnterminatedSequenceAsLiteralText() {
    let runs = ANSIText.parse("a\(esc)[31")
    #expect(runs.count == 1)
    #expect(runs[0].text == "a\(esc)[31")
}

@Test func parseKeepsLoneEscapeAsLiteralText() {
    #expect(ANSIText.parse("a\(esc)b")[0].text == "a\(esc)b")
}

@Test func parseIgnoresBackgroundCodes() {
    // Backgrounds are deliberately unsupported — the panel owns its surface.
    let runs = ANSIText.parse("\(esc)[41mx")
    #expect(runs[0].style.foreground == nil)
    #expect(runs[0].text == "x")
}

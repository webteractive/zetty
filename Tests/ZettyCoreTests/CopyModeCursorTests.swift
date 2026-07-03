import Foundation
import Testing
@testable import ZettyCore

private let grid = (rows: 5, cols: 20)
private let lines = [
    "hello world  foo",
    "",
    "  indented text",
    "single",
    "tail             ",   // trailing spaces are padding
]

private func cursor(_ row: Int, _ col: Int) -> CopyModeCursor { CopyModeCursor(row: row, col: col) }

private func move(_ from: CopyModeCursor, _ motion: CopyMotion, withText: Bool = true) -> CopyModeCursor {
    from.moved(motion, rows: grid.rows, cols: grid.cols, lines: withText ? lines : [])
}

// MARK: - Character motions & clamping

@Test func copyCursorCharMotionsClampAtEdges() {
    #expect(move(cursor(0, 0), .left) == cursor(0, 0))
    #expect(move(cursor(0, 0), .up) == cursor(0, 0))
    #expect(move(cursor(4, 19), .right) == cursor(4, 19))
    #expect(move(cursor(4, 19), .down) == cursor(4, 19))
    #expect(move(cursor(2, 3), .left) == cursor(2, 2))
    #expect(move(cursor(2, 3), .right) == cursor(2, 4))
    #expect(move(cursor(2, 3), .up) == cursor(1, 3))
    #expect(move(cursor(2, 3), .down) == cursor(3, 3))
}

@Test func copyCursorZeroSizedGridIsIdentity() {
    #expect(cursor(2, 3).moved(.down, rows: 0, cols: 0) == cursor(2, 3))
}

// MARK: - Line start / end

@Test func copyCursorLineStartAndEnd() {
    #expect(move(cursor(0, 9), .lineStart) == cursor(0, 0))
    // "hello world  foo" is 16 chars → last content col is 15.
    #expect(move(cursor(0, 2), .lineEnd) == cursor(0, 15))
    // Trailing padding doesn't count: "tail" ends at col 3.
    #expect(move(cursor(4, 0), .lineEnd) == cursor(4, 3))
    // Without line text, lineEnd goes to the last grid column.
    #expect(move(cursor(0, 2), .lineEnd, withText: false) == cursor(0, 19))
}

// MARK: - Word motions

@Test func copyCursorWordForward() {
    // From "hello" start: w → "world", w → "foo".
    #expect(move(cursor(0, 0), .wordForward) == cursor(0, 6))
    #expect(move(cursor(0, 6), .wordForward) == cursor(0, 13))
    // Past the last word: skips the empty row to the next row's first word.
    #expect(move(cursor(0, 13), .wordForward) == cursor(2, 2))
}

@Test func copyCursorWordBackward() {
    #expect(move(cursor(0, 13), .wordBackward) == cursor(0, 6))
    #expect(move(cursor(0, 6), .wordBackward) == cursor(0, 0))
    // From row 2 start: crosses the empty row up to "foo" (last word of row 0).
    #expect(move(cursor(2, 2), .wordBackward) == cursor(0, 13))
    // At the very beginning there is nowhere to go.
    #expect(move(cursor(0, 0), .wordBackward) == cursor(0, 0))
}

@Test func copyCursorWordEnd() {
    // Inside "hello": e → its end (col 4); at the end already → next word's end.
    #expect(move(cursor(0, 0), .wordEnd) == cursor(0, 4))
    #expect(move(cursor(0, 4), .wordEnd) == cursor(0, 10))
    // Mid "world" → its own end.
    #expect(move(cursor(0, 8), .wordEnd) == cursor(0, 10))
}

@Test func copyCursorWordMotionsCoarseFallbackWithoutText() {
    #expect(move(cursor(0, 0), .wordForward, withText: false) == cursor(0, 8))
    #expect(move(cursor(0, 10), .wordBackward, withText: false) == cursor(0, 2))
    // Coarse jumps still clamp to the grid.
    #expect(move(cursor(0, 18), .wordForward, withText: false) == cursor(0, 19))
    #expect(move(cursor(0, 3), .wordBackward, withText: false) == cursor(0, 0))
}

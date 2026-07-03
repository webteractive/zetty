import Foundation

/// A copy-mode cursor motion (vi keys).
public enum CopyMotion: Sendable, Equatable {
    case left, right, up, down
    case lineStart, lineEnd
    case wordForward      // w — next word start
    case wordBackward     // b — previous word start
    case wordEnd          // e — end of current/next word
}

/// The copy-mode keyboard cursor: a viewport cell position (row 0 = top,
/// col 0 = left). Pure math — motions clamp to the grid; word motions scan
/// the viewport line text when available and fall back to coarse 8-column
/// jumps when it isn't (no public viewport-text API on the AppKit surface;
/// zmx capture supplies lines for preserved sessions).
public struct CopyModeCursor: Sendable, Equatable {
    public var row: Int
    public var col: Int

    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }

    /// Column jump used for word motions when no line text is available.
    public static let coarseWordJump = 8

    /// The cursor after applying `motion` on a `rows`×`cols` grid.
    /// `lines` are the viewport rows' text (index = row); pass an empty array
    /// when unavailable. Vertical motions keep the column (vi-style, no
    /// desired-column memory); everything clamps to the grid.
    public func moved(
        _ motion: CopyMotion,
        rows: Int,
        cols: Int,
        lines: [String] = []
    ) -> CopyModeCursor {
        guard rows > 0, cols > 0 else { return self }
        var next = self
        switch motion {
        case .left:
            next.col -= 1
        case .right:
            next.col += 1
        case .up:
            next.row -= 1
        case .down:
            next.row += 1
        case .lineStart:
            next.col = 0
        case .lineEnd:
            next.col = lineLength(of: row, in: lines).map { max(0, $0 - 1) } ?? cols - 1
        case .wordForward:
            next = wordForward(rows: rows, cols: cols, lines: lines)
        case .wordBackward:
            next = wordBackward(rows: rows, cols: cols, lines: lines)
        case .wordEnd:
            next = wordEnd(rows: rows, cols: cols, lines: lines)
        }
        next.row = min(max(next.row, 0), rows - 1)
        next.col = min(max(next.col, 0), cols - 1)
        return next
    }

    // MARK: - Word motions

    /// A "word" is a run of non-space characters (vi's W/B/E "big word"
    /// semantics — simpler and predictable in terminal output).
    private func wordBoundaries(in line: String) -> [(start: Int, end: Int)] {
        var runs: [(Int, Int)] = []
        var runStart: Int?
        for (index, character) in line.enumerated() {
            if character == " " {
                if let start = runStart {
                    runs.append((start, index - 1))
                    runStart = nil
                }
            } else if runStart == nil {
                runStart = index
            }
        }
        if let start = runStart {
            runs.append((start, line.count - 1))
        }
        return runs
    }

    private func lineLength(of row: Int, in lines: [String]) -> Int? {
        guard lines.indices.contains(row) else { return nil }
        // Trailing spaces are padding, not content.
        let trimmed = String(lines[row].reversed().drop(while: { $0 == " " }).reversed())
        return trimmed.count
    }

    private func wordForward(rows: Int, cols: Int, lines: [String]) -> CopyModeCursor {
        guard lines.indices.contains(row) else {
            return CopyModeCursor(row: row, col: col + Self.coarseWordJump)
        }
        // Next word start after the cursor on this row, else first word of
        // the next non-empty row.
        if let next = wordBoundaries(in: lines[row]).first(where: { $0.start > col }) {
            return CopyModeCursor(row: row, col: next.start)
        }
        var candidate = row + 1
        while candidate < min(rows, lines.count) {
            if let first = wordBoundaries(in: lines[candidate]).first {
                return CopyModeCursor(row: candidate, col: first.start)
            }
            candidate += 1
        }
        return self
    }

    private func wordBackward(rows: Int, cols: Int, lines: [String]) -> CopyModeCursor {
        guard lines.indices.contains(row) else {
            return CopyModeCursor(row: row, col: col - Self.coarseWordJump)
        }
        if let previous = wordBoundaries(in: lines[row]).last(where: { $0.start < col }) {
            return CopyModeCursor(row: row, col: previous.start)
        }
        var candidate = row - 1
        while candidate >= 0, lines.indices.contains(candidate) {
            if let last = wordBoundaries(in: lines[candidate]).last {
                return CopyModeCursor(row: candidate, col: last.start)
            }
            candidate -= 1
        }
        return self
    }

    private func wordEnd(rows: Int, cols: Int, lines: [String]) -> CopyModeCursor {
        guard lines.indices.contains(row) else {
            return CopyModeCursor(row: row, col: col + Self.coarseWordJump)
        }
        // End of the word we're in (if the cursor isn't already there), else
        // the end of the next word — matching vi's `e`.
        if let containing = wordBoundaries(in: lines[row]).first(where: { $0.start <= col && col < $0.end }) {
            return CopyModeCursor(row: row, col: containing.end)
        }
        if let next = wordBoundaries(in: lines[row]).first(where: { $0.start > col }) {
            return CopyModeCursor(row: row, col: next.end)
        }
        var candidate = row + 1
        while candidate < min(rows, lines.count) {
            if let first = wordBoundaries(in: lines[candidate]).first {
                return CopyModeCursor(row: candidate, col: first.end)
            }
            candidate += 1
        }
        return self
    }
}

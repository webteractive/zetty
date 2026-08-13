import Foundation
import Testing
@testable import ZettyCore

@Test func classifyReturnsTextForPlainUTF8() {
    let data = Data("let x = 1\n".utf8)
    #expect(FileViewerContent.classify(data, maxBytes: 1024)
            == .text("let x = 1\n", truncatedAtLine: nil))
}

@Test func classifyDetectsBinaryByNulByte() {
    var data = Data("ELF".utf8)
    data.append(0)
    data.append(contentsOf: [1, 2, 3])
    #expect(FileViewerContent.classify(data, maxBytes: 1024) == .binary)
}

@Test func classifyOnlySniffsTheFirst8KB() {
    // A NUL past the sniff window doesn't make it binary.
    var data = Data(repeating: UInt8(ascii: "a"), count: 9000)
    data.append(0)
    guard case .text = FileViewerContent.classify(data, maxBytes: 1_000_000) else {
        Issue.record("expected .text")
        return
    }
}

@Test func classifyRejectsOversizeBeforeSniffing() {
    let data = Data(repeating: UInt8(ascii: "a"), count: 5000)
    #expect(FileViewerContent.classify(data, maxBytes: 1024) == .tooLarge(bytes: 5000))
}

@Test func classifyTruncatesAtLineCap() {
    let text = String(repeating: "x\n", count: FileViewerContent.maxLines + 50)
    let result = FileViewerContent.classify(Data(text.utf8), maxBytes: 10_000_000)
    guard case .text(let body, let truncatedAtLine) = result else {
        Issue.record("expected .text")
        return
    }
    #expect(truncatedAtLine == FileViewerContent.maxLines)
    #expect(body.split(separator: "\n", omittingEmptySubsequences: false).count
            == FileViewerContent.maxLines)
}

@Test func classifyDecodesInvalidUTF8Lossily() {
    var data = Data("ok ".utf8)
    data.append(0xFF)   // invalid UTF-8, but not a NUL
    guard case .text(let body, _) = FileViewerContent.classify(data, maxBytes: 1024) else {
        Issue.record("expected .text")
        return
    }
    #expect(body.hasPrefix("ok "))
}

/// An empty read is its own outcome, never `.text("")`: a zero-character body
/// paints the peek's background and nothing else, which was reported as "the
/// file viewer shows nothing" rather than as an empty file.
@Test func classifyReportsEmptyFileAsEmpty() {
    #expect(FileViewerContent.classify(Data(), maxBytes: 1024) == .empty)
}

/// The size cap is checked first, so a zero-byte file can't be mistaken for one.
@Test func classifyPrefersTooLargeOverEmpty() {
    #expect(FileViewerContent.classify(Data(repeating: 0x41, count: 20), maxBytes: 4)
            == .tooLarge(bytes: 20))
}

/// A file that is only a newline still has a character to draw, so it stays text.
@Test func classifyKeepsWhitespaceOnlyFileAsText() {
    #expect(FileViewerContent.classify(Data("\n".utf8), maxBytes: 1024)
            == .text("\n", truncatedAtLine: nil))
}

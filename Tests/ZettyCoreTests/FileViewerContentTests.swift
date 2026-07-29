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

@Test func classifyAcceptsEmptyFile() {
    #expect(FileViewerContent.classify(Data(), maxBytes: 1024)
            == .text("", truncatedAtLine: nil))
}

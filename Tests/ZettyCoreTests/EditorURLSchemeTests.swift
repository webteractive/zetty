import Foundation
import Testing
@testable import ZettyCore

@Test func zedURLCarriesTheLine() {
    let url = EditorURLScheme.url(bundleID: "dev.zed.Zed",
                                  file: "/work/Theme.swift", line: 412, column: 9)
    #expect(url?.absoluteString == "zed://file/work/Theme.swift:412")
}

@Test func zedURLWithoutALine() {
    let url = EditorURLScheme.url(bundleID: "dev.zed.Zed",
                                  file: "/work/Theme.swift", line: nil, column: nil)
    #expect(url?.absoluteString == "zed://file/work/Theme.swift")
}

@Test func vscodeURLCarriesLineAndColumn() {
    let url = EditorURLScheme.url(bundleID: "com.microsoft.VSCode",
                                  file: "/work/Theme.swift", line: 412, column: 9)
    #expect(url?.absoluteString == "vscode://file/work/Theme.swift:412:9")
}

@Test func cursorAndWindsurfGetTheirOwnSchemes() {
    let cursor = EditorURLScheme.url(bundleID: "com.todesktop.230313mzl4w4u92",
                                     file: "/a.swift", line: 1, column: nil)
    let windsurf = EditorURLScheme.url(bundleID: "com.exafunction.windsurf",
                                       file: "/a.swift", line: 1, column: nil)
    #expect(cursor?.scheme == "cursor")
    #expect(windsurf?.scheme == "windsurf")
}

@Test func textMateUsesItsQueryForm() {
    let url = EditorURLScheme.url(bundleID: "com.macromates.TextMate",
                                  file: "/work/a.swift", line: 12, column: nil)
    #expect(url?.absoluteString == "txmt://open?url=file:///work/a.swift&line=12")
}

@Test func bundleIDMatchingIsCaseInsensitive() {
    let url = EditorURLScheme.url(bundleID: "DEV.ZED.ZED",
                                  file: "/a.swift", line: nil, column: nil)
    #expect(url?.scheme == "zed")
}

@Test func unknownEditorHasNoScheme() {
    #expect(EditorURLScheme.url(bundleID: "com.apple.TextEdit",
                                file: "/a.swift", line: 1, column: nil) == nil)
}

@Test func pathsWithSpacesArePercentEncoded() {
    let url = EditorURLScheme.url(bundleID: "com.microsoft.VSCode",
                                  file: "/work/my file.swift", line: nil, column: nil)
    #expect(url?.absoluteString == "vscode://file/work/my%20file.swift")
}

@Test func columnWithoutALineIsIgnored() {
    // A column is meaningless without a line; it must not produce `::9`.
    let url = EditorURLScheme.url(bundleID: "com.microsoft.VSCode",
                                  file: "/a.swift", line: nil, column: 9)
    #expect(url?.absoluteString == "vscode://file/a.swift")
}

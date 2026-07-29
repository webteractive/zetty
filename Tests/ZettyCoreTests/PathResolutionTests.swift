import Foundation
import Testing
@testable import ZettyCore

@Test func candidatesUseAbsolutePathAsIs() {
    let token = PathToken(path: "/etc/hosts")
    #expect(PathResolution.candidates(for: token, paneCwd: "/tmp", projectRoot: "/proj")
            == ["/etc/hosts"])
}

@Test func candidatesExpandTilde() {
    let token = PathToken(path: "~/.zetty/config")
    let result = PathResolution.candidates(for: token, paneCwd: "/tmp", projectRoot: nil)
    #expect(result == ["\(NSHomeDirectory())/.zetty/config"])
}

@Test func candidatesPreferPaneCwdThenProjectRoot() {
    let token = PathToken(path: "Sources/x.swift")
    #expect(PathResolution.candidates(for: token, paneCwd: "/work/sub", projectRoot: "/work")
            == ["/work/sub/Sources/x.swift", "/work/Sources/x.swift"])
}

@Test func candidatesOfferDiffPrefixStrippedAfterDirectOnes() {
    let token = PathToken(path: "a/Sources/x.swift")
    #expect(PathResolution.candidates(for: token, paneCwd: "/work", projectRoot: nil)
            == ["/work/a/Sources/x.swift", "/work/Sources/x.swift"])
}

@Test func candidatesDedupeWhenCwdEqualsRoot() {
    let token = PathToken(path: "x.swift")
    #expect(PathResolution.candidates(for: token, paneCwd: "/work", projectRoot: "/work")
            == ["/work/x.swift"])
}

@Test func candidatesNormalizeDotSegments() {
    let token = PathToken(path: "./sub/../x.swift")
    #expect(PathResolution.candidates(for: token, paneCwd: "/work", projectRoot: nil)
            == ["/work/x.swift"])
}

@Test func candidatesEmptyWithoutAnyBase() {
    let token = PathToken(path: "x.swift")
    #expect(PathResolution.candidates(for: token, paneCwd: nil, projectRoot: nil).isEmpty)
}

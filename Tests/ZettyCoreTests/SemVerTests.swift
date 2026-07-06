import Testing
@testable import ZettyCore

@Test func semverParsesAndStripsVPrefix() {
    #expect(SemVer("v0.1.7") == SemVer("0.1.7"))
    #expect(SemVer("1.2.3") != nil)
    #expect(SemVer("dev") == nil)
    #expect(SemVer("") == nil)
    #expect(SemVer("1.2") == SemVer("1.2.0"))   // missing patch → 0
}

@Test func semverOrders() {
    #expect(SemVer("0.1.6")! < SemVer("0.1.7")!)
    #expect(SemVer("0.2.0")! > SemVer("0.1.9")!)
    #expect(SemVer("1.0.0")! > SemVer("0.9.9")!)
}

@Test func isNewerHandlesPrefixEqualAndGarbage() {
    #expect(SemVer.isNewer(latest: "v0.1.7", than: "0.1.6"))
    #expect(!SemVer.isNewer(latest: "0.1.6", than: "0.1.6"))   // equal → not newer
    #expect(!SemVer.isNewer(latest: "0.1.5", than: "0.1.6"))   // older → not newer
    #expect(!SemVer.isNewer(latest: "0.1.7", than: "dev"))     // unparseable current → never nag
    #expect(!SemVer.isNewer(latest: "garbage", than: "0.1.6")) // unparseable latest → no
}

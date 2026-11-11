import Foundation
import Testing
@testable import ZettyCore

@Test func defaultNameIsZettyAndTheMacsNameDNSSafe() {
    #expect(ZettyDeviceName.defaultName(hostName: "Inggo’s Mac mini") == "zetty-inggos-mac-mini")
    #expect(ZettyDeviceName.defaultName(hostName: "") == "zetty-mac")
    #expect(ZettyDeviceName.defaultName(hostName: "---") == "zetty-mac")
    #expect(ZettyDeviceName.defaultName(hostName: String(repeating: "a", count: 200)).count <= 63)
}

@Test func renamesAlwaysKeepThePrefix() {
    #expect(ZettyDeviceName.normalized("Mini!", keeping: "zetty-a") == "zetty-mini")
    #expect(ZettyDeviceName.normalized("zetty-mini", keeping: "zetty-a") == "zetty-mini")
    #expect(ZettyDeviceName.normalized("Zetty Mini", keeping: "zetty-a") == "zetty-mini")
    #expect(ZettyDeviceName.normalized("  !! ", keeping: "zetty-a") == "zetty-a")
    #expect(ZettyDeviceName.normalized("", keeping: "zetty-a") == "zetty-a")
}

@Test func zettyNamesAreRecognizedCaseInsensitively() {
    #expect(ZettyDeviceName.isZetty("zetty-mini"))
    #expect(ZettyDeviceName.isZetty("Zetty-Mini"))
    #expect(!ZettyDeviceName.isZetty("WebteractiveGlen"))
    #expect(!ZettyDeviceName.isZetty("zettymini"))
    #expect(!ZettyDeviceName.isZetty("zetty-"))
}

@Test func theSuffixIsWhatSettingsEdits() {
    #expect(ZettyDeviceName.suffix(of: "zetty-mini") == "mini")
    #expect(ZettyDeviceName.suffix(of: "other") == "other")
}

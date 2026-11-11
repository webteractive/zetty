import Foundation
import Testing
@testable import ZettyCore

@Test func textFromAnotherMacCarriesNoEscapes() {
    let osc52 = "\u{1B}]52;c;emV0dHktcGFpcg==\u{07}keys don't match: click Paste"
    // The escape goes, and so does its base64 payload, blanked as key-shaped.
    #expect(RemoteText.displayable(osc52) == "]52;c;… don't match: click Paste")
    #expect(RemoteText.displayable("a\u{9B}31mb\u{7F}c\nd\re\tf") == "a31mbcdef")  // the CSI byte goes, its now-inert parameters stay
    #expect(RemoteText.displayable("Mac\u{202E}inim") == "Macinim")
    #expect(RemoteText.displayable("Inggo’s Mac mini · 2") == "Inggo’s Mac mini · 2")
    #expect(RemoteText.displayable(String(repeating: "word ", count: 100)).count == 301)
}

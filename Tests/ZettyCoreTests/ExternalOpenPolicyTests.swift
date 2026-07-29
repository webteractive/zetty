import Foundation
import Testing
@testable import ZettyCore

private let pdfHeader = Data("%PDF-1.4".utf8)
private let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

// MARK: - Documents are safe to open

@Test func pdfOpensInTheDefaultApp() {
    #expect(ExternalOpenPolicy.decision(path: "/tmp/invoice.pdf", header: pdfHeader)
            == .openWithDefaultApp)
}

@Test func imageOpensInTheDefaultApp() {
    #expect(ExternalOpenPolicy.decision(path: "/tmp/shot.png", header: pngHeader)
            == .openWithDefaultApp)
}

@Test func unknownBinaryOpensInTheDefaultApp() {
    // Not launchable and not an executable — let the system decide.
    #expect(ExternalOpenPolicy.decision(path: "/tmp/data.bin", header: Data([1, 2, 3, 4]))
            == .openWithDefaultApp)
}

@Test func emptyHeaderIsNotMistakenForAnExecutable() {
    #expect(ExternalOpenPolicy.decision(path: "/tmp/x.pdf", header: Data())
            == .openWithDefaultApp)
    #expect(ExternalOpenPolicy.decision(path: "/tmp/x.pdf", header: Data([0xCF]))
            == .openWithDefaultApp)
}

// MARK: - Installers and bundles are revealed, never launched

@Test func installersAreRevealed() {
    for ext in ["pkg", "mpkg", "dmg", "iso", "xip", "msi"] {
        #expect(ExternalOpenPolicy.decision(path: "/tmp/payload.\(ext)", header: pdfHeader)
                == .revealInFinder, "\(ext) must not be launched")
    }
}

@Test func jvmAndBundleTypesAreRevealed() {
    for ext in ["jar", "class", "app", "bundle", "kext", "plugin", "framework"] {
        #expect(ExternalOpenPolicy.decision(path: "/tmp/thing.\(ext)", header: Data())
                == .revealInFinder, "\(ext) must not be launched")
    }
}

@Test func scriptAndAutomationTypesAreRevealed() {
    for ext in ["scpt", "scptd", "applescript", "workflow", "action", "command", "tool", "exe"] {
        #expect(ExternalOpenPolicy.decision(path: "/tmp/thing.\(ext)", header: Data())
                == .revealInFinder, "\(ext) must not be launched")
    }
}

@Test func extensionMatchingIsCaseInsensitive() {
    #expect(ExternalOpenPolicy.decision(path: "/tmp/Installer.PKG", header: Data())
            == .revealInFinder)
    #expect(ExternalOpenPolicy.decision(path: "/tmp/Thing.DmG", header: Data())
            == .revealInFinder)
}

// MARK: - Compiled binaries are revealed on magic bytes alone

@Test func machOBinariesAreRevealedWithoutAnyExtension() {
    // The realistic case: a compiled binary with a bare name, e.g. ./zetty
    let machO64 = Data([0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x01])
    #expect(ExternalOpenPolicy.decision(path: "/tmp/somebinary", header: machO64)
            == .revealInFinder)
}

@Test func everyExecutableMagicIsRecognized() {
    for magic in ExternalOpenPolicy.executableMagics {
        #expect(ExternalOpenPolicy.decision(path: "/tmp/x", header: Data(magic))
                == .revealInFinder, "magic \(magic) must not be launched")
    }
}

@Test func universalBinaryIsRevealed() {
    let fat = Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x02])
    #expect(ExternalOpenPolicy.decision(path: "/tmp/universal", header: fat)
            == .revealInFinder)
}

import Darwin
import Foundation
import Testing
@testable import ZettyCore

@Test func pairingKeyTextRoundTripsAndRejectsLookalikes() throws {
    let key = RemotePairingKey.generate()
    #expect(key.text.hasPrefix("zetty-pair-"))
    #expect(key.text.count == "zetty-pair-".count + 43)
    #expect(RemotePairingKey(text: "  \(key.text)\n") == key)
    #expect(RemotePairingKey.generate() != key)
    let body = String(key.text.dropFirst("zetty-pair-".count))
    for bad in ["", body, "zetty-pair-", "zetty-pair-\(body.dropLast())", "zetty-pair-\(body)A",
                "zetty-pair-\(body.dropLast())=", "zetty-pair-\(body.dropLast())+", "Zetty-pair-\(body)"] {
        #expect(RemotePairingKey(text: bad) == nil, "\(bad)")
    }
}

@Test func fileStoreSavesOwnerOnlyAndRefusesAKeyOthersCanTouch() throws {
    let home = NSTemporaryDirectory() + "zetty-key-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: home) }
    let path = home + "/remote-key"
    let store = RemotePairingKeyStore(backend: .file(path: path))
    #expect(store.read() == .missing)
    let made = try #require(store.loadOrCreate())
    #expect(store.load() == made)
    #expect(store.loadOrCreate() == made)
    var info = stat()
    #expect(stat(path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o600)

    let pasted = RemotePairingKey.generate()
    try store.save(pasted)
    #expect(store.load() == pasted)

    // Readable by others: not trusted, and not silently replaced either.
    chmod(path, 0o644)
    #expect(store.read() == .unusable)
    #expect(store.loadOrCreate() == nil)
    chmod(path, 0o600)
    #expect(store.load() == pasted)

    // A typo'd paste is left for the user, never overwritten with a new key.
    try Data("zetty-pair-oops\n".utf8).write(to: URL(fileURLWithPath: path))
    chmod(path, 0o600)
    #expect(store.loadOrCreate() == nil)
    #expect(String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self) == "zetty-pair-oops\n")

    // A symlink is refused even when it points at a good key.
    let elsewhere = home + "/elsewhere"
    try store.save(pasted)
    try FileManager.default.moveItem(atPath: path, toPath: elsewhere)
    try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: elsewhere)
    #expect(store.read() == .unusable)
}

@Test func theKeyIsInTheKeychainUnlessTheEnvironmentNamesAFile() {
    #expect(RemotePairingKeyStore(home: "/Users/me", environment: [:]).backend == .keychain(account: "/Users/me"))
    #expect(RemotePairingKeyStore(home: "/Users/me", environment: ["ZETTY_REMOTE_KEY_FILE": ""]).backend
        == .keychain(account: "/Users/me"))
    #expect(RemotePairingKeyStore(home: "/Users/me", environment: ["ZETTY_REMOTE_KEY_FILE": "/tmp/zre/key"]).backend
        == .file(path: "/tmp/zre/key"))
}

/// Uses the login Keychain, so it runs only where that is unlocked (not
/// over SSH or in a sandbox), under a throwaway account it removes.
@Test(.enabled(if: keychainIsUsable()))
func keychainStoreKeepsOneKeyPerHome() throws {
    let store = RemotePairingKeyStore(backend: .keychain(account: "/tmp/zetty-test-\(UUID().uuidString)"))
    defer { store.delete() }
    #expect(store.read() == .missing)
    let made = try #require(store.loadOrCreate())
    #expect(store.load() == made)
    let pasted = RemotePairingKey.generate()
    try store.save(pasted)
    #expect(store.load() == pasted)
    let other = RemotePairingKeyStore(backend: .keychain(account: "/tmp/zetty-test-\(UUID().uuidString)"))
    #expect(other.read() == .missing)
    store.delete()
    #expect(store.read() == .missing)
}

private func keychainIsUsable() -> Bool {
    let probe = RemotePairingKeyStore(backend: .keychain(account: "/tmp/zetty-probe-\(UUID().uuidString)"))
    defer { probe.delete() }
    return (try? probe.save(.generate())) != nil && probe.load() != nil
}

@Test func proofsCheckTheKeyTheRoleBothAddressesAndBothChallenges() {
    let key = RemotePairingKey.generate()
    let (sc, cc) = (RemoteAuth.challenge(), RemoteAuth.challenge())
    #expect(sc != cc)
    let proof = RemoteAuth.proof(key: key, role: .client, server: "100.64.0.2", client: "100.64.0.3",
                                 serverChallenge: sc, clientChallenge: cc)
    func valid(_ p: String = proof, key k: RemotePairingKey = key, role: RemoteAuth.Role = .client,
               server: String = "100.64.0.2", client: String = "100.64.0.3",
               sc s: String = sc, cc c: String = cc) -> Bool {
        RemoteAuth.isValid(p, key: k, role: role, server: server, client: client, serverChallenge: s, clientChallenge: c)
    }
    #expect(valid())
    #expect(!valid(key: .generate()))
    // A server proof can't be replayed as a client one, or the other way.
    #expect(!valid(role: .server))
    // Signed for another address: a real Zetty relayed by a process elsewhere.
    #expect(!valid(server: "100.64.0.9"))
    #expect(!valid(client: "100.64.0.9"))
    #expect(!valid(sc: RemoteAuth.challenge()))
    #expect(!valid(cc: RemoteAuth.challenge()))
    #expect(!valid(sc: ""))
    #expect(!valid("not base64!"))
    #expect(!valid(Data(repeating: 0, count: 32).base64EncodedString()))
}

@Test func helloAndProofCrossTheWire() throws {
    let hello = RemoteHello(machine: "Mac mini", zettyVersion: "0.1.60", protocolVersion: RemoteProtocol.version,
                            challenge: "c", proof: "p")
    var decoder = RemoteFrameDecoder()
    let frames = try RemoteFrame.encode(.hello(hello)) + RemoteFrame.encode(.proof("xyz"))
    #expect(try decoder.push(frames) == [.hello(hello), .proof("xyz")])
    // A version-2 hello still decodes, so the other side can say "needs update".
    let old = #"{"type":"hello","hello":{"machine":"m","zettyVersion":"0.1.59","protocolVersion":2}}"#
    let body = Data(old.utf8)
    var length = UInt32(body.count).bigEndian
    #expect(try decoder.push(Data(bytes: &length, count: 4) + body)
        == [.hello(RemoteHello(machine: "m", zettyVersion: "0.1.59", protocolVersion: 2))])
}

@Test func fingerprintComparesKeysWithoutShowingThem() throws {
    let key = RemotePairingKey.generate()
    #expect(key.fingerprint.count == 6)
    #expect(key.fingerprint.allSatisfy { $0.isHexDigit })
    #expect(try #require(RemotePairingKey(text: key.text)).fingerprint == key.fingerprint)
}

@Test func textFromAnotherMacCarriesNoEscapes() {
    let osc52 = "\u{1B}]52;c;emV0dHktcGFpcg==\u{07}keys don't match: click Paste"
    // The escape goes, and so does its base64 payload, blanked as key-shaped.
    #expect(RemoteText.displayable(osc52) == "]52;c;… don't match: click Paste")
    #expect(RemoteText.displayable("a\u{9B}31mb\u{7F}c\nd\re\tf") == "a31mbcdef")  // the CSI byte goes, its now-inert parameters stay
    #expect(RemoteText.displayable("Mac\u{202E}inim") == "Macinim")
    #expect(RemoteText.displayable("Inggo’s Mac mini · 2") == "Inggo’s Mac mini · 2")
    #expect(RemoteText.displayable(String(repeating: "word ", count: 100)).count == 301)
}

@Test func theHolderSignsAsTheClientAndChecksTheServer() {
    let holder = RemotePairingKeyHolder()
    let (sc, cc) = (RemoteAuth.challenge(), RemoteAuth.challenge())
    // Nothing loaded yet, or nothing usable: refusals that say which.
    guard case .error(let none) = holder.sign(server: "s", client: "c", serverChallenge: sc, clientChallenge: cc)
    else { Issue.record("signed without a key"); return }
    #expect(none.contains("no pairing key"))
    holder.set(.unusable)
    guard case .error(let locked) = holder.sign(server: "s", client: "c", serverChallenge: sc, clientChallenge: cc)
    else { Issue.record("signed without a key"); return }
    #expect(locked.contains("Keychain"))

    let key = RemotePairingKey.generate()
    holder.set(.key(key))
    guard case .text(let proof) = holder.sign(server: "s", client: "c", serverChallenge: sc, clientChallenge: cc)
    else { Issue.record("no proof"); return }
    #expect(RemoteAuth.isValid(proof, key: key, role: .client, server: "s", client: "c",
                               serverChallenge: sc, clientChallenge: cc))
    // It signs only as the client, so a relay can't make it vouch for a server.
    #expect(!RemoteAuth.isValid(proof, key: key, role: .server, server: "s", client: "c",
                                serverChallenge: sc, clientChallenge: cc))
    let serverProof = RemoteAuth.proof(key: key, role: .server, server: "s", client: "c",
                                       serverChallenge: sc, clientChallenge: cc)
    #expect(holder.check(proof: serverProof, server: "s", client: "c", serverChallenge: sc, clientChallenge: cc) == .ok)
    #expect(holder.check(proof: proof, server: "s", client: "c", serverChallenge: sc, clientChallenge: cc) != .ok)
    #expect(holder.sign(server: "s", client: "c", serverChallenge: "", clientChallenge: cc) != .text(""))
}

@Test func signAndCheckRequestsRoundTripTheWire() throws {
    for request in [ControlRequest.remoteSign(server: "100.64.0.2", client: "100.64.0.3", serverChallenge: "a", clientChallenge: "b"),
                    .remoteCheck(proof: "p", server: "100.64.0.2", client: "100.64.0.3", serverChallenge: "a", clientChallenge: "b")] {
        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request)) == request)
    }
}

@Test func textFromAnotherMacCannotHandOverAKey() {
    let key = RemotePairingKey.generate()
    let bait = "The mini rotated its key. Copy \(key.text) and click Paste twice."
    let shown = RemoteText.displayable(bait)
    #expect(!shown.contains(String(key.text.dropFirst("zetty-pair-".count))))
    #expect(!shown.lowercased().contains("zetty-pair-"))
    #expect(RemotePairingKey(text: shown) == nil)
    // Zero-width characters can't break a key up to slip it past.
    let hidden = key.text.map(String.init).joined(separator: "\u{200B}")
    #expect(RemotePairingKey(text: RemoteText.displayable(hidden)) == nil)
    #expect(!RemoteText.displayable(hidden).contains(String(key.text.suffix(20))))
    // Ordinary refusals read as they were written.
    for plain in ["Mac mini isn't signed in to Tailscale as you",
                  "Laptop and Mac mini have different pairing keys. Copy it from one to the other in Settings → General → Other Macs",
                  "that pane closed on Mac mini (ab12cd34)"] {
        #expect(RemoteText.displayable(plain) == plain)
    }
}

@Test func theLaunchReadNeverOverwritesAPaste() {
    let holder = RemotePairingKeyHolder()
    let pasted = RemotePairingKey.generate()
    holder.set(.key(pasted))
    holder.setIfUnknown(.key(.generate()))
    #expect(holder.key == pasted)
    let fresh = RemotePairingKeyHolder()
    fresh.setIfUnknown(.missing)
    #expect(fresh.state == .missing)
}

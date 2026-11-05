import CryptoKit
import Darwin
import Foundation

/// The secret the user's Macs share, so each end of a remote-machines
/// connection can prove it is the user's own Zetty and not just another
/// process on one of the user's Macs.
///
/// Tailscale vouches for the machine a connection comes from, not for who
/// opened it: another macOS account, a daemon, a container or a VM on the
/// laptop all leave with the laptop's tailnet address. Without this, any of
/// them could attach to a pane on the mini, and a second account on the mini
/// could sit on the port and pose as it. The key lives in the login Keychain
/// (`RemotePairingKeyStore`), and the user copies it from one Mac to the
/// others (Settings → General → Other Macs).
public struct RemotePairingKey: Equatable, Sendable {
    public static let byteCount = 32
    static let prefix = "zetty-pair-"

    let bytes: Data

    init(bytes: Data) {
        self.bytes = bytes
    }

    public static func generate() -> RemotePairingKey {
        var generator = SystemRandomNumberGenerator()
        return RemotePairingKey(bytes: Data((0 ..< byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    /// `zetty-pair-` and 43 base64url characters: one word, so a double-click
    /// selects all of it and it survives being pasted into a chat.
    public var text: String {
        Self.prefix + bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Six hex digits of the key's SHA-256, for comparing two Macs' keys in
    /// Settings without showing either.
    public var fingerprint: String {
        SHA256.hash(data: bytes).prefix(3).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads `text` as written by `text`, ignoring surrounding whitespace.
    public init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.prefix) else { return nil }
        let body = trimmed.dropFirst(Self.prefix.count)
        guard body.count == 43, body.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        let standard = body.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
        guard let bytes = Data(base64Encoded: standard), bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }
}

/// Where the pairing key is kept: the login Keychain, one item per home
/// folder, or a file when `ZETTY_REMOTE_KEY_FILE` names one.
///
/// Not a file under `~` by default: VM tools such as Lima, Colima and
/// OrbStack mount the home folder into their machines, and anything there
/// could read a key file and connect as the user (security review,
/// 2026-11-05). In the Keychain a VM only ever sees the encrypted database.
///
/// Only the app reads it, once per launch (`RemotePairingKeyHolder` keeps it
/// in memory), and the `zetty attach` relay asks the app to sign for it over
/// the control socket. macOS ties an item to the signature of the app that
/// made it (its partition list), so any other reader — another build, the
/// `security` tool — gets a Keychain prompt, and plain code can't widen that
/// without the login password. A self-signed dev rebuild therefore prompts
/// once at launch; Developer ID releases share a team partition and don't.
///
/// The file is for the test pair in `scripts/remote-e2e.sh`, whose second
/// copy is started over SSH where the login Keychain is locked. It must be a
/// regular file owned by the user with no group or other access.
public struct RemotePairingKeyStore: Sendable {
    public enum Backend: Equatable, Sendable {
        case keychain(account: String)
        case file(path: String)
    }

    public enum Reading: Equatable, Sendable {
        case key(RemotePairingKey)
        /// Nothing stored yet: safe to create one.
        case missing
        /// Something is there but can't be used (a locked Keychain, a typo'd
        /// file, a file others can read). Never replaced automatically.
        case unusable
    }

    public static let fileVariable = "ZETTY_REMOTE_KEY_FILE"
    public static let keychainService = "co.webteractive.zetty.remote-key"

    public let backend: Backend

    public init(backend: Backend) {
        self.backend = backend
    }

    /// The store for `home`: its Keychain item, unless the environment
    /// names a file.
    public init(home: String, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let path = environment[Self.fileVariable], !path.isEmpty {
            backend = .file(path: path)
        } else {
            backend = .keychain(account: home)
        }
    }

    /// `allowingUI` lets the Keychain ask the user (the app's one read at
    /// launch, off the main thread). Without it a read that would need to
    /// ask answers `unusable` instead.
    public func read(allowingUI: Bool = false) -> Reading {
        switch backend {
        case .file(let path): return KeyFile.read(path)
        case .keychain(let account): return KeychainItem.read(account, allowingUI: allowingUI)
        }
    }

    public func load() -> RemotePairingKey? {
        if case .key(let key) = read() { return key }
        return nil
    }

    /// Replaces the key.
    public func save(_ key: RemotePairingKey) throws {
        switch backend {
        case .file(let path): try KeyFile.write(key, to: path)
        case .keychain(let account): try KeychainItem.write(key, account: account)
        }
    }

    /// Removes the key (tests and teardown).
    public func delete() {
        switch backend {
        case .file(let path): unlink(path)
        case .keychain(let account): KeychainItem.delete(account)
        }
    }

    /// The key, made the first time either remote key is on. Only a missing
    /// key is made: an unusable one may be a paste with a typo, or a locked
    /// Keychain, and replacing it would unpair this Mac.
    @discardableResult
    public func loadOrCreate(allowingUI: Bool = false) -> RemotePairingKey? {
        switch read(allowingUI: allowingUI) {
        case .key(let key): return key
        case .unusable: return nil
        case .missing:
            let key = RemotePairingKey.generate()
            return (try? save(key)) == nil ? nil : key
        }
    }
}

private enum KeyFile {
    static func read(_ path: String) -> RemotePairingKeyStore.Reading {
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT ? .missing : .unusable }
        // A key another user could read or replace would let them prove
        // they are this user.
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              let data = FileManager.default.contents(atPath: path),
              let key = RemotePairingKey(text: String(decoding: data, as: UTF8.self)) else { return .unusable }
        return .key(key)
    }

    /// Owner-only from the first byte.
    static func write(_ key: RemotePairingKey, to path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let temporary = path + ".\(getpid()).tmp"
        unlink(temporary)
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let line = Array((key.text + "\n").utf8)
        let written = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, line.count) }
        close(fd)
        guard written == line.count, rename(temporary, path) == 0 else {
            unlink(temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

#if canImport(Security)
import Security

private enum KeychainItem {
    static let label = "Zetty pairing key"

    private static func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: RemotePairingKeyStore.keychainService,
         kSecAttrAccount: account]
    }

    static func read(_ account: String, allowingUI: Bool) -> RemotePairingKeyStore.Reading {
        var search = query(account)
        search[kSecReturnData] = true
        search[kSecMatchLimit] = kSecMatchLimitOne
        // Without UI a locked Keychain, or an item another build made,
        // answers errSecInteractionNotAllowed instead of a dialog.
        if !allowingUI { search[kSecUseAuthenticationUI] = kSecUseAuthenticationUIFail }
        var result: CFTypeRef?
        switch SecItemCopyMatching(search as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data,
                  let key = RemotePairingKey(text: String(decoding: data, as: UTF8.self)) else { return .unusable }
            return .key(key)
        case errSecItemNotFound:
            return .missing
        default:
            return .unusable
        }
    }

    static func write(_ key: RemotePairingKey, account: String) throws {
        delete(account)
        var item = query(account)
        item[kSecAttrLabel] = label
        item[kSecValueData] = Data(key.text.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
#else
private enum KeychainItem {
    static func read(_ account: String, allowingUI: Bool) -> RemotePairingKeyStore.Reading { .unusable }
    static func write(_ key: RemotePairingKey, account: String) throws { throw CocoaError(.featureUnsupported) }
    static func delete(_ account: String) {}
}
#endif

/// The challenge-response both ends run after their hellos.
///
/// Each hello carries a fresh random challenge. The client proves the key
/// over both challenges in its hello; the server checks that before it
/// sends anything else, then proves the key back in a `proof` message,
/// which the client checks before it trusts a snapshot or sends a
/// keystroke. Each proof also covers the role and both socket addresses as
/// that end sees them. That stops a process on one of the user's Macs from
/// relaying a real Zetty's answers: the real one would sign for its own
/// address, not the one the viewer dialled.
public enum RemoteAuth {
    public enum Role: String, Sendable { case client, server }

    public static func challenge() -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).base64EncodedString()
    }

    public static func proof(key: RemotePairingKey, role: Role, server: String, client: String,
                             serverChallenge: String, clientChallenge: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(
            for: transcript(role, server, client, serverChallenge, clientChallenge),
            using: SymmetricKey(data: key.bytes))
        return Data(code).base64EncodedString()
    }

    /// Constant-time.
    public static func isValid(_ proof: String, key: RemotePairingKey, role: Role, server: String, client: String,
                               serverChallenge: String, clientChallenge: String) -> Bool {
        guard let code = Data(base64Encoded: proof), code.count == SHA256.byteCount,
              !serverChallenge.isEmpty, !clientChallenge.isEmpty else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            code, authenticating: transcript(role, server, client, serverChallenge, clientChallenge),
            using: SymmetricKey(data: key.bytes))
    }

    private static func transcript(_ role: Role, _ server: String, _ client: String,
                                   _ serverChallenge: String, _ clientChallenge: String) -> Data {
        Data(["zetty-remote-auth-1", role.rawValue, server, client, serverChallenge, clientChallenge]
            .joined(separator: "\n").utf8)
    }
}

/// The numeric addresses of a connected socket's two ends, as both proofs
/// name them. Each side reads its own socket, so no address crosses the wire.
public enum SocketEnds {
    public static func of(_ fd: Int32) -> (local: String, peer: String)? {
        guard let local = text(fd, getsockname), let peer = text(fd, getpeername) else { return nil }
        return (local, peer)
    }

    private static func text(_ fd: Int32,
                             _ read: (Int32, UnsafeMutablePointer<sockaddr>, UnsafeMutablePointer<socklen_t>) -> Int32)
    -> String? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let got = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { read(fd, $0, &length) }
        }
        guard got == 0 else { return nil }
        return withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { TailnetAddress.text(of: $0) }
        }
    }
}

/// Text another Mac sent, made safe to show: a refusal reason or a machine
/// name can come from a server that never proved the pairing key.
public enum RemoteText {
    /// Drops control characters (C0, DEL, C1, so no escape sequence reaches
    /// a terminal: an OSC 52 could write the clipboard) and every invisible
    /// format character (bidi overrides, zero-width joiners: one name could
    /// read as another, or a key hide in plain sight), then caps the length.
    ///
    /// It also blanks anything shaped like a pairing key: a run of 20 or more
    /// base64url characters, and the `zetty-pair-` prefix. Otherwise an
    /// impostor's refusal could carry its own key and say "copy this and
    /// click Paste" (security review, 2026-11-05).
    public static func displayable(_ text: String, limit: Int = 300) -> String {
        let kept = text.unicodeScalars.filter { scalar in
            let v = scalar.value
            if v < 0x20 || (0x7F ... 0x9F).contains(v) { return false }
            return scalar.properties.generalCategory != .format
        }
        var plain = String(String.UnicodeScalarView(kept))
        plain = plain.replacingOccurrences(of: "zetty-pair-", with: "…", options: .caseInsensitive)
        plain = plain.replacingOccurrences(of: "[A-Za-z0-9_+/=-]{20,}", with: "…", options: .regularExpression)
        return plain.count > limit ? String(plain.prefix(limit)) + "…" : plain
    }
}

/// The app's in-memory copy of the pairing key, read from its store once per
/// launch, and the signer the `zetty attach` relay asks for its proofs.
/// Thread-safe: the remote server and client read it on their own queues,
/// the control socket on its queue, Settings on main.
public final class RemotePairingKeyHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var reading: RemotePairingKeyStore.Reading?

    public init() {}

    /// Nil until the launch read lands.
    public var state: RemotePairingKeyStore.Reading? {
        lock.lock(); defer { lock.unlock() }
        return reading
    }

    public var key: RemotePairingKey? {
        if case .key(let key)? = state { return key }
        return nil
    }

    public func set(_ reading: RemotePairingKeyStore.Reading) {
        lock.lock(); defer { lock.unlock() }
        self.reading = reading
    }

    /// The launch read's landing: it never overwrites a key pasted while the
    /// read was still waiting (on a Keychain prompt, say).
    public func setIfUnknown(_ reading: RemotePairingKeyStore.Reading) {
        lock.lock(); defer { lock.unlock() }
        if self.reading == nil { self.reading = reading }
    }

    /// The answer to a relay's `remote-sign`.
    public func sign(server: String, client: String, serverChallenge: String, clientChallenge: String) -> ControlResponse {
        guard let key else { return .error(missingMessage) }
        guard !serverChallenge.isEmpty, !clientChallenge.isEmpty else { return .error("nothing to sign") }
        return .text(RemoteAuth.proof(key: key, role: .client, server: server, client: client,
                                      serverChallenge: serverChallenge, clientChallenge: clientChallenge))
    }

    /// The answer to a relay's `remote-check`.
    public func check(proof: String, server: String, client: String,
                      serverChallenge: String, clientChallenge: String) -> ControlResponse {
        guard let key else { return .error(missingMessage) }
        return RemoteAuth.isValid(proof, key: key, role: .server, server: server, client: client,
                                  serverChallenge: serverChallenge, clientChallenge: clientChallenge)
            ? .ok : .error("the pairing keys don't match")
    }

    private var missingMessage: String {
        switch state {
        case .unusable?: "this Mac's Zetty can't read its pairing key from the login Keychain"
        default: "this Mac has no pairing key yet: open Zetty's Settings → General → Other Macs"
        }
    }
}

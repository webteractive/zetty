import Foundation
import LocalAuthentication
import Security

/// Where Zetty's Tailscale node keeps its state (its private keys among it):
/// one generic password in the login Keychain, per home folder (the isolated
/// test app has its own) and per Mac (`RemoteMachineID.stateAccount`: a
/// Keychain migrated to another Mac never gives it this Mac's device). Never a file: Lima and Colima mount the
/// home folder into their VMs, and whoever reads the node key *is* this
/// Zetty on the user's tailnet. A VM only sees the encrypted Keychain.
///
/// macOS ties the item to the app that made it, so an ad-hoc dev build is
/// asked once at launch; signed releases aren't. Every call may wait on that
/// prompt: never call one on main.
struct TailnetStateStore {
    static let service = "co.webteractive.zetty.tailscale-state"

    enum LoadResult: Equatable {
        case empty
        case blob(Data)
        /// The item exists but can't be read (a locked Keychain over SSH, a
        /// denied prompt). The node must not start: an empty store would
        /// enroll a second device in place of this one.
        case unreadable(OSStatus)
    }

    let account: String

    init(account: String) { self.account = account }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    func load() -> LoadResult {
        var item: CFTypeRef?
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, !data.isEmpty else { return .empty }
            return .blob(data)
        case errSecItemNotFound:
            return .empty
        default:
            return .unreadable(status)
        }
    }

    @discardableResult
    func save(_ blob: Data) -> Bool {
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: blob] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = blob
        add[kSecAttrLabel as String] = "Zetty Tailscale sign-in"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func clear() -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }

    /// The pairing key's item from before 0.1.62: deleted without being
    /// read, and never with a prompt (an item another build made stays).
    static func deleteOldPairingKey(home: String) {
        let quiet = LAContext()
        quiet.interactionNotAllowed = true
        let old: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: "co.webteractive.zetty.remote-key",
                                  kSecAttrAccount as String: home,
                                  kSecUseAuthenticationContext as String: quiet]
        SecItemDelete(old as CFDictionary)
    }
}

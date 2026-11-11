import Foundation

/// This Zetty's own identity among the user's Macs, sent in every hello. A
/// Tailscale node's ID changes whenever it signs in again (sign out and back
/// in, an expired key), so the sidebar keys machines by this instead: one
/// Mac stays one group. Per Mac and home, never in the shared config.
///
/// The file holds the id and the hardware UUID of the Mac it was made on.
/// Migration Assistant, or a restore onto another Mac, copies `~/.zetty`:
/// on a different Mac the id is made again, so the new Mac never poses as
/// the old one. A restore onto the same Mac keeps it.
public enum RemoteMachineID {
    /// The id at `url` for this Mac (`hardware`: its platform UUID, nil when
    /// unknown), made (0600) when missing, unreadable or another Mac's.
    public static func loadOrCreate(at url: URL, hardware: String? = nil) -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let lines = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if let id = lines.first, isValid(id) {
                let madeOn = lines.count > 1 ? lines[1] : nil
                switch (madeOn, hardware) {
                case (nil, let here?):
                    // From before the binding: this is the Mac it was made on.
                    write(id, hardware: here, to: url)
                    return id
                case (let there?, let here?) where there != here:
                    break
                default:
                    return id
                }
            }
        }
        let id = UUID().uuidString
        write(id, hardware: hardware, to: url)
        return id
    }

    public static func isValid(_ id: String) -> Bool { UUID(uuidString: id) != nil }

    /// The Keychain account for the node's saved sign-in: per home folder (the
    /// isolated test app has its own) and per Mac, so a Keychain migrated to
    /// another Mac never hands it this Mac's Tailscale device.
    public static func stateAccount(home: String, hardware: String?) -> String {
        guard let hardware, !hardware.isEmpty else { return home }
        return "\(home) @ \(hardware)"
    }

    private static func write(_ id: String, hardware: String?, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = id + "\n" + (hardware.map { $0 + "\n" } ?? "")
        // Replaced whole, so a half-written file never loses the id.
        let temp = url.appendingPathExtension("new")
        fm.createFile(atPath: temp.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        if (try? fm.replaceItemAt(url, withItemAt: temp)) == nil {
            try? fm.removeItem(at: temp)
            fm.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

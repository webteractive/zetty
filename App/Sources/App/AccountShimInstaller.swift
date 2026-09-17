import Foundation
import ZettyCore

/// Writes and removes the `z-<account>` shortcut scripts in `~/.local/bin`,
/// beside the `zetty` symlink `CLILink` maintains.
///
/// Filesystem half of the pure `AccountShim`. Idempotent — safe to run on every
/// launch and after every account edit.
enum AccountShimInstaller {

    /// Where the shims live: the same directory as the `zetty` symlink, so a
    /// working `zetty` guarantees the shims are on PATH too.
    static var directory: URL { CLILink.url.deletingLastPathComponent() }

    /// Reconciles the shims with `accounts`. Never touches a file that does not
    /// carry `AccountShim.marker`, so a user's own `z-personal` survives.
    static func sync(accounts: [AgentAccount]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let ours = existingShimNames()
        let (write, remove) = AccountShim.reconcile(
            accounts: accounts, cliPath: CLILink.url.path, existing: ours)

        for name in remove {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
        for shim in write {
            let url = directory.appendingPathComponent(shim.name)
            // A foreign file at this path is left intact and reported instead.
            if fm.fileExists(atPath: url.path), !isOurs(url) { continue }
            guard (try? shim.contents.write(to: url, atomically: true, encoding: .utf8)) != nil
            else { continue }
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    /// Shim names an account wants but that are occupied by a foreign file, so
    /// Settings can say why the command does not exist.
    static func conflicts(accounts: [AgentAccount]) -> [String] {
        accounts.map(AccountShim.name(for:)).filter { name in
            let url = directory.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) && !isOurs(url)
        }
    }

    private static func existingShimNames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter {
            $0.hasPrefix(AccountShim.prefix) && isOurs(directory.appendingPathComponent($0))
        }
    }

    private static func isOurs(_ url: URL) -> Bool {
        (try? String(contentsOf: url, encoding: .utf8))?.contains(AccountShim.marker) ?? false
    }
}

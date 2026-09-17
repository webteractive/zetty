import Foundation

/// The `z-<account>` shortcut commands: naming, script contents, and which
/// files to write or remove for a given set of accounts. Pure — the filesystem
/// half is `AccountShimInstaller` in the app layer.
///
/// A shim is a three-line script that execs the `zetty` CLI, deliberately NOT a
/// symlink to the app binary. Pointing every shim at `~/.local/bin/zetty` means
/// they all inherit the freshness guarantee `CLILink` already provides for that
/// one symlink: an app update or move repairs one link and every shim follows.
/// A symlink per account would instead create one stale-link risk per account.
public enum AccountShim {

    /// Shell-command prefix. Fixed: no known collision (zoxide's `z` is a
    /// function, not a `z-*` command).
    public static let prefix = "z-"

    /// Identifies a file as ours. A file in the shim directory WITHOUT this
    /// line is never written or removed — a user's own `z-personal` survives.
    public static let marker = "# zetty-account-shim"

    public static func name(for account: AgentAccount) -> String {
        prefix + AgentAccountSupport.slug(account.name)
    }

    public static func scriptContents(cliPath: String, accountName: String) -> String {
        """
        #!/bin/sh
        \(marker)
        exec \(ShellQuote.singleQuoted(cliPath)) run \
        \(ShellQuote.singleQuoted(accountName)) "$@"

        """
    }

    /// `write` pairs each desired shim's file name with its full contents;
    /// `remove` is the names of ours that no account claims any more.
    ///
    /// Every desired shim is rewritten rather than diffed, so an edited file or
    /// a stale CLI path self-heals on the next reconcile.
    public static func reconcile(
        accounts: [AgentAccount],
        cliPath: String,
        existing: [String]
    ) -> (write: [(name: String, contents: String)], remove: [String]) {
        let desired = accounts.map { account in
            (name: name(for: account),
             contents: scriptContents(cliPath: cliPath, accountName: account.name))
        }
        let desiredNames = Set(desired.map(\.name))
        return (desired, existing.filter { !desiredNames.contains($0) })
    }
}

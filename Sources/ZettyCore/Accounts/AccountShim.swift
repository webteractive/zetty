import Foundation

/// The `<harness>-<account>` shortcut commands (`claude-work`): naming, script contents, and which
/// files to write or remove for a given set of accounts. Pure — the filesystem
/// half is `AccountShimInstaller` in the app layer.
///
/// A shim is a three-line script that execs the `zetty` CLI, deliberately NOT a
/// symlink to the app binary. Pointing every shim at `~/.local/bin/zetty` means
/// they all inherit the freshness guarantee `CLILink` already provides for that
/// one symlink: an app update or move repairs one link and every shim follows.
/// A symlink per account would instead create one stale-link risk per account.
public enum AccountShim {

    /// What shims were named before they carried their harness. Still
    /// scanned, so an upgrade removes the old `z-<account>` files instead of
    /// leaving both names behind.
    public static let legacyPrefix = "z-"

    /// Name prefixes a shim of ours can start with: the legacy one plus every
    /// harness that can host accounts. The installer scans only these, so it
    /// never reads an unrelated binary in the shim directory.
    public static var candidatePrefixes: [String] {
        [legacyPrefix] + SpawnableAgent.accountCapable.map { $0.id + "-" }
    }

    /// Identifies a file as ours. A file in the shim directory WITHOUT this
    /// line is never written or removed — a user's own `claude-personal` survives.
    public static let marker = "# zetty-account-shim"

    /// Named after the harness the account belongs to, so the command reads
    /// like the agent it starts: `claude-work`, `codex-work`.
    public static func name(for account: AgentAccount) -> String {
        account.agentID + "-" + AgentAccountSupport.slug(account.name)
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

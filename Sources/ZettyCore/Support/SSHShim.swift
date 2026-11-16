import Foundation

/// The `ssh` stand-in Zetty puts in `~/.local/bin`, beside the `zetty` link,
/// which PATH puts ahead of `/usr/bin` (`SSHShimInstaller` writes it).
///
/// Panes run with `TERM=xterm-ghostty`, and a server without that terminfo
/// refuses the login ("'xterm-ghostty': unknown terminal type"). Ghostty's
/// shell `ssh` wrapper only covers an `ssh` typed in a zsh pane; ssh from a
/// bash or fish pane, an agent's tool, a script or git skips it. The stand-in
/// catches every one of them that finds `ssh` on PATH: inside a Zetty pane
/// (`ZETTY_SURFACE` set) it sends `xterm-256color` instead, and anything else
/// passes through untouched. Zetty's copies of the zsh and bash wrappers pass
/// `wrappedVariable`, so a host whose terminfo the wrapper just installed
/// keeps `xterm-ghostty`.
///
/// It then runs the next `ssh` on PATH after its own folder, never one
/// before, so two copies can't call each other; with none, `/usr/bin/ssh`.
public enum SSHShim {

    public static let name = "ssh"

    /// Identifies the file as Zetty's. Without it the file is never written
    /// or removed: a user's own `~/.local/bin/ssh` survives.
    public static let marker = "# zetty-ssh-shim"

    /// Set by Zetty's shell wrappers on the ssh they run.
    public static let wrappedVariable = "ZETTY_SSH_WRAPPED"

    public static let contents = #"""
        #!/bin/sh
        # zetty-ssh-shim
        # Written by Zetty. In a Zetty pane, a server without Zetty's terminal
        # type (xterm-ghostty) refuses the login, so this sends xterm-256color.
        # Anything else passes through. Zetty removes it when
        # shell-integration-features turns off both ssh-env and ssh-terminfo.
        if [ -n "${ZETTY_SSH_WRAPPED-}" ]; then
          unset ZETTY_SSH_WRAPPED
        elif [ "${TERM-}" = xterm-ghostty ] && [ -n "${ZETTY_SURFACE-}" ]; then
          TERM=xterm-256color
          export TERM
        fi
        self=$0
        found=
        set -f
        IFS=:
        for dir in $PATH; do
          if [ -z "$found" ]; then
            [ "$dir/ssh" -ef "$self" ] && found=1
            continue
          fi
          if [ -x "$dir/ssh" ] && [ ! -d "$dir/ssh" ] && [ ! "$dir/ssh" -ef "$self" ]; then
            exec "$dir/ssh" "$@"
          fi
        done
        exec /usr/bin/ssh "$@"

        """#

    /// Whether Ghostty's ssh integration is on, from every
    /// `shell-integration-features` value in the order applied (Zetty's
    /// default first, then the user's directives). `true` / `false` set every
    /// feature; a name turns one on and `no-<name>` off.
    public static func isEnabled(featureValues: [String]) -> Bool {
        var env = false, terminfo = false
        for value in featureValues {
            for token in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                switch token {
                case "true": env = true; terminfo = true
                case "false": env = false; terminfo = false
                case "ssh-env": env = true
                case "no-ssh-env": env = false
                case "ssh-terminfo": terminfo = true
                case "no-ssh-terminfo": terminfo = false
                default: break
                }
            }
        }
        return env || terminfo
    }

    public enum Action: Equatable, Sendable {
        case write, remove, leave
    }

    /// What to do with `~/.local/bin/ssh`, given what's there now (nil when
    /// nothing is).
    public static func action(enabled: Bool, existing: String?) -> Action {
        guard let existing else { return enabled ? .write : .leave }
        guard isOurs(existing) else { return .leave }
        if !enabled { return .remove }
        return existing == contents ? .leave : .write
    }

    /// The marker sits on line 2, under the shebang.
    public static func isOurs(_ text: String) -> Bool {
        text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
            .dropFirst().first.map { $0 == marker } ?? false
    }
}

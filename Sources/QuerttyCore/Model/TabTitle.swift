import Foundation

/// Pure precedence helper for tab display titles.
///
/// Precedence:
/// 1. Non-empty, trimmed `manualTitle` (the user's own name)
/// 2. Non-empty `agentName` — a detected AI agent running in the pane
/// 3. `focusedSurfaceTitle` **when it names a running command** — the terminal's
///    reported foreground process, ignoring bare shell names (an idle shell
///    shouldn't hijack the tab title)
/// 4. Non-empty last path component of `workingDir` (the pwd — the idle default)
/// 5. Positional fallback: `"Tab \(index + 1)"`
public enum TabTitle {

    /// Shell process names that mean "idle at a prompt", not a running command.
    private static let shellNames: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "login", "-zsh", "-bash", "-fish",
    ]

    public static func display(
        manualTitle: String?,
        agentName: String? = nil,
        focusedSurfaceTitle: String?,
        workingDir: String?,
        index: Int
    ) -> String {
        // 1. Manual title.
        if let title = manualTitle?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            return title
        }

        // 2. Detected agent names the tab.
        if let agent = agentName?.trimmingCharacters(in: .whitespaces), !agent.isEmpty {
            return agent
        }

        // 3. The running command (terminal title), unless it's just a shell.
        if let title = focusedSurfaceTitle?.trimmingCharacters(in: .whitespaces),
           !title.isEmpty, !isShellName(title) {
            return title
        }

        // 4. The pwd basename (skip empty/whitespace and the root "/").
        if let path = workingDir {
            let component = URL(fileURLWithPath: path).lastPathComponent
                .trimmingCharacters(in: .whitespaces)
            if !component.isEmpty, component != "/" {
                return component
            }
        }

        // 5. Positional fallback.
        return "Tab \(index + 1)"
    }

    /// True if `title` is just a shell process name (idle prompt), not a command.
    static func isShellName(_ title: String) -> Bool {
        shellNames.contains(title.lowercased())
    }
}

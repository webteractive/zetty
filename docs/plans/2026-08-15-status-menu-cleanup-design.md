# Status Menu Cleanup Design

## Goal

Keep Zetty's hidden-window status menu focused on restoring the app and selecting
awake projects or tabs. Replace the generic terminal symbol with a compact Zetty
identity mark.

## Status item

The status item remains square and appears only while the main window is hidden.
Its button uses a centered, bold uppercase `Z` instead of the
`terminal.fill` SF Symbol. Native menu-bar text automatically follows the current
macOS appearance. The tooltip and accessibility description remain `Zetty`.

## Status menu

The menu contains **Show Zetty** followed, when available, by the existing awake
project and tab destinations. It no longer contains **Quit Zetty** or **Shut Down
Zetty…**, and the separator that introduced those actions is removed so the menu
does not end with a dangling divider.

The regular Zetty application menu is unchanged: it retains **Shut Down Zetty…**,
**Quit Zetty**, and the ⌘Q shortcut. The control CLI lifecycle commands and their
session semantics are also unchanged.

## Documentation and verification

Update the README's hidden-window behavior to describe the Z status item and stop
claiming that lifecycle actions are offered in its dropdown. Verify the change
with diff checks and an AppKit build. Then replace the installed application and
restart it through normal Quit so preserved sessions remain intact. Do not invoke
or test Shut Down.

import Foundation

/// Which surfaces must be HELD instead of freed when the layout drops them.
///
/// Freeing a surface makes libghostty stop draining its pty and join the io
/// thread, which waits for the pane's child to exit. A preserved pane's child
/// is a `zmx attach` client; if the TUI behind it is writing output, the
/// client blocks in that undrained pty, never exits, and the join — on the main
/// thread — freezes the whole app. So a surface leaving the layout is held,
/// still drained, until its session has ended, and only then freed: the order
/// hibernation always used, applied to every close path.
public enum SurfaceTeardownGate {
    /// - Parameters:
    ///   - live: surfaces the registry holds right now.
    ///   - retained: surfaces the layout (or an earlier hold) still keeps.
    ///   - released: surfaces whose teardown finished; freeing them is safe,
    ///     and holding them again would loop forever.
    ///   - canEndSessions: zmx is available. Without it there is no session to
    ///     end first, and the surface is freed as before.
    public static func held(live: Set<UUID>, retained: Set<UUID>, released: Set<UUID>,
                            canEndSessions: Bool) -> Set<UUID> {
        guard canEndSessions else { return [] }
        return live.subtracting(retained).subtracting(released)
    }
}

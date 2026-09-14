import Foundation

/// Pure decision for auto-hibernating a project. Kept free of clocks and AppKit
/// so it's fully testable; the app supplies `idleFor` and `isBusy`.
public enum HibernationPolicy {
    public static func shouldHibernate(
        idleFor: TimeInterval,
        hibernateAfter: TimeInterval,
        isBusy: Bool,
        isActive: Bool,
        isHibernated: Bool,
        autoDisabled: Bool,
        isHome: Bool
    ) -> Bool {
        guard hibernateAfter > 0 else { return false }   // feature off
        // Home is the sidebar's guaranteed floor: it is never put away without
        // someone choosing to, and the UI deliberately offers no hibernate verb
        // for it — so a timer must not create a state the user can't undo.
        guard !isHome else { return false }
        guard !isActive, !isHibernated, !autoDisabled, !isBusy else { return false }
        return idleFor >= hibernateAfter
    }
}

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
        isHome: Bool,
        isKept: Bool = false
    ) -> Bool {
        guard hibernateAfter > 0 else { return false }   // feature off
        // Home is the sidebar's guaranteed floor: it is never put away without
        // someone choosing to, and the UI deliberately offers no hibernate verb
        // for it — so a timer must not create a state the user can't undo.
        guard !isHome else { return false }
        // Kept: woken by hand and not typed into since. Somebody asked for
        // it, so it is not put away again the moment the timer allows.
        guard !isActive, !isHibernated, !autoDisabled, !isBusy, !isKept else { return false }
        return idleFor >= hibernateAfter
    }

    /// Seconds since the project was last active: the latest of when it was
    /// last on screen or typed into (`lastUsedAt`) and each of its agents'
    /// transcript writes. 0 when nothing is known, so a project seen for the
    /// first time gets a full window.
    public static func idleFor(now: Date, lastUsedAt: Date?, transcripts: [Date]) -> TimeInterval {
        guard let latest = ([lastUsedAt].compactMap { $0 } + transcripts).max() else { return 0 }
        return max(0, now.timeIntervalSince(latest))
    }
}

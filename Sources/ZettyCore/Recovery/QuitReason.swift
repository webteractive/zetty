import Foundation

/// Why the app is being asked to quit, as far as restart recovery cares.
///
/// macOS terminates apps at restart, shutdown and logout by sending
/// `kAEQuitApplication` carrying a `kAEQuitReason` attribute. ⌘Q, `zetty quit`
/// and `NSApp.terminate(nil)` carry no current Apple Event (or one without the
/// attribute). All three power-off reasons kill the user's zmx sessions, so
/// they are one case — distinguishing them would buy nothing.
///
/// Codes are packed here from their four-character forms so `ZettyCore` needs
/// no Carbon import; the App layer reads the raw values off
/// `NSAppleEventManager.currentAppleEvent` and passes them in.
public enum QuitReason: Equatable, Sendable {
    case ordinary
    case powerOff

    /// `kCoreEventClass`
    public static let coreEventClass = fourCC("aevt")
    /// `kAEQuitApplication`
    public static let quitEventID = fourCC("quit")
    /// `kAEShutDown`, `kAERestart`, `kAEReallyLogOut`
    public static let powerOffReasons: Set<UInt32> = [fourCC("shut"), fourCC("rest"), fourCC("rlgo")]

    public static func classify(eventClass: UInt32?, eventID: UInt32?, reason: UInt32?) -> QuitReason {
        guard eventClass == coreEventClass, eventID == quitEventID, let reason else { return .ordinary }
        return powerOffReasons.contains(reason) ? .powerOff : .ordinary
    }

    /// Packs a four-character code the way `OSType` does (big-endian ASCII).
    public static func fourCC(_ s: String) -> UInt32 {
        precondition(s.utf8.count == 4, "four-character code required")
        return s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

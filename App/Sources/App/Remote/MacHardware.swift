import Foundation
import IOKit

/// This Mac's hardware, as far as Other Macs needs it.
enum MacHardware {
    /// The platform UUID: the same across reinstalls and restores on this
    /// Mac, different on any other. Ties Zetty's identity and saved sign-in
    /// to the Mac they were made on (`RemoteMachineID`). Nil if IOKit can't
    /// say, which keeps the older per-home behaviour.
    static let uuid: String? = {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        let value = IORegistryEntryCreateCFProperty(entry, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
        guard let text = value?.takeRetainedValue() as? String, !text.isEmpty else { return nil }
        return text
    }()
}

#if canImport(Darwin)
import Darwin

public struct DarwinForegroundProcessProbe: ForegroundProcessProbe {
    public init() {}

    // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is a C macro Swift doesn't import.
    private static let pathMax = 4 * 1024

    public func foregroundCommand(forPTY fd: Int32) -> String? {
        let pgid = tcgetpgrp(fd)
        guard pgid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Self.pathMax)
        let len = proc_pidpath(pgid, &buffer, UInt32(buffer.count))
        guard len > 0 else { return nil }
        return String(cString: buffer)
    }
}
#endif

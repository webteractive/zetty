import Darwin
import Foundation

/// A process's current working folder, from the kernel
/// (`PROC_PIDVNODEPATHINFO`): what a pane's shell is really in, which no
/// terminal output can fake (`CurrentDirectory.choose`'s `process`).
public enum ProcessDirectory {
    /// nil when the process is gone, isn't this user's, or has no folder.
    public static func current(of pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }
}

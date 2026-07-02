public protocol ForegroundProcessProbe: Sendable {
    /// The command (path or name) of the foreground process-group leader on the
    /// given PTY file descriptor, or nil if it can't be determined.
    func foregroundCommand(forPTY fd: Int32) -> String?
}

// ZettyGhostty/Ghostty.swift
//
// Thin wrapper over the libghostty-spm "GhosttyKit" product.
//
// Module is intentionally named "ZettyGhostty" (not "GhosttyKit") to avoid
// a Swift module-name clash with the external package product of the same name.
//
// Runtime-init symbol used verbatim from the libghostty C header:
//   int ghostty_init(uintptr_t, char**);   // called once at process start
// Returns 0 on success.

import GhosttyKit  // the C-API product from libghostty-spm (re-exports libghostty)

public enum Ghostty {
    public private(set) static var isInitialized = false

    /// Initializes the libghostty global runtime exactly once.
    ///
    /// Calls `ghostty_init` with no arguments. Since Ghostty `0e067ded7`
    /// (libghostty-spm 2.2.2026111701) argv is non-null, and Ghostty keeps
    /// the slice for the life of the process even when argc is 0, so it is
    /// a static array, as the package's own bootstrap passes.
    /// Returns 0 on success; any non-zero value is mapped to ``GhosttyError/initFailed(code:)``.
    public static func initializeRuntime() throws {
        guard !isInitialized else { return }
        let rc = ghostty_init(0, emptyArgv)
        guard rc == 0 else { throw GhosttyError.initFailed(code: Int(rc)) }
        isInitialized = true
    }

    private static let emptyArgv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> = {
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 1)
        argv.initialize(to: nil)
        return argv
    }()
}

public enum GhosttyError: Error, Equatable {
    case initFailed(code: Int)
}

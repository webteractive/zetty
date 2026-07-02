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
    /// Calls `ghostty_init(0, nil)` — the documented bootstrap entry point
    /// (argc/argv are optional for embedded use; passing 0 / nil is valid).
    /// Returns 0 on success; any non-zero value is mapped to ``GhosttyError/initFailed(code:)``.
    public static func initializeRuntime() throws {
        guard !isInitialized else { return }
        let rc = ghostty_init(0, nil)
        guard rc == 0 else { throw GhosttyError.initFailed(code: Int(rc)) }
        isInitialized = true
    }
}

public enum GhosttyError: Error, Equatable {
    case initFailed(code: Int)
}

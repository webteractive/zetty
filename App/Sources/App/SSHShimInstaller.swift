import Foundation
import ZettyCore

/// Writes or removes the `ssh` stand-in (`SSHShim`) in `~/.local/bin`,
/// beside the `zetty` link. Idempotent: run at launch and on every config
/// reload. A file there without the marker is never touched.
enum SSHShimInstaller {

    static var url: URL {
        CLILink.url.deletingLastPathComponent().appendingPathComponent(SSHShim.name)
    }

    /// `featureValues`: every `shell-integration-features` value in the order
    /// applied, Zetty's default first.
    static func sync(featureValues: [String]) {
        let fm = FileManager.default
        let existing = try? String(contentsOf: url, encoding: .utf8)
        switch SSHShim.action(enabled: SSHShim.isEnabled(featureValues: featureValues), existing: existing) {
        case .leave:
            return
        case .remove:
            try? fm.removeItem(at: url)
        case .write:
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? SSHShim.contents.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }
}

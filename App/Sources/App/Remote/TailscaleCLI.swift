import Darwin
import Foundation
import ZettyCore

/// Runs the `tailscale` CLI. Every call blocks for up to `timeout`, so call it
/// off the main thread.
enum TailscaleCLI {
    /// The Mac App Store / standalone app's own binary first, then the shell
    /// wrappers Homebrew and the standalone installer put on PATH.
    private static let searchPaths = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
    ]

    static func locate() -> String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func status(timeout: TimeInterval = 3) -> TailscaleStatus? {
        guard let path = locate(), let data = run(path, ["status", "--json"], timeout: timeout) else { return nil }
        return TailscaleStatus.parse(data)
    }

    static func whois(_ ip: String, timeout: TimeInterval = 3) -> TailscaleNode? {
        guard let path = locate(), let data = run(path, ["whois", "--json", ip], timeout: timeout) else { return nil }
        return TailscaleWhois.parse(data)
    }

    /// Stdout on exit 0 within `timeout`, else nil. Same shape as
    /// `ZmxRunner.runData`: one deadline covers the read and the exit, and a
    /// process that overruns is terminated, then killed a second later.
    private static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ZMX_SESSION")
        process.environment = TailscaleCLIEnvironment.prepare(environment)
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }

        let deadline = DispatchTime.now() + timeout
        let output = TailscaleOutput()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output.data = stdout.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        guard read.wait(timeout: deadline) == .success,
              exited.wait(timeout: deadline) == .success else {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if process.isRunning { _ = Darwin.kill(pid, SIGKILL) }
            }
            return nil
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return output.data
    }
}

private final class TailscaleOutput: @unchecked Sendable {
    var data = Data()
}

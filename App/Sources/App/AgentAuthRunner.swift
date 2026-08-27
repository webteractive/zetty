import Foundation
import ZettyGhostty

/// Runs an agent's `auth status` for one account, so the Accounts list can show
/// which identity a config directory actually holds.
///
/// Modeled on `ZmxRunner`: a GUI app doesn't inherit the shell's PATH, so the
/// binary is located through explicit candidates.
///
/// Blocking with a timeout. Call off the main thread, and only on demand —
/// opening Settings, pressing Check, or finishing a sign-in. Never on a timer:
/// this spawns one heavyweight process per account.
enum AgentAuthRunner {

    private static let timeout: TimeInterval = 8

    /// Resolved binary for a catalog agent, or nil when it isn't installed.
    static func locate(_ agent: SpawnableAgent) -> String? {
        let name = agent.defaultCommand
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(NSHomeDirectory())/.\(agent.id)/local/\(name)",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `<binary> auth status --json` with the account's config directory set.
    /// nil when the binary is missing, the call fails, or the output doesn't parse.
    static func probe(account: AgentAccount, home: String = NSHomeDirectory()) -> AccountAuthStatus? {
        guard let agent = SpawnableAgent.byID(account.agentID),
              let binary = locate(agent),
              let envVar = agent.configDirEnvVar,
              let arguments = agent.statusArguments,
              let format = agent.statusFormat
        else { return nil }

        var environment = ProcessInfo.processInfo.environment
        environment[envVar] = AgentAccountSupport.canonical(account.directory, home: home)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read before waiting: a full pipe buffer would deadlock a process we
        // are also waiting on.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }

        return AuthStatusProbe.parse(String(decoding: data, as: UTF8.self), format: format)
    }
}

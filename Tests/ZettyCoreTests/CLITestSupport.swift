import Foundation
@testable import ZettyCore

/// Records every request a command tries to send. The transport is bound
/// task-locally, so nothing here can reach the real app's socket.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [ControlRequest] = []
    private var _output = ""

    var requests: [ControlRequest] { lock.withLock { _requests } }
    var output: String { lock.withLock { _output } }

    func record(_ request: ControlRequest) -> ControlResponse {
        lock.withLock { _requests.append(request) }
        return .error("test transport: no app")
    }

    func write(_ text: String) { lock.withLock { _output += text + "\n" } }
}

func runIsolated(_ arguments: [String]) -> (exit: Int32, recorder: Recorder) {
    let recorder = Recorder()
    let exit = ControlCLI.$transport.withValue({ recorder.record($0) }) {
        ControlCLI.$helpOutput.withValue({ recorder.write($0) }) {
            ControlCLI.run(arguments)
        }
    }
    return (exit, recorder)
}

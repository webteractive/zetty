import Darwin
import Foundation
import ZettyCore

/// What `TerminalViewController.prepareRemoteAttach` found.
enum RemoteAttachPreparation {
    case ready(surfaceID: UUID)
    /// Plain words for the other Mac's pane.
    case refused(String)
}

/// The serving Zetty's answer to a terminal connection: finds the pane, makes
/// it live without moving this Mac's screen, waits for its zmx session, and
/// says what the server runs on the pty. It never creates a session: the plan
/// ends in `zmx attach` only once `zmx list` shows the pane's own.
final class RemoteTerminalHost: RemoteTerminalHosting {
    private weak var viewController: TerminalViewController?
    private let machineName: String
    private let zmxPath: () -> String?
    private let work = DispatchQueue(label: "co.webteractive.zetty.remote-terminal-host",
                                     qos: .utility, attributes: .concurrent)

    /// How long a just-spawned pane has to show up in `zmx list`.
    private static let sessionWait: TimeInterval = 3

    init(viewController: TerminalViewController, machineName: String,
         zmxPath: @escaping () -> String? = { ZmxRunner.locate() }) {
        self.viewController = viewController
        self.machineName = machineName
        self.zmxPath = zmxPath
    }

    func plan(for request: RemoteAttachRequest,
              completion: @escaping (Result<RemoteAttachPlan, RemoteAttachRefusal>) -> Void) {
        let machine = machineName
        DispatchQueue.main.async { [weak self] in
            guard let self, let viewController = self.viewController else {
                completion(.failure(RemoteAttachRefusal(message: "\(machine) is shutting down")))
                return
            }
            switch viewController.prepareRemoteAttach(pane: request.pane, machine: machine) {
            case .refused(let message):
                completion(.failure(RemoteAttachRefusal(message: message)))
            case .ready(let surfaceID):
                let session = SessionPersistence.sessionName(for: surfaceID)
                self.work.async { self.waitForSession(session, request: request, completion: completion) }
            }
        }
    }

    /// Off main: polls `zmx list` until the session exists, then plans.
    private func waitForSession(_ session: String, request: RemoteAttachRequest,
                                completion: @escaping (Result<RemoteAttachPlan, RemoteAttachRefusal>) -> Void) {
        guard let zmx = zmxPath() else {
            completion(.failure(RemoteAttachRefusal(message: "zmx isn't installed on \(machineName)")))
            return
        }
        let deadline = Date().addingTimeInterval(Self.sessionWait)
        while ZmxRunner.sessionPIDs(zmxPath: zmx, timeout: 1)[session] == nil {
            guard Date() < deadline else {
                completion(.failure(RemoteAttachRefusal(message: "that pane's session didn't start on \(machineName)")))
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        completion(.success(Self.plan(session: session, zmx: zmx, scrollback: request.scrollback,
                                      restoreScript: request.scrollback ? ScrollbackRestore.ensureScript() : nil)))
    }

    /// Scrollback first through the restore script (`zmx history --vt`, then
    /// `exec zmx attach`), or a plain attach on a reconnect or when the script
    /// can't be written. `ZMX_SESSION` is stripped: inherited, `zmx attach`
    /// would end that session instead.
    static func plan(session: String, zmx: String, scrollback: Bool, restoreScript: String?) -> RemoteAttachPlan {
        var environment = ProcessInfo.processInfo.environment
        environment["ZMX_SESSION"] = nil
        environment["TERM"] = "xterm-256color"
        if scrollback, let restoreScript {
            return RemoteAttachPlan(executable: "/bin/sh", arguments: [restoreScript, zmx, session],
                                    environment: environment, session: session)
        }
        return RemoteAttachPlan(executable: zmx, arguments: ["attach", session],
                                environment: environment, session: session)
    }

    /// The remote client may have typed last, which leaves the session at its
    /// size. SIGWINCH to this Mac's own `zmx attach` clients makes zmx apply
    /// their size again (checked on zmx 0.6.0, see remote-machines.md).
    func detached(session: String) {
        work.async {
            guard let ps = ZmxRunner.psSnapshot(timeout: 2) else { return }
            for pid in ZmxAttachProcesses.pids(attaching: session, psOutput: ps) {
                kill(pid, SIGWINCH)
            }
        }
    }
}

import Foundation
import ZettyCore

/// Has agents compact their conversations before their project is put away:
/// all of them at once, each off the main thread and bounded by
/// `HandoffCompaction.timeout`. A project's panes hand off together (Glen,
/// 2026-10-08); there was a cap of two, to spare one login's rate limit.
///
/// It only asks and waits, and says how each ended (`onFinished`). What a
/// failure means for the project is the caller's decision
/// (`HibernationPreparation`). Nothing here is a process of ours: the work
/// happens inside the harness, in its pane, so there is nothing to kill at
/// quit and nothing to stop when one is cancelled. A cancelled compaction
/// runs to its end, and that conversation stays compacted.
///
/// `start`, `cancel` and `onFinished` are main-thread only.
final class HandoffCompactor: @unchecked Sendable {

    struct Job {
        let surface: UUID
        let agent: AgentKind
        let session: AgentSession
        /// The harness's store for the pane's login; nil is the default one.
        let configDirectory: String?
        /// Claude's hooks say a turn is running. Codex shows it on screen.
        let midTurn: Bool
    }

    /// How a pane ended, and what its harness called the conversation, for a
    /// pane that never reported a title of its own.
    var onFinished: ((UUID, HandoffCompaction.Result, _ title: String?) -> Void)?

    private let lock = NSLock()
    private var active: Set<UUID> = []
    private var cancelled: Set<UUID> = []

    func start(_ jobs: [Job], zmxPath: String) {
        for job in jobs {
            lock.lock()
            let alreadyAtIt = !active.insert(job.surface).inserted
            cancelled.remove(job.surface)
            lock.unlock()
            // Cancelled moments ago and asked for again: the compaction is
            // still under way, and its answer counts after all.
            if alreadyAtIt { continue }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let (result, title) = run(job, zmxPath: zmxPath)
                DispatchQueue.main.async { [self] in finish(job.surface, result, title: title) }
            }
        }
    }

    /// Stops waiting on a pane. Its answer, when it comes, is dropped.
    func cancel(_ surface: UUID) {
        lock.lock()
        if active.contains(surface) { cancelled.insert(surface) }
        lock.unlock()
    }

    private func isCancelled(_ surface: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled.contains(surface)
    }

    private func run(_ job: Job, zmxPath: String) -> (HandoffCompaction.Result?, title: String?) {
        guard !isCancelled(job.surface) else { return (nil, nil) }
        // A cleared or brand-new chat has a session and nothing to compact.
        guard let transcript = AgentTranscript.url(agent: job.agent, session: job.session,
                                                   configDirectory: job.configDirectory),
              AgentTranscript.hasReply(at: transcript, agent: job.agent) else { return (.skipped, nil) }
        // Compacted, and nothing said since: it is a handoff already, and
        // asking again gets "Not enough messages to compact" and no marker.
        let result = AgentTranscript.needsCompaction(at: transcript, agent: job.agent)
            ? ZmxRunner.compact(
                session: SessionPersistence.sessionName(for: job.surface), agent: job.agent,
                midTurn: job.midTurn, transcript: transcript, zmxPath: zmxPath,
                isCancelled: { [self] in isCancelled(job.surface) })
            : .compacted
        // Read after compacting: a harness may retitle as it summarises.
        return (result, AgentTranscript.title(at: transcript, agent: job.agent))
    }

    private func finish(_ surface: UUID, _ result: HandoffCompaction.Result?, title: String?) {
        lock.lock()
        active.remove(surface)
        let wasCancelled = cancelled.remove(surface) != nil
        lock.unlock()
        guard !wasCancelled else { return }
        // Cancelled and then wanted again in the moment between its last
        // check and here: it stopped waiting, so it cannot say it compacted.
        let result = result ?? .failed("its compaction was interrupted")
        let pane = SessionPersistence.shortID(for: surface)
        switch result {
        case .compacted:           ZettyLog.lifecycle.log("handoff: \(pane) compact")
        case .skipped:             ZettyLog.lifecycle.log("handoff: \(pane) holds no conversation, skipped")
        case .failed(let reason):  ZettyLog.lifecycle.log("handoff: \(pane) none (\(reason))")
        }
        onFinished?(surface, result, title)
    }
}

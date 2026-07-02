import Foundation

/// Reduces the hook-event log (`agent-events.jsonl`) to the agents presumed
/// still alive, for startup replay.
///
/// The live watcher tails only *new* lines, so agents that were already running
/// before launch (e.g. inside preserved zmx sessions) would otherwise be
/// invisible until their next hook fires — tabs lose their agent names on
/// relaunch. Replaying the log's final state per (cwd, agent) restores them.
public enum AgentEventReplay {

    /// The latest event per (cwd, agent), in first-seen order, excluding pairs
    /// whose last event was `ended` (the agent exited). Malformed lines are
    /// skipped, matching the watcher's parsing.
    public static func liveEvents(fromJSONL text: String) -> [AgentEvent] {
        var latest: [String: AgentEvent] = [:]
        var order: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let event = AgentEvent.parse(line: String(line)) else { continue }
            let key = event.cwd + "\u{0}" + event.agent.rawValue
            if latest[key] == nil { order.append(key) }
            latest[key] = event
        }
        return order.compactMap { latest[$0] }.filter { $0.event != .ended }
    }
}

import Foundation
import QuerttyCore

/// Tails the agent-event sink (`~/.quertty/agent-events.jsonl`) that harness
/// hooks append to, parsing newly-appended lines into `AgentEvent`s.
///
/// Like `ConfigFileWatcher`, this is a lightweight poll on the main run loop, so
/// `onEvents` fires on the main thread. It seeds its read offset to EOF at start
/// so pre-existing history isn't replayed, and re-reads from the top if the file
/// is truncated/rotated.
final class AgentEventWatcher {

    private let url: URL
    private let onEvents: ([AgentEvent]) -> Void
    private var timer: Timer?
    private var offset: UInt64 = 0

    init(url: URL, onEvents: @escaping ([AgentEvent]) -> Void) {
        self.url = url
        self.onEvents = onEvents
    }

    func start() {
        stop()
        offset = fileSize()   // ignore anything already in the file
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func fileSize() -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64 else { return 0 }
        return size
    }

    private func poll() {
        let size = fileSize()
        if size < offset { offset = 0 }        // truncated/rotated → re-read
        guard size > offset else { return }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            offset = size
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            let events = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { AgentEvent.parse(line: String($0)) }
            if !events.isEmpty { onEvents(events) }
        } catch {
            // Best-effort: skip this cycle on read error.
        }
    }
}

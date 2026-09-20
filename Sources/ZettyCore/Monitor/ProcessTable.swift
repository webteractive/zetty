import Foundation

/// One process from a `ps` snapshot.
public struct ProcessSample: Equatable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let pgid: Int32
    public let stat: String
    public let tty: String
    public let cpuSeconds: Double
    public let rssBytes: Int64
    public let command: String
}

/// A whole `ps` snapshot, indexed by pid, with parent/child links.
///
/// The format is shared with `ForegroundProcess` on purpose: the foreground
/// probe already runs one `ps` every few seconds, and a second polling loop is
/// the mistake this codebase has made twice before.
public struct ProcessTable: Equatable, Sendable {

    /// The `ps` argument this parser expects. `command` MUST stay last: it
    /// contains spaces, and the split stops counting before it.
    public static let psFormat = "pid=,ppid=,pgid=,stat=,tty=,time=,rss=,command="

    public let samples: [Int32: ProcessSample]
    private let children: [Int32: [Int32]]

    public init(psOutput: String) {
        var samples: [Int32: ProcessSample] = [:]
        var children: [Int32: [Int32]] = [:]
        for line in psOutput.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
            guard fields.count == 8,
                  let pid = Int32(fields[0]), let ppid = Int32(fields[1]),
                  let pgid = Int32(fields[2]),
                  let cpu = CPUTime.seconds(from: String(fields[5])),
                  let rssKiB = Int64(fields[6]) else { continue }
            samples[pid] = ProcessSample(
                pid: pid, ppid: ppid, pgid: pgid,
                stat: String(fields[3]), tty: String(fields[4]),
                cpuSeconds: cpu, rssBytes: rssKiB * 1024,
                command: fields[7].trimmingCharacters(in: .whitespaces)
            )
            children[ppid, default: []].append(pid)
        }
        self.samples = samples
        self.children = children
    }

    /// `root` and everything descended from it — the shell AND its agent,
    /// which is where the cost actually is.
    ///
    /// The visited set is not defensive tidiness: pid reuse can leave a parent
    /// loop in a snapshot, and this walk runs on a timer.
    public func descendants(of root: Int32) -> [ProcessSample] {
        guard samples[root] != nil else { return [] }
        var found: [ProcessSample] = []
        var visited: Set<Int32> = []
        var queue: [Int32] = [root]
        while let pid = queue.popLast() {
            guard visited.insert(pid).inserted, let sample = samples[pid] else { continue }
            found.append(sample)
            queue.append(contentsOf: children[pid] ?? [])
        }
        return found
    }
}

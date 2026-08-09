import Foundation

/// FSEvents stream for one file tree, reporting only changes inside directories
/// the user currently has expanded.
///
/// The filter is load-bearing. Watching a whole project root and refreshing on
/// every event is the per-second churn pattern that once put 59% of the main
/// thread in Auto Layout with CPU pinned near 100%; a collapsed `node_modules`
/// must be able to absorb an entire `npm install` without waking the view.
///
/// `@unchecked Sendable` is deliberate and narrow: every piece of mutable state
/// below is confined to `queue`, which is also the stream's dispatch queue, so
/// the FSEvents callback and `setWatchedDirectories` never race. `stream` itself
/// is only touched during `init`/`stop`, both on the owner's thread.
final class FileTreeWatcher: @unchecked Sendable {

    private let root: String
    private let onChange: @Sendable (Set<String>) -> Void
    private let queue = DispatchQueue(label: "dev.zetty.filetree.watcher")
    private var stream: FSEventStreamRef?
    /// Guarded by `queue`.
    private var watched: Set<String> = []
    private var pending: Set<String> = []
    private var flushScheduled = false

    private static let debounce: DispatchTimeInterval = .milliseconds(250)

    init(root: String, onChange: @escaping @Sendable (Set<String>) -> Void) {
        self.root = root
        self.onChange = onChange
        start()
    }

    deinit { stop() }

    /// The directories whose contents matter right now. Cheap to call on every
    /// expand/collapse.
    func setWatchedDirectories(_ directories: Set<String>) {
        queue.async { [self] in watched = directories }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func start() {
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileTreeWatcher>.fromOpaque(info).takeUnretainedValue()
            // Without kFSEventStreamCreateFlagUseCFTypes the paths arrive as a
            // C array of C strings.
            let cPaths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            var changed: [String] = []
            for index in 0..<count {
                guard let cPath = cPaths[index] else { continue }
                changed.append(String(cString: cPath))
            }
            watcher.absorb(changed)
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0,                                  // we debounce ourselves
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                                     | kFSEventStreamCreateFlagNoDefer)
        ) else {
            // No stream: the tree falls back to on-demand refresh. Not worth an
            // alert — browsing a filesystem must never nag.
            return
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    /// Called on `queue` from the FSEvents callback.
    private func absorb(_ changedPaths: [String]) {
        let relevant = changedPaths.compactMap { path -> String? in
            let parent = (path as NSString).deletingLastPathComponent
            if watched.contains(parent) { return parent }
            // A watched directory changing in its own right counts too.
            if watched.contains(path) { return path }
            return nil
        }
        guard !relevant.isEmpty else { return }
        pending.formUnion(relevant)
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + Self.debounce) { [self] in
            let batch = pending
            pending.removeAll()
            flushScheduled = false
            guard !batch.isEmpty else { return }
            onChange(batch)
        }
    }
}

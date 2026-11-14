import Foundation

/// Something scheduled that can be called off: a timer or a running command.
public protocol LuaCancellable: AnyObject {
    func cancel()
}

/// Runs `zetty.after` / `zetty.every` callbacks later. Injected so tests can
/// fire timers on demand.
public protocol LuaScheduler: AnyObject {
    func schedule(after seconds: TimeInterval, repeats: Bool, _ fire: @escaping () -> Void) -> LuaCancellable
}

/// Timers on the main queue, where the Lua state lives in the app.
public final class MainQueueScheduler: LuaScheduler {
    public init() {}

    public func schedule(after seconds: TimeInterval, repeats: Bool,
                         _ fire: @escaping () -> Void) -> LuaCancellable {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let start = DispatchTime.now() + max(0, seconds)
        if repeats {
            timer.schedule(deadline: start, repeating: seconds)
        } else {
            timer.schedule(deadline: start)
        }
        let handle = MainQueueTimer(timer)
        timer.setEventHandler { [weak handle] in
            guard let handle, !handle.isCancelled else { return }
            if !repeats { handle.cancel() }
            fire()
        }
        timer.resume()
        return handle
    }
}

private final class MainQueueTimer: LuaCancellable {
    private let timer: DispatchSourceTimer
    private(set) var isCancelled = false

    init(_ timer: DispatchSourceTimer) { self.timer = timer }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        timer.cancel()
    }

    deinit { cancel() }
}

import Foundation
import ZettyCore

/// What Tailscale is doing on this Mac, in the terms Settings and the sidebar need.
enum TailscaleState: Equatable {
    case notInstalled
    case stopped
    case needsLogin
    case running(TailscaleStatus)

    init(status: TailscaleStatus?, installed: Bool) {
        guard installed else { self = .notInstalled; return }
        guard let status else { self = .stopped; return }
        switch status.backend {
        case .running where status.me != nil: self = .running(status)
        case .needsLogin: self = .needsLogin
        default: self = .stopped
        }
    }
}

/// Polls `tailscale status` on its own queue and reports changes on main.
/// Only runs while serving or showing other Macs is on.
final class TailscaleMonitor {
    private let interval: TimeInterval
    private let onChange: (TailscaleState) -> Void
    private let queue = DispatchQueue(label: "co.webteractive.zetty.tailscale", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// Last state seen on the queue, to report only changes.
    private var lastOnQueue: TailscaleState?

    /// The most recent state, read on main.
    private(set) var latest: TailscaleState?

    init(interval: TimeInterval = 10, onChange: @escaping (TailscaleState) -> Void) {
        self.interval = interval
        self.onChange = onChange
    }

    func start() {
        guard timer == nil else { return }
        // Before the first tick (same serial queue): a poll still in flight
        // when `stop` ran can leave a stale state here, and a restart that
        // matched it would never report.
        queue.async { [weak self] in self?.lastOnQueue = nil }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.async { [weak self] in self?.lastOnQueue = nil }
        latest = nil
    }

    /// Re-reads now instead of waiting for the next tick (e.g. Settings opened).
    func refresh() {
        queue.async { [weak self] in self?.poll() }
    }

    private func poll() {
        let installed = TailscaleCLI.locate() != nil
        let state = TailscaleState(status: installed ? TailscaleCLI.status() : nil, installed: installed)
        guard state != lastOnQueue else { return }
        lastOnQueue = state
        DispatchQueue.main.async { [weak self] in
            guard let self, self.timer != nil else { return }
            self.latest = state
            self.onChange(state)
        }
    }
}

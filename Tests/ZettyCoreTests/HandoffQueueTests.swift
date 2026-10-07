import Foundation
import Testing
@testable import ZettyCore

private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

@Test func atMostTwoRunAtOnceInTheOrderQueued() {
    var queue = HandoffQueue()
    queue.enqueue([a, b, c])
    #expect(queue.startNext() == [a, b])
    #expect(queue.startNext() == [])
    queue.finish(a)
    #expect(queue.startNext() == [c])
    #expect(queue.isRunning(b) && queue.isRunning(c))
}

@Test func aSurfaceIsNeverQueuedTwice() {
    var queue = HandoffQueue()
    queue.enqueue([a, a])
    _ = queue.startNext()
    queue.enqueue([a, b])
    #expect(queue.startNext() == [b])
}

// A pane woken, closed or quit under while its handoff is owed: whatever the
// fork then prints must not land.
@Test func cancelRemovesItWhateverItsState() {
    var queue = HandoffQueue()
    queue.enqueue([a, b, c, d])
    _ = queue.startNext()
    #expect(queue.cancel(a) == .wasRunning)
    #expect(queue.cancel(c) == .wasQueued)
    #expect(queue.cancel(c) == .notPending)
    #expect(!queue.isPending(a) && !queue.isPending(c))
    #expect(queue.startNext() == [d])
}

@Test func pendingCoversQueuedAndRunning() {
    var queue = HandoffQueue()
    queue.enqueue([a, b, c])
    _ = queue.startNext()
    #expect(queue.isPending(a) && queue.isPending(c))
    #expect(queue.anyPending(among: [c, d]))
    #expect(!queue.anyPending(among: [d]))
    queue.finish(a); queue.finish(b)
    _ = queue.startNext(); queue.finish(c)
    #expect(queue.isEmpty)
}

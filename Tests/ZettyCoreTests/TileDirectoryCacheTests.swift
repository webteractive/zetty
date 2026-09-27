import Foundation
import Testing
@testable import ZettyCore

private let pane = UUID()
private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

@Test func aFirstLookupReadsTheDirectory() {
    var cache = TileDirectoryCache()
    var reads = 0
    let result = cache.directory(for: pane, now: t0) { reads += 1; return "/a" }
    #expect(result.directory == "/a")
    #expect(result.retryAfter == nil)
    #expect(reads == 1)
}

@Test func aCleanPaneIsServedFromCacheWithoutReading() {
    var cache = TileDirectoryCache()
    _ = cache.directory(for: pane, now: t0) { "/a" }
    var reads = 0
    let result = cache.directory(for: pane, now: t0 + 60) { reads += 1; return "/b" }
    #expect(result.directory == "/a")
    #expect(reads == 0)
}

@Test func aDirtyPaneIsReReadOnceTheIntervalHasPassed() {
    // A `cd` reports through the pane's title/cwd change, which marks it dirty.
    var cache = TileDirectoryCache()
    _ = cache.directory(for: pane, now: t0) { "/a" }
    cache.markDirty(pane)
    let result = cache.directory(for: pane, now: t0 + TileDirectoryCache.minimumInterval) { "/b" }
    #expect(result.directory == "/b")
    #expect(result.retryAfter == nil)
    #expect(!cache.hasDirty)
}

@Test func aDirtyPaneWithinTheIntervalKeepsItsCacheAndAsksForARetry() {
    // A spinning agent retitles many times a second; its cwd file is not
    // re-read on every frame, but the pending change is not lost either.
    var cache = TileDirectoryCache()
    _ = cache.directory(for: pane, now: t0) { "/a" }
    cache.markDirty(pane)
    var reads = 0
    let result = cache.directory(for: pane, now: t0 + 0.25) { reads += 1; return "/b" }
    #expect(result.directory == "/a")
    #expect(reads == 0)
    #expect(result.retryAfter.map { abs($0 - 0.75) < 0.0001 } == true)
    #expect(cache.hasDirty)
}

@Test func pruningForgetsPanesNoLongerShown() {
    var cache = TileDirectoryCache()
    let other = UUID()
    _ = cache.directory(for: pane, now: t0) { "/a" }
    _ = cache.directory(for: other, now: t0) { "/o" }
    cache.markDirty(other)
    cache.prune(keeping: [pane])
    #expect(!cache.hasDirty)
    var reads = 0
    _ = cache.directory(for: other, now: t0 + 60) { reads += 1; return "/o2" }
    #expect(reads == 1)
}

@Test func resetForgetsEverything() {
    var cache = TileDirectoryCache()
    _ = cache.directory(for: pane, now: t0) { "/a" }
    cache.markDirty(pane)
    cache.reset()
    #expect(!cache.hasDirty)
    var reads = 0
    _ = cache.directory(for: pane, now: t0) { reads += 1; return "/a" }
    #expect(reads == 1)
}

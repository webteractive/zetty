import Foundation
import Testing
@testable import ZettyCore

@Test func unknownRootHasNoExpandedDirectories() {
    let cache = FileTreeExpansionCache()
    #expect(cache.expanded(for: "/r").isEmpty)
}

@Test func recordedExpansionRoundTrips() {
    var cache = FileTreeExpansionCache()
    cache.record(root: "/r", expanded: ["/r/a", "/r/a/b"])
    #expect(cache.expanded(for: "/r") == ["/r/a", "/r/a/b"])
}

@Test func recordingAgainReplacesRatherThanMerges() {
    var cache = FileTreeExpansionCache()
    cache.record(root: "/r", expanded: ["/r/a"])
    cache.record(root: "/r", expanded: ["/r/b"])
    #expect(cache.expanded(for: "/r") == ["/r/b"])
}

@Test func rootsAreTrackedIndependently() {
    var cache = FileTreeExpansionCache()
    cache.record(root: "/one", expanded: ["/one/a"])
    cache.record(root: "/two", expanded: ["/two/b"])
    #expect(cache.expanded(for: "/one") == ["/one/a"])
    #expect(cache.expanded(for: "/two") == ["/two/b"])
}

@Test func recordingAnEmptySetStillCountsAsALiveRoot() {
    var cache = FileTreeExpansionCache()
    cache.record(root: "/r", expanded: [])
    #expect(cache.rootCount == 1)
}

@Test func oldestRootIsEvictedAtCapacity() {
    var cache = FileTreeExpansionCache(capacity: 2)
    cache.record(root: "/a", expanded: ["/a/x"])
    cache.record(root: "/b", expanded: ["/b/x"])
    cache.record(root: "/c", expanded: ["/c/x"])
    #expect(cache.rootCount == 2)
    #expect(cache.expanded(for: "/a").isEmpty)
    #expect(cache.expanded(for: "/b") == ["/b/x"])
    #expect(cache.expanded(for: "/c") == ["/c/x"])
}

@Test func recordingRefreshesRecencySoTheRefreshedRootSurvives() {
    var cache = FileTreeExpansionCache(capacity: 2)
    cache.record(root: "/a", expanded: ["/a/x"])
    cache.record(root: "/b", expanded: ["/b/x"])
    cache.record(root: "/a", expanded: ["/a/y"])   // /a is now newest
    cache.record(root: "/c", expanded: ["/c/x"])   // evicts /b
    #expect(cache.expanded(for: "/a") == ["/a/y"])
    #expect(cache.expanded(for: "/b").isEmpty)
    #expect(cache.expanded(for: "/c") == ["/c/x"])
}

@Test func readingDoesNotAffectRecency() {
    var cache = FileTreeExpansionCache(capacity: 2)
    cache.record(root: "/a", expanded: ["/a/x"])
    cache.record(root: "/b", expanded: ["/b/x"])
    _ = cache.expanded(for: "/a")                  // a read must not rescue /a
    cache.record(root: "/c", expanded: ["/c/x"])
    #expect(cache.expanded(for: "/a").isEmpty)
}

@Test func capacityBelowOneIsClampedSoTheCacheStaysUsable() {
    var cache = FileTreeExpansionCache(capacity: 0)
    cache.record(root: "/a", expanded: ["/a/x"])
    #expect(cache.expanded(for: "/a") == ["/a/x"])
}

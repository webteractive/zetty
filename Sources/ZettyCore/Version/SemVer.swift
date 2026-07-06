import Foundation

/// A minimal `MAJOR.MINOR.PATCH` version for update comparisons. Tolerates a
/// leading `v` and a missing patch; anything else fails to parse (nil).
public struct SemVer: Comparable, Equatable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 1, parts.count <= 3 else { return nil }
        var nums: [Int] = []
        for part in parts {
            guard let n = Int(part), n >= 0 else { return nil }
            nums.append(n)
        }
        major = nums[0]
        minor = nums.count > 1 ? nums[1] : 0
        patch = nums.count > 2 ? nums[2] : 0
    }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// True only when both parse and `latest` is strictly greater than `current`.
    public static func isNewer(latest: String, than current: String) -> Bool {
        guard let l = SemVer(latest), let c = SemVer(current) else { return false }
        return l > c
    }
}

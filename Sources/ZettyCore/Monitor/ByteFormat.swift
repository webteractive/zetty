import Foundation

/// Byte sizes for chrome: short, stable-width, and never scientific.
public enum ByteFormat {
    public static func short(_ bytes: Int64) -> String {
        let value = max(0, bytes)
        let kb: Int64 = 1024, mb = kb * 1024, gb = mb * 1024
        switch value {
        case gb...:
            // One decimal, so a slowly growing footprint visibly grows.
            return String(format: "%.1f GB", Double(value) / Double(gb))
        case mb...: return "\(value / mb) MB"
        case kb...: return "\(value / kb) KB"
        default: return "\(value) B"
        }
    }
}

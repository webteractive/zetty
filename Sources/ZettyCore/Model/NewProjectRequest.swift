import Foundation

/// Pure, filesystem-free validation + path composition for creating a new
/// project folder. The app/CLI layers perform the actual mkdir / git init.
public struct NewProjectRequest: Equatable, Sendable {
    public let parentPath: String
    public let rawName: String

    public init(parentPath: String, name: String) {
        self.parentPath = parentPath
        self.rawName = name
    }

    /// The folder name, trimmed of surrounding whitespace.
    public var name: String {
        rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public enum ValidationError: Error, Equatable, LocalizedError {
        case emptyName
        case containsSeparator
        case reservedName
        case leadingDot

        public var errorDescription: String? {
            switch self {
            case .emptyName:         return "Enter a folder name."
            case .containsSeparator: return "The name can’t contain “/”."
            case .reservedName:      return "“.” and “..” aren’t valid names."
            case .leadingDot:        return "The name can’t start with a dot."
            }
        }
    }

    /// Validates the trimmed name against the naming rules.
    public static func validate(name rawName: String) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ValidationError.emptyName }
        guard !name.contains("/") else { throw ValidationError.containsSeparator }
        guard name != "." && name != ".." else { throw ValidationError.reservedName }
        guard !name.hasPrefix(".") else { throw ValidationError.leadingDot }
    }

    /// The validated absolute target path `<parent>/<name>`.
    public func targetPath() throws -> String {
        try Self.validate(name: rawName)
        return (parentPath as NSString).appendingPathComponent(name)
    }
}

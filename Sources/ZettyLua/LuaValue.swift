import Foundation

/// A value crossing between Lua and Swift. Tables with keys 1…n become
/// `.array`; any other table becomes `.table` with string keys.
public indirect enum LuaValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([LuaValue])
    case table([String: LuaValue])

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var array: [LuaValue]? {
        switch self {
        case .array(let values): return values
        case .table(let values) where values.isEmpty: return []
        default: return nil
        }
    }

    public subscript(key: String) -> LuaValue? {
        if case .table(let values) = self { return values[key] }
        return nil
    }

    /// Converts `JSONSerialization` output, so anything Codable reaches Lua
    /// as a plain table.
    public init(json: Any) {
        switch json {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(LuaValue.init(json:)))
        case let dictionary as [String: Any]:
            self = .table(dictionary.mapValues(LuaValue.init(json:)))
        default:
            self = .null
        }
    }

    /// Encodes `value` through JSON into a Lua table.
    public init<T: Encodable>(encoding value: T) throws {
        let data = try JSONEncoder().encode(value)
        self.init(json: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }
}

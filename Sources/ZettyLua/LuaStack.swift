import CLua
import Foundation

/// Moving values between Swift and the Lua stack. None of these raise: they
/// are called from Swift frames, which a Lua error must never cross.
extension LuaRuntime {

    static func string(_ L: OpaquePointer, at index: Int32) -> String {
        var length = 0
        guard lua_type(L, index) == LUA_TSTRING || lua_type(L, index) == LUA_TNUMBER,
              let pointer = lua_tolstring(L, index, &length) else {
            return String(cString: lua_typename(L, lua_type(L, index)))
        }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: length), as: UTF8.self)
    }

    static func value(_ L: OpaquePointer, at index: Int32, depth: Int = 0) -> LuaValue {
        let index = lua_absindex(L, index)
        switch lua_type(L, index) {
        case LUA_TNIL, LUA_TNONE:
            return .null
        case LUA_TBOOLEAN:
            return .bool(lua_toboolean(L, index) != 0)
        case LUA_TNUMBER:
            return .number(lua_tonumberx(L, index, nil))
        case LUA_TSTRING:
            return .string(string(L, at: index))
        case LUA_TTABLE:
            guard depth < 16 else { return .string("<table>") }
            var byName: [String: LuaValue] = [:]
            var byIndex: [Int: LuaValue] = [:]
            var onlyIndices = true
            lua_pushnil(L)
            while lua_next(L, index) != 0 {
                let element = value(L, at: -1, depth: depth + 1)
                if lua_type(L, -2) == LUA_TNUMBER, lua_isinteger(L, -2) != 0 {
                    let key = Int(lua_tointegerx(L, -2, nil))
                    byIndex[key] = element
                    byName[String(key)] = element
                } else if lua_type(L, -2) == LUA_TSTRING {
                    onlyIndices = false
                    byName[string(L, at: -2)] = element
                } else {
                    onlyIndices = false
                }
                lua_settop(L, -2)
            }
            if onlyIndices, !byIndex.isEmpty, byIndex.keys.sorted() == Array(1...byIndex.count) {
                return .array((1...byIndex.count).map { byIndex[$0]! })
            }
            return .table(byName)
        default:
            return .string("<\(String(cString: lua_typename(L, lua_type(L, index))))>")
        }
    }

    static func push(_ L: OpaquePointer, _ value: LuaValue) {
        switch value {
        case .null:
            lua_pushnil(L)
        case .bool(let flag):
            lua_pushboolean(L, flag ? 1 : 0)
        case .number(let number):
            if number.rounded() == number, abs(number) < 9_007_199_254_740_992 {
                lua_pushinteger(L, lua_Integer(number))
            } else {
                lua_pushnumber(L, number)
            }
        case .string(let text):
            var text = text
            text.withUTF8 { bytes in
                bytes.withMemoryRebound(to: CChar.self) { chars in
                    _ = lua_pushlstring(L, chars.baseAddress, chars.count)
                }
            }
        case .array(let elements):
            lua_createtable(L, Int32(elements.count), 0)
            for (offset, element) in elements.enumerated() {
                push(L, element)
                lua_rawseti(L, -2, lua_Integer(offset + 1))
            }
        case .table(let fields):
            lua_createtable(L, 0, Int32(fields.count))
            for (key, element) in fields {
                push(L, element)
                lua_setfield(L, -2, key)
            }
        }
    }
}

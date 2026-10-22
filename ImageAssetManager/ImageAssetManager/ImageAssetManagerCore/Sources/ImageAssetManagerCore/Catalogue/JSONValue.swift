import Foundation

/// A Sendable, Equatable JSON tree. The catalogue's `body` objects are held as
/// this so `Catalogue` can be a plain `Sendable` value, then turned back into
/// `[String: Any]` when a request is built.
public indirect enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Builds a value from `JSONSerialization` output. Returns nil for anything
    /// that is not JSON.
    public init?(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let n as NSNumber:
            // JSONSerialization hands booleans back as NSNumber; tell them apart by CFType.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            var items: [JSONValue] = []
            for element in a {
                guard let v = JSONValue(any: element) else { return nil }
                items.append(v)
            }
            self = .array(items)
        case let d as [String: Any]:
            var dict: [String: JSONValue] = [:]
            for (k, element) in d {
                guard let v = JSONValue(any: element) else { return nil }
                dict[k] = v
            }
            self = .object(dict)
        default:
            return nil
        }
    }

    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n):
            // Whole numbers go out as integers (`max_tokens: 4096`, not `4096.0`).
            if n == n.rounded(), abs(n) < 1e15 { return Int(n) }
            return n
        case .string(let s): return s
        case .array(let a): return a.map(\.anyValue)
        case .object(let o): return o.mapValues(\.anyValue)
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

extension JSONValue {
    /// Deep-merge `overlay` over `base`: objects merge key by key, anything
    /// else in `overlay` replaces what `base` held. This is how app-owned
    /// fields are written last, over the catalogue's `body` defaults.
    static func merged(_ base: [String: Any], with overlay: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in overlay {
            if let existing = result[key] as? [String: Any], let incoming = value as? [String: Any] {
                result[key] = merged(existing, with: incoming)
            } else {
                result[key] = value
            }
        }
        return result
    }
}

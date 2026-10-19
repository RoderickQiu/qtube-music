import Foundation

/// An immutable, `Sendable` JSON tree. InnerTube responses are deep, loosely-typed and change shape often, so the
/// parsers walk this value instead of decoding rigid `Codable` structs: a missing key yields `.null` rather than
/// a thrown error, and every accessor is total.
public enum QTJSON: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([QTJSON])
    case object([String: QTJSON])

    // MARK: Decoding

    /// Parses UTF-8 JSON data. `JSONSerialization` is markedly faster than `JSONDecoder` for megabyte-sized
    /// InnerTube responses; the result is converted once into this value type.
    public init(data: Data) throws {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        self.init(any: any)
    }

    /// Converts a `JSONSerialization` object graph.
    public init(any: Any) {
        switch any {
        case let d as [String: Any]:
            var o = [String: QTJSON](minimumCapacity: d.count)
            for (k, v) in d { o[k] = QTJSON(any: v) }
            self = .object(o)
        case let a as [Any]:
            self = .array(a.map(QTJSON.init(any:)))
        case let s as String:
            self = .string(s)
        case let n as NSNumber:
            // NSNumber bridges both JSON booleans and numbers; CFBoolean identifies the former.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        default:
            self = .null
        }
    }

    /// The `JSONSerialization`-compatible object graph (for request bodies and fixture writing).
    public var foundationObject: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): b
        case .number(let n): n
        case .string(let s): s
        case .array(let a): a.map(\.foundationObject)
        case .object(let o): o.mapValues(\.foundationObject)
        }
    }

    /// Serialized JSON. `sortedKeys` makes the output stable (cache keys, fixtures).
    public func data(pretty: Bool = false) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        return try JSONSerialization.data(withJSONObject: foundationObject, options: options)
    }

    // MARK: Access

    public subscript(key: String) -> QTJSON {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    public subscript(index: Int) -> QTJSON {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return .null
    }

    /// Follows a path of object keys.
    public subscript(path keys: String...) -> QTJSON {
        keys.reduce(self) { $0[$1] }
    }

    public var string: String? {
        switch self {
        case .string(let s): s
        case .number(let n): n.rounded() == n ? String(Int(n)) : String(n)
        default: nil
        }
    }

    public var int: Int? {
        switch self {
        case .number(let n): Int(exactly: n.rounded())
        case .string(let s): Int(s)
        default: nil
        }
    }

    public var double: Double? {
        switch self {
        case .number(let n): n
        case .string(let s): Double(s)
        default: nil
        }
    }

    public var bool: Bool? {
        switch self {
        case .bool(let b): b
        case .string(let s): s == "true" ? true : s == "false" ? false : nil
        default: nil
        }
    }

    /// Array elements; an empty array for anything else.
    public var array: [QTJSON] {
        if case .array(let a) = self { return a }
        return []
    }

    public var object: [String: QTJSON]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// The single key of a one-key wrapper object (`{"musicShelfRenderer": {…}}` → `musicShelfRenderer`).
    public var rendererKey: String? {
        guard case .object(let o) = self else { return nil }
        if o.count == 1 { return o.keys.first }
        return o.keys.first { $0.hasSuffix("Renderer") || $0.hasSuffix("ViewModel") }
    }

    /// The value under `rendererKey`.
    public var rendererValue: QTJSON {
        rendererKey.map { self[$0] } ?? .null
    }

    // MARK: Search

    /// Depth-first search for every value stored under `key`, at any depth (array elements in order, object
    /// members in sorted-key order). Does not descend into matched values.
    public func all(_ key: String) -> [QTJSON] {
        var out: [QTJSON] = []
        collect(key, into: &out)
        return out
    }

    /// First value under `key` at any depth. Object members are visited in sorted-key order (JSON objects are
    /// unordered), so the result is deterministic; array elements in order.
    public func first(_ key: String) -> QTJSON? {
        switch self {
        case .object(let o):
            if let v = o[key] { return v }
            for k in o.keys.sorted() {
                if let hit = o[k]!.first(key) { return hit }
            }
            return nil
        case .array(let a):
            for v in a {
                if let hit = v.first(key) { return hit }
            }
            return nil
        default:
            return nil
        }
    }

    private func collect(_ key: String, into out: inout [QTJSON]) {
        switch self {
        case .object(let o):
            if let v = o[key] {
                out.append(v)
                return
            }
            for k in o.keys.sorted() { o[k]!.collect(key, into: &out) }
        case .array(let a):
            for v in a { v.collect(key, into: &out) }
        default:
            break
        }
    }

    // MARK: Transform

    /// A copy with every object entry whose key is in `keys` removed (fixture trimming).
    public func removingKeys(_ keys: Set<String>) -> QTJSON {
        switch self {
        case .object(let o):
            var out = [String: QTJSON](minimumCapacity: o.count)
            for (k, v) in o where !keys.contains(k) { out[k] = v.removingKeys(keys) }
            return .object(out)
        case .array(let a):
            return .array(a.map { $0.removingKeys(keys) })
        default:
            return self
        }
    }

    /// Rewrites the tree bottom-up.
    public func transformed(_ transform: (QTJSON) -> QTJSON) -> QTJSON {
        switch self {
        case .object(let o):
            return transform(.object(o.mapValues { $0.transformed(transform) }))
        case .array(let a):
            return transform(.array(a.map { $0.transformed(transform) }))
        default:
            return transform(self)
        }
    }
}

extension QTJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: QTJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, QTJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, new in new }))
    }
    public init(nilLiteral: ()) { self = .null }
}

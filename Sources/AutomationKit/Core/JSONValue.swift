import Foundation

/// A Sendable, Codable JSON value used for schemas, tool arguments and raw API payloads.
public enum JSONValue: Codable, Sendable, Hashable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByFloatLiteral, ExpressibleByNilLiteral {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    public init(nilLiteral: ()) { self = .null }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var intValue: Int? { doubleValue.map { Int($0) } }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return s == "true"
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool { self == .null }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    /// Extracts the first JSON object from model text that may include prose or code fences.
    public static func extractObject(from text: String) -> JSONValue? {
        if let v = try? parse(text), v.objectValue != nil { return v }
        var cleaned = text
        if let fence = cleaned.range(of: "```") {
            cleaned = String(cleaned[fence.upperBound...])
            if cleaned.hasPrefix("json") { cleaned.removeFirst(4) }
            if let end = cleaned.range(of: "```") { cleaned = String(cleaned[..<end.lowerBound]) }
            if let v = try? parse(cleaned), v.objectValue != nil { return v }
        }
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else {
                if ch == "\"" { inString = true }
                else if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return try? parse(String(text[start...idx]))
                    }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    public func data(pretty: Bool = false) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return (try? enc.encode(self)) ?? Data("null".utf8)
    }

    public func jsonString(pretty: Bool = false) -> String {
        String(decoding: data(pretty: pretty), as: UTF8.self)
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: data())
    }

    public static func from<T: Encodable>(_ value: T) -> JSONValue {
        guard let d = try? JSONEncoder().encode(value), let v = try? parse(d) else { return .null }
        return v
    }
}

/// Builders for strict JSON schemas (every property required, no extra properties), the
/// subset both OpenAI strict mode and Anthropic structured outputs accept.
public enum Schema {
    public static func object(_ properties: [(String, JSONValue)], description: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = [
            "type": "object",
            "properties": .object(Dictionary(properties, uniquingKeysWith: { $1 })),
            "required": .array(properties.map { .string($0.0) }),
            "additionalProperties": false,
        ]
        if let description { o["description"] = .string(description) }
        return .object(o)
    }

    public static func string(_ description: String? = nil, enum values: [String]? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "string"]
        if let description { o["description"] = .string(description) }
        if let values { o["enum"] = .array(values.map { .string($0) }) }
        return .object(o)
    }

    public static func nullableString(_ description: String? = nil, enum values: [String]? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": ["string", "null"]]
        if let description { o["description"] = .string(description) }
        if let values { o["enum"] = .array(values.map { .string($0) } + [.null]) }
        return .object(o)
    }

    public static func number(_ description: String? = nil, nullable: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = ["type": nullable ? ["number", "null"] : "number"]
        if let description { o["description"] = .string(description) }
        return .object(o)
    }

    public static func integer(_ description: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "integer"]
        if let description { o["description"] = .string(description) }
        return .object(o)
    }

    public static func boolean(_ description: String? = nil, nullable: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = ["type": nullable ? ["boolean", "null"] : "boolean"]
        if let description { o["description"] = .string(description) }
        return .object(o)
    }

    public static func array(_ items: JSONValue, description: String? = nil, nullable: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = ["type": nullable ? ["array", "null"] : "array", "items": items]
        if let description { o["description"] = .string(description) }
        return .object(o)
    }

    public static func nullable(_ schema: JSONValue) -> JSONValue {
        .object(["anyOf": [schema, ["type": "null"]]])
    }
}

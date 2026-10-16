import Foundation

/// Minimal JSON tree for schemas and request bodies (Codable, Sendable).
public indirect enum JSONValue: Sendable, Equatable, Codable, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral,
                                ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .string(let s): try c.encode(s)
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int(n)) } else { try c.encode(n) }
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }

    public subscript(key: String) -> JSONValue? { if case .object(let o) = self { o[key] } else { nil } }
    public subscript(index: Int) -> JSONValue? { if case .array(let a) = self, a.indices.contains(index) { a[index] } else { nil } }
    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var int: Int? { if case .number(let n) = self { Int(n) } else { nil } }
    public var double: Double? { if case .number(let n) = self { n } else { nil } }
    public var array: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }

    public func data() throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }

    public static func parse(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data) }
    public static func parse(_ text: String) throws -> JSONValue { try parse(Data(text.utf8)) }

    public func compactString() -> String { (try? data()).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
}

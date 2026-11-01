import Foundation

/// A JSON value as the SDK sends and receives it. An object keeps its members in the order they were
/// added, and an integer stays apart from other numbers, so that the text the SDK writes is, byte for
/// byte, the text it signs (the shared vectors hold every signed payload to its bytes).
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    /// Numbers compare by value, an integer and a double alike; objects compare member by member,
    /// whatever their order.
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.double(a), .double(b)): return a == b
        case let (.int(a), .double(b)), let (.double(b), .int(a)): return Double(a) == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)): return a == b
        default: return false
        }
    }
}

/// A JSON object whose members keep the order they were added in. Setting a member already there
/// keeps its place; setting one to nil removes it.
public struct JSONObject: Equatable, Sendable, Sequence, ExpressibleByDictionaryLiteral {
    public private(set) var keys: [String] = []
    private var members: [String: JSONValue] = [:]

    public init() {}

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        for (key, value) in elements { self[key] = value }
    }

    public init(_ pairs: [(String, JSONValue)]) {
        for (key, value) in pairs { self[key] = value }
    }

    public subscript(key: String) -> JSONValue? {
        get { members[key] }
        set {
            if let value = newValue {
                if members.updateValue(value, forKey: key) == nil { keys.append(key) }
            } else if members.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    public func makeIterator() -> AnyIterator<(key: String, value: JSONValue)> {
        var index = 0
        return AnyIterator {
            guard index < keys.count else { return nil }
            let key = keys[index]
            index += 1
            return (key, members[key]!)
        }
    }

    /// This object with `other`'s members after its own, as a spread does: a member of both takes
    /// `other`'s value and keeps its place here.
    public func merging(_ other: JSONObject) -> JSONObject {
        var merged = self
        for (key, value) in other { merged[key] = value }
        return merged
    }

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        lhs.count == rhs.count && lhs.keys.allSatisfy { rhs.members[$0] == lhs.members[$0] }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(JSONObject(elements.map { ($0.0, $0.1) }))
    }
}

// MARK: - Reading

extension JSONValue {
    public var stringValue: String? { if case .string(let value) = self { return value } else { return nil } }
    /// An integer, and only an integer: `1.0` is a double.
    public var intValue: Int? { if case .int(let value) = self { return value } else { return nil } }
    /// Any number, as a double.
    public var numberValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }
    public var boolValue: Bool? { if case .bool(let value) = self { return value } else { return nil } }
    public var objectValue: JSONObject? { if case .object(let value) = self { return value } else { return nil } }
    public var arrayValue: [JSONValue]? { if case .array(let value) = self { return value } else { return nil } }
    public var isNull: Bool { if case .null = self { return true } else { return false } }

    /// A member of an object; nil for anything else.
    public subscript(key: String) -> JSONValue? { objectValue?[key] }
}

extension JSONValue {
    public init(_ value: String) { self = .string(value) }
    public init(_ value: Int) { self = .int(value) }
    public init(_ value: Bool) { self = .bool(value) }
    public init(_ object: JSONObject) { self = .object(object) }
    public init(_ strings: [String]) { self = .array(strings.map { .string($0) }) }
}

// MARK: - Writing

extension JSONValue {
    /// The value as JSON text, the way every Necessary SDK writes it: no spaces, an object's members
    /// in their order, text in UTF-8 with only `"`, `\` and the control characters escaped (never
    /// `/`), an integer in digits and any other number in its shortest form that reads back the same.
    public var encodedJSON: String {
        var text = ""
        JSONWriter.write(self, into: &text)
        return text
    }
}

extension JSONObject {
    public var encodedJSON: String { JSONValue.object(self).encodedJSON }
}

enum JSONWriter {
    static func write(_ value: JSONValue, into text: inout String) {
        switch value {
        case .null: text += "null"
        case .bool(let flag): text += flag ? "true" : "false"
        case .int(let number): text += String(number)
        case .double(let number): text += format(number)
        case .string(let string): writeString(string, into: &text)
        case .array(let items):
            text += "["
            for (index, item) in items.enumerated() {
                if index > 0 { text += "," }
                write(item, into: &text)
            }
            text += "]"
        case .object(let object):
            text += "{"
            for (index, member) in object.enumerated() {
                if index > 0 { text += "," }
                writeString(member.key, into: &text)
                text += ":"
                write(member.value, into: &text)
            }
            text += "}"
        }
    }

    static func writeString(_ string: String, into text: inout String) {
        text += "\""
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22: text += "\\\""
            case 0x5C: text += "\\\\"
            case 0x08: text += "\\b"
            case 0x09: text += "\\t"
            case 0x0A: text += "\\n"
            case 0x0C: text += "\\f"
            case 0x0D: text += "\\r"
            case 0..<0x20:
                let hex = String(scalar.value, radix: 16)
                text += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: text.unicodeScalars.append(scalar)
            }
        }
        text += "\""
    }

    /// A double as the other SDKs write it: its shortest digits, in positional notation from 1e-6 up
    /// to 1e21 -- with `.0` when it is a whole number -- and as `1.5e-7` or `1e+21` beyond.
    static func format(_ number: Double) -> String {
        guard number.isFinite else { return "null" }  // never made: see JSONValue(native:)
        if number == 0 { return number.sign == .minus ? "-0.0" : "0.0" }
        let (negative, digits, exponent) = shortestDigits(number)
        let k = digits.count, n = exponent  // the value is 0.digits * 10^n
        var body: String
        if k <= n && n <= 21 {
            body = digits + String(repeating: "0", count: n - k) + ".0"
        } else if 0 < n && n <= 21 {
            let cut = digits.index(digits.startIndex, offsetBy: n)
            body = digits[..<cut] + "." + digits[cut...]
        } else if -6 < n && n <= 0 {
            body = "0." + String(repeating: "0", count: -n) + digits
        } else {
            let e = n - 1
            let mantissa = k == 1 ? digits : String(digits.first!) + "." + digits.dropFirst()
            body = mantissa + "e" + (e >= 0 ? "+" : "-") + String(abs(e))
        }
        return (negative ? "-" : "") + body
    }

    /// The shortest digits that read back as `number`, and n with number = 0.digits * 10^n.
    private static func shortestDigits(_ number: Double) -> (Bool, String, Int) {
        // Swift's description is the shortest representation that round-trips: "123.45", "1e-07",
        // "1.5e+16", "5.0".
        var text = "\(number.magnitude)"
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: e)...]) ?? 0
            text = String(text[..<e])
        }
        var integral = text
        var fraction = ""
        if let dot = text.firstIndex(of: ".") {
            integral = String(text[..<dot])
            fraction = String(text[text.index(after: dot)...])
        }
        var digits = integral + fraction
        var n = integral.count + exponent
        while digits.hasPrefix("0") && digits.count > 1 {
            digits.removeFirst()
            n -= 1
        }
        while digits.hasSuffix("0") && digits.count > 1 { digits.removeLast() }
        return (number < 0, digits, n)
    }
}

// MARK: - Parsing

/// JSON text that is not JSON, or not the shape asked for.
public struct JSONParseError: Error, CustomStringConvertible {
    public let description: String
}

extension JSONValue {
    /// Parses JSON text strictly: one value, nothing after it.
    public init(parsing text: String) throws {
        self = try JSONValue(parsing: Data(text.utf8))
    }

    public init(parsing data: Data) throws {
        var parser = JSONParser(bytes: [UInt8](data))
        self = try parser.parseDocument()
    }
}

extension JSONObject {
    /// Parses JSON text that must hold an object.
    public init(parsing text: String) throws {
        guard case .object(let object) = try JSONValue(parsing: text) else {
            throw JSONParseError(description: "The JSON is not an object.")
        }
        self = object
    }

    public init(parsing data: Data) throws {
        guard case .object(let object) = try JSONValue(parsing: data) else {
            throw JSONParseError(description: "The JSON is not an object.")
        }
        self = object
    }
}

struct JSONParser {
    let bytes: [UInt8]
    var index = 0
    var depth = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw fail("Unexpected text after the JSON value") }
        return value
    }

    func fail(_ what: String) -> JSONParseError {
        JSONParseError(description: "\(what) at byte \(index).")
    }

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    mutating func parseValue() throws -> JSONValue {
        guard index < bytes.count else { throw fail("Unexpected end of JSON") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return .object(try parseObject())
        case UInt8(ascii: "["): return .array(try parseArray())
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return try parseNumber()
        }
    }

    mutating func expect(_ word: String) throws {
        let expected = Array(word.utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index..<index + expected.count]) == expected else { throw fail("Invalid JSON") }
        index += expected.count
    }

    mutating func nest() throws {
        depth += 1
        guard depth <= 512 else { throw fail("JSON nested too deeply") }
    }

    mutating func parseObject() throws -> JSONObject {
        try nest()
        defer { depth -= 1 }
        index += 1
        var object = JSONObject()
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return object }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw fail("Expected a member name") }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw fail("Expected ':'") }
            index += 1
            skipWhitespace()
            object[key] = try parseValue()
            skipWhitespace()
            guard index < bytes.count else { throw fail("Unexpected end of JSON") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") { index += 1; return object }
            throw fail("Expected ',' or '}'")
        }
    }

    mutating func parseArray() throws -> [JSONValue] {
        try nest()
        defer { depth -= 1 }
        index += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return items }
        while true {
            skipWhitespace()
            items.append(try parseValue())
            skipWhitespace()
            guard index < bytes.count else { throw fail("Unexpected end of JSON") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "]") { index += 1; return items }
            throw fail("Expected ',' or ']'")
        }
    }

    mutating func parseString() throws -> String {
        index += 1
        var scalars = String.UnicodeScalarView()
        var run = index
        func flush(_ end: Int) throws {
            if end > run {
                guard let text = String(bytes: bytes[run..<end], encoding: .utf8) else { throw fail("Invalid UTF-8") }
                scalars.append(contentsOf: text.unicodeScalars)
            }
        }
        while true {
            guard index < bytes.count else { throw fail("Unterminated string") }
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                try flush(index)
                index += 1
                return String(scalars)
            }
            if byte < 0x20 { throw fail("A control character in a string") }
            if byte != UInt8(ascii: "\\") { index += 1; continue }
            try flush(index)
            index += 1
            guard index < bytes.count else { throw fail("Unterminated string") }
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "\""): scalars.append("\"")
            case UInt8(ascii: "\\"): scalars.append("\\")
            case UInt8(ascii: "/"): scalars.append("/")
            case UInt8(ascii: "b"): scalars.append("\u{08}")
            case UInt8(ascii: "f"): scalars.append("\u{0C}")
            case UInt8(ascii: "n"): scalars.append("\n")
            case UInt8(ascii: "r"): scalars.append("\r")
            case UInt8(ascii: "t"): scalars.append("\t")
            case UInt8(ascii: "u"):
                var unit = try hex4()
                if (0xD800...0xDBFF).contains(unit), index + 1 < bytes.count,
                   bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                    let saved = index
                    index += 2
                    let low = try hex4()
                    if (0xDC00...0xDFFF).contains(low) {
                        unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        index = saved
                    }
                }
                // A lone surrogate cannot be held in a Swift string: it reads as U+FFFD.
                scalars.append(Unicode.Scalar(unit) ?? "\u{FFFD}")
            default:
                throw fail("Invalid escape in a string")
            }
            run = index
        }
    }

    mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw fail("Invalid \\u escape") }
        var value: UInt32 = 0
        for byte in bytes[index..<index + 4] {
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
            default: throw fail("Invalid \\u escape")
            }
            value = value << 4 | digit
        }
        index += 4
        return value
    }

    mutating func parseNumber() throws -> JSONValue {
        let start = index
        var integral = true
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count, isDigit(bytes[index]) else { throw fail("Invalid JSON") }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else {
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            integral = false
            index += 1
            guard index < bytes.count, isDigit(bytes[index]) else { throw fail("Invalid number") }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            integral = false
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count, isDigit(bytes[index]) else { throw fail("Invalid number") }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        if integral, let number = Int(text) { return .int(number) }
        guard let number = Double(text) else { throw fail("Invalid number") }
        return .double(number)
    }

    func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }
}

// MARK: - From the native side

/// A native answer holding something JSON cannot carry.
struct NativeValueError: Error {
    let description: String
}

extension JSONValue {
    /// A value the native side made -- dictionaries, arrays, strings, numbers and flags -- with each
    /// number as the kind it was made: a flag stays a flag, an integer an integer. A dictionary's
    /// members are put in the order of their names, so that two reports of the same measurements read
    /// the same.
    init(native value: Any) throws {
        switch value {
        case let text as String:
            self = .string(text)
        case is NSNull:
            self = .null
        case let items as [Any]:
            self = .array(try items.map { try JSONValue(native: $0) })
        case let members as [String: Any]:
            var object = JSONObject()
            for key in members.keys.sorted() { object[key] = try JSONValue(native: members[key]!) }
            self = .object(object)
        default:
            self = try JSONValue.nativeNumber(value)
        }
    }

    private static func nativeNumber(_ value: Any) throws -> JSONValue {
        #if canImport(Darwin)
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if CFNumberIsFloatType(number as CFNumber) {
                guard number.doubleValue.isFinite else {
                    throw NativeValueError(description: "a number that is not finite")
                }
                return .double(number.doubleValue)
            }
            if let exact = Int(exactly: number.int64Value), number.compare(NSNumber(value: exact)) == .orderedSame {
                return .int(exact)
            }
            return .double(number.doubleValue)
        }
        #endif
        switch value {
        case let flag as Bool: return .bool(flag)
        case let number as Int: return .int(number)
        case let number as Int8: return .int(Int(number))
        case let number as Int16: return .int(Int(number))
        case let number as Int32: return .int(Int(number))
        case let number as Int64: return .int(Int(number))
        case let number as UInt8: return .int(Int(number))
        case let number as UInt16: return .int(Int(number))
        case let number as UInt32: return .int(Int(number))
        case let number as UInt: if let exact = Int(exactly: number) { return .int(exact) }
        case let number as UInt64: if let exact = Int(exactly: number) { return .int(exact) }
        case let number as Double:
            guard number.isFinite else { throw NativeValueError(description: "a number that is not finite") }
            return .double(number)
        case let number as Float:
            guard number.isFinite else { throw NativeValueError(description: "a number that is not finite") }
            return .double(Double(number))
        default: break
        }
        throw NativeValueError(description: "a value of type \(type(of: value))")
    }
}

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Base64url without padding: how every binary value travels.
public func base64UrlNoPadding<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
    Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// The bytes of base64url text, with or without its padding; nil when it is not base64url.
public func base64UrlDecoded(_ text: String) -> Data? {
    var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let remainder = standard.count % 4
    if remainder == 1 { return nil }
    if remainder > 0 { standard += String(repeating: "=", count: 4 - remainder) }
    return Data(base64Encoded: standard)
}

/// 32 random bytes from the system's cryptographically secure source.
public func freshNonce() -> [UInt8] {
    var generator = SystemRandomNumberGenerator()
    return (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
}

/// The SHA-256 of text's UTF-8 bytes, in lower-case hex.
func sha256Hex(_ text: String) -> String {
    sha256Hex(Data(text.utf8))
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { byte in
        let hex = String(byte, radix: 16)
        return hex.count == 1 ? "0" + hex : hex
    }.joined()
}

/// The seconds since 1970 now, as every timestamp of the protocol counts them.
func epochSeconds() -> Int {
    Int((Date().timeIntervalSince1970).rounded(.down))
}

/// A request's path and query as a proof signs them and as the request is sent: the path before any
/// `?`, the query after it (empty when there is none), the fragment dropped; each with its percent
/// escapes normalized -- hex digits in upper case, an escaped letter, digit or `-._~` written as
/// itself -- and any character a URL cannot hold written as its UTF-8 escapes, and a path that starts
/// with `/` with its `.` and `..` segments resolved. A query is otherwise left as it was given: a
/// backend checks it as it was sent, percent-encoding and all.
public struct RequestTarget: Equatable, Sendable {
    public let path: String
    public let query: String
    /// Whether the text had a `?`, even with nothing after it.
    public let hasQuery: Bool

    public init(_ text: String) {
        var rest = Substring(text)
        if let hash = rest.firstIndex(of: "#") { rest = rest[..<hash] }
        var query: Substring = ""
        var hasQuery = false
        if let mark = rest.firstIndex(of: "?") {
            query = rest[rest.index(after: mark)...]
            rest = rest[..<mark]
            hasQuery = true
        }
        var path = RequestTarget.normalize(rest, allowed: RequestTarget.pathCharacters)
        if path.hasPrefix("/") { path = RequestTarget.removeDotSegments(path) }
        self.path = path
        self.query = RequestTarget.normalize(query, allowed: RequestTarget.queryCharacters)
        self.hasQuery = hasQuery
    }

    /// The path, with `?` and the query when there was one.
    public var pathAndQuery: String { hasQuery ? path + "?" + query : path }

    static let unreserved: Set<UInt8> = Set(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8))
    static let pathCharacters: Set<UInt8> = unreserved.union(Array("!$&'()*+,;=:@/".utf8))
    static let queryCharacters: Set<UInt8> = pathCharacters.union(Array("?".utf8))

    static func normalize(_ component: Substring, allowed: Set<UInt8>) -> String {
        let bytes = Array(component.utf8)
        var out = ""
        var index = 0
        func hexValue(_ byte: UInt8) -> Int? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return Int(byte - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return Int(byte - UInt8(ascii: "A")) + 10
            default: return nil
            }
        }
        func escape(_ byte: UInt8) -> String {
            let hex = String(byte, radix: 16, uppercase: true)
            return "%" + (hex.count == 1 ? "0" + hex : hex)
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte < 0x80, allowed.contains(byte) {
                out.unicodeScalars.append(Unicode.Scalar(byte))
                index += 1
            } else if byte == UInt8(ascii: "%") {
                if index + 2 < bytes.count,
                   let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                    let value = UInt8(high * 16 + low)
                    if unreserved.contains(value) {
                        out.unicodeScalars.append(Unicode.Scalar(value))
                    } else {
                        out += escape(value)
                    }
                    index += 3
                } else {
                    out += "%25"
                    index += 1
                }
            } else {
                // Any other byte -- a space, a character beyond ASCII -- is escaped as it is in UTF-8.
                out += escape(byte)
                index += 1
            }
        }
        return out
    }

    static func removeDotSegments(_ path: String) -> String {
        guard path.hasPrefix(".") || path.contains("/.") else { return path }
        var output: [Substring] = []
        var appendSlash = false
        for segment in path.split(separator: "/", omittingEmptySubsequences: false) {
            appendSlash = false
            if segment == ".." {
                if !output.isEmpty {
                    output.removeLast()
                    if output.isEmpty { output.append("") }
                }
                appendSlash = true
            } else if segment == "." {
                appendSlash = true
            } else {
                output.append(segment)
            }
        }
        if appendSlash { output.append("") }
        return output.joined(separator: "/")
    }
}

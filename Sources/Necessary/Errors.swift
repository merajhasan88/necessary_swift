import Foundation

/// A failure of the phone's keystore or of a prompt: `code` says which -- `STEPUP_KEY_INVALIDATED`
/// (the key can never sign again: re-enrol), `STEPUP_CANCELLED`, `STEPUP_REENROL_PENDING`,
/// `KEY_DELETE_FAILED` and the like -- and `message` says it in words, with what the system answered
/// beneath it: the keychain's `OSStatus`, or the signing error's domain, code and description.
public struct NativeKeyError: Error, CustomStringConvertible, LocalizedError {
    /// What failed, for the app to act on.
    public let code: String
    /// The same, in words.
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(message) [\(code)]" }
    public var errorDescription: String? { description }
}

/// A refusal from your backend, or a request that did not reach it: the backend's
/// `{"error": {"code", "message", "details"}}` (the integration guide, section 4), with the HTTP
/// status.
public struct APIError: Error, CustomStringConvertible, LocalizedError {
    /// The backend's message, or what went wrong on the way.
    public let message: String
    /// The HTTP status, when the backend answered.
    public let statusCode: Int?
    /// The backend's `code`: what the app acts on.
    public let code: String?
    /// The backend's `details`, such as `retry_after_seconds`.
    public let details: JSONObject?

    public init(_ message: String, statusCode: Int? = nil, code: String? = nil, details: JSONObject? = nil) {
        self.message = message
        self.statusCode = statusCode
        self.code = code
        self.details = details
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

/// A call that `DeviceTrust.reset()` or `DeviceTrust.close()` ended while it ran: what it found
/// belongs to an installation that is gone, or to a client that is closed, so nothing of it was kept.
/// After a reset, call again.
public struct InterruptedCallError: Error, CustomStringConvertible, LocalizedError {
    public let message: String

    public init(_ message: String) { self.message = message }

    public var description: String { message }
    public var errorDescription: String? { message }
}

/// An answer -- your backend's, or the phone's own native side's -- without what the protocol needs
/// in it: a challenge with no `challenge_id`, a key with no public JWK.
public struct InvalidAnswerError: Error, CustomStringConvertible, LocalizedError {
    public let message: String

    public init(_ message: String) { self.message = message }

    public var description: String { message }
    public var errorDescription: String? { message }
}

/// A call the app made in a way the SDK cannot serve: a scan for one operation with no account
/// session, the app PIN asked for while it is off.
public enum UsageError: Error, CustomStringConvertible, LocalizedError {
    case invalidArgument(String)
    case invalidState(String)

    public var description: String {
        switch self {
        case .invalidArgument(let message), .invalidState(let message): return message
        }
    }

    public var errorDescription: String? { description }
}

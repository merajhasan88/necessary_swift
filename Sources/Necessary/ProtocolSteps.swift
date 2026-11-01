import Foundation

/// What the SDK does about a refusal from your backend's API: the protocol errors of the
/// integration guide's section 4, each acted on once. Any other refusal goes to the app as it came.
public enum ProtocolStep: Equatable, Sendable {
    case askAgain
    case proveAgain
    case registerAgain
    case waitThenRetry
    case stop
}

/// The longest wait the SDK sits through before it retries a 429 itself; a longer one goes to the
/// app.
public let protocolMaxWaitSeconds = 10

/// `deviceSession`: the request ran under the session from `/v1/installations/verify`, which the SDK
/// can renew by proving its key again; an account session is the app's to renew.
public func protocolStep(for error: APIError, deviceSession: Bool) -> ProtocolStep {
    switch error.code {
    case "challenge_expired", "challenge_used", "integrity_challenge_expired", "integrity_challenge_replay":
        return .askAgain
    case "expired_token":
        return deviceSession ? .proveAgain : .stop
    case "installation_not_found":
        return .registerAgain
    default:
        return protocolWait(for: error) == nil ? .stop : .waitThenRetry
    }
}

/// How long a 429 asks the SDK to wait, in seconds, when that is short enough to wait.
public func protocolWait(for error: APIError) -> TimeInterval? {
    guard error.statusCode == 429, let seconds = error.details?["retry_after_seconds"]?.numberValue,
          seconds >= 0, seconds <= Double(protocolMaxWaitSeconds) else { return nil }
    return (seconds * 1000).rounded() / 1000
}

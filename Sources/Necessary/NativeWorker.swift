import Foundation

/// Where the native side's work runs: the Keychain, the Secure Enclave and the collection, one at a
/// time on one serial queue, off the main thread -- while a step-up prompt is open, the calls behind
/// it wait. UIKit and Core Location are read on the main thread, which never waits for this queue.
enum NativeWorker {
    static let queue = DispatchQueue(label: "com.necessarysdk.native", qos: .userInitiated)

    /// Runs `work` on the queue; a native failure comes back as the `NativeKeyError` it names, with
    /// its code untouched.
    static func run<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch let failure as InstallationKeyFailure {
                    continuation.resume(throwing: NativeKeyError(failure.code, failure.message))
                } catch let failure as NativeKeyError {
                    continuation.resume(throwing: failure)
                } catch {
                    continuation.resume(throwing: NativeKeyError("NATIVE_KEY_ERROR", "\(error)"))
                }
            }
        }
    }

    /// A native answer as JSON.
    static func object(_ value: [String: Any]) throws -> JSONObject {
        do {
            guard case .object(let object) = try JSONValue(native: value) else {
                throw NativeValueError(description: "not a dictionary")
            }
            return object
        } catch let error as NativeValueError {
            throw InvalidAnswerError("The native side answered \(error.description).")
        }
    }

    static let missingKey = NativeKeyError(
        "NATIVE_KEY_PLUGIN_MISSING", "This build has no native installation key: it runs on iOS only.")
    static let missingStepUp = NativeKeyError(
        "NATIVE_STEPUP_PLUGIN_MISSING", "This build has no native step-up key: it runs on iOS only.")
    static let missingCollector = NativeKeyError(
        "NATIVE_INTEGRITY_PLUGIN_MISSING", "This build has no native collector: it runs on iOS only.")
}

/// A failure of the native side, with the error-code vocabulary every Necessary SDK uses.
struct InstallationKeyFailure: Error {
    let code: String
    let message: String
}

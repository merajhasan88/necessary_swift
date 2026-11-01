import Foundation

/// The optional step-up key as the native side reports it. `factor`, `mode` and `windowSeconds`
/// describe what the keystore actually enforces -- on iOS read back from the key's label: a per-use
/// key, the passcode or the biometric set enrolled now asked at every signature.
public struct StepUpKeyMetadata: Equatable, Sendable {
    public let publicKey: JSONObject
    public let factor: String
    public let mode: String
    public let windowSeconds: Int
    public let securityLevel: String
    public let hardwareBacked: Bool
    public let created: Bool

    public init(publicKey: JSONObject, factor: String, mode: String, windowSeconds: Int,
                securityLevel: String, hardwareBacked: Bool, created: Bool) {
        self.publicKey = publicKey
        self.factor = factor
        self.mode = mode
        self.windowSeconds = windowSeconds
        self.securityLevel = securityLevel
        self.hardwareBacked = hardwareBacked
        self.created = created
    }

    /// `stepup_key_auth`, as the registration and a re-enrolment send it.
    public var authJSON: JSONObject {
        ["factor": .string(factor), "mode": .string(mode), "window_seconds": .int(windowSeconds)]
    }

    public var description: String {
        mode == "per_use" ? "\(factor), per-use" : "\(factor), \(windowSeconds)s hardware window"
    }

    /// The key's RFC 7638 thumbprint, the form a backend derives from the JWK.
    public var thumbprint: String { Necessary.thumbprint(of: publicKey) }

    /// What the native step-up key provider answered, held to the contract.
    public init(platform value: JSONObject) throws {
        guard let publicKey = value["public_key"]?.objectValue, let auth = value["auth"]?.objectValue else {
            throw InvalidAnswerError("The native step-up key provider returned no public key or auth.")
        }
        guard publicKey["kty"] == "EC", publicKey["crv"] == "P-256", publicKey["alg"] == "ES256",
              publicKey["x"]?.stringValue != nil, publicKey["y"]?.stringValue != nil else {
            throw InvalidAnswerError("The native step-up key provider did not return an EC P-256 public JWK.")
        }
        guard let factor = auth["factor"]?.stringValue, let mode = auth["mode"]?.stringValue,
              let window = auth["window_seconds"]?.intValue else {
            throw InvalidAnswerError("The native step-up key provider returned an invalid auth description.")
        }
        self.init(
            publicKey: publicKey, factor: factor, mode: mode, windowSeconds: window,
            securityLevel: value["security_level"]?.stringValue ?? "unknown",
            hardwareBacked: value["hardware_backed"] == .bool(true),
            created: value["created"] == .bool(true))
    }
}

/// Where a backend takes a re-enrolled step-up key by default (the integration guide, section 4).
public let stepUpReenrolPath = "/v1/installations/stepup-key"

/// How the app wants its step-up key made (the integration guide, section 3): `factor` `passcode` or
/// `biometric`; `mode` `per_use`, or `windowed` with `windowSeconds` from 1 -- iOS makes per-use keys
/// only. `reenrolPath` is where the backend takes a new key (`DeviceTrust.reenrolStepUp`).
public struct StepUpOptions: Equatable, Sendable {
    public let factor: String
    public let mode: String
    public let windowSeconds: Int
    public let reenrolPath: String

    public init(factor: String = "passcode", mode: String = "per_use", windowSeconds: Int = 0,
                reenrolPath: String = Necessary.stepUpReenrolPath) {
        self.factor = factor
        self.mode = mode
        self.windowSeconds = windowSeconds
        self.reenrolPath = reenrolPath
    }

    /// A key made with other values, or already made: whether it satisfies these options -- the same
    /// factor (a backend refuses any other), and a per-use key or a window no longer than this one. A
    /// per-use key satisfies windowed options.
    public func accepts(_ key: StepUpKeyMetadata) -> Bool {
        key.factor == factor && (key.mode == "per_use" || (mode == "windowed" && key.windowSeconds <= windowSeconds))
    }

    public var description: String {
        "\(factor), \(mode == "per_use" ? "per-use" : "\(windowSeconds)s window")"
    }
}

/// The proof a new step-up key signs at re-enrolment: the base64url of its JSON, the members in this
/// order. `nonce` is the request proof's nonce of the re-enrolment request.
public func stepUpReenrolProof(installationId: String, stepUpKeyThumbprint: String, nonce: String,
                               timestamp: Int) -> String {
    let proof: JSONObject = [
        "version": 1,
        "purpose": "stepup_reenrol",
        "installation_id": .string(installationId),
        "stepup_key_thumbprint": .string(stepUpKeyThumbprint),
        "nonce": .string(nonce),
        "timestamp": .int(timestamp),
    ]
    return base64UrlNoPadding(Array(proof.encodedJSON.utf8))
}

/// Whether a step-up key `options` do not accept is replaced before the next registration: only where
/// the new key can then be bound -- by a re-enrolment (`replaceMismatched`), which binds it with the
/// person's re-authentication, or by this installation's first registration, which binds the key it is
/// offered. A known installation's registration never binds an offered key; it only says whether it
/// matches, so replacing the key there orphans the one the backend holds.
public func replacesStepUpKey(_ key: StepUpKeyMetadata, _ options: StepUpOptions, replaceMismatched: Bool,
                              knownInstallation: Bool) -> Bool {
    !key.created && !options.accepts(key) && (replaceMismatched || !knownInstallation)
}

/// The step-up key's native side: a second key the person must unlock -- with the phone's passcode or
/// its biometrics -- for every signature.
@MainActor
public protocol StepUpKeyProvider: AnyObject {
    /// The mode the app asks for.
    var configuredMode: String { get set }

    /// The existing key as the keystore enforces it, or a new one made with these values: an existing
    /// key is never changed, so a caller that needs other values deletes it first.
    func getOrCreateKey(factor: String, mode: String, windowSeconds: Int) async throws -> StepUpKeyMetadata

    /// Shows the system's passcode (or biometric) prompt with `reason`, and answers when the person
    /// does. A cancelled prompt is `STEPUP_CANCELLED`.
    func sign(_ payloadBase64Url: String, reason: String) async throws -> String

    func deleteKey() async throws
}

/// The step-up key in the Secure Enclave, its access control asking for the passcode, or the
/// biometrics enrolled now, at every signature.
@MainActor
public final class NativeStepUpKey: StepUpKeyProvider {
    public var configuredMode: String

    #if os(iOS)
    private let manager: StepUpKeyManager

    public init(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "necessary",
                configuredMode: String = "per_use") {
        manager = StepUpKeyManager(bundleIdentifier: bundleIdentifier)
        self.configuredMode = configuredMode
    }

    public func getOrCreateKey(factor: String, mode: String, windowSeconds: Int) async throws -> StepUpKeyMetadata {
        let manager = self.manager
        let value = try await NativeWorker.run { try manager.getOrCreateKey(factor: factor) }
        return try StepUpKeyMetadata(platform: try NativeWorker.object(value))
    }

    public func sign(_ payloadBase64Url: String, reason: String) async throws -> String {
        let manager = self.manager
        // On the native queue: the call waits there while the system's prompt is up.
        let signature = try await NativeWorker.run { try manager.signPayload(payloadBase64Url, reason: reason) }
        guard !signature.isEmpty else {
            throw NativeKeyError("EMPTY_NATIVE_SIGNATURE", "The step-up key returned no signature.")
        }
        return signature
    }

    public func deleteKey() async throws {
        let manager = self.manager
        _ = try await NativeWorker.run { try manager.deleteKey() }
    }
    #else
    public init(bundleIdentifier: String = "necessary", configuredMode: String = "per_use") {
        self.configuredMode = configuredMode
    }

    public func getOrCreateKey(factor: String, mode: String, windowSeconds: Int) async throws -> StepUpKeyMetadata {
        throw NativeWorker.missingStepUp
    }
    public func sign(_ payloadBase64Url: String, reason: String) async throws -> String { throw NativeWorker.missingStepUp }
    public func deleteKey() async throws { throw NativeWorker.missingStepUp }
    #endif
}

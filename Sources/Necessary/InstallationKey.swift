import Foundation

/// The installation key as the phone's keystore reports it.
public struct NativeKeyMetadata: Equatable, Sendable {
    public let publicKey: JSONObject
    public let algorithm: String
    public let keyAlias: String
    public let provider: String
    public let securityLevel: String
    public let hardwareBacked: Bool
    public let privateKeyExportable: Bool
    public let signatureFormat: String
    public let created: Bool

    public init(publicKey: JSONObject, algorithm: String, keyAlias: String, provider: String,
                securityLevel: String, hardwareBacked: Bool, privateKeyExportable: Bool,
                signatureFormat: String, created: Bool) {
        self.publicKey = publicKey
        self.algorithm = algorithm
        self.keyAlias = keyAlias
        self.provider = provider
        self.securityLevel = securityLevel
        self.hardwareBacked = hardwareBacked
        self.privateKeyExportable = privateKeyExportable
        self.signatureFormat = signatureFormat
        self.created = created
    }

    /// What the native key provider answered, held to the contract: an EC P-256 public JWK, and every
    /// other field present with its type.
    public init(platform value: JSONObject) throws {
        guard let publicKey = value["public_key"]?.objectValue else {
            throw InvalidAnswerError("The native key provider returned no public key.")
        }
        func requiredString(_ field: String) throws -> String {
            guard let item = value[field]?.stringValue, !item.isEmpty else {
                throw InvalidAnswerError("The native key provider returned an invalid \(field).")
            }
            return item
        }
        func requiredBool(_ field: String) throws -> Bool {
            guard let item = value[field]?.boolValue else {
                throw InvalidAnswerError("The native key provider returned an invalid \(field).")
            }
            return item
        }
        guard publicKey["kty"] == "EC", publicKey["crv"] == "P-256", publicKey["alg"] == "ES256",
              publicKey["x"]?.stringValue != nil, publicKey["y"]?.stringValue != nil else {
            throw InvalidAnswerError("The native key provider did not return an EC P-256 public JWK.")
        }
        self.init(
            publicKey: publicKey,
            algorithm: try requiredString("algorithm"),
            keyAlias: try requiredString("key_alias"),
            provider: try requiredString("provider"),
            securityLevel: try requiredString("security_level"),
            hardwareBacked: try requiredBool("hardware_backed"),
            privateKeyExportable: try requiredBool("private_key_exportable"),
            signatureFormat: try requiredString("signature_format"),
            created: try requiredBool("created"))
    }
}

/// The installation key's native side: one non-exportable P-256 key per installation, made on first
/// use, which signs a base64url payload's bytes and answers an ASN.1 DER signature in base64url.
@MainActor
public protocol InstallationKeyProvider: AnyObject {
    func getOrCreateKey() async throws -> NativeKeyMetadata
    func signPayload(_ payloadBase64Url: String) async throws -> String
    func deleteKey() async throws
}

/// The installation: its ID, and the key that is its identity.
@MainActor
public final class InstallationIdentity {
    public let installationId: String
    public let nativeKey: InstallationKeyProvider
    public let metadata: NativeKeyMetadata

    public init(installationId: String, nativeKey: InstallationKeyProvider, metadata: NativeKeyMetadata) {
        self.installationId = installationId
        self.nativeKey = nativeKey
        self.metadata = metadata
    }

    public var publicKeyJSON: JSONObject { metadata.publicKey }
    public var algorithm: String { metadata.algorithm }
    public var keyAlias: String { metadata.keyAlias }
    public var provider: String { metadata.provider }
    public var securityLevel: String { metadata.securityLevel }
    public var hardwareBacked: Bool { metadata.hardwareBacked }
    public var privateKeyExportable: Bool { metadata.privateKeyExportable }
    public var signatureFormat: String { metadata.signatureFormat }
    /// A key made at this launch: a new installation, whatever was kept before belongs to the old one.
    public var createdThisLaunch: Bool { metadata.created }

    /// The key's RFC 7638 thumbprint, in hex: the SHA-256 of its members in canonical order.
    public var keyThumbprint: String { thumbprint(of: publicKeyJSON) }

    public func signPayload(_ payloadBase64Url: String) async throws -> String {
        try await nativeKey.signPayload(payloadBase64Url)
    }

    public func withInstallationId(_ canonicalInstallationId: String) -> InstallationIdentity {
        InstallationIdentity(installationId: canonicalInstallationId, nativeKey: nativeKey, metadata: metadata)
    }
}

/// RFC 7638: the SHA-256 of an EC public JWK's `crv`, `kty`, `x` and `y`, in that order, in hex.
func thumbprint(of jwk: JSONObject) -> String {
    let canonical: JSONObject = [
        "crv": jwk["crv"] ?? .null,
        "kty": "EC",
        "x": jwk["x"] ?? .null,
        "y": jwk["y"] ?? .null,
    ]
    return sha256Hex(canonical.encodedJSON)
}

/// The installation key in the Secure Enclave, or in the Keychain where the Secure Enclave declines.
@MainActor
public final class NativeInstallationKey: InstallationKeyProvider {
    #if os(iOS)
    private let manager: InstallationKeyManager

    public init(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "necessary") {
        manager = InstallationKeyManager(bundleIdentifier: bundleIdentifier)
    }

    public func getOrCreateKey() async throws -> NativeKeyMetadata {
        let manager = self.manager
        let value = try await NativeWorker.run { try manager.getOrCreateKey() }
        return try NativeKeyMetadata(platform: try NativeWorker.object(value))
    }

    public func signPayload(_ payloadBase64Url: String) async throws -> String {
        let manager = self.manager
        let signature = try await NativeWorker.run { try manager.signPayload(payloadBase64Url) }
        guard !signature.isEmpty else {
            throw NativeKeyError("EMPTY_NATIVE_SIGNATURE", "The native key provider returned no signature.")
        }
        return signature
    }

    public func deleteKey() async throws {
        let manager = self.manager
        _ = try await NativeWorker.run { try manager.deleteKey() }
    }
    #else
    public init(bundleIdentifier: String = "necessary") {}

    public func getOrCreateKey() async throws -> NativeKeyMetadata { throw NativeWorker.missingKey }
    public func signPayload(_ payloadBase64Url: String) async throws -> String { throw NativeWorker.missingKey }
    public func deleteKey() async throws { throw NativeWorker.missingKey }
    #endif
}

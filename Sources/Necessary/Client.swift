import Foundation

/// The integration guide's five calls (its section 4) over a `DeviceTrustTransport`, the two scan
/// calls each with its request proof (section 3), and the app PIN's two calls.
@MainActor
public final class DeviceTrustClient {
    public let transport: DeviceTrustTransport
    /// The platform the registration names: `ios`. Tests of a backend may name another.
    public let platform: String

    /// The app PIN's default paths (the integration guide, section 4).
    public nonisolated static let appPinPath = "/v1/account/app-pin"
    public nonisolated static let appPinProofPath = "/v1/account/app-pin/proof"

    /// The fields of the guide's registration, which `registerInstallation`'s `extra` cannot replace.
    public nonisolated static let registrationFields: Set<String> = [
        "installation_id", "platform", "public_key", "reinstall_hint", "key_security", "stepup_public_key",
        "stepup_key_auth",
    ]

    public init(transport: DeviceTrustTransport, platform: String = "ios") {
        self.transport = transport
        self.platform = platform
    }

    /// Sends `proof`'s request. `method`, `path` and `encodedBody` replace what the proof was signed
    /// for -- only to test that a backend refuses them.
    public func sendSigned(_ proof: RequestProof, method: String? = nil, path: String? = nil,
                           encodedBody: String? = nil) async throws -> JSONObject {
        let sentMethod = (method ?? proof.method).uppercased()
        return try await transport.send(
            sentMethod, path ?? proof.path,
            encodedBody: sentMethod == "GET" ? nil : (encodedBody ?? proof.encodedBody),
            bearerToken: proof.bearerToken, headers: proof.headers)
    }

    /// Signs and sends one request under `bearerToken`, its `body` as JSON. `installationId` replaces
    /// the installation the proof names, only to test that a backend refuses it.
    public func signAndSend(_ method: String, _ path: String, bearerToken: String,
                            identity: InstallationIdentity, body: JSONObject? = nil,
                            installationId: String? = nil) async throws -> JSONObject {
        try await sendSigned(
            Necessary.signRequest(
                identity: identity, method: method, path: path, bearerToken: bearerToken,
                encodedBody: (body ?? JSONObject()).encodedJSON, installationId: installationId))
    }

    /// Registers the installation's key, and with `stepUpKey` the step-up key. The answer's
    /// `installation_id` is the installation your backend holds for this key, which may not be the one
    /// proposed. `extra` adds fields of your backend's own.
    public func registerInstallation(_ identity: InstallationIdentity, _ hint: ReinstallHint?,
                                     stepUpKey: StepUpKeyMetadata? = nil,
                                     extra: JSONObject = JSONObject()) async throws -> JSONObject {
        let replaced = extra.keys.filter(DeviceTrustClient.registrationFields.contains)
        if !replaced.isEmpty {
            throw UsageError.invalidArgument(
                "extra replaces the registration fields \(replaced.joined(separator: ", ")).")
        }
        var body: JSONObject = [
            "installation_id": .string(identity.installationId),
            "platform": .string(platform),
            "public_key": .object(identity.publicKeyJSON),
            "reinstall_hint": hint.map { .object($0.json) } ?? .null,
            // What the keystore says about how the key is protected: a claim, not proof. Its value is
            // comparative -- a non-exportable hardware key cannot move into software, so the same key
            // later claiming a weaker level contradicts itself.
            "key_security": [
                "security_level": .string(identity.securityLevel),
                "hardware_backed": .bool(identity.hardwareBacked),
                "provider": .string(identity.provider),
            ],
        ]
        // The step-up key, and how the phone says it is unlocked: also a claim, recorded and compared
        // with what the backend requires.
        if let stepUpKey {
            body["stepup_public_key"] = .object(stepUpKey.publicKey)
            body["stepup_key_auth"] = .object(stepUpKey.authJSON)
        }
        return try await transport.send(
            "POST", "/v1/installations/register", encodedBody: body.merging(extra).encodedJSON,
            bearerToken: nil, headers: [:])
    }

    /// Asks for a key challenge: `challenge_id` and the `payload` to sign.
    public func createInstallationChallenge(_ installationId: String) async throws -> JSONObject {
        try await transport.send(
            "POST", "/v1/installations/challenge",
            encodedBody: (["installation_id": .string(installationId)] as JSONObject).encodedJSON,
            bearerToken: nil, headers: [:])
    }

    /// Answers a key challenge; the answer carries `device_token`, your backend's session for this
    /// installation.
    public func verifyInstallation(installationId: String, challengeId: String, payload: String,
                                   signature: String) async throws -> JSONObject {
        let body: JSONObject = [
            "installation_id": .string(installationId),
            "challenge_id": .string(challengeId),
            "payload": .string(payload),
            "signature": .string(signature),
        ]
        return try await transport.send(
            "POST", "/v1/installations/verify", encodedBody: body.encodedJSON, bearerToken: nil, headers: [:])
    }

    /// Asks for a scan under `session`: the installation's session, from `verifyInstallation` -- or,
    /// for a scan that approves one `operation` (`describeOperation`), your account session for this
    /// installation.
    public func integrityChallenge(session: String, identity: InstallationIdentity,
                                   operation: JSONObject? = nil) async throws -> ScanChallenge {
        var body = JSONObject()
        if let operation { body["operation"] = .object(operation) }
        return try ScanChallenge(json: try await signAndSend(
            "POST", "/v1/integrity/challenge", bearerToken: session, identity: identity, body: body))
    }

    /// Sends `report` under the `session` that asked for its scan. The answer is your backend's own;
    /// for a scan that approves one request it carries `report_id`, sent with that request as
    /// `X-Integrity-Report`.
    public func submitIntegrityReport(session: String, identity: InstallationIdentity,
                                      report: SignedReport) async throws -> JSONObject {
        try await signAndSend(
            "POST", "/v1/integrity/report", bearerToken: session, identity: identity, body: report.json)
    }

    /// Sets the account's app PIN under its account `session`. The backend requires the person's own
    /// re-authentication with it -- `reauthentication` carries it, the account's password for example:
    /// `["password": …]`.
    public func setAppPin(session: String, identity: InstallationIdentity, pin: String,
                          reauthentication: JSONObject = JSONObject(),
                          path: String = DeviceTrustClient.appPinPath) async throws -> JSONObject {
        var body = reauthentication
        body["pin"] = .string(pin)
        return try await signAndSend("POST", path, bearerToken: session, identity: identity, body: body)
    }

    /// Has the backend check the app `pin` for the one signed `request` -- sent once, in a signed
    /// body, never in a header -- and answers that request unlocked by its proof, valid for that
    /// request alone.
    public func proveAppPin(session: String, identity: InstallationIdentity, pin: String,
                            request: RequestProof,
                            path: String = DeviceTrustClient.appPinProofPath) async throws -> RequestProof {
        let answer = try await signAndSend(
            "POST", path, bearerToken: session, identity: identity,
            body: appPinProofRequest(pin: pin, method: request.method, path: request.path,
                                     encodedBody: request.encodedBody, nonce: request.nonce))
        guard let proof = answer["app_pin_proof"]?.stringValue, !proof.isEmpty else {
            throw APIError("The backend answered no app PIN proof.", code: "app_pin_proof_missing")
        }
        return request.withAppPinProof(proof)
    }

    public func close() { transport.close() }
}

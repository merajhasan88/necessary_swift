import Foundation

/// The person's approval of one request: the step-up key's `factor`, and `sign`, which has the
/// step-up key sign a payload -- the phone asks the person.
public struct StepUpApproval {
    public let factor: String
    public let sign: (String) async throws -> String

    public init(factor: String, sign: @escaping (String) async throws -> String) {
        self.factor = factor
        self.sign = sign
    }
}

/// What the installation key signed for one request -- with step-up, what the step-up key signed;
/// with the app PIN, the backend's proof of it; for a request a scan approves, that scan's report --
/// and the headers that carry them beside `Authorization: Bearer`.
public struct RequestProof: Equatable, Sendable {
    public let bearerToken: String
    /// The request the proof was signed for: its method, its path with the query, and the exact body.
    public let method: String
    public let path: String
    public let encodedBody: String
    /// `X-Access-Proof`: the base64url of the proof's JSON bytes.
    public let payload: String
    /// `X-Access-Signature`.
    public let signature: String
    public let timestamp: Int
    public let nonce: String
    /// `X-Step-Up-Proof` and `X-Step-Up-Signature`, for a request the person approved.
    public let stepUpPayload: String?
    public let stepUpSignature: String?
    /// `X-App-PIN-Proof`: the backend's proof that the person entered the app PIN for this request.
    public let appPinProof: String?
    /// `X-Integrity-Report`: the report of the scan made for this request alone.
    public let integrityReport: String?

    public init(bearerToken: String, method: String, path: String, encodedBody: String, payload: String,
                signature: String, timestamp: Int, nonce: String, stepUpPayload: String? = nil,
                stepUpSignature: String? = nil, appPinProof: String? = nil, integrityReport: String? = nil) {
        self.bearerToken = bearerToken
        self.method = method
        self.path = path
        self.encodedBody = encodedBody
        self.payload = payload
        self.signature = signature
        self.timestamp = timestamp
        self.nonce = nonce
        self.stepUpPayload = stepUpPayload
        self.stepUpSignature = stepUpSignature
        self.appPinProof = appPinProof
        self.integrityReport = integrityReport
    }

    public var headers: [String: String] {
        var headers = ["X-Access-Proof": payload, "X-Access-Signature": signature]
        headers["X-Step-Up-Proof"] = stepUpPayload
        headers["X-Step-Up-Signature"] = stepUpSignature
        headers["X-App-PIN-Proof"] = appPinProof
        headers["X-Integrity-Report"] = integrityReport
        return headers
    }

    /// This request, unlocked by the backend's `proof` of the app PIN.
    public func withAppPinProof(_ proof: String) -> RequestProof {
        with(appPinProof: proof, integrityReport: integrityReport)
    }

    /// This request, naming `reportId`, the scan made for it alone.
    public func withIntegrityReport(_ reportId: String) -> RequestProof {
        with(appPinProof: appPinProof, integrityReport: reportId)
    }

    private func with(appPinProof: String?, integrityReport: String?) -> RequestProof {
        RequestProof(bearerToken: bearerToken, method: method, path: path, encodedBody: encodedBody,
                     payload: payload, signature: signature, timestamp: timestamp, nonce: nonce,
                     stepUpPayload: stepUpPayload, stepUpSignature: stepUpSignature,
                     appPinProof: appPinProof, integrityReport: integrityReport)
    }
}

/// What the app sends to have its backend check the app PIN for one request: the PIN, and that
/// request as its request proof signs it -- method, path, query, the hash of the body sent and the
/// request proof's nonce.
public func appPinProofRequest(pin: String, method: String, path: String, encodedBody: String,
                               nonce: String) -> JSONObject {
    let target = RequestTarget(path)
    return [
        "pin": .string(pin),
        "request": [
            "method": .string(method.uppercased()),
            "path": .string(target.path),
            "query": .string(target.query),
            "body_sha256": .string(sha256Hex(encodedBody)),
            "nonce": .string(nonce),
        ],
    ]
}

/// The step-up proof, version 2, that the step-up key signs for one request: the base64url of its
/// JSON, the members in this order. `nonce` is the request proof's nonce for the same request, so the
/// approval is used up with it.
public func stepUpProof(installationId: String, accessToken: String, method: String, path: String,
                        encodedBody: String, factor: String, nonce: String, timestamp: Int) -> String {
    let target = RequestTarget(path)
    let proof: JSONObject = [
        "version": 2,
        "purpose": "stepup",
        "installation_id": .string(installationId),
        "access_token_sha256": .string(sha256Hex(accessToken)),
        "method": .string(method.uppercased()),
        "path": .string(target.path),
        "query": .string(target.query),
        "body_sha256": .string(sha256Hex(encodedBody)),
        "factor": .string(factor),
        "nonce": .string(nonce),
        "timestamp": .int(timestamp),
    ]
    return base64UrlNoPadding(Array(proof.encodedJSON.utf8))
}

/// Signs `method` `path` with `encodedBody` under `bearerToken`: proof version 2, which signs the
/// query string too, exactly as sent. A GET signs an empty body. With `stepUp`, the step-up key signs
/// first -- the phone asks the person -- and the request proof after, with the same nonce, so the
/// time the person takes does not count against the request proof's clock window.
/// `installationId`, `timestamp` and `nonce` replace what the request proof would otherwise carry,
/// for the shared test vectors and for testing a backend's refusals.
@MainActor
public func signRequest(identity: InstallationIdentity, method: String, path: String, bearerToken: String,
                        encodedBody: String = "", stepUp: StepUpApproval? = nil,
                        installationId: String? = nil, timestamp: Int? = nil,
                        nonce: [UInt8]? = nil) async throws -> RequestProof {
    let normalizedMethod = method.uppercased()
    let body = normalizedMethod == "GET" ? "" : encodedBody
    let nonceText = base64UrlNoPadding(nonce ?? freshNonce())
    var stepUpPayload: String?
    var stepUpSignature: String?
    if let stepUp {
        let payload = stepUpProof(
            installationId: identity.installationId, accessToken: bearerToken, method: normalizedMethod,
            path: path, encodedBody: body, factor: stepUp.factor, nonce: nonceText,
            timestamp: epochSeconds())
        stepUpPayload = payload
        stepUpSignature = try await stepUp.sign(payload)
    }
    let signedAt = timestamp ?? epochSeconds()
    let target = RequestTarget(path)
    // The members in this order: the backend checks each against the request it received, and the
    // shared vectors hold both sides to these bytes.
    let proof: JSONObject = [
        "access_token_sha256": .string(sha256Hex(bearerToken)),
        "body_sha256": .string(sha256Hex(body)),
        "installation_id": .string(installationId ?? identity.installationId),
        "method": .string(normalizedMethod),
        "nonce": .string(nonceText),
        "path": .string(target.path),
        "query": .string(target.query),
        "timestamp": .int(signedAt),
        "version": 2,
    ]
    // The key signs the exact JSON bytes this base64url value carries; the private key never leaves
    // the Secure Enclave or the Keychain.
    let payload = base64UrlNoPadding(Array(proof.encodedJSON.utf8))
    return RequestProof(
        bearerToken: bearerToken, method: normalizedMethod, path: path, encodedBody: body,
        payload: payload, signature: try await identity.signPayload(payload), timestamp: signedAt,
        nonce: nonceText, stepUpPayload: stepUpPayload, stepUpSignature: stepUpSignature)
}

/// The one request a scan is to approve, described exactly as it will be sent: what the challenge
/// names as its `operation`.
public func describeOperation(_ method: String, _ path: String, _ encodedBody: String) -> JSONObject {
    let target = RequestTarget(path)
    return [
        "method": .string(method.uppercased()),
        "path": .string(target.path),
        "query": .string(target.query),
        "body_sha256": .string(sha256Hex(encodedBody)),
    ]
}

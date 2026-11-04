// DeviceTrust against a backend that answers as the integration guide says, with the phone's native
// side replaced: what it sends, under which session, and what it does about each of the guide's
// protocol errors.
import Foundation
import XCTest
@testable import Necessary

struct Call {
    let method: String
    let path: String
    let body: JSONObject
    let bearer: String?
    let headers: [String: String]
}

/// One answer of a fake backend: an object, or a refusal thrown.
enum Answer {
    case object(JSONObject)
    case refusal(APIError)
}

/// Answers each path from its queue, the last answer repeating; a refusal in the queue is thrown.
@MainActor
class FakeBackend: DeviceTrustTransport {
    var answers: [String: [Answer]]
    var calls: [Call] = []

    init(_ answers: [String: [Answer]] = [:]) {
        var all: [String: [Answer]] = [
            "/v1/installations/register": [.object(["installation_id": "proposed-id"])],
            "/v1/installations/challenge": [.object(["challenge_id": "key-challenge", "payload": "cGF5"])],
            "/v1/installations/verify": [.object(["device_token": "installation-session"])],
            "/v1/integrity/challenge": [.object([
                "challenge_id": "scan-challenge",
                "nonce": "bm9uY2U",
                "platform": "ios",
                "required_probes": ["app_identity"],
                "optional_probes": ["location"],
            ])],
            "/v1/integrity/report": [.object(["integrity": ["report_id": "report-1"]])],
            "/v1/account/app-pin": [.object(["app_pin_set": true])],
            "/v1/account/app-pin/proof": [.object(["app_pin_proof": "pin-proof"])],
            "/v1/installations/stepup-key": [.object(["stepup_key_registered": true])],
        ]
        for (path, queue) in answers { all[path] = queue }
        self.answers = all
    }

    var paths: [String] { calls.map(\.path) }

    func send(_ method: String, _ path: String, encodedBody: String?, bearerToken: String?,
              headers: [String: String]) async throws -> JSONObject {
        let body = (encodedBody?.isEmpty ?? true) ? JSONObject() : try JSONObject(parsing: encodedBody!)
        calls.append(Call(method: method, path: path, body: body, bearer: bearerToken, headers: headers))
        var queue = answers[path]!
        let next = queue.count > 1 ? queue.removeFirst() : queue[0]
        answers[path] = queue
        switch next {
        case .object(let object): return object
        case .refusal(let error): throw error
        }
    }

    func close() {}
}

/// Answers as FakeBackend does, but holds the answer to `heldPath` until `gate` opens.
@MainActor
final class HeldBackend: FakeBackend {
    let heldPath: String
    let gate: Gate
    let asked = Gate()

    init(_ path: String, _ gate: Gate) {
        heldPath = path
        self.gate = gate
        super.init()
    }

    override func send(_ method: String, _ path: String, encodedBody: String?, bearerToken: String?,
                       headers: [String: String]) async throws -> JSONObject {
        if path == heldPath {
            asked.open()
            await gate.wait()
        }
        return try await super.send(method, path, encodedBody: encodedBody, bearerToken: bearerToken, headers: headers)
    }
}

func keyMetadata(created: Bool = false) -> NativeKeyMetadata {
    NativeKeyMetadata(
        publicKey: ["kty": "EC", "crv": "P-256", "alg": "ES256", "x": "x", "y": "y"], algorithm: "ES256",
        keyAlias: "test", provider: "SecureEnclave", securityLevel: "secure_enclave",
        hardwareBacked: true, privateKeyExportable: false, signatureFormat: "der", created: created)
}

@MainActor
final class FakeKey: InstallationKeyProvider {
    func getOrCreateKey() async throws -> NativeKeyMetadata { keyMetadata() }
    func signPayload(_ payloadBase64Url: String) async throws -> String { "signed" }
    func deleteKey() async throws {}
}

@MainActor
final class FakeStore: InstallationStore {
    var saved: String?
    var reenrolPending = false

    init() { super.init(key: FakeKey(), storage: MemoryStorage()) }

    override func loadOrCreate() async throws -> InstallationIdentity {
        InstallationIdentity(installationId: "proposed-id", nativeKey: key, metadata: keyMetadata())
    }

    override func saveInstallationId(_ installationId: String) async throws { saved = installationId }
    override func stepUpReenrolPending() async throws -> Bool { reenrolPending }
    override func setStepUpReenrolPending(_ pending: Bool) async throws { reenrolPending = pending }

    override func clear() async throws {
        saved = nil
        reenrolPending = false
    }
}

@MainActor
final class FakeCollector: IntegrityCollector {
    var enabled: [String]?

    func collect(requiredProbes: [String], challengeNonce: String, enabledMeasurements: [String],
                 optionalProbes: [String]) async throws -> JSONObject {
        enabled = enabledMeasurements
        var probes = JSONObject()
        for probe in requiredProbes { probes[probe] = ["status": "ok"] }
        return ["platform": "ios", "challenge_nonce_echo": .string(challengeNonce), "collector_version": 8,
                "probes": .object(probes)]
    }

    func requestLocationPermission() async throws -> String { "none" }
}

@MainActor
final class FakeHints: ReinstallHintReader {
    init() { super.init(platform: "ios") }
    override func read() async -> ReinstallHint? { ReinstallHint(kind: "idfv_sha256", value: "hint") }
}

@MainActor
class FakeStepUpKey: StepUpKeyProvider {
    var configuredMode = "per_use"
    let refuse: NativeKeyError?
    var reason: String?

    init(refuse: NativeKeyError? = nil) { self.refuse = refuse }

    func getOrCreateKey(factor: String, mode: String, windowSeconds: Int) async throws -> StepUpKeyMetadata {
        if let refuse { throw refuse }
        return StepUpKeyMetadata(
            publicKey: ["kty": "EC", "crv": "P-256", "alg": "ES256", "x": "sx", "y": "sy"], factor: factor,
            mode: mode, windowSeconds: windowSeconds, securityLevel: "secure_enclave",
            hardwareBacked: true, created: true)
    }

    func sign(_ payloadBase64Url: String, reason: String) async throws -> String {
        self.reason = reason
        return "approved"
    }

    func deleteKey() async throws {}
}

/// A key that died with the screen lock: its first signature fails, and a new one is made once it is
/// deleted.
@MainActor
class DyingStepUpKey: FakeStepUpKey {
    var deleted = 0

    override func sign(_ payloadBase64Url: String, reason: String) async throws -> String {
        if deleted == 0 { throw NativeKeyError("STEPUP_KEY_INVALIDATED", "the lock was removed") }
        return try await super.sign(payloadBase64Url, reason: reason)
    }

    override func deleteKey() async throws { deleted += 1 }
}

/// A key the keystore cannot vouch for (STEPUP_KEY_UNAVAILABLE) until it is replaced.
@MainActor
final class UnavailableStepUpKey: FakeStepUpKey {
    var deleted = 0

    override func getOrCreateKey(factor: String, mode: String, windowSeconds: Int) async throws -> StepUpKeyMetadata {
        if deleted == 0 {
            throw NativeKeyError("STEPUP_KEY_UNAVAILABLE", "the keystore could not say whether the key is usable")
        }
        return try await super.getOrCreateKey(factor: factor, mode: mode, windowSeconds: windowSeconds)
    }

    override func deleteKey() async throws { deleted += 1 }
}

/// A dying key whose first prompt after its replacement is cancelled.
@MainActor
final class CancelledStepUpKey: DyingStepUpKey {
    var cancelled = false

    override func sign(_ payloadBase64Url: String, reason: String) async throws -> String {
        if deleted > 0 && !cancelled {
            cancelled = true
            throw NativeKeyError("STEPUP_CANCELLED", "the person cancelled")
        }
        return try await super.sign(payloadBase64Url, reason: reason)
    }
}

/// A key the phone lost after it was registered: the next one is made new, and the person cancels its
/// first prompt.
@MainActor
final class LostStepUpKey: FakeStepUpKey {
    var asked = 0
    var cancelled = false

    override func getOrCreateKey(factor: String, mode: String, windowSeconds: Int) async throws -> StepUpKeyMetadata {
        asked += 1
        let key = try await super.getOrCreateKey(factor: factor, mode: mode, windowSeconds: windowSeconds)
        return StepUpKeyMetadata(publicKey: key.publicKey, factor: key.factor, mode: key.mode,
                                 windowSeconds: key.windowSeconds, securityLevel: key.securityLevel,
                                 hardwareBacked: key.hardwareBacked, created: asked > 1)
    }

    override func sign(_ payloadBase64Url: String, reason: String) async throws -> String {
        if asked > 1 && !cancelled {
            cancelled = true
            throw NativeKeyError("STEPUP_CANCELLED", "the person cancelled")
        }
        return try await super.sign(payloadBase64Url, reason: reason)
    }
}

/// Refuses the first key it is asked for, then makes one.
@MainActor
final class FlakyStepUpKey: FakeStepUpKey {
    var attempts = 0

    override func getOrCreateKey(factor: String, mode: String, windowSeconds: Int) async throws -> StepUpKeyMetadata {
        attempts += 1
        if attempts == 1 { throw NativeKeyError("STEPUP_NO_DEVICE_CREDENTIAL", "no screen lock yet") }
        return try await super.getOrCreateKey(factor: factor, mode: mode, windowSeconds: windowSeconds)
    }
}

@MainActor
func makeTrust(_ backend: FakeBackend, store: FakeStore? = nil, collector: FakeCollector? = nil,
               stepUpKey: FakeStepUpKey? = nil, personal: Set<PersonalMeasurement> = [],
               stepUp: StepUpOptions? = nil, appPin: AppPinOptions? = nil,
               onRegistered: ((JSONObject) async throws -> Void)? = nil) -> DeviceTrust {
    DeviceTrust(over: backend, personalMeasurements: personal, stepUp: stepUp, appPin: appPin,
                onRegistered: onRegistered, store: store ?? FakeStore(), collector: collector ?? FakeCollector(),
                hintReader: FakeHints(), stepUpKey: stepUpKey ?? FakeStepUpKey())
}

func refusal(_ code: String, _ status: Int, _ details: JSONObject? = nil) -> Answer {
    .refusal(APIError(code, statusCode: status, code: code, details: details))
}

/// One approval with the step-up key, for a payment.
@MainActor
func approve(_ trust: DeviceTrust) async throws -> RequestProof {
    try await trust.signRequest(method: "POST", path: "/v1/pay", bearer: "account-session", stepUp: true)
}

let scanChallenge: JSONObject = [
    "challenge_id": "scan-challenge", "nonce": "bm9uY2U", "platform": "ios", "required_probes": ["app_identity"],
]

@MainActor
final class DeviceTrustTests: XCTestCase {
    func testStartRegistersTheKeyWithTheStepUpKeyAndProvesIt() async throws {
        let backend = FakeBackend()
        let trust = makeTrust(backend, stepUp: StepUpOptions())
        try await trust.start()
        XCTAssertEqual(backend.paths, ["/v1/installations/register", "/v1/installations/challenge",
                                       "/v1/installations/verify"])
        let registration = backend.calls[0].body
        XCTAssertEqual(registration["installation_id"], "proposed-id")
        XCTAssertEqual(registration["platform"], "ios")
        XCTAssertEqual(registration["public_key"]?["kty"], "EC")
        XCTAssertEqual(registration["reinstall_hint"], ["kind": "idfv_sha256", "value": "hint"])
        XCTAssertEqual(registration["key_security"]?["hardware_backed"], true)
        XCTAssertEqual(registration["stepup_public_key"]?["x"], "sx")
        XCTAssertEqual(registration["stepup_key_auth"], ["factor": "passcode", "mode": "per_use", "window_seconds": 0])
        XCTAssertEqual(backend.calls[2].body["signature"], "signed")
        XCTAssertEqual(trust.installationSession, "installation-session")
    }

    func testAnAnswerThatLacksAFieldIsAnInvalidAnswerNeverACrash() async throws {
        let unverified = makeTrust(FakeBackend(["/v1/installations/verify": [.object(JSONObject())]]))
        let noToken = await thrown { try await unverified.start() }
        XCTAssertTrue(noToken is InvalidAnswerError, String(describing: noToken))
        let trust = makeTrust(FakeBackend(["/v1/integrity/challenge": [.object(["challenge_id": "scan-challenge"])]]))
        try await trust.start()
        let noNonce = await thrown { try await trust.scan() }
        XCTAssertTrue(noNonce is InvalidAnswerError, String(describing: noNonce))
    }

    func testTheInstallationTheBackendHoldsForTheKeyIsKept() async throws {
        let store = FakeStore()
        var answers: [JSONObject] = []
        let backend = FakeBackend(["/v1/installations/register": [.object(["installation_id": "held-id", "more": 1])]])
        let trust = makeTrust(backend, store: store, onRegistered: { answers.append($0) })
        try await trust.start()
        XCTAssertEqual(trust.identity?.installationId, "held-id")
        XCTAssertEqual(store.saved, "held-id")
        XCTAssertEqual(backend.calls[1].body["installation_id"], "held-id")
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers.first?["more"], 1)
    }

    func testAScanUnderTheInstallationSessionTheEnabledMeasurementsInTheGuidesOrder() async throws {
        let backend = FakeBackend()
        let collector = FakeCollector()
        let trust = makeTrust(backend, collector: collector, personal: [.mockLocation, .localAddresses])
        try await trust.start()
        let scan = try await trust.scan()
        XCTAssertEqual(collector.enabled, ["local_addresses", "mock_location"])
        let challenge = backend.calls[3]
        XCTAssertEqual(challenge.path, "/v1/integrity/challenge")
        XCTAssertEqual(challenge.bearer, "installation-session")
        XCTAssertTrue(challenge.body.isEmpty)
        XCTAssertNotNil(challenge.headers["X-Access-Proof"])
        let report = backend.calls[4]
        XCTAssertEqual(report.bearer, "installation-session")
        let signed = try decoded(report.body["report_payload"]!.stringValue!)
        XCTAssertEqual(signed["challenge_id"], "scan-challenge")
        XCTAssertEqual(signed["enabled_measurements"], ["local_addresses", "mock_location"])
        XCTAssertEqual(scan.reportId, "report-1")
    }

    func testThePersonalMeasurementsChangeWithTheAppAndTheInstallationStays() async throws {
        let backend = FakeBackend()
        let collector = FakeCollector()
        let trust = makeTrust(backend, collector: collector, stepUp: StepUpOptions())
        try await trust.start()
        _ = try await trust.scan()
        XCTAssertEqual(collector.enabled, [])
        trust.personalMeasurements = [.location, .accessibility]
        _ = try await trust.scan()
        XCTAssertEqual(collector.enabled, ["accessibility", "location"])
        XCTAssertNotNil(trust.stepUpKey)
        XCTAssertEqual(backend.paths.filter { $0.hasPrefix("/v1/installations") }.count, 3)
    }

    func testReenrolmentReplacesADeadKeyItsProofBoundToTheRequestProofsNonce() async throws {
        let backend = FakeBackend()
        let key = DyingStepUpKey()
        let trust = makeTrust(backend, stepUpKey: key, stepUp: StepUpOptions())
        try await trust.start()
        let answer = try await trust.reenrolStepUp(session: "account-session", reauthentication: ["password": "pw"])
        XCTAssertEqual(answer["stepup_key_registered"], true)
        XCTAssertEqual(key.deleted, 1)
        let call = backend.calls.last!
        XCTAssertEqual(call.path, "/v1/installations/stepup-key")
        XCTAssertEqual(call.bearer, "account-session")
        XCTAssertEqual(call.body["password"], "pw")
        XCTAssertEqual(call.body["stepup_public_key"]?["x"], "sx")
        XCTAssertEqual(call.body["stepup_key_auth"]?["factor"], "passcode")
        XCTAssertEqual(call.body["stepup_key_signature"], "approved")
        let proof = try decoded(call.body["stepup_key_proof"]!.stringValue!)
        XCTAssertEqual(proof["version"], 1)
        XCTAssertEqual(proof["purpose"], "stepup_reenrol")
        XCTAssertEqual(proof["installation_id"], "proposed-id")
        XCTAssertEqual(proof["nonce"], try decoded(call.headers["X-Access-Proof"]!)["nonce"])
        let approval = try await trust.signRequest(method: "POST", path: "/v1/pay", bearer: "account-session", stepUp: true)
        XCTAssertNotNil(approval.headers["X-Step-Up-Proof"])
    }

    func testAKeyTheKeystoreCannotVouchForIsKeptAtStartAndReplacedOnlyByAReenrolment() async throws {
        let key = UnavailableStepUpKey()
        let trust = makeTrust(FakeBackend(), stepUpKey: key, stepUp: StepUpOptions())
        try await trust.start()
        XCTAssertEqual(trust.stepUpUnavailable?.code, "STEPUP_KEY_UNAVAILABLE")
        XCTAssertEqual(key.deleted, 0)
        let answer = try await trust.reenrolStepUp(session: "account-session", reauthentication: ["password": "pw"])
        XCTAssertEqual(answer["stepup_key_registered"], true)
        XCTAssertEqual(key.deleted, 1)
        XCTAssertNil(trust.stepUpUnavailable)
    }

    func testAReenrolmentTheBackendRefusedLeavesApprovalsWaitingAcrossARestartToo() async throws {
        let backend = FakeBackend(["/v1/installations/stepup-key": [
            refusal("reauthentication_failed", 401), .object(["stepup_key_registered": true]),
        ]])
        let store = FakeStore()
        let key = DyingStepUpKey()
        func started() -> DeviceTrust { makeTrust(backend, store: store, stepUpKey: key, stepUp: StepUpOptions()) }
        let trust = started()
        try await trust.start()
        let refused = await thrown { try await trust.reenrolStepUp(session: "account-session", reauthentication: ["password": "wrong"]) }
        XCTAssertTrue(refused is APIError)
        // The dead key is gone and the new one not taken: approvals wait.
        let pending1 = await nativeCode { try await approve(trust) }
        XCTAssertEqual(pending1, "STEPUP_REENROL_PENDING")
        XCTAssertEqual(trust.stepUpUnavailable?.code, "STEPUP_REENROL_PENDING")
        let restarted = started()
        try await restarted.start()
        let pending2 = await nativeCode { try await approve(restarted) }
        XCTAssertEqual(pending2, "STEPUP_REENROL_PENDING")
        let answer = try await restarted.reenrolStepUp(session: "account-session", reauthentication: ["password": "pw"])
        XCTAssertEqual(answer["stepup_key_registered"], true)
        XCTAssertFalse(store.reenrolPending)
        XCTAssertNil(restarted.stepUpUnavailable)
        let approval = try await approve(restarted)
        XCTAssertNotNil(approval.headers["X-Step-Up-Proof"])
    }

    func testAKeyThePhoneLostMadeAgainByAReenrolmentThePersonCancelledLeavesApprovalsWaitingToo() async throws {
        let store = FakeStore()
        let trust = makeTrust(FakeBackend(), store: store, stepUpKey: LostStepUpKey(), stepUp: StepUpOptions())
        try await trust.start()
        func reenrol() async throws -> JSONObject {
            try await trust.reenrolStepUp(session: "account-session", reauthentication: ["password": "pw"])
        }
        let cancelled = await nativeCode { try await reenrol() }
        XCTAssertEqual(cancelled, "STEPUP_CANCELLED")
        let pending = await nativeCode { try await approve(trust) }
        XCTAssertEqual(pending, "STEPUP_REENROL_PENDING")
        XCTAssertTrue(store.reenrolPending)
        let answer = try await reenrol()
        XCTAssertEqual(answer["stepup_key_registered"], true)
        XCTAssertFalse(store.reenrolPending)
        let approval = try await approve(trust)
        XCTAssertNotNil(approval.headers["X-Step-Up-Proof"])
    }

    func testAReenrolmentCancelledThenLostIsFinishedByTheNextOne() async throws {
        let backend = FakeBackend(["/v1/installations/stepup-key": [
            refusal("bad_gateway", 502), .object(["stepup_key_registered": true]),
        ]])
        let store = FakeStore()
        let trust = makeTrust(backend, store: store, stepUpKey: CancelledStepUpKey(), stepUp: StepUpOptions())
        try await trust.start()
        func reenrol() async throws -> JSONObject {
            try await trust.reenrolStepUp(session: "account-session", reauthentication: ["password": "pw"])
        }
        let cancelled = await nativeCode { try await reenrol() }
        XCTAssertEqual(cancelled, "STEPUP_CANCELLED")
        let pending1 = await nativeCode { try await approve(trust) }
        XCTAssertEqual(pending1, "STEPUP_REENROL_PENDING")
        let lost = await thrown { try await reenrol() }
        XCTAssertTrue(lost is APIError)
        let pending2 = await nativeCode { try await approve(trust) }
        XCTAssertEqual(pending2, "STEPUP_REENROL_PENDING")
        XCTAssertTrue(store.reenrolPending)
        let answer = try await reenrol()
        XCTAssertEqual(answer["stepup_key_registered"], true)
        XCTAssertFalse(store.reenrolPending)
        let approval = try await approve(trust)
        XCTAssertNotNil(approval.headers["X-Step-Up-Proof"])
    }

    func testABackendThatDoesNotHoldTheKeyOfferedLeavesApprovalsWaitingOneThatDoesClearsIt() async throws {
        let backend = FakeBackend(["/v1/installations/register": [
            .object(["installation_id": "proposed-id", "stepup_key_registered": false, "stepup_key_matches": false]),
            .object(["installation_id": "proposed-id", "stepup_key_registered": true, "stepup_key_matches": true]),
        ]])
        let store = FakeStore()
        let trust = makeTrust(backend, store: store, stepUp: StepUpOptions())
        try await trust.start()
        XCTAssertEqual(trust.stepUpUnavailable?.code, "STEPUP_REENROL_PENDING")
        let pending = await nativeCode { try await approve(trust) }
        XCTAssertEqual(pending, "STEPUP_REENROL_PENDING")
        XCTAssertTrue(store.reenrolPending)
        try await trust.start()
        XCTAssertNil(trust.stepUpUnavailable)
        XCTAssertFalse(store.reenrolPending)
        let approval = try await approve(trust)
        XCTAssertNotNil(approval.headers["X-Step-Up-Proof"])
    }

    func testAKeyThePhoneCouldNotMakeAtRegistrationMadeAtTheNextStartWaitsForReenrolment() async throws {
        let trust = makeTrust(FakeBackend(), store: FakeStore(), stepUpKey: FlakyStepUpKey(), stepUp: StepUpOptions())
        try await trust.start()
        XCTAssertEqual(trust.stepUpUnavailable?.code, "STEPUP_NO_DEVICE_CREDENTIAL")
        try await trust.start()
        XCTAssertEqual(trust.stepUpUnavailable?.code, "STEPUP_REENROL_PENDING")
        let pending = await nativeCode { try await approve(trust) }
        XCTAssertEqual(pending, "STEPUP_REENROL_PENDING")
        let answer = try await trust.reenrolStepUp(session: "account-session", reauthentication: ["password": "pw"])
        XCTAssertEqual(answer["stepup_key_registered"], true)
        let approval = try await approve(trust)
        XCTAssertNotNil(approval.headers["X-Step-Up-Proof"])
    }

    func testResetDeletesTheStepUpKeyWithTheInstallation() async throws {
        let key = DyingStepUpKey()
        let trust = makeTrust(FakeBackend(), stepUpKey: key, stepUp: StepUpOptions())
        try await trust.start()
        try await trust.reset()
        XCTAssertEqual(key.deleted, 1)
        XCTAssertNil(trust.stepUpKey)
    }

    func testAResetWhileAReenrolmentWaitsForItsAnswerWaitsThenDeletesItsKeyAndMarker() async throws {
        let answer = Gate()
        let backend = HeldBackend("/v1/installations/stepup-key", answer)
        let store = FakeStore()
        let key = DyingStepUpKey()
        let trust = makeTrust(backend, store: store, stepUpKey: key, stepUp: StepUpOptions())
        try await trust.start()
        let reenrolled = Task { @MainActor in
            await thrown { try await trust.reenrolStepUp(session: "account-session", reauthentication: ["password": "pw"]) }
        }
        await backend.asked.wait()
        XCTAssertTrue(store.reenrolPending)
        XCTAssertEqual(key.deleted, 1)
        var reset = false
        let resetting = Task { @MainActor in
            try await trust.reset()
            reset = true
        }
        await pump()
        XCTAssertFalse(reset, "the reset waits for the re-enrolment")
        answer.open()
        let interrupted = await reenrolled.value
        XCTAssertTrue(interrupted is InterruptedCallError, "\(String(describing: interrupted))")
        try await resetting.value
        XCTAssertFalse(store.reenrolPending)
        XCTAssertEqual(key.deleted, 2, "the re-enrolled key deleted after it")
    }

    func testReenrolmentWithStepUpOffRefusesBeforeSending() async throws {
        let backend = FakeBackend()
        let trust = makeTrust(backend)
        try await trust.start()
        let code = await nativeCode { try await trust.reenrolStepUp(session: "account-session") }
        XCTAssertEqual(code, "STEPUP_OFF")
        XCTAssertFalse(backend.paths.contains("/v1/installations/stepup-key"))
    }

    func testAScanForOneOperationIsAskedUnderTheAccountSession() async throws {
        let backend = FakeBackend()
        let trust = makeTrust(backend)
        try await trust.start()
        let operation = describeOperation("POST", "/v1/pay", #"{"amount":5}"#)
        let refused = await thrown { try await trust.scan(operation: operation) }
        guard case .invalidArgument = refused as? UsageError else { return XCTFail("\(String(describing: refused))") }
        _ = try await trust.scan(session: "account-session", operation: operation)
        let challenge = backend.calls[3]
        XCTAssertEqual(challenge.bearer, "account-session")
        XCTAssertEqual(challenge.body["operation"], .object(operation))
        XCTAssertEqual(backend.calls[4].bearer, "account-session")
    }

    func testAnExpiredInstallationSessionIsProvedAgainOnceAnExpiredAccountSessionGoesToTheApp() async throws {
        let backend = FakeBackend(["/v1/integrity/challenge": [refusal("expired_token", 401), .object(scanChallenge)]])
        let trust = makeTrust(backend)
        try await trust.start()
        _ = try await trust.scan()
        XCTAssertEqual(Array(backend.paths[3...]), [
            "/v1/integrity/challenge", "/v1/installations/challenge", "/v1/installations/verify",
            "/v1/integrity/challenge", "/v1/integrity/report",
        ])
        let account = FakeBackend(["/v1/integrity/challenge": [refusal("expired_token", 401)]])
        let other = makeTrust(account)
        try await other.start()
        let code = await apiCode { try await other.scan(session: "account-session", operation: JSONObject()) }
        XCTAssertEqual(code, "expired_token")
        XCTAssertEqual(account.paths.filter { $0 == "/v1/installations/verify" }.count, 1)
    }

    func testALostInstallationRegistersAgainUnderTheInstallationSessionNeverAnAccountSession() async throws {
        let backend = FakeBackend(["/v1/integrity/challenge": [refusal("installation_not_found", 404), .object(scanChallenge)]])
        let trust = makeTrust(backend)
        try await trust.start()
        _ = try await trust.scan()
        XCTAssertEqual(Array(backend.paths[3..<7]), [
            "/v1/integrity/challenge", "/v1/installations/register", "/v1/installations/challenge",
            "/v1/installations/verify",
        ])
        let account = FakeBackend(["/v1/integrity/challenge": [refusal("installation_not_found", 404)]])
        let other = makeTrust(account)
        try await other.start()
        let error = await thrown { try await other.scan(session: "account-session", operation: JSONObject()) }
        XCTAssertTrue(error is APIError)
        XCTAssertEqual(account.paths.filter { $0 == "/v1/installations/register" }.count, 1)
    }

    func testAShortWaitIsWaitedOutOnceALongOneGoesToTheApp() async throws {
        let backend = FakeBackend(["/v1/integrity/report": [
            refusal("too_many", 429, ["retry_after_seconds": 0]), .object(["integrity": ["report_id": "report-2"]]),
        ]])
        let trust = makeTrust(backend)
        try await trust.start()
        let scan = try await trust.scan()
        XCTAssertEqual(scan.reportId, "report-2")
        let slow = FakeBackend(["/v1/integrity/report": [refusal("too_many", 429, ["retry_after_seconds": 30])]])
        let other = makeTrust(slow)
        try await other.start()
        let error = await thrown { try await other.scan() }
        XCTAssertTrue(error is APIError)
        XCTAssertEqual(slow.paths.filter { $0 == "/v1/integrity/report" }.count, 1)
    }

    func testARefusalOutsideTheGuideGoesToTheAppAsItCame() async throws {
        let backend = FakeBackend(["/v1/installations/register": [refusal("try_again_later", 409)]])
        let code = await apiCode { try await makeTrust(backend).start() }
        XCTAssertEqual(code, "try_again_later")
        XCTAssertEqual(backend.paths, ["/v1/installations/register"])
    }

    func testASignedRequestThePersonApprovesFirstTheRequestProofAfterOnTheSameNonce() async throws {
        let backend = FakeBackend(["/v1/pay": [.object(["paid": true])]])
        let key = FakeStepUpKey()
        let trust = makeTrust(backend, stepUpKey: key, stepUp: StepUpOptions(), appPin: AppPinOptions())
        try await trust.start()
        let proof = try await trust.signRequest(
            method: "post", path: "/v1/pay", bearer: "account-session", body: #"{"amount":5}"#, stepUp: true,
            reason: "Approve the payment", appPin: "246810", reportId: "report-1")
        let access = try decoded(proof.headers["X-Access-Proof"]!)
        let stepUp = try decoded(proof.headers["X-Step-Up-Proof"]!)
        XCTAssertEqual(stepUp["nonce"], access["nonce"])
        XCTAssertEqual(stepUp["method"], "POST")
        XCTAssertEqual(stepUp["factor"], "passcode")
        XCTAssertEqual(proof.headers["X-Step-Up-Signature"], "approved")
        XCTAssertEqual(key.reason, "Approve the payment")
        XCTAssertEqual(proof.headers["X-App-PIN-Proof"], "pin-proof")
        XCTAssertEqual(proof.headers["X-Integrity-Report"], "report-1")
        let pin = backend.calls.last!
        XCTAssertEqual(pin.path, "/v1/account/app-pin/proof")
        XCTAssertEqual(pin.bearer, "account-session")
        XCTAssertEqual(pin.body, [
            "pin": "246810",
            "request": [
                "method": "POST", "path": "/v1/pay", "query": "",
                "body_sha256": .string(sha256Hex(#"{"amount":5}"#)), "nonce": access["nonce"]!,
            ],
        ])
        try await trust.send(proof)
        XCTAssertEqual(backend.calls.last?.path, "/v1/pay")
        XCTAssertEqual(backend.calls.last?.headers, proof.headers)
    }

    func testStepUpAndTheAppPinAreOptionsOffTheyRefuse() async throws {
        let trust = makeTrust(FakeBackend())
        try await trust.start()
        let stepUp = await thrown { try await trust.signRequest(method: "POST", path: "/p", bearer: "b", stepUp: true) }
        XCTAssertTrue(stepUp is NativeKeyError)
        let pin = await thrown { try await trust.signRequest(method: "POST", path: "/p", bearer: "b", appPin: "1") }
        guard case .invalidState = pin as? UsageError else { return XCTFail("\(String(describing: pin))") }
        let set = await thrown { try await trust.setAppPin(session: "b", pin: "1") }
        guard case .invalidState = set as? UsageError else { return XCTFail("\(String(describing: set))") }
    }

    func testTheAppPinIsSetWithTheReauthenticationTheAppGives() async throws {
        let backend = FakeBackend()
        let trust = makeTrust(backend, appPin: AppPinOptions())
        try await trust.start()
        try await trust.setAppPin(session: "account-session", pin: "246810", reauthentication: ["password": "secret"])
        XCTAssertEqual(backend.calls.last?.path, "/v1/account/app-pin")
        XCTAssertEqual(backend.calls.last?.bearer, "account-session")
        XCTAssertEqual(backend.calls.last?.body, ["password": "secret", "pin": "246810"])
        XCTAssertEqual(backend.calls.last?.body.keys, ["password", "pin"])
    }

    func testAPhoneThatCannotMakeTheStepUpKeyRegistersWithoutIt() async throws {
        let backend = FakeBackend()
        let trust = makeTrust(backend, stepUpKey: FakeStepUpKey(
            refuse: NativeKeyError("STEPUP_NO_DEVICE_CREDENTIAL", "no screen lock")), stepUp: StepUpOptions())
        try await trust.start()
        XCTAssertNil(backend.calls[0].body["stepup_public_key"])
        XCTAssertEqual(trust.stepUpUnavailable?.code, "STEPUP_NO_DEVICE_CREDENTIAL")
        XCTAssertEqual(trust.installationSession, "installation-session")
    }

    func testAKeyThePhoneCouldNotMakeAtRegistrationIsNotMadeLaterForARequest() async throws {
        let backend = FakeBackend()
        let key = FlakyStepUpKey()
        let trust = makeTrust(backend, stepUpKey: key, stepUp: StepUpOptions())
        try await trust.start()
        XCTAssertNil(backend.calls[0].body["stepup_public_key"])
        let code = await nativeCode { try await trust.signRequest(method: "POST", path: "/p", bearer: "b", stepUp: true) }
        XCTAssertEqual(code, "STEPUP_NO_DEVICE_CREDENTIAL")
        XCTAssertEqual(key.attempts, 1)
    }

    func testThePersonalMeasurementsAreThePublishedContracts() throws {
        let schema = try repositoryObject("contract/report-1/android-8-ios-5/report.schema.json")
        let names = schema["properties"]?["enabled_measurements"]?["items"]?["enum"]
        XCTAssertEqual(names, JSONValue(PersonalMeasurement.allCases.map(\.wireName)))
    }
}

// The SDK end to end against a sample backend (backend/), over real HTTP with real P-256 signatures:
// only the phone's keychain and collector are replaced, by a software key and the contract's iOS
// samples -- the complete one unless a test says otherwise.
//
// Runs when NECESSARY_BACKEND_URL names a backend; skipped otherwise. The tests that need the
// backend's test controls need NECESSARY_TEST_TOKEN, the token they answer (backend/run_e2e.sh sets
// both); without it they are skipped, as for a deployed sample.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import XCTest
@testable import Necessary

private let backend = ProcessInfo.processInfo.environment["NECESSARY_BACKEND_URL"]
private let testToken = ProcessInfo.processInfo.environment["NECESSARY_TEST_TOKEN"]

/// A P-256 key in software: signs as the phone's keychain does, ECDSA over SHA-256 with an ASN.1 DER
/// signature.
private final class SoftwareKey {
    let key = P256.Signing.PrivateKey()

    var jwk: JSONObject {
        let raw = key.publicKey.rawRepresentation
        return ["kty": "EC", "crv": "P-256", "alg": "ES256", "x": .string(base64UrlNoPadding(raw.prefix(32))),
                "y": .string(base64UrlNoPadding(raw.suffix(32)))]
    }

    func sign(_ payloadBase64Url: String) throws -> String {
        base64UrlNoPadding(try key.signature(for: base64UrlDecoded(payloadBase64Url)!).derRepresentation)
    }
}

@MainActor
private final class SoftwareInstallationKey: InstallationKeyProvider {
    let key = SoftwareKey()
    var made = false

    func getOrCreateKey() async throws -> NativeKeyMetadata {
        let created = !made
        made = true
        return NativeKeyMetadata(
            publicKey: key.jwk, algorithm: "ES256", keyAlias: "software", provider: "Keychain",
            securityLevel: "software", hardwareBacked: false, privateKeyExportable: false,
            signatureFormat: "asn1_der", created: created)
    }

    func signPayload(_ payloadBase64Url: String) async throws -> String { try key.sign(payloadBase64Url) }
    func deleteKey() async throws { made = false }
}

/// The installation ID in memory, beside the software key.
@MainActor
private final class MemoryStore: InstallationStore {
    var stored: String?
    var reenrolPending = false

    init() { super.init(key: SoftwareInstallationKey(), storage: MemoryStorage()) }

    override func loadOrCreate() async throws -> InstallationIdentity {
        let metadata = try await key.getOrCreateKey()
        if stored == nil || metadata.created { stored = UUID().uuidString.lowercased() }
        return InstallationIdentity(installationId: stored!, nativeKey: key, metadata: metadata)
    }

    override func saveInstallationId(_ installationId: String) async throws { stored = installationId }
    override func stepUpReenrolPending() async throws -> Bool { reenrolPending }
    override func setStepUpReenrolPending(_ pending: Bool) async throws { reenrolPending = pending }
}

@MainActor
private final class E2EStepUpKey: StepUpKeyProvider {
    var configuredMode = "per_use"
    var key = SoftwareKey()
    /// The passcode removed: the key can no longer sign.
    var dead = false
    /// Whether the phone has a passcode: without one no key is made.
    var locked = true

    func getOrCreateKey(factor: String, mode: String, windowSeconds: Int) async throws -> StepUpKeyMetadata {
        guard locked else { throw NativeKeyError("STEPUP_NO_DEVICE_CREDENTIAL", "no passcode") }
        return StepUpKeyMetadata(publicKey: key.jwk, factor: factor, mode: mode, windowSeconds: windowSeconds,
                                 securityLevel: "software", hardwareBacked: false, created: false)
    }

    func sign(_ payloadBase64Url: String, reason: String) async throws -> String {
        if dead { throw NativeKeyError("STEPUP_KEY_INVALIDATED", "the passcode was removed") }
        return try key.sign(payloadBase64Url)
    }

    func deleteKey() async throws {
        key = SoftwareKey()
        dead = false
    }
}

private let samplesFolder = "contract/report-1/android-8-ios-5/samples"

/// One of the contract's sample reports, with its plan and how it is judged.
private func sample(_ name: String) throws -> JSONObject {
    try repositoryObject("\(samplesFolder)/\(name).json")
}

/// Answers with one of the contract's iOS samples, whatever is asked -- with the two measurements the
/// samples leave out and the backends ask for, the environment and the simulator, answered as a clean
/// phone answers them.
@MainActor
private final class SampleCollector: IntegrityCollector {
    let probes: JSONObject
    let collectorVersion: Int

    init(_ name: String = "ios-5-complete", collectorVersion: Int? = nil) throws {
        let report = try sample(name)["report"]!.objectValue!
        var probes = report["probe_results"]!.objectValue!
        if probes["environment"] == nil { probes["environment"] = ["status": "ok", "dyld_insert_libraries": ""] }
        if probes["simulator"] == nil { probes["simulator"] = ["status": "ok", "is_simulator": false, "model": "iPhone9,3"] }
        self.probes = probes
        self.collectorVersion = collectorVersion ?? report["collector_version"]!.intValue!
    }

    func collect(requiredProbes: [String], challengeNonce: String, enabledMeasurements: [String],
                 optionalProbes: [String]) async throws -> JSONObject {
        ["platform": "ios", "challenge_nonce_echo": .string(challengeNonce),
         "collector_version": .int(collectorVersion), "probes": .object(probes)]
    }

    func requestLocationPermission() async throws -> String { "none" }
}

@MainActor
private final class RandomHint: ReinstallHintReader {
    override func read() async -> ReinstallHint? {
        ReinstallHint(kind: "idfv_sha256", value: (0..<64).map { _ in String("0123456789abcdef".randomElement()!) }.joined())
    }
}

@MainActor
private func e2eTrust(stepUp: StepUpOptions? = nil, appPin: AppPinOptions? = nil, stepUpKey: E2EStepUpKey? = nil,
                      collector: SampleCollector? = nil) throws -> DeviceTrust {
    DeviceTrust(over: HTTPTransport(baseURL: backend!), stepUp: stepUp, appPin: appPin, store: MemoryStore(),
                collector: try collector ?? SampleCollector(), hintReader: RandomHint(),
                stepUpKey: stepUpKey ?? E2EStepUpKey())
}

/// A test control, and its answer.
private func control(_ path: String, _ body: JSONObject) async throws -> JSONObject {
    var request = URLRequest(url: URL(string: backend! + path)!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(testToken ?? "", forHTTPHeaderField: "X-Test-Token")
    request.httpBody = Data(body.encodedJSON.utf8)
    let (data, status): (Data, Int) = try await withCheckedThrowingContinuation { continuation in
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { return continuation.resume(throwing: error) }
            continuation.resume(returning: (data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
        }.resume()
    }
    XCTAssertEqual(status, 200, "the backend runs with --test-controls, answering NECESSARY_TEST_TOKEN")
    return try JSONObject(parsing: data)
}

/// From now on the backend holds each app PIN check once it has claimed its attempt, until released.
private func holdPinChecks() async throws { _ = try await control("/test/pin-checks", ["hold": true]) }

/// Releases the checks held -- with `fail`, as if their verifier broke.
private func releasePinChecks(fail: Bool = false) async throws {
    _ = try await control("/test/pin-checks", ["hold": false, "fail": .bool(fail)])
}

/// Waits until `count` app PIN checks are held.
private func pinChecksHeld(_ count: Int) async throws {
    for _ in 0..<200 {
        if try await control("/test/pin-checks", JSONObject())["waiting"] == .int(count) { return }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("the backend never held \(count) app PIN checks")
}

/// This backend's own sign-in, under the installation session: its account session for this
/// installation.
@MainActor
private func signIn(_ trust: DeviceTrust, password: String = "correct horse") async throws -> String {
    let body: JSONObject = ["handle": .string("e2e-\(UInt32.random(in: .min ... .max))"), "password": .string(password)]
    let proof = try await trust.signRequest(method: "POST", path: "/v1/demo/sign-in", bearer: trust.installationSession!,
                                            body: body.encodedJSON)
    return try await trust.send(proof)["account_session"]!.stringValue!
}

/// The code `body` was refused with -- and, like every refusal here, without naming the check that
/// failed: the phone is told what to do next, never what gave a request away.
@MainActor
private func refusedCode<T>(_ body: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async -> String? {
    let error = await thrown(body)
    guard let refusal = error as? APIError else {
        XCTFail("not refused: \(String(describing: error))", file: file, line: line)
        return nil
    }
    XCTAssertNil(refusal.details?["check"], "the failed check named", file: file, line: line)
    XCTAssertNil(refusal.details?["at"], "the failed check named", file: file, line: line)
    return refusal.code
}

@MainActor
final class BackendEndToEndTests: XCTestCase {
    override func setUp() async throws {
        if backend == nil { throw XCTSkip("NECESSARY_BACKEND_URL is not set") }
    }

    func requireControls() throws {
        if testToken == nil { throw XCTSkip("NECESSARY_TEST_TOKEN is not set") }
    }

    func testStartRegistersAndProvesAScanIsAnsweredWithItsReport() async throws {
        let trust = try e2eTrust()
        try await trust.start()
        let scan = try await trust.scan()
        XCTAssertFalse(scan.reportId?.isEmpty ?? true)
        XCTAssertEqual(scan.answer["integrity"]?["next"], "allow")
        // What catches hooks, gadgets and changes in memory is asked for on every scan, never left to
        // chance.
        for _ in 0..<3 {
            let required = try await trust.scan().challenge.requiredProbes
            for probe in ["dyld_images", "environment", "code_integrity", "debugger"] {
                XCTAssertTrue(required.contains(probe), "\(probe) in \(required)")
            }
        }
        // Every personal measurement is asked for, so that the example app can show each one it enables.
        XCTAssertEqual(scan.challenge.optionalProbes, PersonalMeasurement.allCases.map(\.wireName))
    }

    func testARequestCarriesItsProofOnce() async throws {
        let trust = try e2eTrust()
        try await trust.start()
        let account = try await signIn(trust)
        let proof = try await trust.signRequest(method: "POST", path: "/v1/demo/echo", bearer: account, body: #"{"hello":1}"#)
        let awaited1 = try await trust.send(proof)
        XCTAssertEqual(awaited1["done"], "/v1/demo/echo")
        let code = await refusedCode { try await trust.send(proof) }
        XCTAssertEqual(code, "proof_reused")
    }

    func testAScanForOneActionApprovesThatRequestOnce() async throws {
        let trust = try e2eTrust()
        try await trust.start()
        let account = try await signIn(trust)
        let body = #"{"amount":25,"to":"payee-7"}"#
        let scan = try await trust.scan(session: account, operation: describeOperation("POST", "/v1/demo/transfer", body))
        func transfer(_ reportId: String?) async throws -> JSONObject {
            try await trust.send(trust.signRequest(method: "POST", path: "/v1/demo/transfer", bearer: account,
                                                   body: body, reportId: reportId))
        }
        let without = await refusedCode { try await transfer(nil) }
        XCTAssertEqual(without, "needs_scan")
        let awaited2 = try await transfer(scan.reportId)
        XCTAssertEqual(awaited2["done"], "/v1/demo/transfer")
        let again = await refusedCode { try await transfer(scan.reportId) }
        XCTAssertEqual(again, "needs_scan")
    }

    func testAScanForOneActionApprovesItOnlyWhenTheBackendAllowsIt() async throws {
        let body = #"{"amount":25,"to":"payee-7"}"#
        for (name, next) in [("ios-5-complete", "allow"), ("ios-5-incomplete", "scan_again"), ("ios-5-invalid", "review")] {
            let trust = try e2eTrust(collector: try SampleCollector(name))
            try await trust.start()
            let account = try await signIn(trust)
            let scan = try await trust.scan(session: account, operation: describeOperation("POST", "/v1/demo/transfer", body))
            XCTAssertEqual(scan.answer["integrity"]?["next"], .string(next), name)
            func transfer() async throws -> JSONObject {
                try await trust.send(trust.signRequest(method: "POST", path: "/v1/demo/transfer", bearer: account,
                                                       body: body, reportId: scan.reportId))
            }
            if next == "allow" {
                let awaited3 = try await transfer()
                XCTAssertEqual(awaited3["done"], "/v1/demo/transfer", name)
            } else {
                let code = await refusedCode { try await transfer() }
                XCTAssertEqual(code, "needs_scan", name)
            }
        }
        // A collector older than the contract is refused, never read.
        let old = try e2eTrust(collector: try SampleCollector("ios-5-complete", collectorVersion: 4))
        try await old.start()
        let code = await refusedCode { try await old.scan() }
        XCTAssertEqual(code, "report_not_accepted")
    }

    func testEverySampleOfTheContractIsJudgedAsItSaysUnderItsOwnPlan() async throws {
        try requireControls()
        let samples = try contractSamples()
        XCTAssertEqual(samples.count, 11)
        for file in samples {
            let sample = try JSONObject(parsing: try Data(contentsOf: file))
            let answer = try await control("/test/judge", [
                "report": sample["report"]!, "required_probes": sample["plan"]!["required_probes"]!,
            ])
            XCTAssertEqual(answer["judged"], sample["expect"], file.lastPathComponent)
        }
    }

    func testASensitiveRequestNeedsThePersonsApprovalStepUpTheAppPinOrBoth() async throws {
        let trust = try e2eTrust(stepUp: StepUpOptions(), appPin: AppPinOptions())
        try await trust.start()
        let account = try await signIn(trust, password: "pin owner")
        func sensitive(stepUp: Bool = false, pin: String? = nil) async throws -> JSONObject {
            try await trust.send(trust.signRequest(method: "POST", path: "/v1/demo/sensitive", bearer: account,
                                                   body: #"{"payee":"payee-7"}"#, stepUp: stepUp, appPin: pin))
        }
        let none = await refusedCode { try await sensitive() }
        XCTAssertEqual(none, "needs_approval")
        let awaited4 = try await sensitive(stepUp: true)
        XCTAssertEqual(awaited4["done"], "/v1/demo/sensitive")
        let notSet = await refusedCode { try await sensitive(pin: "135790") }
        XCTAssertEqual(notSet, "app_pin_not_set")
        let set = try await trust.setAppPin(session: account, pin: "135790", reauthentication: ["password": "pin owner"])
        XCTAssertEqual(set["app_pin_set"], true)
        let wrong = await refusedCode { try await sensitive(pin: "000000") }
        XCTAssertEqual(wrong, "app_pin_invalid")
        let awaited5 = try await sensitive(pin: "135790")
        XCTAssertEqual(awaited5["done"], "/v1/demo/sensitive")
        let awaited6 = try await sensitive(stepUp: true, pin: "135790")
        XCTAssertEqual(awaited6["done"], "/v1/demo/sensitive")
    }

    func testARequestProofIsRefusedForAnotherBodyPathOrTimeAndUnderAnotherPhonesKey() async throws {
        let trust = try e2eTrust()
        try await trust.start()
        let account = try await signIn(trust)
        let body = #"{"amount":25}"#
        func echo() async throws -> RequestProof {
            try await trust.signRequest(method: "POST", path: "/v1/demo/echo", bearer: account, body: body)
        }
        let changed = await refusedCode { try await trust.client.sendSigned(try await echo(), encodedBody: #"{"amount":2500}"#) }
        XCTAssertEqual(changed, "proof_not_accepted")
        let moved = await refusedCode { try await trust.client.sendSigned(try await echo(), path: "/v1/demo/sensitive") }
        XCTAssertEqual(moved, "proof_not_accepted")
        let stale = await refusedCode {
            try await trust.send(Necessary.signRequest(
                identity: trust.identity!, method: "POST", path: "/v1/demo/echo", bearerToken: account,
                encodedBody: body, timestamp: Int(Date().timeIntervalSince1970) - 600))
        }
        XCTAssertEqual(stale, "proof_not_accepted")
        // The session copied to another phone: its key cannot sign for this installation, even naming it.
        let other = try e2eTrust()
        try await other.start()
        let copied = await refusedCode {
            try await other.send(Necessary.signRequest(
                identity: other.identity!, method: "POST", path: "/v1/demo/echo", bearerToken: account,
                encodedBody: body, installationId: trust.identity!.installationId))
        }
        XCTAssertEqual(copied, "invalid_installation_signature")
    }

    func testReenrolmentReplacesADeadStepUpKeyWithThePasswordForThatAccountAlone() async throws {
        let stepUpKey = E2EStepUpKey()
        let trust = try e2eTrust(stepUp: StepUpOptions(), stepUpKey: stepUpKey)
        try await trust.start()
        let account = try await signIn(trust, password: "key owner")
        func sensitive(_ session: String) async throws -> JSONObject {
            try await trust.send(trust.signRequest(method: "POST", path: "/v1/demo/sensitive", bearer: session,
                                                   body: #"{"payee":"payee-7"}"#, stepUp: true))
        }
        let awaited7 = try await sensitive(account)
        XCTAssertEqual(awaited7["done"], "/v1/demo/sensitive")
        // The passcode removed: the key the backend holds cannot sign.
        stepUpKey.dead = true
        let dead = await nativeCode { try await sensitive(account) }
        XCTAssertEqual(dead, "STEPUP_KEY_INVALIDATED")
        let wrong = await refusedCode {
            try await trust.reenrolStepUp(session: account, reauthentication: ["password": "wrong password"])
        }
        XCTAssertEqual(wrong, "reauthentication_failed")
        let answer = try await trust.reenrolStepUp(session: account, reauthentication: ["password": "key owner"])
        XCTAssertEqual(answer["stepup_key_registered"], true)
        let awaited8 = try await sensitive(account)
        XCTAssertEqual(awaited8["done"], "/v1/demo/sensitive")
        // Another account on the same phone gains no step-up from it.
        let another = try await signIn(trust)
        let refused = await refusedCode { try await sensitive(another) }
        XCTAssertEqual(refused, "step_up_not_accepted")
    }

    func testAnAppPinCheckSettlesAgainstThePinItCompared() async throws {
        try requireControls()
        let trust = try e2eTrust(appPin: AppPinOptions())
        try await trust.start()
        let account = try await signIn(trust, password: "pin owner")
        func setPin(_ pin: String) async throws {
            try await trust.setAppPin(session: account, pin: pin, reauthentication: ["password": "pin owner"])
        }
        func unlock(_ pin: String) async throws -> RequestProof {
            try await trust.signRequest(method: "POST", path: "/v1/demo/sensitive", bearer: account,
                                        body: #"{"payee":"payee-7"}"#, appPin: pin)
        }
        func sensitive(_ pin: String) async throws -> JSONObject { try await trust.send(try await unlock(pin)) }
        func refusedLater(_ pin: String) -> Task<String?, Never> {
            Task { @MainActor in await refusedCode { try await unlock(pin) } }
        }
        try await setPin("111111")

        // A right PIN still being checked when a new one is set unlocks nothing; asked now, the old PIN is
        // simply wrong.
        try await holdPinChecks()
        let right = refusedLater("111111")
        try await pinChecksHeld(1)
        try await setPin("222222")
        try await releasePinChecks()
        let settled = await right.value
        XCTAssertEqual(settled, "app_pin_invalid")
        let old = await refusedCode { try await sensitive("111111") }
        XCTAssertEqual(old, "app_pin_invalid")
        let awaited9 = try await sensitive("222222")
        XCTAssertEqual(awaited9["done"], "/v1/demo/sensitive")

        // Five wrong PINs being checked hold every attempt, so a sixth waits; when a new PIN is set
        // meanwhile they neither count against it nor lock it.
        try await holdPinChecks()
        let wrong = (0..<5).map { refusedLater("99999\($0)") }
        try await pinChecksHeld(5)
        let busy = await refusedCode { try await unlock("999995") }
        XCTAssertEqual(busy, "pin_busy")
        try await setPin("333333")
        try await releasePinChecks()
        for check in wrong {
            let code = await check.value
            XCTAssertEqual(code, "app_pin_invalid")
        }
        let awaited10 = try await sensitive("333333")
        XCTAssertEqual(awaited10["done"], "/v1/demo/sensitive")

        // A proof made before a new PIN no longer serves.
        let made = try await unlock("333333")
        try await setPin("444444")
        let stale = await refusedCode { try await trust.send(made) }
        XCTAssertEqual(stale, "app_pin_not_accepted")
        let awaited11 = try await sensitive("444444")
        XCTAssertEqual(awaited11["done"], "/v1/demo/sensitive")

        // A check that could not run gives its attempt back: four wrong PINs after it still leave the
        // last attempt, which two checks at once cannot both take.
        try await holdPinChecks()
        let broken = refusedLater("444444")
        try await pinChecksHeld(1)
        try await releasePinChecks(fail: true)
        let unavailable = await broken.value
        XCTAssertEqual(unavailable, "pin_unavailable")
        for i in 0..<4 {
            let code = await refusedCode { try await sensitive("00000\(i)") }
            XCTAssertEqual(code, "app_pin_invalid")
        }
        try await holdPinChecks()
        let last = Task { @MainActor in try await unlock("444444") }
        try await pinChecksHeld(1)
        let second = await refusedCode { try await unlock("444444") }
        XCTAssertEqual(second, "pin_busy")
        try await releasePinChecks()
        let awaited12 = try await trust.send(try await last.value)
        XCTAssertEqual(awaited12["done"], "/v1/demo/sensitive")
    }

    func testAPasscodeSetOnlyAfterTheInstallationWasRegisteredWaitsForReenrolmentThenApproves() async throws {
        let stepUpKey = E2EStepUpKey()
        stepUpKey.locked = false
        let trust = try e2eTrust(stepUp: StepUpOptions(), stepUpKey: stepUpKey)
        try await trust.start()
        XCTAssertEqual(trust.stepUpUnavailable?.code, "STEPUP_NO_DEVICE_CREDENTIAL")
        let account = try await signIn(trust, password: "lock owner")
        // The passcode set, the app started again: the key it makes now is not one the backend took.
        stepUpKey.locked = true
        try await trust.start()
        XCTAssertEqual(trust.stepUpUnavailable?.code, "STEPUP_REENROL_PENDING")
        func sensitive() async throws -> JSONObject {
            try await trust.send(trust.signRequest(method: "POST", path: "/v1/demo/sensitive", bearer: account,
                                                   body: #"{"payee":"payee-7"}"#, stepUp: true))
        }
        let pending = await nativeCode { try await sensitive() }
        XCTAssertEqual(pending, "STEPUP_REENROL_PENDING")
        let answer = try await trust.reenrolStepUp(session: account, reauthentication: ["password": "lock owner"])
        XCTAssertEqual(answer["stepup_key_registered"], true)
        let awaited13 = try await sensitive()
        XCTAssertEqual(awaited13["done"], "/v1/demo/sensitive")
    }

    func testTheGuidesProtocolErrorsEachActedOnOnce() async throws {
        try requireControls()
        let trust = try e2eTrust()
        try await trust.start()
        // The installation session expired: the key is proved again.
        _ = try await control("/test/expire-sessions", JSONObject())
        let awaited14 = try await trust.scan()
        XCTAssertFalse(awaited14.reportId?.isEmpty ?? true)
        // The backend lost the installation: registered again with the same key.
        _ = try await control("/test/forget", ["installation_id": .string(trust.identity!.installationId)])
        let awaited15 = try await trust.scan()
        XCTAssertFalse(awaited15.reportId?.isEmpty ?? true)
        // A key challenge expired before its answer: a new one, once.
        _ = try await control("/test/refuse-next", ["path": "/v1/installations/verify", "status": 401,
                                                    "code": "challenge_expired"])
        let awaited16 = try await trust.prove()
        XCTAssertFalse(awaited16.isEmpty)
        // A scan's challenge expired before its report: a new scan, once.
        _ = try await control("/test/refuse-next", ["path": "/v1/integrity/report", "status": 401,
                                                    "code": "integrity_challenge_expired"])
        let awaited17 = try await trust.scan()
        XCTAssertFalse(awaited17.reportId?.isEmpty ?? true)
        // A short wait is waited out, once.
        _ = try await control("/test/refuse-next", ["path": "/v1/integrity/challenge", "status": 429, "code": "busy",
                                                    "details": ["retry_after_seconds": 1]])
        let awaited18 = try await trust.scan()
        XCTAssertFalse(awaited18.reportId?.isEmpty ?? true)
        // Any other refusal reaches the app as it came.
        _ = try await control("/test/refuse-next", ["path": "/v1/integrity/challenge", "status": 403,
                                                    "code": "installation_inactive"])
        let code = await refusedCode { try await trust.scan() }
        XCTAssertEqual(code, "installation_inactive")
    }
}

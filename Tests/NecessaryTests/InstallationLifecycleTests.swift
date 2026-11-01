// The installation across a phone's life: the first start, a restart, a key the keychain lost, and a
// reinstall that kept the key but not the app's other data -- two of the SDK's calls at once, and a
// reset or a close while calls still run.
import Foundation
import XCTest
@testable import Necessary

private let storedKey = "recognition.installation_id.v2"

/// A keychain holding, or not holding, the installation key.
@MainActor
class Keystore: InstallationKeyProvider {
    var holds: Bool

    init(holds: Bool) { self.holds = holds }

    func getOrCreateKey() async throws -> NativeKeyMetadata {
        let created = !holds
        holds = true
        return keyMetadata(created: created)
    }

    func signPayload(_ payloadBase64Url: String) async throws -> String { "signed" }
    func deleteKey() async throws { holds = false }
}

/// A keychain that holds the key but cannot be read at first: the native side then answers
/// KEY_LOOKUP_FAILED and makes no key.
@MainActor
final class UnreadableKeystore: Keystore {
    var readable = false

    init() { super.init(holds: true) }

    override func getOrCreateKey() async throws -> NativeKeyMetadata {
        if !readable {
            throw NativeKeyError("KEY_LOOKUP_FAILED", "The keychain could not load the installation key (OSStatus -25308).")
        }
        return try await super.getOrCreateKey()
    }
}

/// Answers as the guide says; counts what it was asked.
@MainActor
class LifecycleBackend: DeviceTrustTransport {
    var paths: [String] = []

    func send(_ method: String, _ path: String, encodedBody: String?, bearerToken: String?,
              headers: [String: String]) async throws -> JSONObject {
        paths.append(path)
        await Task.yield()
        switch path {
        case "/v1/installations/register": return ["installation_id": "held"]
        case "/v1/installations/challenge": return ["challenge_id": "k", "payload": "cA"]
        case "/v1/installations/verify": return ["device_token": "session"]
        case "/v1/integrity/challenge":
            return ["challenge_id": "s", "nonce": "bg", "platform": "ios", "required_probes": ["app_identity"]]
        default: return ["integrity": ["report_id": "r"]]
        }
    }

    func close() {}
}

@MainActor
class LifecycleCollector: IntegrityCollector {
    func collect(requiredProbes: [String], challengeNonce: String, enabledMeasurements: [String],
                 optionalProbes: [String]) async throws -> JSONObject {
        ["platform": "ios", "challenge_nonce_echo": .string(challengeNonce), "collector_version": 8,
         "probes": ["app_identity": ["status": "ok"]]]
    }

    func requestLocationPermission() async throws -> String { "none" }
}

@MainActor
final class NoHint: ReinstallHintReader {
    override func read() async -> ReinstallHint? { nil }
}

/// A build with no native step-up key: every call says so, and a reset has none to delete.
@MainActor
final class NoStepUpKey: StepUpKeyProvider {
    var configuredMode = "per_use"
    func getOrCreateKey(factor: String, mode: String, windowSeconds: Int) async throws -> StepUpKeyMetadata {
        throw NativeWorker.missingStepUp
    }
    func sign(_ payloadBase64Url: String, reason: String) async throws -> String { throw NativeWorker.missingStepUp }
    func deleteKey() async throws { throw NativeWorker.missingStepUp }
}

/// Answers as LifecycleBackend does, but with a new installation ID and a new session each time, in
/// the order answered; and holds the answer to a path while a test says so.
@MainActor
final class LifecycleHeldBackend: LifecycleBackend {
    private var held: [String: Gate] = [:]
    private var askedGates: [String: Gate] = [:]
    private var registered = 0
    private var proved = 0

    /// The next request to `path` waits for the gate.
    func hold(_ path: String) -> Gate {
        let gate = Gate()
        held[path] = gate
        return gate
    }

    /// Opens once `path` has been asked.
    func asked(_ path: String) -> Gate {
        if let gate = askedGates[path] { return gate }
        let gate = Gate()
        askedGates[path] = gate
        return gate
    }

    override func send(_ method: String, _ path: String, encodedBody: String?, bearerToken: String?,
                       headers: [String: String]) async throws -> JSONObject {
        asked(path).open()
        if let gate = held.removeValue(forKey: path) { await gate.wait() }
        let answer = try await super.send(method, path, encodedBody: encodedBody, bearerToken: bearerToken, headers: headers)
        switch path {
        case "/v1/installations/register":
            registered += 1
            return ["installation_id": .string("held-\(registered)")]
        case "/v1/installations/verify":
            proved += 1
            return ["device_token": .string("session-\(proved)")]
        default:
            return answer
        }
    }
}

/// A collector that waits, at its first collection, until the test lets it go on; and notes what each
/// collection was allowed to measure.
@MainActor
final class HeldCollector: LifecycleCollector {
    let reached = Gate()
    let goOn = Gate()
    var enabled: [[String]] = []

    override func collect(requiredProbes: [String], challengeNonce: String, enabledMeasurements: [String],
                          optionalProbes: [String]) async throws -> JSONObject {
        enabled.append(enabledMeasurements)
        reached.open()
        await goOn.wait()
        return try await super.collect(requiredProbes: requiredProbes, challengeNonce: challengeNonce,
                                       enabledMeasurements: enabledMeasurements, optionalProbes: optionalProbes)
    }
}

/// A store that counts its loads, each taking a moment.
@MainActor
final class CountingStore: InstallationStore {
    var loads = 0

    override func loadOrCreate() async throws -> InstallationIdentity {
        loads += 1
        try await Task.sleep(nanoseconds: 5_000_000)
        return try await super.loadOrCreate()
    }
}

/// A keychain whose signatures wait, once `hold` is set, until `goOn`.
@MainActor
final class HeldSigningKeystore: Keystore {
    var hold = false
    let reached = Gate()
    let goOn = Gate()

    init() { super.init(holds: false) }

    override func signPayload(_ payloadBase64Url: String) async throws -> String {
        if hold {
            reached.open()
            await goOn.wait()
        }
        return try await super.signPayload(payloadBase64Url)
    }
}

/// A store whose first step-up marker write waits until `goOn`.
@MainActor
final class HeldMarkerStore: InstallationStore {
    let reached = Gate()
    let goOn = Gate()

    override func setStepUpReenrolPending(_ pending: Bool) async throws {
        if !reached.isOpen {
            reached.open()
            await goOn.wait()
        }
        try await super.setStepUpReenrolPending(pending)
    }
}

/// A phone that makes no step-up key; or, given `deleteFails`, one whose key the keychain will not
/// delete.
@MainActor
final class StepUpKeystore: StepUpKeyProvider {
    var configuredMode = "per_use"
    let makes: Bool
    let deleteFails: String?

    init(makes: Bool = false, deleteFails: String? = nil) {
        self.makes = makes
        self.deleteFails = deleteFails
    }

    func getOrCreateKey(factor: String, mode: String, windowSeconds: Int) async throws -> StepUpKeyMetadata {
        if !makes { throw NativeKeyError("STEPUP_NO_DEVICE_CREDENTIAL", "no passcode") }
        return StepUpKeyMetadata(
            publicKey: ["kty": "EC", "crv": "P-256", "alg": "ES256", "x": "sx", "y": "sy"], factor: factor,
            mode: mode, windowSeconds: windowSeconds, securityLevel: "secure_enclave", hardwareBacked: true,
            created: true)
    }

    func sign(_ payloadBase64Url: String, reason: String) async throws -> String { "approved" }

    func deleteKey() async throws {
        if let deleteFails { throw NativeKeyError(deleteFails, "the keychain refused") }
    }
}

@MainActor
final class InstallationLifecycleTests: XCTestCase {
    var storage: MemoryStorage!

    override func setUp() async throws {
        storage = MemoryStorage()
    }

    func storedId() -> String? { storage.values[storedKey] }

    func store(_ key: InstallationKeyProvider) -> InstallationStore {
        InstallationStore(key: key, storage: storage)
    }

    func trust(_ backend: LifecycleBackend, store: InstallationStore, collector: LifecycleCollector? = nil,
               stepUp: StepUpOptions? = nil, stepUpKey: StepUpKeyProvider? = nil) -> DeviceTrust {
        DeviceTrust(over: backend, stepUp: stepUp, store: store, collector: collector ?? LifecycleCollector(),
                    hintReader: NoHint(), stepUpKey: stepUpKey ?? NoStepUpKey())
    }

    func testTheFirstStartMakesTheKeyAndAnIdARestartFindsBoth() async throws {
        let keystore = Keystore(holds: false)
        let first = try await store(keystore).loadOrCreate()
        XCTAssertTrue(first.createdThisLaunch)
        XCTAssertEqual(storedId(), first.installationId)
        let restarted = try await store(keystore).loadOrCreate()
        XCTAssertFalse(restarted.createdThisLaunch)
        XCTAssertEqual(restarted.installationId, first.installationId)
    }

    func testAKeyTheKeychainLostIsANewInstallationUnderANewId() async throws {
        storage = MemoryStorage([storedKey: "old-installation"])
        let identity = try await store(Keystore(holds: false)).loadOrCreate()
        XCTAssertTrue(identity.createdThisLaunch)
        XCTAssertNotEqual(identity.installationId, "old-installation")
        XCTAssertEqual(storedId(), identity.installationId)
    }

    func testAKeyKeptWithoutItsIdProposesANewOneAndKeepsTheOneTheBackendHolds() async throws {
        let kept = store(Keystore(holds: true))
        let proposed = try await kept.loadOrCreate()
        XCTAssertFalse(proposed.createdThisLaunch)
        let trust = trust(LifecycleBackend(), store: kept)
        try await trust.start()
        XCTAssertEqual(trust.identity?.installationId, "held")
        XCTAssertEqual(storedId(), "held")
    }

    func testAKeychainThatCannotBeReadLeavesTheInstallationAsItWas() async throws {
        storage = MemoryStorage([storedKey: "kept-installation"])
        let keystore = UnreadableKeystore()
        let backend = LifecycleBackend()
        let trust = trust(backend, store: store(keystore))
        let code = await nativeCode { try await trust.start() }
        XCTAssertEqual(code, "KEY_LOOKUP_FAILED")
        XCTAssertEqual(backend.paths, [])
        XCTAssertEqual(storedId(), "kept-installation")
        XCTAssertTrue(keystore.holds)
        keystore.readable = true
        let again = try await store(keystore).loadOrCreate()
        XCTAssertFalse(again.createdThisLaunch)
        XCTAssertEqual(again.installationId, "kept-installation")
    }

    func testResetDeletesTheKeyAndTheIdTheNextStartIsANewInstallation() async throws {
        let keystore = Keystore(holds: false)
        let trust = trust(LifecycleBackend(), store: store(keystore))
        try await trust.start()
        try await trust.reset()
        XCTAssertFalse(keystore.holds)
        XCTAssertNil(storedId())
        XCTAssertNil(trust.identity)
        XCTAssertNil(trust.installationSession)
        let next = try await trust.loadIdentity()
        XCTAssertTrue(next.createdThisLaunch)
    }

    func testTwoCallsOfOneKindAtOnceShareOneRunOtherScansRunApart() async throws {
        let backend = LifecycleBackend()
        let trust = trust(backend, store: store(Keystore(holds: false)))
        async let first = trust.start()
        async let second = trust.start()
        let started = try await [first, second]
        XCTAssertTrue(started[0] === started[1])
        XCTAssertEqual(backend.paths.filter { $0 == "/v1/installations/register" }.count, 1)
        XCTAssertEqual(backend.paths.filter { $0 == "/v1/installations/verify" }.count, 1)

        backend.paths.removeAll()
        let pay = describeOperation("POST", "/v1/pay", "{}")
        let payee = describeOperation("POST", "/v1/payee", "{}")
        async let a = trust.scan()
        async let b = trust.scan()
        async let c = trust.scan(session: "account", operation: pay)
        async let d = trust.scan(session: "account", operation: payee)
        let scans = try await [a, b, c, d]
        XCTAssertTrue(scans[0] === scans[1])
        XCTAssertEqual(backend.paths.filter { $0 == "/v1/integrity/challenge" }.count, 3)
        XCTAssertEqual(backend.paths.filter { $0 == "/v1/integrity/report" }.count, 3)
    }

    func testAResetWhileStartWaitsForItsKeyChallengesAnswerKeepsTheOldAnswerNowhere() async throws {
        let backend = LifecycleHeldBackend()
        let trust = trust(backend, store: store(Keystore(holds: false)))
        let verify = backend.hold("/v1/installations/verify")
        let old = Task { @MainActor in await thrown { try await trust.start() } }
        await backend.asked("/v1/installations/verify").wait()
        try await trust.reset()
        let fresh = try await trust.start()
        XCTAssertEqual(trust.installationSession, "session-1")
        verify.open()
        let interrupted = await old.value
        XCTAssertTrue(interrupted is InterruptedCallError, "\(String(describing: interrupted))")
        XCTAssertEqual(trust.installationSession, "session-1")
        XCTAssertEqual(trust.identity?.installationId, fresh.installationId)
        XCTAssertEqual(storedId(), fresh.installationId)
    }

    func testAResetWhileStartWaitsForItsRegistrationNeverKeepsTheIdTheOldAnswerNames() async throws {
        let backend = LifecycleHeldBackend()
        let trust = trust(backend, store: store(Keystore(holds: false)))
        let register = backend.hold("/v1/installations/register")
        let old = Task { @MainActor in await thrown { try await trust.start() } }
        await backend.asked("/v1/installations/register").wait()
        try await trust.reset()
        let fresh = try await trust.start()
        XCTAssertEqual(fresh.installationId, "held-1")
        register.open()
        let interrupted = await old.value
        XCTAssertTrue(interrupted is InterruptedCallError, "\(String(describing: interrupted))")
        XCTAssertEqual(trust.identity?.installationId, "held-1")
        XCTAssertEqual(storedId(), "held-1")
    }

    func testAResetWhileTheOldRegistrationWritesTheStepUpMarkerWaitsForTheWrite() async throws {
        let marker = HeldMarkerStore(key: Keystore(holds: false), storage: storage)
        let trust = trust(LifecycleBackend(), store: marker, stepUp: StepUpOptions(), stepUpKey: StepUpKeystore())
        let old = Task { @MainActor in await thrown { try await trust.start() } }
        await marker.reached.wait()
        var reset = false
        let resetting = Task { @MainActor in
            try await trust.reset()
            reset = true
        }
        await pump()
        XCTAssertFalse(reset, "the reset waits for the write in flight")
        marker.goOn.open()
        try await resetting.value
        let interrupted = await old.value
        XCTAssertTrue(interrupted is InterruptedCallError, "\(String(describing: interrupted))")
        let pending = try await marker.stepUpReenrolPending()
        XCTAssertFalse(pending)
    }

    func testAResetWhileARequestIsSignedNeverHandsOutTheProof() async throws {
        let key = HeldSigningKeystore()
        let trust = trust(LifecycleBackend(), store: store(key))
        try await trust.start()
        key.hold = true
        let signing = Task { @MainActor in
            await thrown { try await trust.signRequest(method: "POST", path: "/v1/pay", bearer: "session") }
        }
        await key.reached.wait()
        try await trust.reset()
        key.goOn.open()
        let interrupted = await signing.value
        XCTAssertTrue(interrupted is InterruptedCallError, "\(String(describing: interrupted))")
    }

    func testAStepUpKeyTheKeychainWillNotDeleteFailsTheResetTheInstallationGoneAllTheSame() async throws {
        let trust = trust(LifecycleBackend(), store: store(Keystore(holds: false)), stepUp: StepUpOptions(),
                          stepUpKey: StepUpKeystore(makes: true, deleteFails: "KEY_DELETE_FAILED"))
        try await trust.start()
        let code = await nativeCode { try await trust.reset() }
        XCTAssertEqual(code, "KEY_DELETE_FAILED")
        XCTAssertNil(trust.identity)
        XCTAssertNil(storedId())
        let plain = self.trust(LifecycleBackend(), store: store(Keystore(holds: false)), stepUp: StepUpOptions(),
                               stepUpKey: StepUpKeystore(deleteFails: "NATIVE_STEPUP_PLUGIN_MISSING"))
        try await plain.start()
        try await plain.reset()
    }

    func testAResetWhileAScanCollectsNeverSendsItsReport() async throws {
        let backend = LifecycleBackend()
        let collector = HeldCollector()
        let trust = trust(backend, store: store(Keystore(holds: false)), collector: collector)
        try await trust.start()
        let scan = Task { @MainActor in await thrown { try await trust.scan() } }
        await collector.reached.wait()
        try await trust.reset()
        collector.goOn.open()
        let interrupted = await scan.value
        XCTAssertTrue(interrupted is InterruptedCallError, "\(String(describing: interrupted))")
        XCTAssertFalse(backend.paths.contains("/v1/integrity/report"))
    }

    func testCloseWhileStartRunsKeepsNothing() async throws {
        let backend = LifecycleHeldBackend()
        let trust = trust(backend, store: store(Keystore(holds: false)))
        let verify = backend.hold("/v1/installations/verify")
        let started = Task { @MainActor in await thrown { try await trust.start() } }
        await backend.asked("/v1/installations/verify").wait()
        trust.close()
        verify.open()
        let interrupted = await started.value
        XCTAssertTrue(interrupted is InterruptedCallError, "\(String(describing: interrupted))")
        XCTAssertNil(trust.installationSession)
    }

    func testTheStoreItselfAskedTwiceAtOnceMakesOneIdForOneKey() async throws {
        let shared = store(Keystore(holds: false))
        async let first = shared.loadOrCreate()
        async let second = shared.loadOrCreate()
        let loaded = try await [first, second]
        XCTAssertEqual(loaded[0].installationId, loaded[1].installationId)
        XCTAssertEqual(storedId(), loaded[0].installationId)
    }

    func testTwoFirstLoadsAtOnceLoadOnce() async throws {
        let counting = CountingStore(key: Keystore(holds: false), storage: storage)
        let trust = trust(LifecycleBackend(), store: counting)
        async let first = trust.loadIdentity()
        async let second = trust.loadIdentity()
        let loaded = try await [first, second]
        XCTAssertTrue(loaded[0] === loaded[1])
        XCTAssertEqual(counting.loads, 1)
        XCTAssertEqual(storedId(), loaded[0].installationId)
    }

    func testAScanAskedAfterThePersonalMeasurementsChangedNeverJoinsOneAskedBefore() async throws {
        let collector = HeldCollector()
        let trust = trust(LifecycleBackend(), store: store(Keystore(holds: false)), collector: collector)
        try await trust.start()
        let before = Task { @MainActor in try await trust.scan() }
        await collector.reached.wait()
        trust.personalMeasurements = [.location]
        let after = Task { @MainActor in try await trust.scan() }
        await pump()
        collector.goOn.open()
        let scans = try await [before.value, after.value]
        XCTAssertFalse(scans[0] === scans[1])
        XCTAssertEqual(collector.enabled, [[], ["location"]])
        XCTAssertEqual(scans[1].report.report["enabled_measurements"], ["location"])
    }
}

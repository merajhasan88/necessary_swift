import Foundation

/// The personal measurements an app may enable (the integration guide, section 8). Each is collected
/// only when the backend asks for it as well -- the location only with the person's permission too.
public enum PersonalMeasurement: String, CaseIterable, Sendable {
    case localAddresses = "local_addresses"
    case accessibility = "accessibility"
    case notificationAccess = "notification_access"
    case otherAccess = "other_access"
    case screenCapture = "screen_capture"
    case location = "location"
    case mockLocation = "mock_location"

    /// The name the report and the backend use.
    public var wireName: String { rawValue }
}

/// Where the backend takes the app PIN's two calls (the integration guide, section 4).
public struct AppPinOptions: Equatable, Sendable {
    public let path: String
    public let proofPath: String

    public init(path: String = DeviceTrustClient.appPinPath, proofPath: String = DeviceTrustClient.appPinProofPath) {
        self.path = path
        self.proofPath = proofPath
    }
}

/// One scan: the challenge it answered, the report as signed, and the backend's answer, whole.
@MainActor
public final class ScanResult {
    public let challenge: ScanChallenge
    public let report: SignedReport
    public let answer: JSONObject

    public init(challenge: ScanChallenge, report: SignedReport, answer: JSONObject) {
        self.challenge = challenge
        self.report = report
        self.answer = answer
    }

    /// The stored report (`integrity.report_id`), which a scan made for one request sends back with
    /// that request.
    public var reportId: String? { answer["integrity"]?["report_id"]?.stringValue }
}

/// DeviceTrust: the one object an app configures -- its backend, the personal measurements it
/// enables, step-up and the app PIN -- and what it asks of it: start, scan, and sign a request (the
/// integration guide). It lives on the main actor; the keychain, the Secure Enclave and the
/// collection run on a queue of their own.
@MainActor
public final class DeviceTrust {
    /// The guide's calls, for an app that makes them itself.
    public let client: DeviceTrustClient

    /// What this app enables; the backend asks for what it needs of them. The app may change it
    /// whenever the person does -- in a privacy setting, say: the next scan measures what it holds
    /// then, and the installation, its session and its step-up key stay as they are.
    public var personalMeasurements: Set<PersonalMeasurement>

    /// How the step-up key is made, or nil for no step-up. An app that takes these from its backend
    /// sets them before `start()`.
    public var stepUp: StepUpOptions?

    /// The app PIN's calls, or nil for no app PIN.
    public let appPin: AppPinOptions?

    /// Every registration's answer, whole -- also those made again inside a scan, when the backend had
    /// lost the installation -- awaited before the installation goes on.
    public let onRegistered: ((JSONObject) async throws -> Void)?

    private let store: InstallationStore
    private let collector: IntegrityCollector
    private let hintReader: ReinstallHintReader
    private let stepUpKeyProvider: StepUpKeyProvider

    private var currentIdentity: InstallationIdentity?
    private var session: String?

    // One call of each kind in flight; a second waits for the first's result.
    private var loading: (id: UUID, task: Task<InstallationIdentity, Error>)?
    private var starting: (id: UUID, task: Task<InstallationIdentity, Error>)?
    private var proving: (id: UUID, task: Task<String, Error>)?
    private var scanning: [String: (id: UUID, task: Task<ScanResult, Error>)] = [:]

    // Which installation the calls running now belong to: reset() and close() move on to the next,
    // and a call of an earlier one keeps nothing it finds.
    private var generation = 0
    // A reset's deletion, which every later load waits for; and the installation ID being saved and a
    // re-enrolment, which a reset waits for.
    private var resetting: Task<Void, Never>?
    private var saving: Task<Void, Error>?
    private var reenrolling: Task<Void, Never>?
    // The persistent writes and key changes running now (mutate): a reset waits for each before it
    // deletes, so none outlives the deletion.
    private var mutations: [UUID: () async -> Void] = [:]
    private var offeredStepUpKey: StepUpKeyMetadata?
    private var hint: ReinstallHint?
    private var hintRead = false

    /// Why step-up is off on this phone although the app turned it on -- no passcode, say -- or nil.
    public internal(set) var stepUpUnavailable: NativeKeyError?

    public var identity: InstallationIdentity? { currentIdentity }

    /// The installation session from proving the key, or nil before `start()`.
    public var installationSession: String? { session }

    /// The step-up key offered at the last registration.
    public var stepUpKey: StepUpKeyMetadata? { offeredStepUpKey }

    /// The wire names of `personalMeasurements`, in the guide's order.
    public var enabledMeasurements: [String] {
        PersonalMeasurement.allCases.filter(personalMeasurements.contains).map(\.wireName)
    }

    #if os(iOS)
    /// Talks to your backend over JSON and HTTPS under `baseURL`, the SDK's default API (the
    /// integration guide, section 4).
    public convenience init(baseURL: String, personalMeasurements: Set<PersonalMeasurement> = [],
                            stepUp: StepUpOptions? = nil, appPin: AppPinOptions? = nil,
                            onRegistered: ((JSONObject) async throws -> Void)? = nil) {
        self.init(over: HTTPTransport(baseURL: baseURL), personalMeasurements: personalMeasurements,
                  stepUp: stepUp, appPin: appPin, onRegistered: onRegistered)
    }
    #endif

    /// The same over the app's own `transport`; `store`, `collector`, `hintReader` and `stepUpKey`
    /// replace the native ones in tests, and `platform` the one the registration names.
    public init(over transport: DeviceTrustTransport, personalMeasurements: Set<PersonalMeasurement> = [],
                stepUp: StepUpOptions? = nil, appPin: AppPinOptions? = nil,
                onRegistered: ((JSONObject) async throws -> Void)? = nil, store: InstallationStore? = nil,
                collector: IntegrityCollector? = nil, hintReader: ReinstallHintReader? = nil,
                stepUpKey: StepUpKeyProvider? = nil, platform: String = "ios") {
        client = DeviceTrustClient(transport: transport, platform: platform)
        self.personalMeasurements = personalMeasurements
        self.stepUp = stepUp
        self.appPin = appPin
        self.onRegistered = onRegistered
        self.store = store ?? InstallationStore()
        self.collector = collector ?? NativeIntegrityCollector()
        self.hintReader = hintReader ?? ReinstallHintReader(platform: platform)
        self.stepUpKeyProvider = stepUpKey ?? NativeStepUpKey()
    }

    // MARK: - The installation

    /// The installation: its key, made on first use, and its ID. A key made now is a new installation
    /// (`InstallationIdentity.createdThisLaunch`): whatever the app kept for the one before belongs to
    /// that one. Calls at once share one load, so one key gets one ID.
    public func loadIdentity() async throws -> InstallationIdentity {
        if let known = currentIdentity { return known }
        if let running = loading { return try await running.task.value }
        let id = UUID()
        let task = Task<InstallationIdentity, Error> { @MainActor in
            defer { if self.loading?.id == id { self.loading = nil } }
            return try await self.load()
        }
        loading = (id, task)
        return try await task.value
    }

    private func load() async throws -> InstallationIdentity {
        // A reset's deletion first, so that nothing loads the key it deletes.
        await resetting?.value
        let generation = self.generation
        let loaded = try await store.loadOrCreate()
        try current(generation)
        if let known = currentIdentity { return known }
        currentIdentity = loaded
        return loaded
    }

    /// A persistent write or a key change for the installation `generation`: refused before it starts
    /// when reset() or close() has ended that installation, and waited for by a reset that began while
    /// it ran. The order is the whole guarantee: endCalls() moves the generation on at once, as reset()
    /// is called, so a write asked for after that throws here without writing; one asked for before is
    /// in `mutations`, which the reset waits for before it deletes anything.
    private func mutate<T>(_ generation: Int, _ change: @escaping () async throws -> T) async throws -> T {
        try current(generation)
        let id = UUID()
        let task = Task<T, Error> { @MainActor in
            defer { self.mutations[id] = nil }
            return try await change()
        }
        mutations[id] = { _ = await task.result }
        return try await task.value
    }

    /// Throws when reset() or close() ended the installation `generation` belongs to: a call keeps
    /// nothing of one that is gone.
    private func current(_ generation: Int) throws {
        if generation != self.generation {
            throw InterruptedCallError(
                "The installation was reset, or the client closed, while this call ran: nothing it found was kept.")
        }
    }

    /// Loads or makes the key, registers it -- with the step-up key, when step-up is on -- and proves
    /// the installation holds it: the installation session. A refusal outside the guide's protocol
    /// errors goes to the app as it came. A second call while one runs gets its result.
    @discardableResult
    public func start() async throws -> InstallationIdentity {
        if let running = starting { return try await running.task.value }
        let id = UUID()
        let task = Task<InstallationIdentity, Error> { @MainActor in
            defer { if self.starting?.id == id { self.starting = nil } }
            return try await self.startOnce()
        }
        starting = (id, task)
        return try await task.value
    }

    private func startOnce() async throws -> InstallationIdentity {
        let generation = self.generation
        _ = try await loadIdentity()
        try await register(generation)
        _ = try await prove()
        try current(generation)
        return currentIdentity!
    }

    /// A new installation session: the key's challenge, answered. A second call while one runs gets
    /// its result.
    @discardableResult
    public func prove() async throws -> String {
        if let running = proving { return try await running.task.value }
        let id = UUID()
        let generation = self.generation
        let task = Task<String, Error> { @MainActor in
            defer { if self.proving?.id == id { self.proving = nil } }
            return try await self.proveOnce(generation, retried: false)
        }
        proving = (id, task)
        return try await task.value
    }

    /// Deletes the key, the installation ID and the step-up key, and forgets the session: the next
    /// start is a new installation, linked to this one by nothing it holds. Calls still running end
    /// with `InterruptedCallError` and keep nothing; calls made from now on wait for the deletion, and
    /// never join one made before.
    public func reset() async throws {
        let loading = self.loading?.task
        let saving = self.saving
        let reenrolling = self.reenrolling
        let earlier = self.resetting
        let changing = Array(mutations.values)
        endCalls()
        offeredStepUpKey = nil
        hint = nil
        hintRead = false
        let store = self.store
        let stepUpKey = self.stepUpKeyProvider
        let deleting = Task<Void, Error> { @MainActor in
            await earlier?.value
            // A load or a save still running finishes first, so that nothing it writes outlives the
            // deletion. So does a re-enrolment: its key, which a backend may already have taken, is
            // deleted after it, and the marker it writes is cleared. So does every write and key change
            // still running (mutate): the step-up marker, a step-up key being made.
            _ = await loading?.result
            _ = await saving?.result
            await reenrolling?.value
            for change in changing { await change() }
            try await store.clear()
            // The step-up key goes with the installation, as on a reinstall: kept, it would link the
            // next installation to this one. None to delete is no failure; nor is a build with no
            // step-up key at all. A key that stays is: reset() fails with it, the installation itself
            // gone, so the app knows and may call reset() again.
            do {
                try await stepUpKey.deleteKey()
            } catch let error as NativeKeyError {
                if error.code != "NATIVE_STEPUP_PLUGIN_MISSING" && error.code != "UNSUPPORTED_ANDROID_VERSION" {
                    throw NativeKeyError(
                        error.code,
                        "The installation was reset, but its step-up key could not be deleted: "
                            + "\(error.message) Call reset() again.")
                }
            }
        }
        // Later loads wait for the deletion, whatever came of it; the caller of reset hears what did.
        resetting = Task { _ = await deleting.result }
        try await deleting.value
    }

    /// Moves on to the next installation: the calls running now keep nothing, and the next ones start
    /// afresh.
    private func endCalls() {
        generation += 1
        currentIdentity = nil
        session = nil
        loading = nil
        starting = nil
        proving = nil
        scanning.removeAll()
    }

    private func proveOnce(_ generation: Int, retried: Bool) async throws -> String {
        let identity = try await loadIdentity()
        try current(generation)
        do {
            let challenge = try await client.createInstallationChallenge(identity.installationId)
            guard let payload = challenge["payload"]?.stringValue,
                  let challengeId = challenge["challenge_id"]?.stringValue else {
                throw InvalidAnswerError("The backend's key challenge has no challenge_id or payload.")
            }
            let verified = try await client.verifyInstallation(
                installationId: identity.installationId, challengeId: challengeId, payload: payload,
                signature: try await identity.signPayload(payload))
            try current(generation)
            guard let token = verified["device_token"]?.stringValue else {
                throw InvalidAnswerError("The backend's answer to the key challenge has no device_token.")
            }
            session = token
            return token
        } catch let error as APIError {
            if retried { throw error }
            switch protocolStep(for: error, deviceSession: true) {
            case .askAgain:
                break
            case .registerAgain:
                try await register(generation)
            case .waitThenRetry:
                try await sleep(protocolWait(for: error)!)
            case .proveAgain, .stop:
                throw error
            }
            return try await proveOnce(generation, retried: true)
        }
    }

    private func register(_ generation: Int) async throws {
        let identity = try await loadIdentity()
        try current(generation)
        if !hintRead {
            let read = await hintReader.read()
            try current(generation)
            hint = read
            hintRead = true
        }
        let offered = try await prepareStepUpKey(generation)
        let answer = try await client.registerInstallation(identity, hint, stepUpKey: offered)
        try current(generation)
        // The key is the installation's identity: a backend that holds it under another ID answers
        // with that one, which is kept.
        if let held = answer["installation_id"]?.stringValue, !held.isEmpty, held != identity.installationId {
            currentIdentity = identity.withInstallationId(held)
            let store = self.store
            let saving = Task<Void, Error> { @MainActor in try await store.saveInstallationId(held) }
            self.saving = saving
            try await saving.value
        }
        try await settleStepUpKey(answer, offered, generation)
        try await onRegistered?(answer)
    }

    /// Whether the backend holds the step-up key offered: it takes one only when it first registers an
    /// installation, so a key made later -- after the passcode was removed and set again, say -- it
    /// takes by re-enrolment alone. Its answer says so (`stepup_key_matches`, or for an installation new
    /// to it `stepup_key_registered`); until it holds this key, approvals wait for reenrolStepUp(),
    /// across restarts too. A registration without a key, the phone unable to make one, leaves any key
    /// made later waiting the same way. A backend whose answer says nothing is taken at its word unless
    /// a re-enrolment is pending.
    private func settleStepUpKey(_ answer: JSONObject, _ offered: StepUpKeyMetadata?, _ generation: Int) async throws {
        guard stepUp != nil else { return }
        let matches = answer["stepup_key_matches"]?.boolValue
        let registered = answer["stepup_key_registered"]?.boolValue
        let bound: Bool? = offered == nil ? nil : (matches ?? registered)
        let store = self.store
        if offered == nil || bound == false {
            try await mutate(generation) { try await store.setStepUpReenrolPending(true) }
        } else if bound == true {
            try await mutate(generation) { try await store.setStepUpReenrolPending(false) }
        }
        var pending = false
        if offered != nil && bound != true {
            pending = try await store.stepUpReenrolPending()
        }
        try current(generation)
        if pending {
            offeredStepUpKey = nil
            stepUpUnavailable = DeviceTrust.reenrolPending()
        }
    }

    /// The step-up key as `stepUp` asks: an existing key is kept as it is. Step-up is optional, so a
    /// key the phone cannot make leaves it off. Its use waits for the backend's answer
    /// (settleStepUpKey).
    private func prepareStepUpKey(_ generation: Int) async throws -> StepUpKeyMetadata? {
        guard let options = stepUp else {
            stepUpUnavailable = nil
            offeredStepUpKey = nil
            return nil
        }
        stepUpKeyProvider.configuredMode = options.mode
        var key: StepUpKeyMetadata?
        var unavailable: NativeKeyError?
        let provider = stepUpKeyProvider
        do {
            key = try await mutate(generation) {
                try await provider.getOrCreateKey(factor: options.factor, mode: options.mode,
                                                  windowSeconds: options.windowSeconds)
            }
        } catch let error as NativeKeyError {
            unavailable = error
        }
        try current(generation)
        stepUpUnavailable = unavailable
        offeredStepUpKey = key
        return key
    }

    /// A step-up key a re-enrolment replaces: one that can never sign again, or one the keystore
    /// cannot vouch for.
    private static func replaceableKey(_ error: NativeKeyError) -> Bool {
        error.code == "STEPUP_KEY_INVALIDATED" || error.code == "STEPUP_KEY_UNAVAILABLE"
    }

    /// What approvals answer while the backend does not hold the step-up key.
    private static func reenrolPending() -> NativeKeyError {
        NativeKeyError(
            "STEPUP_REENROL_PENDING",
            "The backend does not hold this step-up key -- a re-enrolment unfinished, or a key made after "
                + "the installation was registered: reenrolStepUp() first.")
    }

    // MARK: - The scan

    /// A scan: under the installation session -- or, for a scan that approves one `operation`
    /// (`describeOperation`), under the app's account `session` for this installation, the one that
    /// will send that request. The guide's protocol errors are acted on once; an account session is the
    /// app's to renew. A second call for the same scan while one runs gets its result; a scan whose
    /// answer was lost is simply asked for again.
    public func scan(session: String? = nil, operation: JSONObject? = nil) async throws -> ScanResult {
        if operation != nil && session == nil {
            throw UsageError.invalidArgument(
                "A scan for one operation is asked under the account session that will send it.")
        }
        // The personal measurements enabled now are part of the scan: one asked for after the person
        // changed them never joins one asked for before.
        let enabled = enabledMeasurements
        let kind = JSONValue.array([
            session.map { .string($0) } ?? .null,
            operation.map { .object($0) } ?? .null,
            JSONValue(enabled),
        ]).encodedJSON
        if let running = scanning[kind] { return try await running.task.value }
        let id = UUID()
        let generation = self.generation
        let task = Task<ScanResult, Error> { @MainActor in
            defer { if self.scanning[kind]?.id == id { self.scanning[kind] = nil } }
            return try await self.scanWithProtocol(generation, session, operation, enabled)
        }
        scanning[kind] = (id, task)
        return try await task.value
    }

    private func scanWithProtocol(_ generation: Int, _ session: String?, _ operation: JSONObject?,
                                  _ enabled: [String]) async throws -> ScanResult {
        do {
            return try await scanOnce(generation, session, operation, enabled)
        } catch let error as APIError {
            let installationSession = session == nil
            switch protocolStep(for: error, deviceSession: installationSession) {
            case .askAgain:
                break
            case .proveAgain:
                _ = try await prove()
            case .registerAgain:
                // An account session belongs to the installation the backend lost: the app signs in
                // again.
                if !installationSession { throw error }
                try await register(generation)
                _ = try await prove()
            case .waitThenRetry:
                try await sleep(protocolWait(for: error)!)
            case .stop:
                throw error
            }
            return try await scanOnce(generation, session, operation, enabled)
        }
    }

    private func scanOnce(_ generation: Int, _ session: String?, _ operation: JSONObject?,
                          _ enabled: [String]) async throws -> ScanResult {
        let identity = try await loadIdentity()
        let bearer: String
        if let session {
            bearer = session
        } else if let known = self.session {
            bearer = known
        } else {
            bearer = try await prove()
        }
        try current(generation)
        let challenge = try await client.integrityChallenge(session: bearer, identity: identity, operation: operation)
        let report = try await collectReport(
            challenge: challenge, identity: identity, collector: collector, enabledMeasurements: enabled)
        // A report of an installation reset meanwhile is never sent.
        try current(generation)
        let answer = try await client.submitIntegrityReport(session: bearer, identity: identity, report: report)
        try current(generation)
        return ScanResult(challenge: challenge, report: report, answer: answer)
    }

    // MARK: - Requests

    /// Signs one request to your backend under `bearer`, your account session: `body` is sent exactly
    /// as given. With `stepUp` the person approves it with the step-up key -- the phone asks, saying
    /// `reason`; with `appPin` the backend checks the PIN for it first; `reportId` names the scan made
    /// for it alone. Send it with `RequestProof.headers` beside `Authorization: Bearer`, or with
    /// `send(_:)`; each proof serves this request once.
    public func signRequest(method: String, path: String, bearer: String, body: String = "",
                            stepUp: Bool = false, reason: String = "Approve this request",
                            appPin: String? = nil, reportId: String? = nil) async throws -> RequestProof {
        let generation = self.generation
        let identity = try await loadIdentity()
        try current(generation)
        var approval: StepUpApproval?
        if stepUp {
            // Only the key the backend received at registration: a key made later would sign approvals
            // the backend cannot check.
            guard let key = offeredStepUpKey else {
                throw stepUpUnavailable ?? NativeKeyError(
                    "STEPUP_OFF",
                    self.stepUp == nil
                        ? "Step-up is off: DeviceTrust(stepUp: StepUpOptions(…))."
                        : "No step-up key was registered: start() first.")
            }
            let provider = stepUpKeyProvider
            approval = StepUpApproval(factor: key.factor) { payload in
                try await provider.sign(payload, reason: reason)
            }
        }
        var proof = try await Necessary.signRequest(
            identity: identity, method: method, path: path, bearerToken: bearer, encodedBody: body,
            stepUp: approval)
        // The installation reset, or the client closed, while the phone signed: the proof is of an
        // installation that is gone, and is never handed out.
        try current(generation)
        if let appPin {
            guard let options = self.appPin else {
                throw UsageError.invalidState("The app PIN is off: DeviceTrust(appPin: AppPinOptions()).")
            }
            proof = try await client.proveAppPin(
                session: bearer, identity: identity, pin: appPin, request: proof, path: options.proofPath)
            try current(generation)
        }
        return reportId.map { proof.withIntegrityReport($0) } ?? proof
    }

    /// Re-enrols the step-up key under the account `session`, with the person's own
    /// `reauthentication` -- the account's password, say: `["password": …]`. For a key the phone has
    /// lost or can no longer use -- the passcode removed (`STEPUP_KEY_INVALIDATED`) -- or one made for
    /// other options: the person unlocks the new key to sign its proof, the phone showing `reason`, and
    /// the backend takes it for that account alone (the integration guide, section 3). Approvals use it
    /// from then on. A key replaced before the backend took the new one -- the person cancelled, the
    /// password was wrong, the answer was lost -- leaves step-up waiting: approvals answer
    /// `STEPUP_REENROL_PENDING`, across restarts too, until a call of this succeeds.
    @discardableResult
    public func reenrolStepUp(session: String, reauthentication: JSONObject = JSONObject(),
                              reason: String = "Confirm your new step-up key") async throws -> JSONObject {
        let running = Task<JSONObject, Error> { @MainActor in
            try await self.reenrolStepUpOnce(session, reauthentication, reason)
        }
        // reset() waits for it, whatever comes of it.
        reenrolling = Task { _ = await running.result }
        return try await running.value
    }

    private func reenrolStepUpOnce(_ session: String, _ reauthentication: JSONObject,
                                   _ reason: String) async throws -> JSONObject {
        guard let options = stepUp else {
            throw NativeKeyError("STEPUP_OFF", "Step-up is off: DeviceTrust(stepUp: StepUpOptions(…)).")
        }
        let generation = self.generation
        let identity = try await loadIdentity()
        try current(generation)
        stepUpKeyProvider.configuredMode = options.mode
        let provider = stepUpKeyProvider
        let store = self.store

        func newKey(replace: Bool) async throws -> StepUpKeyMetadata {
            if replace {
                // From here the phone's key and the backend's differ until the backend takes the new
                // one: approvals wait for that.
                try await mutate(generation) { try await store.setStepUpReenrolPending(true) }
                try current(generation)
                offeredStepUpKey = nil
                stepUpUnavailable = DeviceTrust.reenrolPending()
                try await mutate(generation) { try await provider.deleteKey() }
            }
            return try await mutate(generation) {
                try await provider.getOrCreateKey(factor: options.factor, mode: options.mode,
                                                  windowSeconds: options.windowSeconds)
            }
        }

        // A re-enrolment is the explicit recovery: a key the keystore cannot vouch for
        // (STEPUP_KEY_UNAVAILABLE), or one that can never sign again, is replaced here -- and only here.
        var key: StepUpKeyMetadata
        do {
            key = try await newKey(replace: false)
        } catch let error as NativeKeyError {
            guard DeviceTrust.replaceableKey(error) else { throw error }
            key = try await newKey(replace: true)
        }
        if !key.created && !options.accepts(key) {
            key = try await newKey(replace: true)
        }
        // The new key signs a proof bound to this request's own nonce, which the request proof then
        // signs too.
        let nonce = freshNonce()
        func prove(with current: StepUpKeyMetadata) async throws -> JSONObject {
            let payload = stepUpReenrolProof(
                installationId: identity.installationId, stepUpKeyThumbprint: current.thumbprint,
                nonce: base64UrlNoPadding(nonce), timestamp: epochSeconds())
            return [
                "stepup_key_proof": .string(payload),
                "stepup_key_signature": .string(try await provider.sign(payload, reason: reason)),
            ]
        }
        var keyProof: JSONObject
        do {
            keyProof = try await prove(with: key)
        } catch let error as NativeKeyError {
            // A key that died with the passcode is found only when it signs.
            guard DeviceTrust.replaceableKey(error) || error.code == "STEPUP_KEY_NOT_FOUND" else { throw error }
            key = try await newKey(replace: true)
            keyProof = try await prove(with: key)
        }
        var body = reauthentication
        body["stepup_public_key"] = .object(key.publicKey)
        body["stepup_key_auth"] = .object(key.authJSON)
        let proof = try await Necessary.signRequest(
            identity: identity, method: "POST", path: options.reenrolPath, bearerToken: session,
            encodedBody: body.merging(keyProof).encodedJSON, nonce: nonce)
        let answer = try await send(proof)
        try await mutate(generation) { try await store.setStepUpReenrolPending(false) }
        try current(generation)
        offeredStepUpKey = key
        stepUpUnavailable = nil
        return answer
    }

    /// Sends `proof`'s request through the SDK's transport.
    @discardableResult
    public func send(_ proof: RequestProof) async throws -> JSONObject {
        try await client.sendSigned(proof)
    }

    /// Sets the account's app PIN under the account `session`, with the person's own
    /// `reauthentication` -- the account's password, say: `["password": …]`.
    @discardableResult
    public func setAppPin(session: String, pin: String,
                          reauthentication: JSONObject = JSONObject()) async throws -> JSONObject {
        guard let options = appPin else {
            throw UsageError.invalidState("The app PIN is off: DeviceTrust(appPin: AppPinOptions()).")
        }
        let generation = self.generation
        let identity = try await loadIdentity()
        try current(generation)
        let answer = try await client.setAppPin(
            session: session, identity: identity, pin: pin, reauthentication: reauthentication, path: options.path)
        try current(generation)
        return answer
    }

    /// Asks the person for the location permission, for the location measurements: from a button on
    /// the app's own screen, since a scan never asks. Answers `precise`, `approximate` or `none`.
    public func requestLocationPermission() async throws -> String {
        try await collector.requestLocationPermission()
    }

    /// Closes the transport. Calls still running end with `InterruptedCallError`, or with the
    /// transport's own failure, and keep nothing; the key and the installation stay as they are.
    public func close() {
        endCalls()
        client.close()
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

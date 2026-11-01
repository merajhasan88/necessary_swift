// The sample backend's own API (../backend/README.md): how an app signs what it sends to its own
// backend -- a request proof on every request, and the person's approval on a sensitive one -- and
// requests made wrong on purpose, which a backend must refuse.
import Foundation
import Necessary

@MainActor
final class SampleAPI {
    let trust: DeviceTrust

    /// The sample's account session for this installation, after signIn.
    var account: String?

    private static let echo = "/v1/demo/echo"
    private static let sensitivePath = "/v1/demo/sensitive"
    private static let echoBody = #"{"hello":"backend"}"#
    private static let payeeBody = #"{"payee":"payee-7"}"#

    init(trust: DeviceTrust) { self.trust = trust }

    private func session() throws -> String {
        guard let account else { throw UsageError.invalidState("Sign in first.") }
        return account
    }

    /// The sample's sign-in, under the installation session from start(): an account session for this
    /// installation. The sample makes the account at its first sign-in.
    func signIn(handle: String, password: String) async throws {
        guard let installationSession = trust.installationSession else {
            throw UsageError.invalidState("Start first.")
        }
        let body: JSONObject = ["handle": .string(handle), "password": .string(password)]
        let proof = try await trust.signRequest(
            method: "POST", path: "/v1/demo/sign-in", bearer: installationSession, body: body.encodedJSON)
        guard let session = try await trust.send(proof)["account_session"]?.stringValue else {
            throw InvalidAnswerError("The sample answered no account_session.")
        }
        account = session
    }

    /// A request with its request proof alone: only this installation's key can sign it, so the session
    /// is useless on another phone.
    func protectedRequest() async throws -> JSONObject {
        try await trust.send(trust.signRequest(
            method: "POST", path: SampleAPI.echo, bearer: try session(), body: SampleAPI.echoBody))
    }

    /// The sensitive request. With `stepUp` the person approves it with the passcode -- the phone asks,
    /// showing the reason; with `appPin` the backend checks the PIN for this request first. With
    /// neither the backend refuses it.
    func sensitive(stepUp: Bool = false, appPin: String? = nil) async throws -> JSONObject {
        try await trust.send(trust.signRequest(
            method: "POST", path: SampleAPI.sensitivePath, bearer: try session(), body: SampleAPI.payeeBody,
            stepUp: stepUp, reason: "Approve the new payee", appPin: appPin))
    }

    /// A new step-up key, with the person's password: after the passcode was removed, say, when
    /// approvals fail with STEPUP_KEY_INVALIDATED.
    func reenrolStepUp(password: String) async throws -> JSONObject {
        try await trust.reenrolStepUp(session: try session(), reauthentication: ["password": .string(password)])
    }

    /// Sets the account's app PIN, with the person's password.
    func setAppPin(_ pin: String, password: String) async throws -> JSONObject {
        try await trust.setAppPin(session: try session(), pin: pin, reauthentication: ["password": .string(password)])
    }

    // --- Requests a backend must refuse.

    private func signedEcho() async throws -> RequestProof {
        try await trust.signRequest(method: "POST", path: SampleAPI.echo, bearer: try session(), body: SampleAPI.echoBody)
    }

    /// One signed request sent twice: the second is a replay.
    func replay() async throws -> JSONObject {
        let proof = try await signedEcho()
        do {
            try await trust.send(proof)
        } catch let error as APIError {
            // The first must go through, or the second tests nothing.
            throw UsageError.invalidState(
                "The first send was refused: \(error.statusCode.map(String.init) ?? "") \(error.code ?? "").")
        }
        return try await trust.send(proof)
    }

    /// A signed request whose body is changed on the way.
    func changedBody() async throws -> JSONObject {
        try await trust.client.sendSigned(try await signedEcho(), encodedBody: #"{"hello":"changed"}"#)
    }

    /// A signed request sent to another path.
    func otherPath() async throws -> JSONObject {
        try await trust.client.sendSigned(try await signedEcho(), path: SampleAPI.sensitivePath)
    }

    /// A request proof signed ten minutes ago.
    func staleProof() async throws -> JSONObject {
        try await trust.send(Necessary.signRequest(
            identity: try await trust.loadIdentity(), method: "POST", path: SampleAPI.echo,
            bearerToken: try session(), encodedBody: SampleAPI.echoBody,
            timestamp: Int(Date().timeIntervalSince1970) - 600))
    }

    /// This phone's account session and installation, to try on another phone.
    func shareSession() throws -> String {
        let shared: JSONObject = [
            "session": .string(try session()),
            "installation_id": .string(trust.identity?.installationId ?? ""),
        ]
        return shared.encodedJSON
    }

    /// A session `shared` from another phone, used here: this phone's key signs a request naming that
    /// phone's installation.
    func sessionFromAnotherPhone(_ shared: String) async throws -> JSONObject {
        let copied = try JSONObject(parsing: shared.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let session = copied["session"]?.stringValue,
              let installation = copied["installation_id"]?.stringValue else {
            throw UsageError.invalidArgument("That is not a session copied from this example.")
        }
        return try await trust.send(Necessary.signRequest(
            identity: try await trust.loadIdentity(), method: "POST", path: SampleAPI.echo,
            bearerToken: session, encodedBody: SampleAPI.echoBody, installationId: installation))
    }
}

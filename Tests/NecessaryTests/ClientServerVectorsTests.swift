// The shared client-server vectors, vectors/client_server.json: the SDK must produce, byte for byte,
// the request proof it signs, the operation a scan names, its key's thumbprint, the step-up proofs and
// the app PIN's request -- the integration guide's sections 1 to 3. A backend can test itself against
// the same file.
import XCTest
@testable import Necessary

/// Signs nothing: the vectors fix what is signed, and ECDSA signatures are randomized, so the
/// signature is the backend's own check.
@MainActor
final class VectorKey: InstallationKeyProvider {
    func getOrCreateKey() async throws -> NativeKeyMetadata { fatalError("unused") }
    func signPayload(_ payloadBase64Url: String) async throws -> String { "unsigned" }
    func deleteKey() async throws {}
}

@MainActor
func vectorIdentity(_ installationId: String, _ jwk: JSONObject) -> InstallationIdentity {
    InstallationIdentity(
        installationId: installationId, nativeKey: VectorKey(),
        metadata: NativeKeyMetadata(
            publicKey: jwk, algorithm: "ES256", keyAlias: "vector", provider: "vector",
            securityLevel: "software", hardwareBacked: false, privateKeyExportable: false,
            signatureFormat: "der", created: false))
}

@MainActor
final class ClientServerVectorsTests: XCTestCase {
    var vectors: JSONObject!

    override func setUp() async throws {
        vectors = try repositoryObject("vectors/client_server.json")
    }

    func section(_ name: String) -> [JSONObject] {
        (vectors[name]?.arrayValue ?? []).compactMap(\.objectValue)
    }

    func testEverySectionHasItsVectors() {
        for name in ["access_proof", "operation", "thumbprint", "step_up_proof", "app_pin_proof_request",
                     "step_up_reenrol_proof"] {
            XCTAssertFalse(section(name).isEmpty, name)
        }
    }

    func testAccessProof() async throws {
        let someKey = section("thumbprint").first!["jwk"]!.objectValue!
        for vector in section("access_proof") {
            let name = vector["name"]!.stringValue!
            let body = vector["body"]!
            let proof = try await signRequest(
                identity: vectorIdentity(vector["installation_id"]!.stringValue!, someKey),
                method: vector["method"]!.stringValue!, path: vector["path"]!.stringValue!,
                bearerToken: vector["bearer"]!.stringValue!,
                encodedBody: body.isNull ? "" : body.encodedJSON,
                timestamp: vector["timestamp"]!.intValue!, nonce: unpadded(vector["nonce"]!.stringValue!))
            XCTAssertEqual(proof.encodedBody, vector["sent_body"]!.stringValue!, "\(name): the body sent")
            XCTAssertEqual(text(proof.payload), vector["proof_json"]!.stringValue!, "\(name): the proof, as JSON")
            XCTAssertEqual(proof.payload, vector["proof"]!.stringValue!, "\(name): the proof, as sent")
        }
    }

    func testTheOperationAScanNames() {
        for vector in section("operation") {
            let name = vector["name"]!.stringValue!
            let sent = vector["body"]!.encodedJSON
            XCTAssertEqual(sent, vector["sent_body"]!.stringValue!, "\(name): the body sent")
            let operation = describeOperation(vector["method"]!.stringValue!, vector["path"]!.stringValue!, sent)
            XCTAssertEqual(JSONValue.object(operation), vector["operation"]!, name)
            // Byte for byte too, in the guide's order.
            XCTAssertEqual(operation.encodedJSON, vector["operation"]!.encodedJSON, name)
        }
    }

    func testTheKeyThumbprint() {
        for vector in section("thumbprint") {
            let identity = vectorIdentity("00000000-0000-4000-8000-000000000000", vector["jwk"]!.objectValue!)
            XCTAssertEqual(identity.keyThumbprint, vector["thumbprint"]!.stringValue!, vector["name"]!.stringValue!)
        }
    }

    // The step-up proofs (the integration guide, section 3): what the step-up key signs for one
    // request, and what a new step-up key signs at re-enrolment.
    func testStepUpProofVersion2() {
        for vector in section("step_up_proof") {
            let name = vector["name"]!.stringValue!
            let sent = vector["body"]!.encodedJSON
            XCTAssertEqual(sent, vector["sent_body"]!.stringValue!, "\(name): the body sent")
            let payload = stepUpProof(
                installationId: vector["installation_id"]!.stringValue!, accessToken: vector["bearer"]!.stringValue!,
                method: "POST", path: vector["path"]!.stringValue!, encodedBody: sent,
                factor: vector["factor"]!.stringValue!, nonce: vector["nonce"]!.stringValue!,
                timestamp: vector["timestamp"]!.intValue!)
            XCTAssertEqual(text(payload), vector["proof_json"]!.stringValue!, "\(name): the proof, as JSON")
            XCTAssertEqual(payload, vector["proof"]!.stringValue!, "\(name): the proof, as sent")
        }
    }

    func testStepUpKeyReenrolmentProof() {
        for vector in section("step_up_reenrol_proof") {
            let name = vector["name"]!.stringValue!
            let payload = stepUpReenrolProof(
                installationId: vector["installation_id"]!.stringValue!,
                stepUpKeyThumbprint: vector["stepup_key_thumbprint"]!.stringValue!,
                nonce: vector["nonce"]!.stringValue!, timestamp: vector["timestamp"]!.intValue!)
            XCTAssertEqual(text(payload), vector["proof_json"]!.stringValue!, "\(name): the proof, as JSON")
            XCTAssertEqual(payload, vector["proof"]!.stringValue!, "\(name): the proof, as sent")
        }
    }

    // What the app sends to have its backend check the app PIN for one request (the integration
    // guide, section 3).
    func testAppPinProofRequest() {
        for vector in section("app_pin_proof_request") {
            let name = vector["name"]!.stringValue!
            let sent = vector["body"]!.encodedJSON
            XCTAssertEqual(sent, vector["sent_body"]!.stringValue!, "\(name): the body of the request it unlocks")
            let asked = appPinProofRequest(
                pin: vector["pin"]!.stringValue!, method: "POST", path: vector["path"]!.stringValue!,
                encodedBody: sent, nonce: vector["nonce"]!.stringValue!)
            XCTAssertEqual(asked.encodedJSON, vector["asked_body"]!.stringValue!, name)
        }
    }
}

// The SDK's reports against the published measurement contract: from the collector answer in each
// sample of the contract's samples folder, the SDK builds that sample's report -- every member but the
// phone's clock. The SDK judges nothing: an invalid or refused sample is built just as faithfully.
import Foundation
import XCTest
@testable import Necessary

@MainActor
private final class SampleKey: InstallationKeyProvider {
    func getOrCreateKey() async throws -> NativeKeyMetadata { fatalError("unused") }
    func signPayload(_ payloadBase64Url: String) async throws -> String { "signed" }
    func deleteKey() async throws {}
}

/// Answers what the sample's collector answered.
@MainActor
private final class Recorded: IntegrityCollector {
    let report: JSONObject

    init(_ report: JSONObject) { self.report = report }

    func collect(requiredProbes: [String], challengeNonce: String, enabledMeasurements: [String],
                 optionalProbes: [String]) async throws -> JSONObject {
        ["platform": report["platform"]!, "challenge_nonce_echo": .string(challengeNonce),
         "collector_version": report["collector_version"]!, "probes": report["probe_results"]!]
    }

    func requestLocationPermission() async throws -> String { "none" }
}

@MainActor
final class ReportContractTests: XCTestCase {
    func testTheContractHasItsSamples() throws {
        XCTAssertEqual(try contractSamples().count, 11)
    }

    func testEverySampleIsBuiltAsTheContractShowsIt() async throws {
        for file in try contractSamples() {
            let sample = try JSONObject(parsing: try Data(contentsOf: file))
            let expected = sample["report"]!.objectValue!
            let plan = sample["plan"]!.objectValue!
            let name = file.lastPathComponent
            let built = try await collectReport(
                challenge: try ScanChallenge(json: [
                    "challenge_id": expected["challenge_id"]!,
                    "nonce": expected["challenge_nonce"]!,
                    "platform": expected["platform"]!,
                    "required_probes": plan["required_probes"] ?? [],
                    "optional_probes": plan["optional_probes"] ?? [],
                ]),
                identity: InstallationIdentity(
                    installationId: expected["installation_id"]!.stringValue!, nativeKey: SampleKey(),
                    metadata: NativeKeyMetadata(
                        publicKey: JSONObject(), algorithm: "ES256", keyAlias: "sample", provider: "sample",
                        securityLevel: "software", hardwareBacked: false, privateKeyExportable: false,
                        signatureFormat: "der", created: false)),
                collector: Recorded(expected),
                enabledMeasurements: (expected["enabled_measurements"]?.arrayValue ?? []).compactMap(\.stringValue))
            XCTAssertNotNil(built.report["collected_at"]?.intValue, name)
            var clockless = built.report
            clockless["collected_at"] = expected["collected_at"]
            XCTAssertEqual(clockless, expected, name)
            XCTAssertEqual(try decoded(built.payload), built.report, "\(name): the payload is the report, as signed")
        }
    }
}

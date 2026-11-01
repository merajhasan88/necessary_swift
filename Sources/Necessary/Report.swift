import Foundation

/// The most a backend takes: a report of 65,536 bytes of JSON (the measurement contract, section 1).
public let reportByteLimit = 65536

/// The lists a report may shorten, by measurement -- each beside the `truncated` flag that says the
/// phone had more (the measurement contract, section 6).
public let shortenableLists: [(probe: String, lists: [String])] = [
    ("accessibility", ["services", "settings_only"]),
    ("notification_access", ["listeners"]),
    ("other_access", ["device_admins", "remote_access_apps"]),
]

/// `report` made to fit `reportByteLimit`: the longest list it may shorten is halved, and marked
/// `truncated`, until it fits. A report that cannot fit is never cut anywhere else: the answer is an
/// error naming the limit.
public func fitReport(_ report: JSONObject) throws -> JSONObject {
    guard var probes = report["probe_results"]?.objectValue else {
        throw InvalidAnswerError("The report has no probe_results.")
    }
    var fitted = report
    func size() -> Int {
        fitted["probe_results"] = .object(probes)
        return fitted.encodedJSON.utf8.count
    }
    var bytes = size()
    while bytes > reportByteLimit {
        var probe: String?
        var field: String?
        var longest = 0
        for (name, lists) in shortenableLists {
            for list in lists {
                if let items = probes[name]?[list]?.arrayValue, items.count > longest {
                    probe = name
                    field = list
                    longest = items.count
                }
            }
        }
        guard let probe, let field, var shortened = probes[probe]?.objectValue else {
            throw APIError("The report would be \(bytes) bytes; a backend takes at most \(reportByteLimit).",
                           code: "report_too_large",
                           details: ["bytes": .int(bytes), "limit": .int(reportByteLimit)])
        }
        shortened[field] = .array(Array(shortened[field]!.arrayValue!.prefix(longest / 2)))
        shortened["truncated"] = true
        probes[probe] = .object(shortened)
        bytes = size()
    }
    return fitted
}

/// A challenge for a scan, as your backend sent it.
public struct ScanChallenge: Equatable, Sendable {
    public let challengeId: String
    public let nonce: String
    public let platform: String
    /// The measurements the report must answer.
    public let requiredProbes: [String]
    /// The personal measurements asked for, answered only where the app enabled them; none from a
    /// backend that names none.
    public let optionalProbes: [String]
    /// The challenge whole.
    public let answer: JSONObject

    public init(json value: JSONObject) throws {
        func required(_ field: String) throws -> String {
            guard let text = value[field]?.stringValue else {
                throw InvalidAnswerError("The backend's scan challenge has no \(field).")
            }
            return text
        }
        func names(_ field: String) -> [String] {
            (value[field]?.arrayValue ?? []).map { item in
                switch item {
                case .string(let text): return text
                case .null: return "null"
                default: return item.encodedJSON
                }
            }
        }
        challengeId = try required("challenge_id")
        nonce = try required("nonce")
        platform = try required("platform")
        requiredProbes = names("required_probes")
        optionalProbes = names("optional_probes")
        answer = value
    }
}

/// A report as the installation key signed it.
public struct SignedReport: Equatable, Sendable {
    /// The report, as signed.
    public let report: JSONObject
    /// `report_payload`: the base64url of the report's JSON bytes.
    public let payload: String
    /// `report_signature`.
    public let signature: String

    public init(report: JSONObject, payload: String, signature: String) {
        self.report = report
        self.payload = payload
        self.signature = signature
    }

    public var json: JSONObject { ["report_payload": .string(payload), "report_signature": .string(signature)] }
}

/// Measures what `challenge` asks for -- and, of the personal measurements it asks for, those in
/// `enabledMeasurements` -- and signs the report with `identity`'s key.
@MainActor
public func collectReport(challenge: ScanChallenge, identity: InstallationIdentity,
                          collector: IntegrityCollector, enabledMeasurements: [String]) async throws -> SignedReport {
    let native = try await collector.collect(
        requiredProbes: challenge.requiredProbes, challengeNonce: challenge.nonce,
        enabledMeasurements: enabledMeasurements, optionalProbes: challenge.optionalProbes)
    guard let probes = native["probes"]?.objectValue else {
        throw APIError("The native collector returned no probe map.", code: "invalid_native_integrity_result")
    }
    guard native["platform"] == .string(challenge.platform),
          native["challenge_nonce_echo"] == .string(challenge.nonce) else {
        throw APIError("The native integrity response did not match the server challenge.",
                       code: "integrity_challenge_binding_failed")
    }
    let version = native["collector_version"]?.numberValue.map { Int($0) } ?? 1
    let report = try fitReport([
        "challenge_id": .string(challenge.challengeId),
        "challenge_nonce": .string(challenge.nonce),
        "installation_id": .string(identity.installationId),
        "platform": .string(challenge.platform),
        "collector_version": .int(version),
        "collected_at": .int(epochSeconds()),
        "probe_results": .object(probes),
        // The personal measurements this app enabled, whether or not this scan asked for them.
        "enabled_measurements": JSONValue(enabledMeasurements),
        "version": 1,
    ])
    let payload = base64UrlNoPadding(Array(report.encodedJSON.utf8))
    return SignedReport(report: report, payload: payload, signature: try await identity.signPayload(payload))
}

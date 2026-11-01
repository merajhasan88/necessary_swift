import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The reinstall hint: a SHA-256 of the platform's per-app device identifier, which the backend keys
/// before storing. Client input, never proof.
public struct ReinstallHint: Equatable, Sendable {
    public let kind: String
    public let value: String

    public init(kind: String, value: String) {
        self.kind = kind
        self.value = value
    }

    public var json: JSONObject { ["kind": .string(kind), "value": .string(value)] }
}

/// Reads the reinstall hint: on iOS the identifier for vendor -- the same for every app of this
/// vendor on the phone, until the last of them is removed -- hashed before it leaves the phone, kind
/// `idfv_sha256`.
@MainActor
open class ReinstallHintReader {
    /// `platform` and `identifier` replace the phone's own in tests.
    public let platform: String
    private let identifier: () async -> String?

    public init(platform: String = "ios", identifier: (() async -> String?)? = nil) {
        self.platform = platform
        self.identifier = identifier ?? ReinstallHintReader.identifierForVendor
    }

    private static func identifierForVendor() async -> String? {
        #if canImport(UIKit) && os(iOS)
        return await MainActor.run { UIDevice.current.identifierForVendor?.uuidString }
        #else
        return nil
        #endif
    }

    open func read() async -> ReinstallHint? {
        // The identifier for vendor; on any other platform, no hint.
        guard platform == "ios" else { return nil }
        let kind = "idfv"
        let value = (await identifier() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // A missing hint never stops the installation's cryptographic identity.
        guard !value.isEmpty else { return nil }
        let digest = sha256Hex("device-recognition-hint-v1|\(kind)|\(value)")
        return ReinstallHint(kind: "\(kind)_sha256", value: digest)
    }
}

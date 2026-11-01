import Foundation
#if os(iOS)
import CoreLocation
#endif

/// The integrity collector: measures what a challenge asks for and the app enabled, and nothing else.
@MainActor
public protocol IntegrityCollector: AnyObject {
    /// `enabledMeasurements`: the personal measurements this app's developers allow; with
    /// `optionalProbes`, what the backend asks for, the collector measures only what is in both. The
    /// answer carries `platform`, `challenge_nonce_echo`, `collector_version` and `probes`.
    func collect(requiredProbes: [String], challengeNonce: String, enabledMeasurements: [String],
                 optionalProbes: [String]) async throws -> JSONObject

    /// Asks the person for the location permission and answers what the app now holds: `precise`,
    /// `approximate` or `none`. Only the app asks, from its own screen; a scan never prompts.
    func requestLocationPermission() async throws -> String
}

/// The iOS collector (`collector_version` 8).
@MainActor
public final class NativeIntegrityCollector: IntegrityCollector {
    #if os(iOS)
    private let probes = IntegrityProbeManager()
    private let permission = LocationPermission()

    public init() {}

    public func collect(requiredProbes: [String], challengeNonce: String, enabledMeasurements: [String],
                        optionalProbes: [String]) async throws -> JSONObject {
        let probes = self.probes
        let enabled = Set(enabledMeasurements)
        let value = try await NativeWorker.run {
            probes.collect(requiredProbes: requiredProbes, challengeNonce: challengeNonce,
                           optionalProbes: optionalProbes, enabledMeasurements: enabled)
        }
        return try NativeWorker.object(value)
    }

    public func requestLocationPermission() async throws -> String {
        await permission.request()
    }
    #else
    public init() {}

    public func collect(requiredProbes: [String], challengeNonce: String, enabledMeasurements: [String],
                        optionalProbes: [String]) async throws -> JSONObject {
        throw NativeWorker.missingCollector
    }

    public func requestLocationPermission() async throws -> String { throw NativeWorker.missingCollector }
    #endif
}

#if os(iOS)
/// The app's own request for the location permission, answered when the person chooses.
@MainActor
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    private var manager: CLLocationManager?
    private var waiting: CheckedContinuation<String, Never>?

    private func state(_ manager: CLLocationManager) -> String {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return manager.accuracyAuthorization == .reducedAccuracy ? "approximate" : "precise"
        case .notDetermined:
            return "undetermined"
        default:
            return "none"
        }
    }

    func request() async -> String {
        let manager = self.manager ?? CLLocationManager()
        self.manager = manager
        let current = state(manager)
        // A second request while the first one's prompt is up holds nothing yet.
        guard current == "undetermined", waiting == nil else {
            return current == "undetermined" ? "none" : current
        }
        return await withCheckedContinuation { continuation in
            waiting = continuation
            manager.delegate = self
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let answer = self.state(manager)
            guard answer != "undetermined", let waiting = self.waiting else { return }
            self.waiting = nil
            waiting.resume(returning: answer)
        }
    }
}
#endif

// How an app sets up the SDK: one DeviceTrust for its backend, with the options it chooses.
// Everything else in the example uses what is made here.
import Foundation
import Necessary

/// A backend the example can talk to: its name on the screen, and its base URL.
struct Backend: Identifiable {
    let name: String
    let url: String
    var id: String { name }
}

/// The backends to choose among, by name: the build setting NECESSARY_BACKENDS
/// (`Name=https://…;Other=https://…`), or the one NECESSARY_BACKEND_URL.
let backends: [Backend] = {
    let info = Bundle.main.infoDictionary ?? [:]
    let list = (info["NecessaryBackends"] as? String ?? "").trimmingCharacters(in: .whitespaces)
    let single = (info["NecessaryBackendURL"] as? String ?? "").trimmingCharacters(in: .whitespaces)
    let named: [Backend] = list.split(separator: ";").compactMap { entry -> Backend? in
        guard let equals = entry.firstIndex(of: "=") else { return nil }
        return Backend(name: entry[..<equals].trimmingCharacters(in: .whitespaces),
                       url: entry[entry.index(after: equals)...].trimmingCharacters(in: .whitespaces))
    }
    return named.isEmpty ? [Backend(name: "Sample", url: single.isEmpty ? "http://127.0.0.1:8787" : single)] : named
}()

/// A DeviceTrust for the backend at `baseURL`.
@MainActor
func setUpDeviceTrust(_ baseURL: String, personalMeasurements: Set<PersonalMeasurement> = []) -> DeviceTrust {
    DeviceTrust(
        baseURL: baseURL,
        // The personal measurements this app allows -- none unless it names them. The backend asks for
        // those it needs, and only what both name is measured. They can change while the app runs:
        // trust.personalMeasurements = [...].
        personalMeasurements: personalMeasurements,
        // Step-up: a second key, which the person unlocks to approve one request. factor "passcode"
        // (the phone's passcode) or "biometric" (Face ID or Touch ID, as enrolled now); iOS makes
        // per-use keys only. Leave it out for no step-up.
        stepUp: StepUpOptions(factor: "passcode", mode: "per_use"),
        // The app PIN, which the backend checks for one request. Its two calls default to the guide's
        // paths. Leave it out for no app PIN.
        appPin: AppPinOptions())
}

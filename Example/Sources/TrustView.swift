// The screen: the installation, the scan, an account, requests with and without the person's
// approval, and requests a backend must refuse -- each result with a check when the backend did what
// it should, a red cross when it did not.
import Necessary
import SwiftUI
import UIKit

/// What a backend that makes the guide's checks does with a request.
enum Expect { case accepted, refused }

/// One action's result as shown: `asExpected` when the backend did what Expect says.
struct Outcome: Identifiable {
    let id = UUID()
    let action: String
    let text: String
    let asExpected: Bool
}

@MainActor
final class ExampleModel: ObservableObject {
    @Published var backend: String = backends[0].name
    @Published private(set) var trust: DeviceTrust
    @Published private(set) var api: SampleAPI
    @Published var scan: ScanResult?
    @Published var locationPermission: String?
    @Published var busy = false
    @Published var latest: [String: Outcome] = [:]
    @Published var log: [Outcome] = []
    @Published var copied = false

    init() {
        let trust = setUpDeviceTrust(backends[0].url)
        self.trust = trust
        api = SampleAPI(trust: trust)
    }

    var backendURL: String { backends.first { $0.name == backend }?.url ?? "" }
    var started: Bool { trust.installationSession != nil }
    var signedIn: Bool { api.account != nil }

    /// Another backend: the same key, an installation of its own there, and the same personal
    /// measurements.
    func choose(_ name: String) {
        let enabled = trust.personalMeasurements
        trust.close()
        backend = name
        trust = setUpDeviceTrust(backendURL, personalMeasurements: enabled)
        api = SampleAPI(trust: trust)
        scan = nil
        latest = [:]
    }

    /// Runs one action of `section` and shows how the backend answered it.
    func run(_ section: String, _ action: String, expect: Expect = .accepted, _ step: @escaping () async throws -> String) {
        busy = true
        Task { @MainActor in
            let outcome: Outcome
            do {
                let answer = try await step()
                outcome = expect == .accepted
                    ? Outcome(action: action, text: answer, asExpected: true)
                    : Outcome(action: action, text: "Accepted, but a backend should refuse this: \(answer)", asExpected: false)
            } catch let error as APIError {
                let refusal = "\(error.statusCode.map(String.init) ?? "") \(error.code ?? "")"
                    .trimmingCharacters(in: .whitespaces)
                // A session the backend no longer takes says nothing of the check a request was made
                // wrong to test: the sample's session lasts ten minutes.
                let sessionGone = error.code == "expired_token" || error.code == "not_signed_in"
                if expect == .refused && !sessionGone {
                    outcome = Outcome(action: action, text: "Refused, as it should be: \(refusal)", asExpected: true)
                } else {
                    outcome = Outcome(
                        action: action,
                        text: sessionGone
                            ? "Refused: \(refusal). The session is no longer valid: sign in again."
                            : "Refused: \(refusal). \(error.message)",
                        asExpected: false)
                }
            } catch let error as NativeKeyError {
                outcome = Outcome(action: action, text: "The phone said \(error.code): \(error.message)", asExpected: false)
            } catch {
                outcome = Outcome(action: action, text: "\(error)", asExpected: false)
            }
            // Also to the device log, for whoever runs a test.
            NSLog("EXAMPLE: [%@] %@ — %@", backend, action, outcome.text)
            busy = false
            latest[section] = outcome
            log.insert(outcome, at: 0)
        }
    }

    // --- The installation.

    func start() async throws -> String {
        let identity = try await trust.start()
        let off = trust.stepUpUnavailable
        return "Installation \(identity.installationId), proved; step-up \(off.map { "off here (\($0.code))" } ?? "on")."
    }

    func prove() async throws -> String {
        try await trust.prove()
        return "A new installation session."
    }

    func newInstallation() async throws -> String {
        try await trust.reset()
        api.account = nil
        scan = nil
        return try await start()
    }

    // --- The scan.

    func setPersonal(_ enabled: Set<PersonalMeasurement>) {
        objectWillChange.send()
        trust.personalMeasurements = enabled
    }

    func askLocation() async throws -> String {
        let permission = try await trust.requestLocationPermission()
        locationPermission = permission
        return "The app holds: \(permission)."
    }

    func doScan() async throws -> String {
        let scan = try await trust.scan()
        self.scan = scan
        return "The backend answered next: \(scan.answer["integrity"]?["next"]?.stringValue ?? "not said"), "
            + "report \(scan.reportId ?? "not named")."
    }
}

struct TrustView: View {
    @StateObject private var model = ExampleModel()
    @State private var handle = "example"
    @State private var password = "example password"
    @State private var pin = ""
    @State private var shared = ""
    @State private var confirmReset = false
    @FocusState private var secret: SecretField?
    @State private var protected = false

    enum SecretField { case password, pin }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if backends.count > 1 {
                        Picker("Backend", selection: Binding(get: { model.backend }, set: { model.choose($0) })) {
                            ForEach(backends, id: \.name) { Text($0.name).tag($0.name) }
                        }
                        .pickerStyle(.segmented)
                        .disabled(model.busy)
                    }
                    Text("Backend: \(model.backendURL)").font(.caption).foregroundColor(.secondary)
                    section("Installation",
                            model.started ? "Its key made, registered and proved" : "Start: make the key, register it, prove it",
                            expanded: true) { installation }
                    section("Measurements",
                            model.scan.map { "\($0.report.report["probe_results"]?.objectValue?.count ?? 0) sent in the last scan" }
                                ?? "What the phone measures, signed with its key") { measurements }
                    section("Account", model.signedIn ? "Signed in" : "Sign in to the sample backend") { account }
                    section("Requests", "A proof on each; the person's approval on a sensitive one") { requests }
                    section("Requests a backend must refuse", "Made wrong on purpose") { refusals }
                    section("Log", "\(model.log.count) results, the latest first") {
                        ForEach(model.log) { OutcomeLine(outcome: $0) }
                    }
                }
                .padding(12)
            }
            .navigationTitle("Necessary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if model.busy { ProgressView() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onChange(of: secret) { focused in
            // No recording of the window while a secret is typed.
            let typing = focused != nil
            if typing != protected {
                protected = typing
                SecureScreen.protect(typing)
            }
        }
        .alert("A new installation?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) {}
            Button("Start again", role: .destructive) {
                model.run("Installation", "New installation") { try await model.newInstallation() }
            }
        } message: {
            Text("This deletes the installation key, its ID and the step-up key, as a reinstall would, "
                 + "and starts again with new keys.")
        }
    }

    // MARK: - Sections

    @ViewBuilder private var installation: some View {
        let identity = model.trust.identity
        let stepUp = model.trust.stepUpKey
        let off = model.trust.stepUpUnavailable
        actions {
            button("Installation", model.started ? "Start again" : "Start", primary: true) { try await model.start() }
            button("Installation", "Prove again", enabled: model.started) { try await model.prove() }
            Button("New installation") { confirmReset = true }
                .buttonStyle(.bordered)
                .disabled(model.busy || identity == nil)
        }
        latestLine("Installation")
        if let identity {
            field("Installation ID", identity.installationId)
            field("Key thumbprint", identity.keyThumbprint)
            field("Key", "\(identity.algorithm), \(identity.provider), \(identity.securityLevel)")
            field("Hardware-backed", identity.hardwareBacked ? "yes" : "no")
            field("Can leave the phone", identity.privateKeyExportable ? "yes" : "no")
            field("New this launch", identity.createdThisLaunch ? "yes" : "no")
            field("Step-up key", stepUp.map { "\($0.description), \($0.securityLevel)" }
                    ?? off.map { "off on this phone: \($0.code)" } ?? "made at start")
        }
    }

    @ViewBuilder private var measurements: some View {
        let enabled = model.trust.personalMeasurements
        Text("Personal measurements").font(.subheadline).bold()
        note("Measured only when this app turns one on and the backend asks for it. None is on until the app says so.")
        Toggle("All of them", isOn: Binding(
            get: { enabled.count == PersonalMeasurement.allCases.count },
            set: { model.setPersonal($0 ? Set(PersonalMeasurement.allCases) : []) }))
            .disabled(model.busy)
        ForEach(PersonalMeasurement.allCases, id: \.self) { measurement in
            Toggle(isOn: Binding(
                get: { model.trust.personalMeasurements.contains(measurement) },
                set: { on in
                    var changed = model.trust.personalMeasurements
                    if on { changed.insert(measurement) } else { changed.remove(measurement) }
                    model.setPersonal(changed)
                })) {
                VStack(alignment: .leading) {
                    Text(personalInfo(measurement).title)
                    Text(personalInfo(measurement).about).font(.caption).foregroundColor(.secondary)
                }
            }
            .disabled(model.busy)
        }
        code(personalCode(enabled))
        if enabled.contains(.location) || enabled.contains(.mockLocation) {
            actions {
                button("Measurements", model.locationPermission.map { "Location permission: \($0)" }
                        ?? "Ask for the location permission") { try await model.askLocation() }
            }
        }
        actions {
            button("Measurements", "Scan", enabled: model.started, primary: true) { try await model.doScan() }
        }
        latestLine("Measurements")
        if let scan = model.scan {
            ScanView(required: scan.challenge.requiredProbes, optional: scan.challenge.optionalProbes,
                     results: scan.report.report["probe_results"]?.objectValue ?? JSONObject(),
                     enabled: (scan.report.report["enabled_measurements"]?.arrayValue ?? []).compactMap(\.stringValue))
        }
    }

    /// The code for the personal measurements chosen above.
    private func personalCode(_ enabled: Set<PersonalMeasurement>) -> String {
        guard !enabled.isEmpty else { return "trust.personalMeasurements = []" }
        let names = PersonalMeasurement.allCases.filter(enabled.contains).map { "    .\($0)," }
        return (["trust.personalMeasurements = ["] + names + ["]"]).joined(separator: "\n")
    }

    @ViewBuilder private var account: some View {
        TextField("Handle", text: $handle)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .textFieldStyle(.roundedBorder)
        SecureField("Password", text: $password)
            .focused($secret, equals: .password)
            .textFieldStyle(.roundedBorder)
        note("The sample makes the account at its first sign-in")
        actions {
            button("Account", "Sign in", enabled: model.started, primary: true) {
                try await model.api.signIn(handle: handle, password: password)
                return "An account session for this installation."
            }
            Button("Sign out") {
                model.objectWillChange.send()
                model.api.account = nil
            }
            .buttonStyle(.bordered)
            .disabled(model.busy || !model.signedIn)
        }
        latestLine("Account")
    }

    @ViewBuilder private var requests: some View {
        note("Each request carries a proof signed by this installation's key. The sensitive one also needs the "
             + "person's approval: the step-up key, unlocked with the passcode, or the app PIN.")
        actions {
            button("Requests", "Protected request", enabled: model.signedIn) {
                try await model.api.protectedRequest().encodedJSON
            }
            button("Requests", "Sensitive, without approval", enabled: model.signedIn, expect: .refused) {
                try await model.api.sensitive().encodedJSON
            }
            button("Requests", "Sensitive, with step-up", enabled: model.signedIn) {
                try await model.api.sensitive(stepUp: true).encodedJSON
            }
            button("Requests", "Re-enrol the step-up key", enabled: model.signedIn) {
                try await model.api.reenrolStepUp(password: password).encodedJSON
            }
        }
        SecureField("App PIN (6 digits)", text: $pin)
            .keyboardType(.numberPad)
            .focused($secret, equals: .pin)
            .textFieldStyle(.roundedBorder)
            .onChange(of: pin) { typed in if typed.count > 6 { pin = String(typed.prefix(6)) } }
        note("The screen is covered while it is typed, if it is recorded")
        actions {
            button("Requests", "Set the app PIN", enabled: model.signedIn) {
                _ = try await model.api.setAppPin(pin, password: password)
                return "Set, with the account password."
            }
            button("Requests", "Sensitive, with the app PIN", enabled: model.signedIn) {
                try await model.api.sensitive(appPin: pin).encodedJSON
            }
        }
        latestLine("Requests")
    }

    @ViewBuilder private var refusals: some View {
        note("Each of these is a request made wrong on purpose. A backend that makes the guide's checks refuses every one.")
        actions {
            refusal("Send one request twice", enabled: model.signedIn) { try await model.api.replay() }
            refusal("Change the body after signing", enabled: model.signedIn) { try await model.api.changedBody() }
            refusal("Send it to another path", enabled: model.signedIn) { try await model.api.otherPath() }
            refusal("A proof ten minutes old", enabled: model.signedIn) { try await model.api.staleProof() }
        }
        Text("A session copied to another phone").font(.subheadline).bold().padding(.top, 8)
        note("Copy this phone's session, get it to another phone running this example, paste it there and use it: "
             + "that phone's key cannot sign for this installation.")
        actions {
            Button("Copy this phone's session") {
                if let session = try? model.api.shareSession() {
                    UIPasteboard.general.string = session
                    model.copied = true
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.busy || !model.signedIn)
        }
        if model.copied { Text("Copied this phone's session").font(.caption) }
        TextField("A session from another phone", text: $shared)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .textFieldStyle(.roundedBorder)
        actions {
            refusal("Use it here", enabled: model.started && !shared.trimmingCharacters(in: .whitespaces).isEmpty) {
                try await model.api.sessionFromAnotherPhone(shared)
            }
        }
        latestLine("Refusals")
    }

    // MARK: - Pieces of the screen

    private func section<Content: View>(_ title: String, _ subtitle: String, expanded: Bool = false,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        CardSection(title: title, subtitle: subtitle, expanded: expanded, content: content())
    }

    private func button(_ section: String, _ label: String, enabled: Bool = true, primary: Bool = false,
                        expect: Expect = .accepted, _ step: @escaping () async throws -> String) -> some View {
        Group {
            if primary && expect == .accepted {
                Button(label) { model.run(section, label, expect: expect, step) }.buttonStyle(.borderedProminent)
            } else {
                Button(label) { model.run(section, label, expect: expect, step) }.buttonStyle(.bordered)
            }
        }
        .disabled(model.busy || !enabled)
    }

    private func refusal(_ label: String, enabled: Bool, _ step: @escaping () async throws -> JSONObject) -> some View {
        button("Refusals", label, enabled: enabled, expect: .refused) { try await step().encodedJSON }
    }

    private func actions<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        FlowLayout { content() }.padding(.vertical, 4)
    }

    @ViewBuilder private func latestLine(_ section: String) -> some View {
        if let outcome = model.latest[section] { OutcomeLine(outcome: outcome) }
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.footnote).bold().frame(maxWidth: .infinity, alignment: .leading)
            Text(value).font(.footnote).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundColor(.secondary)
    }

    private func code(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(UIColor.secondarySystemBackground)))
    }
}

/// A section that opens and closes, and keeps what it shows while closed.
struct CardSection<Content: View>: View {
    let title: String
    let subtitle: String
    @State var expanded: Bool
    let content: Content

    init(title: String, subtitle: String, expanded: Bool, content: Content) {
        self.title = title
        self.subtitle = subtitle
        _expanded = State(initialValue: expanded)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(title).font(.headline).foregroundColor(.primary)
                        Text(subtitle).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").foregroundColor(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) { content }
                .frame(height: expanded ? nil : 0, alignment: .top)
                .clipped()
                .opacity(expanded ? 1 : 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemBackground).opacity(0.5)))
    }
}

/// Buttons in rows, as many to a row as fit.
struct FlowLayout<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        // iOS 15 has no Layout protocol: a vertical stack of buttons that wrap their text reads the
        // same on every width.
        VStack(alignment: .leading, spacing: 6) { content() }
    }
}

struct OutcomeLine: View {
    let outcome: Outcome

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: outcome.asExpected ? "checkmark.circle" : "exclamationmark.circle")
                .foregroundColor(outcome.asExpected ? .accentColor : .red)
            Text("\(outcome.action): \(outcome.text)").font(.footnote).textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

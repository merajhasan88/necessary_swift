// Reading a scan: every measurement the signed report carried, each with its status and its fields as
// the phone sent them, grouped by what it catches -- the hooks, gadgets and changes in memory first. A
// measurement the backend did not ask for shows as not asked rather than disappearing. The titles and
// descriptions follow the integration guide's sections 6 and 8.
import Necessary
import SwiftUI

/// What a group of measurements catches.
enum MeasurementGroup: CaseIterable {
    case hooks, app, system, device, personal

    var title: String {
        switch self {
        case .hooks: return "Hooks, gadgets and memory changes"
        case .app: return "The app as built"
        case .system: return "Jailbreak and the system"
        case .device: return "Device and network"
        case .personal: return "Personal measurements"
        }
    }

    var note: String {
        switch self {
        case .hooks:
            return "Frida and other instrumentation, found by name; debuggers and tracers; and the code in "
                + "memory compared with its file, where an inline hook changes bytes. A backend asks for "
                + "every one of these on every scan."
        case .app: return "What is installed: its identity, its hash and its signature."
        case .system: return "Traces of a jailbreak, and how the system is set up."
        case .device: return "Sent with every scan, asked for or not."
        case .personal: return "Asked for by the backend, and measured only where this app turned them on."
        }
    }
}

/// A measurement's name in the report, a title, what it tells a backend, and its group.
struct MeasurementInfo {
    let name: String
    let title: String
    let about: String
    let group: MeasurementGroup
}

let iosMeasurements: [MeasurementInfo] = [
    MeasurementInfo(name: "dyld_images", title: "Loaded libraries",
                    about: "Instrumentation and jailbreak names among the loaded libraries: Frida, its gadget, "
                        + "Cycript, Substrate and others.", group: .hooks),
    MeasurementInfo(name: "environment", title: "Environment",
                    about: "Libraries injected through the environment.", group: .hooks),
    MeasurementInfo(name: "code_integrity", title: "Code integrity",
                    about: "The app's code in memory compared with its file, image by image: an inline hook "
                        + "changes bytes, and app_diff_bytes counts them.", group: .hooks),
    MeasurementInfo(name: "debugger", title: "Debugger", about: "A debugger tracing the process.", group: .hooks),
    MeasurementInfo(name: "app_identity", title: "App identity",
                    about: "The installed app and its executable's hash.", group: .app),
    MeasurementInfo(name: "code_signing", title: "Code signing",
                    about: "The executable's own code signature.", group: .app),
    MeasurementInfo(name: "jailbreak_files", title: "Jailbreak files",
                    about: "Known jailbreak paths that exist.", group: .system),
    MeasurementInfo(name: "sandbox", title: "Sandbox",
                    about: "Whether the app can write outside its sandbox.", group: .system),
    MeasurementInfo(name: "simulator", title: "Simulator",
                    about: "The simulator, and the hardware model.", group: .system),
    MeasurementInfo(name: "device", title: "Device",
                    about: "The OS version and build, the model and the memory page size.", group: .device),
    MeasurementInfo(name: "network", title: "Network",
                    about: "A VPN, inferred from the interfaces the proxy settings are scoped to; an HTTP proxy.",
                    group: .device),
]

/// The personal measurements, in the order of PersonalMeasurement.
let personalCatalog: [MeasurementInfo] = [
    MeasurementInfo(name: "local_addresses", title: "Local addresses",
                    about: "The phone's own IP addresses, link-local ones left out.", group: .personal),
    MeasurementInfo(name: "accessibility", title: "Accessibility",
                    about: "The Accessibility services that are on, and the keyboard in use. iOS shows an app none: unsupported.",
                    group: .personal),
    MeasurementInfo(name: "notification_access", title: "Notification access",
                    about: "The apps allowed to read notifications. iOS shows an app none: unsupported.", group: .personal),
    MeasurementInfo(name: "other_access", title: "Other access",
                    about: "Device-administrator apps, and known remote-control apps installed. iOS shows an app none: unsupported.",
                    group: .personal),
    MeasurementInfo(name: "screen_capture", title: "Screen capture",
                    about: "The screen being recorded, mirrored or cast.", group: .personal),
    MeasurementInfo(name: "location", title: "Location",
                    about: "The last location the phone already knows: never a fresh fix, never a prompt. Needs "
                        + "the location permission.", group: .personal),
    MeasurementInfo(name: "mock_location", title: "Mock location",
                    about: "Whether that location was faked.", group: .personal),
]

/// What a personal measurement reports, for its switch.
func personalInfo(_ measurement: PersonalMeasurement) -> MeasurementInfo {
    personalCatalog.first { $0.name == measurement.wireName }!
}

/// One scan as the phone sent it: the backend's plan -- `required` and the personal measurements it
/// asked for, `optional` -- and the report's `results` (`probe_results`).
struct ScanView: View {
    let required: [String]
    let optional: [String]
    let results: JSONObject
    /// The personal measurements the app enabled for this scan.
    let enabled: [String]

    private var catalog: [MeasurementInfo] { iosMeasurements + personalCatalog }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("The phone reports what it measured; your backend decides what it means.")
                .font(.caption).italic()
            ForEach(MeasurementGroup.allCases, id: \.self) { group in
                let members = catalog.filter { info in
                    info.group == group
                        && (group != .personal || optional.contains(info.name) || results[info.name] != nil)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title).font(.subheadline).bold()
                    Text(group == .personal
                         ? "\(group.note) On: \(enabled.isEmpty ? "none" : enabled.joined(separator: ", "))."
                         : group.note)
                        .font(.caption).foregroundColor(.secondary)
                    ForEach(members, id: \.name) { info in tile(info) }
                    if members.isEmpty { Text("The backend asked for none.").font(.caption) }
                }
                .padding(.top, 12)
            }
            let other = results.keys.filter { name in !catalog.contains { $0.name == name } }
            if !other.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Other measurements").font(.subheadline).bold()
                    Text("In the report as sent.").font(.caption).foregroundColor(.secondary)
                    ForEach(other, id: \.self) { name in
                        tile(MeasurementInfo(name: name, title: name, about: "Not described here.", group: .device))
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    private func tile(_ info: MeasurementInfo) -> some View {
        MeasurementTile(info: info, result: results[info.name]?.objectValue,
                        asked: required.contains(info.name) || optional.contains(info.name))
    }
}

/// A measurement's status as the badge says it: whether the phone measured it, never whether what it
/// found is good or bad.
private let statusLabels = ["ok": "measured", "error": "failed", "not_enabled": "off"]

/// One measurement: its title and status, opening to what it tells a backend and every field the
/// phone sent.
struct MeasurementTile: View {
    let info: MeasurementInfo
    /// The measurement as the report carries it, or nil when it is absent.
    let result: JSONObject?
    /// Whether the backend asked for it in this scan.
    let asked: Bool

    var body: some View {
        let partly = !(result?["unread"]?.objectValue?.isEmpty ?? true)
        let status = result == nil ? (asked ? "missing" : "not asked") : (result?["status"]?.stringValue ?? "no status")
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.about).font(.caption)
                if let result {
                    if result["status"] == "not_enabled" {
                        Text("The backend asked; this app has not turned it on.").font(.caption)
                    }
                    if partly {
                        Text("Parts it could not read are not measured: never read them as a clean \"no\".")
                            .font(.caption).foregroundColor(.red)
                    }
                    ForEach(Array(fieldRows(withoutStatus(result)).enumerated()), id: \.offset) { _, row in
                        FieldRow(row: row)
                    }
                } else {
                    Text(asked
                         ? "Asked for, but not in the report: a backend refuses such a report."
                         : "Not asked for in this scan, so not measured.")
                        .font(.caption)
                }
            }
            .padding(.bottom, 8)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(info.title)
                    Spacer()
                    if partly { Badge(label: "unread", warning: true) }
                    if result?["truncated"] == .bool(true) { Badge(label: "truncated") }
                    Badge(label: statusLabels[status] ?? status,
                          warning: status == "error" || status == "missing"
                              || (status == "not asked" && info.group == .hooks))
                }
                Text(info.name).font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
            }
        }
        .accessibilityIdentifier("measurement:\(info.name)")
    }
}

/// Every field but `status`, which the badge shows.
func withoutStatus(_ result: JSONObject) -> JSONObject {
    var fields = result
    fields["status"] = nil
    return fields
}

/// One field as the screen shows it: its name, its value, how deep it is nested.
struct Field {
    let name: String
    let value: String?
    let depth: Int
}

/// Every field of `fields`, nested objects and lists indented under their name.
func fieldRows(_ fields: JSONObject, depth: Int = 0) -> [Field] {
    var rows: [Field] = []
    for (name, value) in fields {
        if let object = value.objectValue, !object.isEmpty {
            rows.append(Field(name: name, value: nil, depth: depth))
            rows += fieldRows(object, depth: depth + 1)
        } else if let items = value.arrayValue, items.contains(where: { $0.objectValue != nil }) {
            rows.append(Field(name: name, value: "\(items.count)", depth: depth))
            for (index, item) in items.enumerated() {
                if let member = item.objectValue {
                    var numbered = JSONObject()
                    for (key, inner) in member { numbered["\(index + 1). \(key)"] = inner }
                    rows += fieldRows(numbered, depth: depth + 1)
                } else {
                    rows.append(Field(name: "\(index + 1).", value: scalar(item), depth: depth + 1))
                }
            }
        } else {
            rows.append(Field(name: name, value: scalar(value), depth: depth))
        }
    }
    return rows
}

private func scalar(_ value: JSONValue) -> String {
    switch value {
    case .null: return "null"
    case .bool(let flag): return flag ? "yes" : "no"
    case .array(let items): return items.isEmpty ? "none" : items.map(scalar).joined(separator: ", ")
    case .object: return "none"
    case .string(let text): return text.isEmpty ? "\"\"" : text
    case .int(let number): return String(number)
    case .double: return value.encodedJSON
    }
}

struct FieldRow: View {
    let row: Field

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(row.name).font(.caption).bold().frame(maxWidth: .infinity, alignment: .leading)
            Text(row.value ?? "").font(.caption).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(12 * row.depth))
        .padding(.vertical, 1)
    }
}

struct Badge: View {
    let label: String
    var warning = false

    var body: some View {
        let color: Color = warning ? .red : (label == "measured" ? .accentColor : .gray)
        Text(label)
            .font(.caption2)
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color))
    }
}

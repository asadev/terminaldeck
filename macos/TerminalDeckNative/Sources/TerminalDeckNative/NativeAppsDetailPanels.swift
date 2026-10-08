import Foundation
import SwiftUI
import TerminalDeckNativeCore

/// Uses the same grey selection, measure and hover as NativeStoreScreen's rail.
/// A reusable tab-row piece if the shared native kit needs one later.
struct NativeAppsDetailTabButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(selected ? Color.primary.opacity(0.1) : hover ? Color.primary.opacity(0.06) : .clear,
                            in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Content-shaped, non-interactive rows keep the page's measure while reading.
struct NativeAppsDetailSkeleton: View {
    let tab: NativeAppsTab

    var body: some View {
        Section {
            NativePageNote("Reading \(tab.title.lowercased())…", busy: true)
                .frame(height: 28)
            if tab == .logs {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<7) { index in
                        Text(index.isMultiple(of: 2) ? "A log line will appear here when the app answers." : "Reading the latest activity from this app.")
                            .font(.caption.monospaced())
                    }
                }
                .redacted(reason: .placeholder)
                .accessibilityHidden(true)
                .padding(.vertical, 8)
            } else {
                ForEach(0..<3) { _ in
                    NativeSettingRow(label: rowLabel, help: rowHelp) {
                        Text(rowValue)
                    }
                    .redacted(reason: .placeholder)
                    .accessibilityHidden(true)
                    .padding(.vertical, 4)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var rowLabel: String {
        switch tab {
        case .overview: "App status"
        case .deploys: "Latest deploy"
        case .settings: "API_KEY"
        case .address: "app.example.com"
        case .backups: "Saved backup"
        case .logs: "App log"
        }
    }

    private var rowHelp: String {
        switch tab {
        case .deploys, .backups: "Created on this server"
        case .settings: "Secret value is hidden"
        case .address: "Secure connection"
        default: "Details from this server"
        }
    }

    private var rowValue: String {
        switch tab {
        case .settings: "Replace value"
        case .backups: "Restore backup"
        case .address: "Pointing to this server"
        default: "Waiting for the app"
        }
    }
}

struct NativeAppsEnvironmentRow: View {
    let key: NativeAppsEnvironmentKey
    let appName: String
    let busy: Bool
    var editable: Bool = true
    let onSave: (String) -> Void
    let onRemove: () -> Void
    @State private var editing = false
    @State private var value = ""
    @State private var removing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NativeSettingRow(label: key.key, help: editable
                ? (key.isSecret ? "Secret value is hidden" : "Value is hidden")
                : "Set when this database was created.") {
                if editable {
                    HStack(spacing: 8) {
                        Button(editing ? "Cancel" : "Replace value") {
                            value = ""
                            editing.toggle()
                        }
                        Button("Remove…", role: .destructive) { removing = true }
                    }
                    .disabled(busy)
                } else {
                    Text("Created with the database").font(.callout).foregroundStyle(.secondary)
                }
            }
            if editing && editable {
                HStack(spacing: 8) {
                    SecureField("Replacement value", text: $value)
                        .accessibilityLabel("Replacement value for \(key.key)")
                    Button("Save replacement") {
                        let replacement = value
                        value = ""
                        editing = false
                        onSave(replacement)
                    }
                    .disabled(busy || value.isEmpty)
                }
            }
        }
        .padding(.vertical, 4)
        .alert("Remove \(key.key) from \(appName)?", isPresented: $removing) {
            Button("Cancel", role: .cancel) {}
            Button("Remove setting", role: .destructive, action: onRemove)
                .disabled(busy || !editable)
        } message: {
            Text("The app will no longer receive this setting. You can add it again with a new value.")
        }
        .onChange(of: editable) { _, next in
            if !next { value = ""; editing = false; removing = false }
        }
        .onDisappear { value = "" }
    }
}

struct NativeAppsNewEnvironmentRow: View {
    let busy: Bool
    let existingKeys: Set<String>
    var kind = "app"
    let onSave: (String, String) -> Void
    @State private var key = ""
    @State private var value = ""

    private var validKey: Bool { NativeAppsRules.validEnvironmentKey(key) }
    private var protectedKey: Bool { NativeAppsRules.isDatabaseLoginKey(kind: kind, key: key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a setting").font(.callout.weight(.medium))
            NativeSettingRow(label: "Name", help: "Use letters, numbers and underscores, such as API_KEY.") {
                TextField("API_KEY", text: $key).frame(minWidth: 160, maxWidth: 260)
                    .accessibilityLabel("New setting name")
            }
            NativeSettingRow(label: "Value") {
                SecureField("New value", text: $value).frame(minWidth: 160, maxWidth: 260)
                    .accessibilityLabel("New setting value")
            }
            if protectedKey {
                NativeSettingsProse(text: "This setting controls the database’s saved login. This editor cannot change that login.")
                    .font(.callout)
                Button("Clear name") { key = ""; value = "" }
            } else if existingKeys.contains(key) {
                NativeSettingsProse(text: "This setting already exists. Choose Replace value above to change it.")
                    .font(.callout)
            }
            Button("Add setting") {
                let name = key
                let replacement = value
                value = ""
                key = ""
                onSave(name, replacement)
            }
            .disabled(busy || !validKey || protectedKey || existingKeys.contains(key) || value.isEmpty)
        }
        .padding(.vertical, 4)
        .onDisappear { value = "" }
    }
}

struct NativeAppsBackupScheduleEditor: View {
    let schedule: NativeAppsBackupSchedule?
    let busy: Bool
    let onSave: (NativeAppsBackupSchedule) -> Void
    @State private var enabled: Bool
    @State private var time: String
    @State private var retentionCount: Int

    init(schedule: NativeAppsBackupSchedule?, busy: Bool, onSave: @escaping (NativeAppsBackupSchedule) -> Void) {
        self.schedule = schedule
        self.busy = busy
        self.onSave = onSave
        _enabled = State(initialValue: schedule?.enabled ?? true)
        _time = State(initialValue: schedule?.time ?? "03:00")
        _retentionCount = State(initialValue: schedule?.retentionCount ?? 7)
    }

    private var validTime: Bool {
        time.range(of: "^([01][0-9]|2[0-3]):[0-5][0-9]$", options: .regularExpression) != nil
    }

    private var hasOtherTiming: Bool { schedule?.enabled == true && schedule?.time.isEmpty == true }

    private var saveTitle: String {
        if !enabled { return "Turn off schedule" }
        if hasOtherTiming { return "Use daily schedule" }
        return schedule == nil ? "Add schedule" : "Save schedule"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if schedule == nil {
                NativeSettingsProse(text: "No saved schedule was returned. Choose a daily time to add one.")
            }
            if hasOtherTiming {
                NativeSettingsProse(text: "The saved schedule uses a different timing pattern. Enter a daily time below to replace it, or turn the schedule off.")
                if let calendar = schedule?.calendar, !calendar.isEmpty {
                    NativeSettingRow(label: "Saved timing") {
                        Text(calendar).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            NativeSettingRow(label: "Scheduled backups") {
                Toggle("Scheduled backups", isOn: $enabled).labelsHidden().toggleStyle(.switch)
            }
            if enabled {
                NativeSettingRow(label: "Daily at", help: "Use the server’s time, in 24-hour form: 03:00 means 3 am.") {
                    TextField("03:00", text: $time).frame(width: 90)
                        .accessibilityLabel("Daily backup time on the server")
                }
                NativeSettingRow(label: "Keep latest") {
                    Stepper("\(retentionCount) backups", value: $retentionCount, in: 1...365)
                        .accessibilityLabel("Number of backups to keep")
                }
                if !validTime {
                    NativeCodingAINotice(tone: .warn, text: "Enter a time from 00:00 to 23:59.")
                }
            }
            Button(saveTitle) {
                onSave(NativeAppsBackupSchedule(enabled: enabled, time: time, retentionCount: retentionCount))
            }
            .disabled(busy || (enabled && !validTime))
            NativeSettingsProse(text: "The server makes scheduled backups even when this Mac is off.")
                .font(.callout)
        }
        .disabled(busy)
        .onChange(of: schedule?.time) { _, next in
            if let next { time = next }
        }
        .onChange(of: schedule?.enabled) { _, next in
            if let next { enabled = next }
        }
        .onChange(of: schedule?.retentionCount) { _, next in
            if let next { retentionCount = next }
        }
    }
}

enum NativeAppsDetailConfirmation: Identifiable {
    case removeApp
    case restore(String, String)
    case removeAddress(String)

    var id: String {
        switch self {
        case .removeApp: return "remove-app"
        case .restore(let id, _): return "restore-" + id
        case .removeAddress(let hostname): return "remove-address-" + hostname
        }
    }

    var needsName: Bool {
        switch self {
        case .removeApp, .restore: return true
        case .removeAddress: return false
        }
    }

    var buttonTitle: String {
        switch self {
        case .removeApp: return "Remove app"
        case .restore: return "Restore backup"
        case .removeAddress: return "Remove address"
        }
    }

    func title(appName: String) -> String {
        switch self {
        case .removeApp: return "Remove \(appName)?"
        case .restore: return "Restore \(appName)?"
        case .removeAddress(let hostname): return "Remove \(hostname)?"
        }
    }

    func message(appName: String) -> String {
        switch self {
        case .removeApp:
            return "Remove \(appName) from this server. Make sure you have any backups you need before continuing. This cannot be undone here."
        case .restore(_, let date):
            return "Replace the current data in \(appName) with \(date). The database pauses during restore. Changes made after this backup will be lost."
        case .removeAddress(let hostname):
            return "\(hostname) will stop serving \(appName). This does not remove the app or change your domain provider’s DNS settings."
        }
    }
}

struct NativeAppsDetailConfirmationSheet: View {
    let request: NativeAppsDetailConfirmation
    let appName: String
    let busy: Bool
    let onConfirm: (String) -> Void
    let onCancel: () -> Void
    @State private var typedName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NativeSettingsHead(title: request.title(appName: appName), blurb: nil)
            NativeSettingsProse(text: request.message(appName: appName))
            if request.needsName {
                Text("Type \(appName) to confirm.").font(.callout)
                TextField("App name", text: $typedName)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Type \(appName) to confirm")
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(request.buttonTitle, role: .destructive) { onConfirm(typedName) }
                    .disabled(busy || (request.needsName && !NativeAppsRules.matchesConfirmation(typed: typedName, name: appName)))
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

enum NativeAppsDetailWords {
    /// Only ordinary secure web links can leave the app. Credentials and custom
    /// schemes never become clickable, even if an unexpected server record arrives.
    static func secureURL(_ address: String) -> URL? {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        let candidate = input.contains("://") ? input : "https://" + input
        guard let url = NativeAppsRules.safeAddress(candidate), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }
}

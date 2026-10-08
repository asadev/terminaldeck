import SwiftUI
import TerminalDeckNativeCore

/// Save a database connection into an existing app's protected settings. This
/// panel never receives a password/URI and never automatically deploys an app.
struct NativeAppsDataDatabaseBindingEditor: View {
    let apps: [NativeAppsSummary]
    let databaseID: String
    let busy: Bool
    let problem: String?
    let onCreateApp: () -> Void
    let onBind: (String, String) -> Void
    @State private var draft: NativeAppsDataDatabaseBindingDraft

    init(apps: [NativeAppsSummary], databaseID: String, kind: String, busy: Bool, problem: String?,
         onCreateApp: @escaping () -> Void, onBind: @escaping (String, String) -> Void) {
        self.apps = apps; self.databaseID = databaseID; self.busy = busy; self.problem = problem
        self.onCreateApp = onCreateApp; self.onBind = onBind
        _draft = State(initialValue: NativeAppsDataDatabaseBindingDraft(kind: kind))
    }

    private var eligible: [NativeAppsSummary] {
        NativeAppsDataDatabaseBindingDraft.eligibleApps(apps, databaseID: databaseID)
    }
    private var validationMessage: String? { draft.validationMessage(apps: apps, databaseID: databaseID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NativeSettingsProse(text: "Save the private connection into an app’s settings. Its password stays protected on this server.")
            NativeSettingsProse(text: "If this setting already exists, saving replaces it.")
            if eligible.isEmpty {
                NativeSettingsProse(text: "Create an app on this server first, then save its connection here.")
                Button("Create app", action: onCreateApp).disabled(busy)
            } else {
                NativeSettingRow(label: "App") {
                    if eligible.count == 1, let only = eligible.first {
                        Text(only.name).font(.callout).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Picker("App", selection: $draft.targetAppID) {
                            Text("Choose an app").tag("")
                            ForEach(eligible, id: \.id) { app in Text(app.name).tag(app.id) }
                        }
                        .labelsHidden()
                    }
                }
                NativeSettingRow(label: "Setting name", help: "Use the name your app reads, usually DATABASE_URL or REDIS_URL.") {
                    TextField("DATABASE_URL", text: $draft.key).frame(minWidth: 200, maxWidth: 300)
                        .accessibilityLabel("Connection setting name")
                }
                Button("Save connection") {
                    guard validationMessage == nil, !busy else { return }
                    onBind(draft.targetAppID, draft.key)
                }
                .disabled(busy || validationMessage != nil)
                NativeSettingsProse(text: "Deploy the app to apply its saved connection. Saving here does not deploy it.")
                if let validationMessage {
                    Text(validationMessage).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if busy {
                NativePageNote("Waiting for the current server change…", busy: true).frame(height: 28)
            }
            if let problem, !problem.isEmpty { NativeCodingAINotice(tone: .error, text: problem) }
        }
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
        .disabled(busy)
        .onChange(of: eligible.map(\.id), initial: true) { _, ids in
            if ids.count == 1 { draft.targetAppID = ids[0] }
            else if !ids.contains(draft.targetAppID) { draft.targetAppID = "" }
        }
    }
}

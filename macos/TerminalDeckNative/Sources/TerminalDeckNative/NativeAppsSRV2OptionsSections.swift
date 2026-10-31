import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// SRV2: the app page's option sections — Build, Deploy steps, Health check,
/// Address options, Variables, Storage — for the settings tab's existing Form.
/// Owns one NativeAppsSRV2OptionsModel per app; a different app gets a new one.
struct NativeAppsSRV2OptionsSections: View {
    let serverID: String
    let appID: String
    let appName: String
    /// The page's own state: another change running, or changes unavailable.
    var writesDisabled = false
    @State private var holder = NativeAppsSRV2OptionsHolder()

    var body: some View {
        NativeAppsSRV2OptionsSectionList(model: holder.model(serverID: serverID, appID: appID),
                                         appName: appName, writesDisabled: writesDisabled)
    }
}

/// Keeps the model for the app on screen without making the page re-render.
@MainActor
final class NativeAppsSRV2OptionsHolder {
    private var current: NativeAppsSRV2OptionsModel?

    func model(serverID: String, appID: String) -> NativeAppsSRV2OptionsModel {
        if let current, current.serverID == serverID, current.appID == appID { return current }
        let next = NativeAppsSRV2OptionsModel(serverID: serverID, appID: appID)
        current = next
        return next
    }
}

/// The sections themselves, for a given model.
struct NativeAppsSRV2OptionsSectionList: View {
    @Bindable var model: NativeAppsSRV2OptionsModel
    let appName: String
    var writesDisabled = false

    private typealias Part = NativeAppsSRV2OptionsModel.Part
    private var controlsDisabled: Bool { writesDisabled || model.busy != nil }
    private var loadKey: String { model.serverID + "/" + model.appID }

    var body: some View {
        if let saved = model.saved {
            build.task(id: loadKey) { model.loadIfNeeded() }
            steps
            health
            web(saved)
            variables
            storage
        } else {
            Section("App options") {
                if model.loading {
                    NativePageNote("Reading app options…", busy: true).frame(height: 28)
                } else {
                    NativeCodingAINotice(tone: .error, text: model.loadProblem ?? "The app’s options could not be read.")
                    Button("Read again", action: model.load)
                }
            }
            .task(id: loadKey) { model.loadIfNeeded() }
        }
    }

    // MARK: Build

    private var build: some View {
        Section("Build") {
            NativeSettingRow(label: "App folder", help: "The folder in your code that holds the app. Leave blank for the top folder.") {
                TextField("App folder", text: $model.draft.build.baseDirectory, prompt: Text("Top folder")).labelsHidden().frame(minWidth: 160, maxWidth: 260)
                    .accessibilityLabel("App folder")
            }
            NativeSettingRow(label: "Build file", help: "Leave blank to use the standard build file in the app folder.") {
                TextField("Build file", text: $model.draft.build.dockerfile, prompt: Text("Standard")).labelsHidden().frame(minWidth: 160, maxWidth: 260)
                    .accessibilityLabel("Build file")
            }
            NativeSettingRow(label: "Build stage", help: "Leave blank to build every stage.") {
                TextField("Build stage", text: $model.draft.build.target, prompt: Text("Last stage")).labelsHidden().frame(minWidth: 160, maxWidth: 260)
                    .accessibilityLabel("Build stage")
            }
            NativeSettingRow(label: "Build from scratch each time", help: "Slower, but nothing is reused from earlier builds.") {
                Toggle("Build from scratch each time", isOn: $model.draft.build.noCache).labelsHidden().toggleStyle(.switch)
            }
            NativeSettingsProse(text: "Variables marked “During build” are passed to the build.").font(.callout)
            saveRow(.build)
        }
        .disabled(controlsDisabled)
    }

    // MARK: Deploy steps

    private var steps: some View {
        Section("Deploy steps") {
            VStack(alignment: .leading, spacing: 8) {
                NativeSettingRow(label: "Run before deploy",
                                 help: "Runs once in a copy of the new version before it starts, for example database migrations. If it fails, the current version keeps running.") {
                    EmptyView()
                }
                NativeAppsSRV2TextEditor(text: $model.draft.steps.beforeDeploy, placeholder: "Leave empty to skip",
                                         label: "Command to run before deploy")
            }
            .padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 8) {
                NativeSettingRow(label: "Run after deploy",
                                 help: "Runs inside the new version right after it goes live. If it fails, the previous version is put back.") {
                    EmptyView()
                }
                NativeAppsSRV2TextEditor(text: $model.draft.steps.afterDeploy, placeholder: "Leave empty to skip",
                                         label: "Command to run after deploy")
            }
            .padding(.vertical, 4)
            NativeSettingRow(label: "Time limit", help: "Each command is stopped after this long.") {
                NativeAppsSRV2NumberField(label: "Time limit", value: $model.draft.steps.timeoutSeconds, range: 10...3600, unit: "seconds")
            }
            saveRow(.steps)
        }
        .disabled(controlsDisabled)
    }

    // MARK: Health check

    private var health: some View {
        Section("Health check") {
            NativeSettingsProse(text: "The new version must pass this check before visitors are switched to it.")
            NativeSettingRow(label: "Check the new version") {
                Toggle("Check the new version", isOn: $model.draft.health.enabled).labelsHidden().toggleStyle(.switch)
            }
            if model.draft.health.enabled {
                NativeSettingRow(label: "Path", help: "The page to ask for, such as / or /health.") {
                    TextField("Path", text: $model.draft.health.path, prompt: Text("/")).labelsHidden().frame(minWidth: 160, maxWidth: 260)
                        .accessibilityLabel("Health check path")
                }
                NativeSettingRow(label: "Expected answer", help: "Leave blank to accept any OK answer.") {
                    TextField("Expected answer", value: $model.draft.health.expectedStatus, format: IntegerFormatStyle<Int>().grouping(.never),
                              prompt: Text("Any OK answer"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                        .accessibilityLabel("Expected answer code")
                }
                NativeSettingRow(label: "Check every") {
                    NativeAppsSRV2NumberField(label: "Check every", value: $model.draft.health.intervalSeconds, range: 1...300, unit: "seconds")
                }
                NativeSettingRow(label: "Wait for an answer") {
                    NativeAppsSRV2NumberField(label: "Wait for an answer", value: $model.draft.health.timeoutSeconds, range: 1...120, unit: "seconds")
                }
                NativeSettingRow(label: "Tries") {
                    NativeAppsSRV2NumberField(label: "Tries", value: $model.draft.health.retries, range: 1...20, unit: nil)
                }
                NativeSettingRow(label: "Start time", help: "Time the app gets to start before failed checks count.") {
                    NativeAppsSRV2NumberField(label: "Start time", value: $model.draft.health.startPeriodSeconds, range: 0...900, unit: "seconds")
                }
                NativeSettingsProse(text: "A deploy waits up to \(model.draft.health.deadlineSeconds) seconds for the new version to pass.").font(.callout)
            } else {
                NativeSettingsProse(text: "Visitors are switched as soon as the new version is running.").font(.callout)
            }
            saveRow(.health)
        }
        .disabled(controlsDisabled)
    }

    // MARK: Address options

    private func web(_ saved: NativeAppsOptions) -> some View {
        let httpsLocked = model.router?.forceHTTPSOptional == false
        return Section("Address options") {
            if let note = model.router?.note, !note.isEmpty {
                NativeSettingsProse(text: note)
            } else if let problem = model.routerProblem {
                NativeSettingsProse(text: problem)
            }
            NativeSettingRow(label: "www address", help: "Where visitors land when they type the address with or without www.") {
                Picker("www address", selection: $model.draft.web.redirect) {
                    Text("Keep both").tag(NativeAppsOptions.Redirect.none)
                    Text("Send www to the main address").tag(NativeAppsOptions.Redirect.toApex)
                    Text("Send the main address to www").tag(NativeAppsOptions.Redirect.toWWW)
                }
                .labelsHidden()
                .fixedSize()
            }
            NativeSettingRow(label: "Always use https",
                             help: httpsLocked ? "This server’s address manager decides this." : "Visitors always reach the secure address.") {
                Toggle("Always use https", isOn: $model.draft.web.forceHTTPS).labelsHidden().toggleStyle(.switch)
                    .disabled(httpsLocked)
            }
            NativeSettingRow(label: "Compress pages", help: "Pages reach visitors faster.") {
                Toggle("Compress pages", isOn: $model.draft.web.compression).labelsHidden().toggleStyle(.switch)
            }
            password(saved)
            saveRow(.web)
        }
        .disabled(controlsDisabled)
    }

    @ViewBuilder private func password(_ saved: NativeAppsOptions) -> some View {
        let savedName = saved.hasPassword ? saved.web.password?.username : nil
        let protected = model.draft.web.password != nil
        if let savedName, protected, !model.changingPassword {
            NativeSettingRow(label: "Password protection", help: "Visitors sign in as \(savedName) before they see the app.") {
                HStack(spacing: 8) {
                    Text("A password is set").foregroundStyle(.secondary)
                    Button("Change") { model.changingPassword = true; model.newPassword = "" }
                    Button("Remove") { model.draft.web.password = nil; model.newPassword = "" }
                }
            }
        } else if savedName != nil, !protected {
            NativeSettingRow(label: "Password protection", help: "Saving removes the password. Anyone with the address can open the app.") {
                Button("Keep password") { model.draft.web.password = saved.web.password }
            }
        } else if savedName == nil {
            NativeSettingRow(label: "Password protection", help: "Visitors must sign in before they see the app.") {
                Toggle("Password protection", isOn: Binding(get: { model.draft.web.password != nil }, set: { on in
                    model.draft.web.password = on ? .init(username: "") : nil
                    if !on { model.newPassword = "" }
                }))
                .labelsHidden().toggleStyle(.switch)
            }
        }
        if protected, savedName == nil || model.changingPassword {
            if model.changingPassword {
                NativeSettingRow(label: "Password protection", help: "Enter a new password, then save.") { EmptyView() }
            }
            NativeSettingRow(label: "User name", help: "Letters, numbers, dots, dashes, underscores and @.") {
                TextField("User name", text: Binding(get: { model.draft.web.password?.username ?? "" },
                                                     set: { model.draft.web.password?.username = $0 }), prompt: Text("visitor"))
                    .labelsHidden()
                    .frame(minWidth: 160, maxWidth: 260)
                    .accessibilityLabel("Password protection user name")
            }
            NativeSettingRow(label: savedName == nil ? "Password" : "New password", help: "8 to 72 characters. It is saved only in scrambled form.") {
                SecureField("Password", text: $model.newPassword, prompt: Text("8 or more characters")).labelsHidden().frame(minWidth: 160, maxWidth: 260)
                    .accessibilityLabel(savedName == nil ? "Password" : "New password")
            }
            if model.changingPassword {
                Button("Keep the current password") {
                    model.draft.web.password = saved.web.password
                    model.newPassword = ""
                    model.changingPassword = false
                }
            }
        }
    }

    // MARK: Variables

    private var variables: some View {
        Section("Variables") {
            NativeSettingsProse(text: "Values your app reads, such as keys and passwords. Locked values stay hidden here and from AI tools.")
            if let problem = model.variablesProblem {
                NativeCodingAINotice(tone: .error, text: problem)
                Button("Read again", action: model.load).disabled(model.loading || model.busy != nil)
            } else if model.variableDrafts.isEmpty {
                NativePageNote("No variables yet.").frame(height: 28)
            }
            ForEach($model.variableDrafts) { $row in
                NativeAppsSRV2VariableRow(row: $row, saved: model.variables.first { $0.key == row.key },
                                          startingReplacement: model.startingReplacement(row.key),
                                          appName: appName, busy: controlsDisabled) {
                    model.removeVariable(row.key, writesDisabled: writesDisabled)
                }
            }
            if model.variablesProblem == nil {
                NativeAppsSRV2NewVariableRow(variable: $model.newVariable)
            }
            NativeSettingsProse(text: "New values reach the app on its next deploy.").font(.callout)
            saveRow(.variables)
        }
        .disabled(controlsDisabled)
    }

    // MARK: Storage

    private var storage: some View {
        Section("Storage") {
            NativeSettingsProse(text: "Keep the app’s files between deploys, or give it a file or a folder from the server.")
            if model.storage.isEmpty {
                NativePageNote("No storage yet.").frame(height: 28)
            }
            ForEach($model.storage) { $item in
                NativeAppsSRV2StorageRow(item: $item, appName: appName, busy: controlsDisabled) {
                    model.removeStorage(item.id)
                }
            }
            Menu("Add storage") {
                Button { model.addStorage(.volume) } label: { Label("Saved volume", systemImage: "externaldrive") }
                Button { model.addStorage(.file) } label: { Label("File", systemImage: "doc.text") }
                Button { model.addStorage(.folder) } label: { Label("Server folder", systemImage: "folder") }
            }
            .menuStyle(.button)
            .fixedSize()
            .accessibilityLabel("Add storage")
            saveRow(.storage)
        }
        .disabled(controlsDisabled)
    }

    // MARK: Save

    /// Save (and Undo changes) for one section, then that section's result.
    @ViewBuilder private func saveRow(_ part: Part) -> some View {
        let changed = model.isChanged(part)
        HStack(spacing: 8) {
            Button("Save") { model.save(part, writesDisabled: writesDisabled) }
                .buttonStyle(.borderedProminent)
                .disabled(!changed || controlsDisabled)
            if changed {
                Button("Undo changes") { model.revert(part) }
                    .disabled(controlsDisabled)
            }
        }
        if model.resultPart == part {
            if let busy = model.busy {
                NativePageNote(busy + "…", busy: true).frame(height: 28)
            } else if let problem = model.problem {
                NativeCodingAINotice(tone: .error, text: problem)
            } else if let note = model.note {
                NativeSettingsProse(text: note).font(.callout)
            }
        }
    }
}

// MARK: - Rows

/// One saved variable: name, value (hidden when locked), where it is used,
/// its lock, a replacement editor and removal with confirmation.
struct NativeAppsSRV2VariableRow: View {
    @Binding var row: NativeAppsSRV2OptionsModel.VariableDraft
    let saved: NativeAppsVariable?
    let startingReplacement: String
    let appName: String
    let busy: Bool
    let onRemove: () -> Void
    @State private var removing = false

    private var changed: Bool {
        guard let saved else { return false }
        return row.build != saved.build || row.run != saved.run || row.locked != saved.locked || row.replacement != nil
    }

    private var shownValue: String {
        guard let saved else { return "" }
        if saved.locked { return NativeAppsVariable.mask }
        if saved.value.isEmpty { return "Empty" }
        let first = saved.value.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return saved.multiline ? first + " …" : first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.key).font(.callout.weight(.medium)).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle).help(row.key)
                    Text(shownValue).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .accessibilityLabel(saved?.locked == true ? "Value hidden" : "Value \(shownValue)")
                }
                Spacer(minLength: 12)
                if changed {
                    Text("Not saved").font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    row.locked.toggle()
                } label: {
                    Image(systemName: row.locked ? "lock" : "lock.open")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(row.locked ? "Locked: the value stays hidden here and from AI tools." : "Unlocked: the value is shown here and to AI tools.")
                .accessibilityLabel(row.locked ? "Unlock \(row.key)" : "Lock \(row.key)")
                Button(row.replacement == nil ? "Replace value" : "Cancel") {
                    row.replacement = row.replacement == nil ? startingReplacement : nil
                }
                Button("Remove…", role: .destructive) { removing = true }
            }
            HStack(spacing: 12) {
                Toggle("During build", isOn: $row.build).toggleStyle(.checkbox)
                Toggle("While running", isOn: $row.run).toggleStyle(.checkbox)
            }
            .font(.callout)
            if row.replacement != nil {
                NativeAppsSRV2TextEditor(text: Binding(get: { row.replacement ?? "" }, set: { row.replacement = $0 }),
                                         placeholder: "New value", label: "New value for \(row.key)")
            }
        }
        .padding(.vertical, 4)
        .disabled(busy)
        .alert("Remove \(row.key) from \(appName)?", isPresented: $removing) {
            Button("Cancel", role: .cancel) {}
            Button("Remove variable", role: .destructive, action: onRemove)
        } message: {
            Text("The app will no longer receive \(row.key) after its next deploy. You can add it again with a new value.")
        }
    }
}

/// "Add a variable": a name, a value that may span lines, and where it is used.
struct NativeAppsSRV2NewVariableRow: View {
    @Binding var variable: NativeAppsSRV2OptionsModel.NewVariable

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a variable").font(.callout.weight(.medium))
            NativeSettingRow(label: "Name", help: "Use letters, numbers and underscores, such as API_KEY.") {
                TextField("Name", text: $variable.key, prompt: Text("API_KEY")).labelsHidden().frame(minWidth: 160, maxWidth: 260)
                    .accessibilityLabel("New variable name")
            }
            NativeSettingRow(label: "Value") { EmptyView() }
            NativeAppsSRV2TextEditor(text: $variable.value, placeholder: "Value", label: "New variable value")
            HStack(spacing: 12) {
                Toggle("During build", isOn: $variable.build).toggleStyle(.checkbox)
                Toggle("While running", isOn: $variable.run).toggleStyle(.checkbox)
                Toggle("Locked", isOn: $variable.locked).toggleStyle(.checkbox)
                    .help("Locked values stay hidden here and from AI tools.")
            }
            .font(.callout)
        }
        .padding(.vertical, 4)
    }
}

/// One storage item: what it is, where the app sees it, where it comes from.
struct NativeAppsSRV2StorageRow: View {
    @Binding var item: NativeAppsSRV2OptionsModel.StorageDraft
    let appName: String
    let busy: Bool
    let onRemove: () -> Void
    @State private var removing = false

    private var kind: NativeAppsOptions.MountKind { item.mount.kind }

    private var symbol: String {
        switch kind {
        case .volume: "externaldrive"
        case .file: "doc.text"
        case .folder: "folder"
        }
    }

    private var title: String {
        switch kind {
        case .volume: "Saved volume"
        case .file: "File"
        case .folder: "Server folder"
        }
    }

    private var removalMessage: String {
        switch kind {
        case .volume: "The app stops using it after you save. The saved volume and its data stay on the server."
        case .file: "The app stops receiving this file after you save, and its text is removed."
        case .folder: "The app stops using this folder after you save. The folder and its files stay on the server."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
                    .accessibilityHidden(true)
                Text(title).font(.callout.weight(.medium))
                Spacer(minLength: 12)
                Toggle("Read only", isOn: $item.mount.readOnly).toggleStyle(.checkbox).font(.callout)
                    .help("The app can read it but not change it.")
                Button("Remove…", role: .destructive) { removing = true }
            }
            NativeSettingRow(label: "Inside the app", help: "Where the app finds it, starting with /.") {
                TextField("Inside the app", text: $item.mount.path, prompt: Text(kind == .file ? "/app/config.json" : "/data")).labelsHidden().frame(minWidth: 160, maxWidth: 260)
                    .accessibilityLabel("\(title) path inside the app")
            }
            switch kind {
            case .volume:
                NativeSettingRow(label: "Volume name", help: "Lowercase letters, numbers, dots and dashes. Its data is kept between deploys.") {
                    TextField("Volume name", text: $item.mount.source, prompt: Text("myapp-data")).labelsHidden().frame(minWidth: 160, maxWidth: 260)
                        .accessibilityLabel("Saved volume name")
                }
            case .folder:
                NativeSettingRow(label: "Server folder", help: "A folder of your own on the server, such as /srv/myapp/uploads.") {
                    TextField("Server folder", text: $item.mount.source, prompt: Text("/srv/myapp/uploads")).labelsHidden().frame(minWidth: 160, maxWidth: 260)
                        .accessibilityLabel("Folder on the server")
                }
            case .file:
                NativeSettingRow(label: "File contents", help: "Plain text, up to 64 KB.") { EmptyView() }
                NativeAppsSRV2TextEditor(text: Binding(get: { item.mount.content ?? "" }, set: { item.mount.content = $0 }),
                                         placeholder: "File contents", label: "Contents of \(item.mount.path.isEmpty ? "the file" : item.mount.path)")
            }
        }
        .padding(.vertical, 4)
        .disabled(busy)
        .alert("Remove this \(title.lowercased()) from \(appName)?", isPresented: $removing) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive, action: onRemove)
        } message: {
            Text(removalMessage)
        }
    }
}

// MARK: - Small controls

/// A multi-line, monospaced editor in the look of the app's other editors
/// (NativeAGSControls), with a quiet placeholder.
struct NativeAppsSRV2TextEditor: View {
    @Binding var text: String
    let placeholder: String
    let label: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.callout, design: .monospaced))
            .scrollContentBackground(.hidden)
            .autocorrectionDisabled()
            .frame(minHeight: 64, maxHeight: 120)
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(label)
    }
}

/// A whole number with a unit and a stepper, as NativeSettingNumberField lays it out.
struct NativeAppsSRV2NumberField: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: String?

    var body: some View {
        HStack(spacing: 4) {
            TextField(label, value: Binding(get: { value }, set: { value = min(range.upperBound, max(range.lowerBound, $0)) }),
                      format: IntegerFormatStyle<Int>().grouping(.never))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
            if let unit {
                Text(unit).foregroundStyle(.secondary)
            }
            Stepper(label, value: $value, in: range).labelsHidden()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

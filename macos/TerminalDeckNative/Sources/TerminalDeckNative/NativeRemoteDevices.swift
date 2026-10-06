import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// The four per-device lists under "Your own devices", drawn in Swift — the web's
/// `remote/DeviceFolders.tsx`, `DeviceSessions.tsx`, `DeviceLogins.tsx` and
/// `DeviceWindows.tsx` one-to-one: the folders a guest may open (with the hold
/// sentence and the one-time administrator grant), the sessions a device may
/// open, the logins it may use, and the devices that may act on browser windows.
/// Each reads and writes its own channel, the page's: `remote:folders(:set)`,
/// `confine:state` / `confine:grant`, `remote:sessions(:running|:set)`,
/// `remote:accounts(:set)`, `remote:windows(:set)`.

// MARK: - Shared pieces

/// A settings group: its quiet title, then what it holds — the page's `Group`.
struct RemoteGroup<Content: View>: View {
    let title: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 22)
    }
}

/// The page's settings `Notice`: a tinted box, with a small dot for a warning (orange)
/// or an error (red); an info notice has no dot.
struct RemoteNotice: View {
    enum Tone { case info, warn, error }
    let tone: Tone
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if tone != .info {
                Circle()
                    .fill(tone == .warn ? Color.orange : Color.red)
                    .frame(width: 7, height: 7)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    .accessibilityHidden(true)
            }
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(tone == .info ? [] : .updatesFrequently)
    }
}

/// A sentence with its "i" beside it — the page's `settings-label-line` + `HoverNote`.
struct RemoteProse: View {
    let text: Text
    var noteLabel: String?
    var note: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            text
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let noteLabel, let note { NativeCodingAIInfo(label: noteLabel, text: note) }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }
}

/// The page's `SegmentedSwitch` with All / Selected.
struct RemoteShareSwitch: View {
    let label: String
    let value: RemoteShare
    let disabled: Bool
    let change: (RemoteShare) -> Void

    var body: some View {
        Picker(label, selection: Binding(get: { value }, set: { change($0) })) {
            ForEach(RemoteShare.allCases, id: \.self) { mode in Text(mode.label).tag(mode) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}

/// A folder as the lists show it: its name, and the whole path quieter beneath.
struct RemoteFolderLabel: View {
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(RemoteGrants.folderName(path))
            Text(path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
        }
    }
}

@MainActor
enum RemoteCall {
    /// One engine call; the page's `errorText(error, fallback)` for a failure.
    static func invoke(_ channel: String, _ args: [Any?] = []) async throws -> Any {
        try await EngineBridge.shared.invoke(channel, args)
    }

    static func text(_ error: Error, _ fallback: String) -> String {
        let said = EngineDeadline.describe(error)
        return said.isEmpty ? fallback : said
    }
}

// MARK: - Folders a guest may open

@MainActor
@Observable
final class RemoteFoldersModel {
    private(set) var grants: [String: [String]]?
    private(set) var problem: String?
    private(set) var busy: String?
    private(set) var confine: RemoteGrants.Confine?
    private(set) var granting = false
    private(set) var grantProblem: String?

    func load() async {
        await read()
        confine = RemoteGrants.Confine(json: try? await RemoteCall.invoke("confine:state"))
    }

    func read() async {
        do {
            grants = RemoteGrants.folders(try await RemoteCall.invoke("remote:folders"))
            problem = nil
        } catch {
            problem = RemoteCall.text(error, "Could not read which folders each device may use.")
        }
    }

    func grant() async {
        granting = true
        grantProblem = nil
        do {
            let outcome = RemoteGrants.grantOutcome(try await RemoteCall.invoke("confine:grant"))
            confine = outcome.state
            grantProblem = outcome.problem
        } catch {
            grantProblem = RemoteCall.text(error, "That did not go through.")
        }
        granting = false
    }

    private func write(_ deviceId: String, _ folders: [String]) async {
        busy = deviceId
        do {
            grants = RemoteGrants.folders(try await RemoteCall.invoke("remote:folders:set", [deviceId, folders]))
            problem = nil
        } catch {
            problem = RemoteCall.text(error, "Could not save that. The folder list is unchanged.")
            await read()
        }
        busy = nil
    }

    func add(_ deviceId: String) async {
        let chosen: String?
        do {
            chosen = try await RemoteCall.invoke("project:pick") as? String
        } catch {
            problem = RemoteCall.text(error, "The folder chooser did not open.")
            return
        }
        guard let chosen, !chosen.isEmpty else { return }
        let current = grants?[deviceId] ?? []
        guard !current.contains(chosen) else { return }
        await write(deviceId, current + [chosen])
    }

    func remove(_ deviceId: String, _ folder: String) async {
        await write(deviceId, (grants?[deviceId] ?? []).filter { $0 != folder })
    }
}

struct RemoteFoldersView: View {
    let devices: [RemoteDevice]
    @State private var model = RemoteFoldersModel()

    var body: some View {
        let machine = RemoteRules.thisMachine
        RemoteGroup("Folders a guest may open") {
            if RemoteGrants.holdsSessions(model.confine) {
                RemoteProse(text: Text("Pick which folders each guest can use. On \(machine) a session started from a device is ") + Text("held inside them").bold() + Text("."),
                            noteLabel: "what a held session can reach",
                            note: "It can read and write those folders and nothing else. Not your other projects, not your home folder, not your keys, not the accounts you are signed in to. It still runs node, git and the agent tools, and it still reaches the internet. It gets a home folder of its own, so it starts signed out of those tools until that device signs in. If a session cannot be held inside its folder, it does not start at all. A guest only sees the sessions running inside these folders — including ones you started. Everything else on \(machine) is invisible to it, and stops being reachable the moment you take a folder away.")
            } else if let confine = model.confine, confine.canGrant {
                RemoteProse(text: Text("Pick which folders each guest can use. On \(machine) a session started from a device can be ") + Text("held inside them").bold()
                            + Text(", but only an administrator can grant that once.") + Text(" Until you do, a session from a device runs unconfined").bold()
                            + Text(" and can reach anything your account can."),
                            noteLabel: "the one-time permission", note: RemoteGrants.grantNote(confine))
                if let problem = model.grantProblem { RemoteNotice(tone: .error, text: problem) }
                Button(model.granting ? "Waiting for the administrator prompt…" : "Hold sessions inside their folders") {
                    Task { await model.grant() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.granting)
            } else {
                RemoteProse(text: Text("Pick where each guest can start a session. On \(machine), ") + Text("that is all this does").bold()
                            + Text(" — it is for keeping your own devices tidy, not for keeping anyone out."),
                            noteLabel: "why this is not a boundary",
                            note: "A session is a shell, and once it is running it can move to any other folder, the same as one you start here. This build cannot hold a session inside its folder here, so choosing one says where a device starts and nothing about where it can go.")
            }

            if let problem = model.problem {
                RemoteNotice(tone: .error, text: "\(problem) What is below may be out of date.")
            }
            if let grants = model.grants, devices.contains(where: { grants[$0.id] == nil }) {
                RemoteSentence( "A device paired before folder approval existed has nothing chosen for it, so it can open nothing on \(machine). Add a folder here, or revoke it and pair it again.")
            }

            if devices.isEmpty {
                RemoteSentence( "No guest device has been let in, so there is nothing to choose for. Your own devices have full access and are not listed here.")
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(devices) { device in
                        let chosen = model.grants?[device.id]
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(device.name).font(.body.weight(.medium))
                                Text(RemoteGrants.folderSummary(chosen, loaded: model.grants != nil)).font(.callout).foregroundStyle(.secondary)
                            }
                            if let chosen, !chosen.isEmpty {
                                ForEach(chosen, id: \.self) { folder in
                                    HStack {
                                        RemoteFolderLabel(path: folder)
                                        Spacer()
                                        Button("Remove") { Task { await model.remove(device.id, folder) } }
                                            .disabled(model.busy != nil)
                                    }
                                    .padding(.leading, 12)
                                }
                            }
                            Button(model.busy == device.id ? "Saving…" : "Add a folder…") { Task { await model.add(device.id) } }
                                .disabled(model.busy != nil)
                        }
                    }
                }
            }
        }
        .task { await model.load() }
    }
}

// MARK: - Sessions a device may open

@MainActor
@Observable
final class RemoteSessionsModel {
    private(set) var choices: [String: RemoteGrants.Choice]?
    private(set) var running: [RemoteGrants.Running] = []
    private(set) var problem: String?
    private(set) var busy: String?
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []

    func start() async {
        if subscriptions.isEmpty {
            subscriptions = ["session:created", "session:removed", "session:exit"].map { channel in
                EngineBridge.shared.on(channel) { [weak self] _ in Task { await self?.read() } }
            }
        }
        await read()
    }

    func stop() {
        for subscription in subscriptions { subscription.cancel() }
        subscriptions = []
    }

    func read() async {
        do {
            let grants = try await RemoteCall.invoke("remote:sessions")
            let live = try await RemoteCall.invoke("remote:sessions:running")
            choices = RemoteGrants.choices(grants, listKey: "sessions")
            running = RemoteGrants.running(live)
            problem = nil
        } catch {
            problem = RemoteCall.text(error, "Could not read which sessions each device may open.")
        }
    }

    func choice(_ deviceId: String) -> RemoteGrants.Choice { choices?[deviceId] ?? .all }

    private func write(_ deviceId: String, _ mode: RemoteShare, _ sessions: [String]) async {
        busy = deviceId
        do {
            choices = RemoteGrants.choices(try await RemoteCall.invoke("remote:sessions:set", [deviceId, mode.rawValue, sessions]), listKey: "sessions")
            problem = nil
        } catch {
            problem = RemoteCall.text(error, "Could not save that. The session list is unchanged.")
            await read()
        }
        busy = nil
    }

    func setMode(_ deviceId: String, _ mode: RemoteShare) async {
        let current = choice(deviceId)
        guard current.mode != mode else { return }
        await write(deviceId, mode, mode == .selected ? current.ids : [])
    }

    func toggle(_ deviceId: String, _ sessionId: String, on: Bool) async {
        await write(deviceId, .selected, RemoteGrants.toggled(choice(deviceId), id: sessionId, on: on))
    }
}

struct RemoteSessionsView: View {
    let devices: [RemoteDevice]
    @State private var model = RemoteSessionsModel()

    var body: some View {
        Group {
            if !devices.isEmpty {
                RemoteGroup("Sessions a device may open") {
                    if let problem = model.problem { Text(problem).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently) }
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(devices) { device in
                            let choice = model.choice(device.id)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(device.name).font(.body.weight(.medium))
                                    Spacer()
                                    RemoteShareSwitch(label: "Sessions \(device.name) may open", value: choice.mode, disabled: model.busy != nil) { mode in
                                        Task { await model.setMode(device.id, mode) }
                                    }
                                }
                                if choice.mode == .selected {
                                    ForEach(model.running) { session in
                                        Toggle(isOn: Binding(get: { choice.ids.contains(session.id) },
                                                             set: { on in Task { await model.toggle(device.id, session.id, on: on) } })) {
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(session.title)
                                                Text(session.cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(session.cwd)
                                            }
                                        }
                                        .toggleStyle(.checkbox)
                                        .disabled(model.busy != nil)
                                        .padding(.leading, 12)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .task { await model.start() }
        .onDisappear { model.stop() }
    }
}

// MARK: - Logins a device may use

@MainActor
@Observable
final class RemoteLoginsModel {
    private(set) var choices: [String: RemoteGrants.Choice]?
    private(set) var problem: String?
    private(set) var busy: String?

    func read() async {
        do {
            choices = RemoteGrants.choices(try await RemoteCall.invoke("remote:accounts"), listKey: "accounts")
            problem = nil
        } catch {
            problem = RemoteCall.text(error, "Could not read which logins each device may use.")
        }
    }

    func choice(_ deviceId: String) -> RemoteGrants.Choice { choices?[deviceId] ?? .all }

    private func write(_ deviceId: String, _ mode: RemoteShare, _ accounts: [String]) async {
        busy = deviceId
        do {
            choices = RemoteGrants.choices(try await RemoteCall.invoke("remote:accounts:set", [deviceId, mode.rawValue, accounts]), listKey: "accounts")
            problem = nil
        } catch {
            problem = RemoteCall.text(error, "Could not save that. The login list is unchanged.")
            await read()
        }
        busy = nil
    }

    func setMode(_ deviceId: String, _ mode: RemoteShare) async {
        let current = choice(deviceId)
        guard current.mode != mode else { return }
        await write(deviceId, mode, mode == .selected ? current.ids : [])
    }

    func toggle(_ deviceId: String, _ accountId: String, on: Bool) async {
        await write(deviceId, .selected, RemoteGrants.toggled(choice(deviceId), id: accountId, on: on))
    }
}

/// This Mac's logins as the approval and the logins list name them (`profileLoginLabel`).
@MainActor
enum RemoteLogins {
    static var rows: [(id: String, label: String)] {
        let store = NativeCodingAIStore.shared
        return store.snapshot.accounts.map { (id: $0.id, label: CodingAIAccountLabels.profileLoginLabel($0, store.signIn[$0.id])) }
    }
}

struct RemoteLoginsView: View {
    let devices: [RemoteDevice]
    @State private var model = RemoteLoginsModel()

    var body: some View {
        Group {
            if !devices.isEmpty {
                RemoteGroup("Logins a device may use") {
                    if let problem = model.problem { Text(problem).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently) }
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(devices) { device in
                            let choice = model.choice(device.id)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(device.name).font(.body.weight(.medium))
                                    Spacer()
                                    RemoteShareSwitch(label: "Logins \(device.name) may use", value: choice.mode, disabled: model.busy != nil) { mode in
                                        Task { await model.setMode(device.id, mode) }
                                    }
                                }
                                if choice.mode == .selected {
                                    ForEach(RemoteLogins.rows, id: \.id) { login in
                                        Toggle(login.label, isOn: Binding(get: { choice.ids.contains(login.id) },
                                                                          set: { on in Task { await model.toggle(device.id, login.id, on: on) } }))
                                            .toggleStyle(.checkbox)
                                            .disabled(model.busy != nil)
                                            .padding(.leading, 12)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .task {
            NativeCodingAIStore.shared.reloadAccounts()
            await model.read()
        }
    }
}

// MARK: - Devices that may act on browser windows here

@MainActor
@Observable
final class RemoteWindowsModel {
    private(set) var allowed: Set<String>?
    private(set) var problem: String?
    private(set) var busy: String?

    func read() async {
        do {
            allowed = RemoteGrants.windows(try await RemoteCall.invoke("remote:windows"))
            problem = nil
        } catch {
            problem = RemoteCall.text(error, "Could not read which devices may act on browser windows here.")
        }
    }

    func set(_ deviceId: String, _ on: Bool) async {
        busy = deviceId
        do {
            allowed = RemoteGrants.windows(try await RemoteCall.invoke("remote:windows:set", [deviceId, on]))
            problem = nil
        } catch {
            problem = RemoteCall.text(error, "Could not save that. Nothing changed.")
            await read()
        }
        busy = nil
    }
}

struct RemoteWindowsView: View {
    let devices: [RemoteDevice]
    @State private var model = RemoteWindowsModel()

    var body: some View {
        Group {
            if !devices.isEmpty {
                RemoteGroup("Devices that may act on browser windows here") {
                    if let problem = model.problem { Text(problem).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently) }
                    ForEach(devices) { device in
                        Toggle(device.name, isOn: Binding(get: { model.allowed?.contains(device.id) == true },
                                                          set: { on in Task { await model.set(device.id, on) } }))
                            .toggleStyle(.checkbox)
                            .disabled(model.busy != nil)
                    }
                }
            }
        }
        .task { await model.read() }
    }
}

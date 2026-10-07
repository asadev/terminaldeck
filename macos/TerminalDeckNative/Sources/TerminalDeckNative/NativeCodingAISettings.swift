import SwiftUI
import TerminalDeckNativeCore

/// Settings → Coding AI, drawn in Swift.
///
/// The same subject as the web section (`AgentsSection.tsx`), on one pane: where
/// the agents run (this Mac, the servers, each linked device), the default
/// coding tool, the primary account, the accounts of every agent with their
/// sign-in state, and the Setup warning. Every control calls the engine channel
/// the web one calls; signing in opens a session in the main window, which is
/// where the agent's own login runs.
struct NativeCodingAISettings: View {
    @State private var store = NativeCodingAIStore.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var activeState
    private let app = AppModel.shared

    var body: some View {
        Group {
            if app.engineIsUp {
                form
            } else {
                ContentUnavailableView("Terminal Deck isn't running",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text("Use Try Again in the main window."))
            }
        }
        .onAppear {
            NativeSettingsValues.shared.start()
            store.refreshAll()
            store.scopeShown(store.scope)
        }
        .onDisappear { store.screenLeft() }
        .onChange(of: app.engineIsUp) { _, up in
            if up {
                store.refreshAll()
                store.scopeShown(store.scope)
            }
        }
        .onChange(of: store.scope) { _, scope in store.scopeShown(scope) }
        .onChange(of: activeState) { _, state in if state == .key { store.windowCameForward() } }
        // Signing in opened a session in the main window: bring it forward, where the login is.
        .onChange(of: store.mainWindowRequest) { _, _ in
            let open = openWindow
            NativeFront.whenPersonActs("main") { open(id: "main") }
        }
        .sheet(isPresented: $store.addingPresented) {
            NativeCodingAIAddAccountSheet(store: store)
        }
    }

    private var form: some View {
        Form {
            Section {
                NativeCodingAIScopePicker(store: store)
            } header: {
                NativeSettingsHead(title: SettingsSchema.section("agents")?.label ?? "Coding AI",
                                   blurb: SettingsSchema.section("agents")?.blurb)
            }

            switch store.scope {
            case .servers:
                NativeCodingAIServersSection(model: store.serversModel)
            case .device(let id):
                if let device = store.machines.devices.first(where: { $0.id == id }) {
                    NativeCodingAIDeviceSection(device: device, model: store.deviceModel(id))
                }
            case .thisMachine:
                NativeCodingAIThisMachine(store: store)
            }
        }
        .formStyle(.grouped)
        // The page's foot: whether the last change saved, and Shortcuts.
        .safeAreaInset(edge: .bottom, spacing: 0) { NativeSettingsFoot() }
    }
}

/// The switch at the top: this Mac (by name), Servers, then each linked device.
struct NativeCodingAIScopePicker: View {
    @Bindable var store: NativeCodingAIStore

    var body: some View {
        let seats = CodingAIScopes.seats(here: store.machines.here, devices: store.machines.devices)
        Picker("Where these agents run", selection: $store.scope) {
            ForEach(seats) { seat in
                Text(seat.label).tag(seat.scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Where these agents run")
    }
}

// MARK: - This machine

struct NativeCodingAIThisMachine: View {
    @Bindable var store: NativeCodingAIStore

    var body: some View {
        Section {
            if let error = store.sectionError {
                NativeCodingAINotice(tone: .error, text: error)
            }
            defaultToolRow
            primaryAccountRow
        }

        NativeCodingAIAccountsSections(store: store)

        if store.setupWarning != nil || store.setupError != nil {
            Section {
                if let error = store.setupError { NativeCodingAINotice(tone: .error, text: error) }
                if let warning = store.setupWarning { NativeCodingAINotice(tone: .warn, text: warning) }
            }
        }
    }

    private var defaultToolRow: some View {
        let options = CodingAIDefaultTool.options(store.prerequisites)
        return VStack(alignment: .leading, spacing: 4) {
            Picker(selection: Binding(get: { store.defaultTool }, set: { store.setDefaultTool($0) })) {
                ForEach(options) { option in
                    Text(option.title)
                        .tag(option.value)
                        .disabled(option.disabled)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(CodingAIDefaultTool.label)
                        NativeCodingAIInfo(label: CodingAIDefaultTool.label, text: CodingAIDefaultTool.more)
                    }
                    Text(CodingAIDefaultTool.help)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!store.defaultToolLoaded)
        }
    }

    @ViewBuilder private var primaryAccountRow: some View {
        let choices = withSelected(CodingAIPrimaryAccount.choices(store.snapshot.accounts, providerRows: store.providerRows))
        Picker(selection: Binding(
            get: { CodingAIPrimaryAccount.selected(defaultId: store.snapshot.defaultId) },
            set: { store.choosePrimary($0) })
        ) {
            ForEach(choices) { account in
                Text(CodingAIAccountLabels.profileLoginLabel(account, store.signIn[account.id]))
                    .tag(account.id)
            }
        } label: {
            HStack(spacing: 4) {
                Text(CodingAIPrimaryAccount.label)
                NativeCodingAIInfo(label: CodingAIPrimaryAccount.label, text: CodingAIPrimaryAccount.more)
            }
        }
        .disabled(choices.isEmpty)
    }

    /// The stored default always has a row, so the picker never shows a blank.
    private func withSelected(_ choices: [CodingAIAccount]) -> [CodingAIAccount] {
        let selected = CodingAIPrimaryAccount.selected(defaultId: store.snapshot.defaultId)
        guard !choices.contains(where: { $0.id == selected }),
              let account = store.snapshot.accounts.first(where: { $0.id == selected }) else { return choices }
        return choices + [account]
    }
}

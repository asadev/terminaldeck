import Observation
import SwiftUI
import TerminalDeckNativeCore

/// Which AI Settings › Agents shows (Coding AIs' Default model / Default effort rows open it on their AI).
@MainActor @Observable
final class NativeAGSPageChoice {
    static let shared = NativeAGSPageChoice()
    var provider = "claude"
}

/// The one draft of the app-wide agent defaults, shared by the Agents page and its Hooks page so going from one to
/// the other keeps unsaved changes.
@MainActor
enum NativeAGSAppDefaults {
    static let model = NativeAGSSettingsModel()
    /// Read once; a draft with changes is kept as it is (never reloaded over).
    static func open() async {
        if model.loaded, model.hasChanges { return }
        await model.start()
    }
    static func close() { if !model.hasChanges { model.stop() } }
    /// The AIs the segmented control offers: installed ones only (all three until the installed list is read).
    static func installed(_ present: [CodingAITool]?) -> [String] {
        let known = ["claude", "codex", "gemini"]
        guard let present else { return known }
        let ids = Set(present.map(\.id))
        let shown = known.filter { ids.contains($0) }
        return shown.isEmpty ? known : shown
    }
}

/// The top bar's one action while the draft has changes: Discard, Save (owner: nothing extra on the page itself).
struct NativeAGSSaveBar: View {
    var model: NativeAGSSettingsModel
    var body: some View {
        if model.hasChanges || model.saving {
            HStack(spacing: DeckTokens.Spacing.s8) {
                Button("Discard") { model.discardChanges() }.disabled(model.busy)
                Button(model.saving ? "Saving…" : "Save") { Task { await model.save() } }
                    .buttonStyle(.borderedProminent).disabled(!model.canSave)
            }
        }
    }
}

/// Settings › Agents (owner, 15 Nov; DESIGN.md section 6): a segmented control of the installed AIs at the top, then
/// Defaults · Budgets · Behaviour for that AI, and one row to the Terminal Deck hooks.
struct NativeAGSDefaultsSettingsSections: View {
    var model = NativeAGSAppDefaults.model
    var choice = NativeAGSPageChoice.shared
    /// Pictures pass the installed AIs.
    var fixtureProviders: [String]? = nil
    @Environment(\.deckSettingsOpen) private var open

    var body: some View {
        @Bindable var model = model
        @Bindable var choice = choice
        let providers = fixtureProviders ?? NativeAGSAppDefaults.installed(NativeCodingAIStore.shared.prerequisites?.agentsPresent)
        let shown = providers.contains(choice.provider) ? choice.provider : (providers.first ?? "claude")
        DeckSettingsScaffold(title: "Agents", trailing: AnyView(NativeAGSSaveBar(model: model))) {
            if providers.count > 1 {
                Picker("AI", selection: Binding(get: { shown }, set: { choice.provider = $0 })) {
                    ForEach(providers, id: \.self) { Text(NativeAGSWords.provider($0)).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .frame(maxWidth: .infinity)
            }
            if let problem = model.problem { DeckSettingsGroup { DeckSettingsProblem(text: problem) } }
            if model.loaded || fixtureProviders != nil {
                NativeAGSDefaultsEditor(defaults: $model.defaults, busy: model.busy, savedHooks: model.savedDefaults.hooks,
                                        testHook: { id in try await model.testHook(id) }, provider: shown)
                DeckSettingsGroup {
                    DeckSettingsLinkRow(title: "Terminal Deck hooks", value: model.defaults.hooks.isEmpty ? nil : "\(model.defaults.hooks.count)") {
                        open(NativeSettingsNavigation.agentHooksID)
                    }
                }
            } else if model.loading {
                DeckSettingsGroup("Defaults") {
                    DeckSettingsRow("Model", state: "Default")
                    DeckSettingsRow("Thinking", state: "Default")
                    DeckSettingsRow("Permission", state: "Default")
                }
                .redacted(reason: .placeholder).accessibilityLabel("Reading agent settings")
            } else {
                DeckSettingsGroup {
                    DeckSettingsButtonRow(title: "Read again") { Task { await model.load(discardDraft: true) } }
                }
            }
        }
        .task { if fixtureProviders == nil { await NativeAGSAppDefaults.open() } }
        .onDisappear { if fixtureProviders == nil { NativeAGSAppDefaults.close() } }
    }
}

/// Settings › Agents › Terminal Deck hooks.
struct NativeAGSHooksPage: View {
    var model = NativeAGSAppDefaults.model
    var body: some View {
        @Bindable var model = model
        DeckSettingsScaffold(title: "Terminal Deck hooks", trailing: AnyView(HStack(spacing: DeckTokens.Spacing.s8) {
            DeckSettingsInfoButton(label: "Terminal Deck hooks", text: NativeAGSAppHooksEditor.info)
            NativeAGSSaveBar(model: model)
        })) {
            if let problem = model.problem { DeckSettingsGroup { DeckSettingsProblem(text: problem) } }
            if model.loaded {
                NativeAGSAppHooksEditor(defaults: $model.defaults, busy: model.busy, savedHooks: model.savedDefaults.hooks,
                                     testHook: { id in try await model.testHook(id) })
            }
        }
        .task { await NativeAGSAppDefaults.open() }
        .onDisappear { NativeAGSAppDefaults.close() }
    }
}

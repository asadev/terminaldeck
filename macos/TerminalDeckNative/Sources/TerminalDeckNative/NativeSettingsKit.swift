import Observation
import SwiftUI
import TerminalDeckNativeCore

// What every native Settings section is built from — the native counterparts of
// `settings/controls.tsx` and the Settings page around a section
// (`SettingsWindow.tsx`'s load and save, `SettingsPage.tsx`'s foot):
//
//  - `NativeSettingsValues`: the stored values (settings file + preferences, read
//    over the engine), saved the way the page saves them, and handed back to the
//    main window on the settings relay after every save, as the page does.
//  - `NativeSettingsPage`: the section's heading and line, the load error, the
//    rows, and the foot (save status, Shortcuts).
//  - `NativeSettingRow` / `NativeSettingControl` / `NativeSettingsList`: one row
//    of the table — label, ⓘ, help line, and the control on the right.

@MainActor
@Observable
final class NativeSettingsValues {
    static let shared = NativeSettingsValues()

    /// Every value, merged (defaults filled, old names moved, preferences winning).
    private(set) var values: [String: CodingAIJSON] = SettingsSchema.defaults
    /// True until the stored values have arrived; controls stay disabled.
    private(set) var loading = true
    private(set) var loadError: String?
    private(set) var saveState: SettingsSaveState = .idle
    /// The page's `features.v2` store, which decides the feature-owned rows.
    private(set) var featureState: String?

    @ObservationIgnored private var loadId = 0
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var saveClear: Task<Void, Never>?

    private init() {}

    private func call(_ channel: String, _ args: [Any?] = []) async throws -> CodingAIJSON {
        CodingAIJSON(try await EngineBridge.shared.invoke(channel, args))
    }

    /// Read everything, once per visit to a section (the page reads on open).
    func start() {
        if subscriptions.isEmpty, EngineBridge.shared.isReady {
            // A stored value changed somewhere else — the copilot, a paired device.
            subscriptions = [
                EngineBridge.shared.on("prefs:changed") { [weak self] _ in self?.load() },
                EngineBridge.shared.on("settings:changed") { [weak self] _ in self?.load() },
            ]
        }
        load()
        NativeCodingAIPages.evaluate(CodingAIPageScripts.readStorage(SettingsFeatures.storageKey), in: .settings) { [weak self] value in
            self?.featureState = value
        }
    }

    func load() {
        loadId += 1
        let mine = loadId
        // A read that never settles must not leave every control disabled.
        Task {
            try? await Task.sleep(for: .seconds(8))
            guard mine == loadId, loading else { return }
            loadError = "Your saved settings are taking too long to read — showing defaults for now."
            loading = false
        }
        Task {
            do {
                async let prefs = call("prefs:get")
                async let extra = call("settings:get")
                let (prefsValue, extraValue) = try await (prefs, extra)
                guard mine == loadId else { return }
                values = SettingsSchema.values(settings: extraValue, preferences: prefsValue)
                loading = false
                loadError = nil
            } catch {
                guard mine == loadId else { return }
                loadError = CodingAIErrorText.from(error, fallback: "Could not read your saved settings — showing defaults.")
                loading = false
            }
        }
    }

    /// Optimistic, like the page: the value shows at once, then is written to the
    /// store that owns it, then the main window is handed the whole set.
    func save(_ patch: [String: CodingAIJSON]) {
        var raw = values
        for (key, value) in patch { raw[key] = value }
        values = SettingsSchema.merge(raw)
        let split = SettingsSchema.split(patch)
        guard !split.prefs.isEmpty || !split.extra.isEmpty else { return }
        saveState = .saving
        saveClear?.cancel()
        let next = values
        Task {
            do {
                if !split.prefs.isEmpty { _ = try await call("prefs:set", [split.prefs.mapValues(\.foundation)]) }
                if !split.extra.isEmpty { _ = try await call("settings:set", [split.extra.mapValues(\.foundation)]) }
                saveState = .saved
                handBack(next)
                saveClear = Task {
                    try? await Task.sleep(for: .milliseconds(1600))
                    if !Task.isCancelled, saveState == .saved { saveState = .idle }
                }
            } catch {
                saveState = .failed(CodingAIErrorText.from(error, fallback: "Could not save that change — it may not survive a restart."))
            }
        }
    }

    /// The page's `onChange(values)`: the main window replaces its own copy with these.
    func handBack(_ values: [String: CodingAIJSON]? = nil) {
        NativeCodingAIPages.evaluate(CodingAIPageScripts.relay(SettingsSchema.changedMessage(values ?? self.values)), in: .settings)
    }

    /// Say something at the foot (a reset that could not write everything, say).
    func report(_ state: SettingsSaveState) { saveState = state }

    func settingOn(_ id: String) -> Bool { SettingsFeatures.settingOn(id, state: featureState) }

    func bool(_ id: String) -> Bool { SettingsSchema.bool(values, id) }
    func string(_ id: String) -> String { SettingsSchema.string(values, id) }
    func number(_ id: String) -> Double { SettingsSchema.number(values, id) }
}

// The Shortcuts button at the foot opens the keyboard-shortcuts sheet, which the
// app frame owns: `NativeSettingsShortcuts.present()` (lane S, NativeShortcutsSheet.swift).

// MARK: - The page around a section

struct NativeSettingsPage<Content: View>: View {
    let sectionId: String
    @ViewBuilder let content: () -> Content
    private let store = NativeSettingsValues.shared
    /// How far the groups have scrolled, and how tall the heading is.
    @State private var scrolled: CGFloat = 0
    @State private var headHeight: CGFloat = 64

    var body: some View {
        let info = SettingsSchema.section(sectionId)
        Form {
            if let error = store.loadError {
                Section {
                    NativeCodingAINotice(tone: .error, text: error)
                }
            }
            content()
        }
        .formStyle(.grouped)
        // The page's heading sits above the groups, bare, and scrolls with them, as on
        // the web: room is kept for it at the top of the scrolled content, and it is
        // drawn there, moved by exactly as much as the content has scrolled. (Not the
        // header of an empty section — that made the next group's heading draw small
        // and grey, like a footer — and not a row, which boxed it.)
        .contentMargins(.top, headHeight, for: .scrollContent)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, now in
            scrolled = now
        }
        .overlay(alignment: .top) {
            NativeSettingsHead(title: info?.label ?? sectionId, blurb: info?.blurb)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.top, 18)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { headHeight = $0 }
                .offset(y: -scrolled)
                .allowsHitTesting(false)
        }
        .clipped()
        .safeAreaInset(edge: .bottom, spacing: 0) { NativeSettingsFoot() }
        .onAppear { store.start() }
    }
}

/// `SectionHead`: the section's name and the one line under it.
struct NativeSettingsHead: View {
    let title: String
    let blurb: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            if let blurb, !blurb.isEmpty {
                Text(blurb)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The foot of the page: whether the last change saved, and Shortcuts.
struct NativeSettingsFoot: View {
    private let store = NativeSettingsValues.shared

    var body: some View {
        HStack {
            Text(store.saveState.line)
                .font(.callout)
                .foregroundStyle(store.saveState.isFailure ? Color.red : Color.secondary)
                .accessibilityAddTraits(.updatesFrequently)
            Spacer()
            Button {
                NativeSettingsShortcuts.present()
            } label: {
                Label("Shortcuts", systemImage: "keyboard")
            }
            .buttonStyle(.borderless)
            .help("Keyboard shortcuts")
            .accessibilityLabel("Keyboard shortcuts")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

// MARK: - Rows

/// `Row`: the label (with its ⓘ) and help line on the left, the control on the right.
struct NativeSettingRow<Control: View>: View {
    let label: String
    var help: String?
    var more: String?
    @ViewBuilder let control: () -> Control

    var body: some View {
        LabeledContent {
            control()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(label)
                    if let more { NativeCodingAIInfo(label: label, text: more) }
                }
                if let help, !help.isEmpty {
                    Text(help)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// `SettingControl`: one setting of the table as a row, with anything extra under it.
struct NativeSettingControl<Extra: View>: View {
    let setting: SettingDefinition
    var help: String?
    var onSave: (([String: CodingAIJSON]) -> Void)?
    @ViewBuilder let extra: () -> Extra
    private let store = NativeSettingsValues.shared

    var body: some View {
        let value = SettingsSchema.value(store.values, setting)
        VStack(alignment: .leading, spacing: 8) {
            NativeSettingRow(label: setting.label, help: help ?? SettingsSchema.help(setting, value: value), more: setting.more) {
                control(value)
                    .disabled(store.loading)
            }
            extra()
        }
    }

    private func save(_ value: CodingAIJSON) {
        let patch = [setting.id: value]
        if let onSave { onSave(patch) } else { store.save(patch) }
    }

    @ViewBuilder private func control(_ value: CodingAIJSON) -> some View {
        switch setting.kind {
        case .toggle:
            Toggle(setting.label, isOn: Binding(get: { value.bool ?? false }, set: { save(.bool($0)) }))
                .toggleStyle(.switch)
                .labelsHidden()
        case .select:
            let options = setting.options
            if options.count == 1, let only = options.first {
                // One option is an answer, not a choice.
                Text(only.label)
            } else {
                Picker(setting.label, selection: Binding(get: { value.string ?? "" }, set: { save(.string($0)) })) {
                    ForEach(options) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        case .number:
            NativeSettingNumberField(setting: setting, value: value.number ?? 0, onCommit: { save(.number($0)) })
        case .text:
            NativeSettingTextField(setting: setting, value: value.string ?? "", onCommit: { save(.string($0)) })
        }
    }
}

extension NativeSettingControl where Extra == EmptyView {
    init(setting: SettingDefinition, help: String? = nil, onSave: (([String: CodingAIJSON]) -> Void)? = nil) {
        self.init(setting: setting, help: help, onSave: onSave, extra: { EmptyView() })
    }
}

/// A number: saved while typing whenever it is in range, clamped when you leave it.
struct NativeSettingNumberField: View {
    let setting: SettingDefinition
    let value: Double
    let onCommit: (Double) -> Void
    @State private var draft: String?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField(setting.label, text: Binding(
                get: { draft ?? Self.format(value) },
                set: { raw in
                    draft = raw
                    if let next = SettingsSchema.numberWhileTyping(setting, raw) { onCommit(next) }
                }))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .focused($focused)
                .onSubmit(leave)
                .onChange(of: focused) { _, now in if !now { leave() } }
            if let unit = setting.number?.unit {
                Text(unit).foregroundStyle(.secondary)
            }
            if let range = setting.number {
                Stepper(setting.label, value: Binding(get: { value }, set: { onCommit(min(range.max, max(range.min, $0))) }),
                        in: range.min...range.max, step: range.step)
                    .labelsHidden()
            }
        }
    }

    private func leave() {
        guard let raw = draft else { return }
        draft = nil
        if let next = SettingsSchema.numberOnLeaving(setting, raw), next != value { onCommit(next) }
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}

/// A text: saved 400 ms after the last keystroke, or when you leave it.
struct NativeSettingTextField: View {
    let setting: SettingDefinition
    let value: String
    let onCommit: (String) -> Void
    @State private var draft: String?
    @State private var timer: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        TextField(setting.label, text: Binding(
            get: { draft ?? value },
            set: { next in
                draft = next
                timer?.cancel()
                timer = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    if !Task.isCancelled { flush() }
                }
            }), prompt: setting.placeholder.map { Text($0) })
            .labelsHidden()
            .autocorrectionDisabled()
            .frame(minWidth: 200, maxWidth: 260)
            .focused($focused)
            .onSubmit(flush)
            .onChange(of: focused) { _, now in if !now { flush() } }
            .onChange(of: value) { _, _ in
                // The stored value moved under the field: drop the draft and any pending save.
                timer?.cancel()
                draft = nil
            }
            .onDisappear(perform: flush)
    }

    private func flush() {
        timer?.cancel()
        guard let next = draft else { return }
        if next != value { onCommit(next) }
        draft = nil
    }
}

/// `SettingList`: a section's rows from the table, in order, without the ones the
/// section draws itself or whose feature is off.
struct NativeSettingsList: View {
    let section: String
    var omit: [String] = []
    var helpFor: [String: String] = [:]
    var onSave: (([String: CodingAIJSON]) -> Void)?
    var extras: [String: AnyView] = [:]
    private let store = NativeSettingsValues.shared

    var body: some View {
        ForEach(SettingsSchema.settings(in: section).filter { !omit.contains($0.id) && store.settingOn($0.id) }) { setting in
            NativeSettingControl(setting: setting, help: helpFor[setting.id], onSave: onSave) {
                if let extra = extras[setting.id] { extra }
            }
        }
    }
}

/// `Explain` / `settings-prose`: a paragraph in a group.
struct NativeSettingsProse: View {
    let text: String
    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

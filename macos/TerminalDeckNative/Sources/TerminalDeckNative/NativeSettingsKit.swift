import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

// One-line seam for SHELL-CORE's palette, once READY GLITCH is published.
typealias NativeSettingsStyle = DeckTokens

typealias NativeSettingsFormFrame = NativeSettingsFallbackFrame
struct NativeSettingsFallbackFrame: View {
    let title: String
    let content: AnyView
    init<Content: View>(title: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.content = AnyView(content())
    }
    var body: some View {
        VStack(spacing: 0) {
            NativeSettingsHead(title: title, blurb: nil)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .padding(.horizontal, 20)
            content.frame(minHeight: 0, maxHeight: .infinity)
        }
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(NativeSettingsStyle.page)
    }
}
private struct NativeSettingsHoverRow<Content: View>: View {
    let content: Content
    let pressed: Bool
    @State private var hovering = false
    var body: some View {
        content.background(pressed ? NativeSettingsStyle.selection : hovering ? NativeSettingsStyle.cardHover : .clear,
                           in: RoundedRectangle(cornerRadius: 8))
            .onHover { hovering = $0 }
    }
}

/// Stable store ids; the Mac's names and order are owned by this window.
enum NativeSettingsNavigation {
    struct Item: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let tint: Color
        let group: Int
        let description: String
    }
    static let items: [Item] = [
        .init(id: "general", title: "General", symbol: "gearshape", tint: .gray, group: 0, description: "Sessions and this Mac."),
        .init(id: "appearance", title: "Appearance", symbol: "circle.lefthalf.filled", tint: Color(white: 0.2), group: 0, description: "The window and your sessions."),
        .init(id: "notifications", title: "Notifications", symbol: "bell", tint: .red, group: 0, description: "What the app tells you, and how."),
        .init(id: "island", title: "Dynamic Island", symbol: "capsule", tint: .black, group: 0, description: "Hoot at the top of the screen."),
        .init(id: "agents", title: "Coding AIs", symbol: "terminal", tint: .blue, group: 1, description: "Accounts and live session status."),
        .init(id: "ai-apps", title: "Outside AI apps", symbol: "link", tint: .indigo, group: 1, description: "Let other AI apps reach this Mac."),
        .init(id: "agent-defaults", title: "Agents", symbol: "person.2", tint: .green, group: 1, description: "Defaults for every agent."),
        .init(id: "browser", title: "Browser", symbol: "globe", tint: .teal, group: 2, description: "Pages, sign-ins, downloads and capture."),
        .init(id: "tasks", title: "Tasks", symbol: "checklist", tint: .orange, group: 2, description: "Connected task systems."),
        .init(id: "features", title: "Voice", symbol: "mic", tint: .pink, group: 2, description: "Turn your voice into text."),
        .init(id: "plugins", title: "Plugins", symbol: "puzzlepiece.extension", tint: .purple, group: 2, description: "Tools you add yourself."),
        .init(id: "privacy", title: "Privacy", symbol: "hand.raised", tint: .blue, group: 3, description: "Mac permissions and old helper entries."),
        .init(id: "advanced", title: "Advanced", symbol: "bolt", tint: .gray, group: 3, description: "Help with problems and starting over."),
        .init(id: "help", title: "About", symbol: "info.circle", tint: .gray, group: 3, description: "Version, links and help topics."),
    ]
    static func item(_ id: String) -> Item? { items.first { $0.id == canonical(id) } }
    /// Hoot's own section moved to the Hoot page; its ids stay valid as links that open that page.
    static func isHoot(_ id: String) -> Bool { id == "copilot" || id == "hoot" }
    /// What the sidebar selects: an unknown or Hoot id shows the first section.
    static func shown(_ id: String?) -> String {
        guard let id, !isHoot(id) else { return items.first?.id ?? "general" }
        return canonical(id)
    }
    static func canonical(_ id: String) -> String {
        switch id {
        case "power": "general"
        case "scraping": "browser"
        case "linux": "general"
        default: id
        }
    }
    static func matching(_ query: String) -> [Item] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? items : items.filter {
            ($0.title + " " + $0.description).localizedCaseInsensitiveContains(text)
        }
    }
}

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
    @ObservationIgnored private var saveTail: Task<Void, Never>?
    @ObservationIgnored private var saveGeneration = 0

    #if DEBUG
    @ObservationIgnored private var offscreenFixture = false
    /// XCTest only: bridge calls remain real, but app/window/page side effects stop.
    func beginOffscreenFixture() {
        offscreenFixture = true
        loading = true
        loadError = nil
        featureState = nil
    }
    func endOffscreenFixture() async {
        await saveTail?.value
        saveClear?.cancel()
        loadId += 1
        subscriptions.forEach { $0.cancel() }
        subscriptions = []
        offscreenFixture = false
    }
    #endif
    private var usesOffscreenFixture: Bool {
        #if DEBUG
        return offscreenFixture
        #else
        return false
        #endif
    }

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
        guard !usesOffscreenFixture else { return }
        NativeCodingAIPages.evaluate(CodingAIPageScripts.readStorage(SettingsFeatures.storageKey), in: .settings) { [weak self] value in
            self?.featureState = value
        }
    }

    func load() {
        guard saveTail == nil else { return }
        loadId += 1
        let mine = loadId
        let generation = saveGeneration
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
                guard mine == loadId, generation == saveGeneration else { return }
                values = SettingsSchema.values(settings: extraValue, preferences: prefsValue)
                applyNativeAppearance()
                loading = false
                loadError = nil
            } catch {
                guard mine == loadId, generation == saveGeneration else { return }
                loadError = CodingAIErrorText.from(error, fallback: "Could not read your saved settings — showing defaults.")
                loading = false
            }
        }
    }

    /// Optimistic, like the page: the value shows at once, then is written to the
    /// store that owns it, then the main window is handed the whole set.
    func save(_ patch: [String: CodingAIJSON]) {
        let before = values
        var raw = values
        for (key, value) in patch { raw[key] = value }
        values = SettingsSchema.merge(raw)
        let split = SettingsSchema.split(patch)
        guard !split.prefs.isEmpty || !split.extra.isEmpty else { return }
        // Which control saved what, and whether the person was here (walk-1 theme flip:
        // keystrokes typed into another app landed in this window after it took the front).
        if !usesOffscreenFixture {
            let event = NSApp.currentEvent.map { "\($0.type.rawValue)" } ?? "none"
            AppModel.shared.engine.log.note("settings saved: " + patch.keys.sorted().joined(separator: ",")
                + (split.prefs["theme"]?.string.map { " theme=" + $0 } ?? "")
                + " (app active \(NSApp.isActive), event \(event))")
        }
        saveState = .saving
        saveClear?.cancel()
        let previous = saveTail
        saveGeneration += 1
        let mine = saveGeneration
        saveTail = Task {
            var failed = false
            defer {
                if mine == saveGeneration {
                    saveTail = nil
                    // Read what is really stored (a half-done save included), so the control never flips back later by itself.
                    if failed { load() }
                }
            }
            await previous?.value
            do {
                if !split.prefs.isEmpty { _ = try await call("prefs:set", [split.prefs.mapValues(\.foundation)]) }
                if !split.extra.isEmpty { _ = try await call("settings:set", [split.extra.mapValues(\.foundation)]) }
                guard mine == saveGeneration else { return }
                saveState = .saved
                applyNativeAppearance()
                handBack()
                saveClear = Task {
                    try? await Task.sleep(for: .milliseconds(1600))
                    if !Task.isCancelled, saveState == .saved { saveState = .idle }
                }
            } catch {
                guard mine == saveGeneration else { return }
                failed = true
                values = Self.reverting(values, keys: patch.keys, to: before)
                saveState = .failed(CodingAIErrorText.from(error, fallback: "Could not save that change. It shows what is saved."))
            }
        }
    }
    /// A refused change goes back to the value it had before, at once; the re-read then confirms what is stored.
    static func reverting(_ values: [String: CodingAIJSON], keys: some Sequence<String>, to before: [String: CodingAIJSON]) -> [String: CodingAIJSON] {
        var raw = values
        for key in keys { raw[key] = before[key] }
        return SettingsSchema.merge(raw)
    }

    private func applyNativeAppearance() {
        guard !usesOffscreenFixture else { return }
        guard let appearance = AppAppearance(preference: string("appearance.theme"), resolved: nil) else { return }
        AppModel.shared.applyAppearance(appearance)
    }

    /// The page's `onChange(values)`: the main window replaces its own copy with these.
    func handBack(_ values: [String: CodingAIJSON]? = nil) {
        guard !usesOffscreenFixture else { return }
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

    var body: some View {
        let info = NativeSettingsNavigation.item(sectionId)
        NativeSettingsFormFrame(title: info?.title ?? sectionId) {
          Form {
            if let error = store.loadError {
                Section {
                    NativeSettingsNote(tone: .error, text: error)
                }
            }
            content()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .clipped()
        }
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
                .font(.system(size: 20, weight: .semibold))
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
            Text(store.saveState == .idle ? "Changes save as you make them." : store.saveState.line)
                .font(.callout)
                .foregroundStyle(store.saveState.isFailure ? Color.red : Color.secondary)
                .accessibilityAddTraits(.updatesFrequently)
            Spacer()
            NativeSessionButton {
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
        .background(NativeSettingsStyle.frame)
    }
}

/// Short notices keep the approved status colours, with full details in help.
struct NativeSettingsNote: View {
    let tone: NativeCodingAINotice.Tone
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch tone {
            case .error: Circle().fill(.red).frame(width: 6, height: 6)
            case .warn: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            case .info: Image(systemName: "info.circle").foregroundStyle(Color.accentColor)
            }
            Text(text).foregroundStyle(.primary).lineLimit(1).help(text).textSelection(.enabled)
        }.font(.callout)
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
            // The row owns the label; a control's own label would otherwise be squeezed
            // into a one-letter column beside it (Theme → "T h e m e").
            control().labelsHidden()
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
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(help)
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
            if setting.kind == .toggle {
                NativeSettingsToggle(label: setting.label,
                    help: help ?? SettingsSchema.help(setting, value: value), more: setting.more,
                    value: Binding(get: { value.bool ?? false }, set: { save(.bool($0)) }))
                    .disabled(store.loading)
            } else {
                NativeSettingRow(label: setting.label, help: help ?? SettingsSchema.help(setting, value: value), more: setting.more) {
                    control(value).disabled(store.loading)
                }
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

/// A native toggle owns its label, so the full row works with click or Space.
struct NativeSettingsToggle: View {
    let label: String
    var help: String?
    var more: String?
    @Binding var value: Bool
    var body: some View {
        Toggle(isOn: $value) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(label)
                    if let more { NativeCodingAIInfo(label: label, text: more) }
                }
                if let help, !help.isEmpty {
                    Text(help).font(.callout).foregroundStyle(.secondary).lineLimit(1).help(help)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
        }.toggleStyle(.switch)
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
            NativeSessionTextField(setting.label, text: Binding(
                get: { draft ?? Self.format(value) },
                set: { raw in
                    draft = raw
                    if let next = SettingsSchema.numberWhileTyping(setting, raw) { onCommit(next) }
                }))
                .sessionFocused($focused)
                .onSubmit(leave)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
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
        NativeSessionTextField(setting.placeholder ?? setting.label, text: Binding(
            get: { draft ?? value },
            set: { next in
                draft = next
                timer?.cancel()
                timer = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    if !Task.isCancelled { flush() }
                }
            }))
            .sessionFocused($focused)
            .onSubmit(flush)
            .accessibilityLabel(setting.label)
            .labelsHidden()
            .autocorrectionDisabled()
            .frame(minWidth: 200, maxWidth: 260)
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

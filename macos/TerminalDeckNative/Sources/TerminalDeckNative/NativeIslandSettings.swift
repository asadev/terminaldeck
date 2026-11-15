import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// The screen seam is supplied by FIXES, which owns the remembered display and
/// the immediate move. The Settings page never creates or orders an island.
@MainActor
enum NativeIslandSettingsAccess {
    static var readScreen: (@MainActor () async throws -> CodingAIJSON)? = { @MainActor in
        CodingAIJSON(NativeFIXESIslandPreferences.shared.read().foundation)
    }
    static var setScreen: (@MainActor (CodingAIJSON) async throws -> CodingAIJSON)? = { @MainActor raw in
        CodingAIJSON(try await NativeFIXESIslandPreferences.shared.configure(NativeRPCValue.fromFoundation(raw.foundation)).foundation)
    }
}

struct NativeIslandSettings: View {
    @State private var model = NativeIslandSettingsModel()

    var body: some View {
        DeckSettingsScaffold(title: NativeSettingsNavigation.title("island")) {
            // The preview draws what the island would show now, from the app's own facts.
            NativeIslandSettingsContent(model: model, facts: IslandController.shared.liveFacts)
        }
        .onAppear { NativeSettingsValues.shared.start() }
        .task { await model.load() }
        .onDisappear { model.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            model.displaysChanged()
        }
    }
}

/// Separately renderable: a fixture model performs no calls and reads no data. DESIGN.md section 5: the preview, then
/// ONE group; no sentence under any row, explanations behind the info button.
struct NativeIslandSettingsContent: View {
    @Bindable var model: NativeIslandSettingsModel
    var facts = NativeIslandFacts()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NativeIslandSettingsPreview(shows: model.shows, look: model.look, width: model.width, facts: facts, scheme: scheme)
        DeckSettingsGroup {
            DeckSettingsToggleRow("Show at the top of the screen",
                info: "Status, replies and approvals without opening the app.",
                isOn: Binding(get: { model.enabled }, set: model.setEnabled))
                .disabled(model.loading)
            DeckSettingsRow("Shows", info: "What lives in the island: Hoot and his chat, your running sessions, your open tasks, or only what is waiting for you. A click opens it.") {
                Picker("Shows", selection: Binding(get: { model.shows.rawValue }, set: { model.saveString(NativeIslandSettingsModel.showsKey, $0) })) {
                    ForEach(NativeIslandShows.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                .fixedSize().disabled(model.loading)
            }
            DeckSettingsRow("Look", info: "On a screen with a notch it is always black, to blend in.") {
                Picker("Look", selection: Binding(get: { model.look }, set: { model.saveString(NativeIslandSettingsModel.lookKey, $0) })) {
                    Text("Match the app").tag("app")
                    Text("Always dark").tag("dark")
                }
                .fixedSize().disabled(model.loading)
            }
            DeckSettingsRow("Size") {
                Picker("Size", selection: Binding(get: { model.width }, set: { model.saveString(NativeIslandSettingsModel.widthKey, $0) })) {
                    Text("Compact").tag("compact")
                    Text("Standard").tag("standard")
                    Text("Wide").tag("wide")
                }
                .fixedSize().disabled(model.loading)
            }
            DeckSettingsRow("When nothing is happening") {
                Picker("When nothing is happening", selection: Binding(get: { model.quiet }, set: { model.saveString(NativeIslandSettingsModel.quietKey, $0) })) {
                    Text("Stay small").tag("small")
                    Text("Hide").tag("hide")
                }
                .fixedSize().disabled(model.loading)
            }
            if model.displays.count > 1 {
                DeckSettingsRow("Screen", info: "Where it sits. This choice stays on this Mac.") {
                    Picker("Screen", selection: Binding(get: { model.screen }, set: model.setScreen)) {
                        Text("Screen with the menu bar").tag("main")
                        if model.displays.contains(where: \.builtIn) {
                            Text("Built-in display").tag("builtIn")
                        } else if model.screen == "builtIn" {
                            Text("Built-in display (disconnected)").tag("builtIn")
                        }
                        ForEach(model.displays) { display in Text(display.name).tag("named:" + display.id) }
                        if model.screen.hasPrefix("named:"), !model.displays.contains(where: { "named:" + $0.id == model.screen }) {
                            Text((model.rememberedScreenName ?? "Chosen screen") + " (disconnected)").tag(model.screen)
                        }
                        Text("Screen with the mouse").tag("pointer")
                    }
                    .fixedSize()
                    .disabled(model.loading || !model.screenAvailable)
                }
            }
            if let error = model.error { DeckSettingsProblem(text: error) }
        }
    }
}

@MainActor @Observable
final class NativeIslandSettingsModel {
    struct Display: Identifiable {
        let id: String
        let name: String
        let builtIn: Bool
    }
    typealias Invoke = @MainActor (String, [String: CodingAIJSON]) async throws -> CodingAIJSON
    typealias Read = @MainActor () async throws -> CodingAIJSON
    typealias Configure = @MainActor (CodingAIJSON) async throws -> CodingAIJSON
    static let lookKey = "copilot.islandLook", widthKey = "copilot.islandWidthPreset"
    static let quietKey = "copilot.islandQuiet", showsKey = NativeFIXESIslandPreferences.showsKey
    var loading = true
    var error: String?
    var enabled = true
    var screen = "main"
    var rememberedScreenName: String?
    var displays: [Display] = []
    var screenAvailable = false
    private(set) var pendingChanges = 0
    private var values: [String: CodingAIJSON] = [:]
    private let fixture: Bool
    @ObservationIgnored private let injectedRead: Read?
    @ObservationIgnored private let injectedConfigure: Configure?
    @ObservationIgnored private let invoke: Invoke
    @ObservationIgnored private let liveBridge: Bool
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var loadID = 0
    @ObservationIgnored private var loadTimeout: Task<Void, Never>?

    init(fixtureValues: [String: CodingAIJSON]? = nil, fixtureDisplays: [Display] = [],
         read: Read? = nil, configure: Configure? = nil, invoke: Invoke? = nil) {
        fixture = fixtureValues != nil
        injectedRead = read
        injectedConfigure = configure
        liveBridge = invoke == nil
        self.invoke = invoke ?? { channel, patch in
            let args: [Any?] = patch.isEmpty ? [] : [patch.mapValues(\.foundation)]
            return CodingAIJSON(try await EngineBridge.shared.invoke(channel, args))
        }
        if let fixtureValues {
            acceptValues(.object(fixtureValues))
            loading = false
            screenAvailable = true
            displays = fixtureDisplays
        }
    }
    private var read: Read? { injectedRead ?? (liveBridge ? NativeIslandSettingsAccess.readScreen : nil) }
    private var configure: Configure? { injectedConfigure ?? (liveBridge ? NativeIslandSettingsAccess.setScreen : nil) }
    var look: String { values[Self.lookKey]?.string == "dark" ? "dark" : "app" }
    var width: String {
        let value = values[Self.widthKey]?.string ?? "standard"
        return ["compact", "standard", "wide"].contains(value) ? value : "standard"
    }
    var quiet: String { values[Self.quietKey]?.string == "hide" ? "hide" : "small" }
    var shows: NativeIslandShows { NativeIslandShows(stored: values[Self.showsKey]?.string) }
    var hasBuiltInDisplay: Bool { displays.contains(where: \.builtIn) }

    func load() async {
        guard !fixture else { return }
        loadID += 1
        let mine = loadID
        if liveBridge, subscriptions.isEmpty, EngineBridge.shared.isReady {
            subscriptions = [EngineBridge.shared.on("settings:changed") { [weak self] args in
                let envelope = CodingAIJSON(args.first)
                Task { await self?.settingsChanged(envelope) }
            }, EngineBridge.shared.on("prefs:changed") { [weak self] _ in
                Task { await self?.load() }
            }]
        }
        loadTimeout?.cancel()
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.loadID == mine, self.loading else { return }
            self.loadID += 1
            self.loading = false
            self.error = "Saved settings are taking too long to read. Showing defaults."
        }
        loadTimeout = timeout
        defer { timeout.cancel() }
        do {
            let stored = try await invoke("settings:get", [:])
            let shown = try await invoke("hoot-menubar:config", [:])
            let snapshot = try await read?()
            guard loadID == mine else { return }
            acceptValues(stored)
            enabled = shown["enabled"].bool ?? enabled
            if let snapshot { acceptScreen(snapshot) } else { screenAvailable = false }
            loading = false
            error = nil
        } catch {
            guard loadID == mine else { return }
            self.error = CodingAIErrorText.from(error, fallback: "Could not read Dynamic Island settings.")
            loading = false
        }
    }
    func stop() {
        loadID += 1
        loadTimeout?.cancel()
        loadTimeout = nil
        subscriptions.forEach { $0.cancel() }
        subscriptions = []
    }
    /// Uses the same path for real settings events and direct, inert model tests.
    func settingsChanged(_ envelope: CodingAIJSON) async {
        guard !fixture else { return }
        acceptValues(envelope)
        do {
            if let read { acceptScreen(try await read()) }
        } catch {
            self.error = CodingAIErrorText.from(error, fallback: "Could not read the connected screens.")
        }
    }
    func displaysChanged() {
        guard !fixture, let read else { return }
        Task {
            do { acceptScreen(try await read()) }
            catch { self.error = CodingAIErrorText.from(error, fallback: "Could not read the connected screens.") }
        }
    }
    private func acceptValues(_ raw: CodingAIJSON) {
        values = SettingsSchema.stored(raw)
        enabled = values["copilot.menuBar"]?.bool ?? true
        let choice = values["IslandShowOn"]?.string.map(CodingAIJSON.parse) ?? .null
        if choice.isObject { acceptChoice(choice) }
        else { screen = "main"; rememberedScreenName = nil }
    }
    private func acceptChoice(_ choice: CodingAIJSON) {
        let mode = choice["mode"].string ?? "main"
        screen = mode == "named" ? "named:" + (choice["screenUUID"].string ?? choice["screenID"].string ?? "") : mode
        rememberedScreenName = choice["screenName"].string
    }
    private func acceptScreen(_ raw: CodingAIJSON) {
        screenAvailable = true
        if let enabled = raw["enabled"].bool { self.enabled = enabled }
        if let look = raw["look"].string { values[Self.lookKey] = .string(look) }
        if let width = raw["width"].string { values[Self.widthKey] = .string(width) }
        if let quiet = raw["whenQuiet"].string { values[Self.quietKey] = .string(quiet) }
        if let shows = raw["shows"].string { values[Self.showsKey] = .string(shows) }
        acceptChoice(raw["showOn"])
        displays = (raw["screens"].array ?? []).compactMap {
            guard let id = $0["id"].string ?? $0["screenUUID"].string, let name = $0["name"].string else { return nil }
            return Display(id: id, name: name, builtIn: $0["builtIn"].bool ?? false)
        }
    }
    func setScreen(_ selection: String) {
        guard !fixture, let configure else { return }
        let named = selection.hasPrefix("named:")
        var fields: [String: CodingAIJSON] = ["mode": .string(named ? "named" : selection)]
        if named { fields["screenUUID"] = .string(String(selection.dropFirst(6))) }
        let patch = CodingAIJSON.object(fields)
        enqueue { self.acceptScreen(try await configure(patch)) }
    }
    func setEnabled(_ next: Bool) {
        let configure = configure
        enqueue {
            if let configure { self.acceptScreen(try await configure(.object(["enabled": .bool(next)]))) }
            else {
                let result = try await self.invoke("hoot-menubar:configure", ["enabled": .bool(next)])
                self.enabled = result["enabled"].bool ?? self.enabled
            }
        }
    }
    func saveString(_ key: String, _ value: String) { save(key, .string(value)) }
    func saveBool(_ key: String, _ value: Bool) { save(key, .bool(value)) }
    private func save(_ key: String, _ value: CodingAIJSON) {
        let configure = configure
        let option = [Self.lookKey: "look", Self.widthKey: "width", Self.quietKey: "whenQuiet", Self.showsKey: "shows"][key]
        var fields = [key: value]
        // The fallback uses the existing scalar settings owner too. A preset
        // removes a remembered drag width, while retaining its chosen height.
        if key == Self.widthKey { fields["copilot.islandWidth"] = .null }
        let patch = fields
        enqueue {
            if let option, let configure {
                self.acceptScreen(try await configure(.object([option: value])))
            } else {
                self.acceptValues(try await self.invoke("settings:set", patch))
            }
        }
    }
    func waitForPendingChanges() async { await saveTask?.value }
    private func report(_ state: SettingsSaveState) {
        if liveBridge { NativeSettingsValues.shared.report(state) }
    }
    private func enqueue(_ action: @escaping @MainActor () async throws -> Void) {
        guard !fixture else { return }
        let previous = saveTask
        pendingChanges += 1
        report(.saving)
        saveTask = Task {
            await previous?.value
            do {
                try await action()
                self.error = nil
                self.pendingChanges -= 1
                self.report(self.pendingChanges == 0 ? .saved : .saving)
            } catch {
                // Controls keep their last confirmed state. Each immutable
                // queued request still runs after a rejected earlier request.
                let message = CodingAIErrorText.from(error, fallback: "Could not save that change.")
                self.error = message
                self.pendingChanges -= 1
                self.report(self.pendingChanges == 0 ? .failed(message) : .saving)
            }
        }
    }
}

/// The preview (DESIGN.md section 5): 560 x 120, radius 12, the island drawn with the chosen options by the real
/// island's own pieces (its layout policy, outline and capsule), over a plain desktop and menu bar.
struct NativeIslandSettingsPreview: View {
    let shows: NativeIslandShows
    let look: String
    let width: String
    let facts: NativeIslandFacts
    let scheme: SwiftUI.ColorScheme

    static let size = CGSize(width: 560, height: 120)
    private static let screen = IslandScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 876))

    private var options: FIXESIslandOptions {
        FIXESIslandOptions(look: FIXESIslandOptions.Look(rawValue: look) ?? .matchApp,
            width: FIXESIslandOptions.Width(rawValue: width) ?? .standard)
    }
    private var dark: Bool { FIXESIslandDisplayPolicy.dark(appearance: scheme == .dark ? "dark" : "light", builtIn: false, hasNotch: false, look: options.look) }

    var body: some View {
        let face = NativeIslandFace.make(shows: shows, facts: facts)
        let layout = FIXESIslandDisplayPolicy.layout(for: Self.screen, options: options, quiet: face.quiet)
        ZStack(alignment: .top) {
            LinearGradient(colors: scheme == .dark
                    ? [Color(red: 0.16, green: 0.19, blue: 0.27), Color(red: 0.27, green: 0.22, blue: 0.20)]
                    : [Color(red: 0.62, green: 0.72, blue: 0.87), Color(red: 0.89, green: 0.79, blue: 0.69)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(.regularMaterial).frame(height: 24).frame(maxHeight: .infinity, alignment: .top)
            ZStack(alignment: .top) {
                IslandOutline(width: layout.pill.width, height: layout.pill.height, radius: layout.pill.radius, shoulder: layout.pill.shoulder)
                    .fill(dark ? Color.black : Color.white)
                    .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                IslandIndicators(face: face, layout: layout)
            }
            .frame(width: layout.pill.outerWidth, height: layout.pill.height, alignment: .top)
            .environment(\.colorScheme, dark ? .dark : .light)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dynamic Island preview")
        .accessibilityValue(face.line)
    }
}

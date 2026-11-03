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
        NativeSettingsPage(sectionId: "island") {
            NativeIslandSettingsContent(model: model)
        }
        .task { await model.load() }
        .onDisappear { model.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            model.displaysChanged()
        }
    }
}

/// Separately renderable: a fixture model performs no calls and reads no data.
struct NativeIslandSettingsContent: View {
    @Bindable var model: NativeIslandSettingsModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Section {
            NativeIslandSettingsPreview(look: model.look, width: model.width, scheme: scheme)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
        if let error = model.error {
            Section { NativeSettingsNote(tone: .error, text: error) }
        }
        Section {
            toggle("Show Hoot at the top of the screen",
                   help: "Status, replies and approvals without opening the app.",
                   value: model.enabled, action: model.setEnabled)
        }
        Section {
            NativeSettingRow(label: "Screen", help: "Where it sits when you have more than one.") {
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
                .labelsHidden()
                .fixedSize()
                .disabled(model.loading || !model.screenAvailable)
            }
            NativeSettingRow(label: "Look", help: "On a screen with a notch it is always black, to blend in.") {
                Picker("Look", selection: Binding(get: { model.look }, set: { model.saveString(NativeIslandSettingsModel.lookKey, $0) })) {
                    Text("Match the app").tag("app")
                    Text("Always dark").tag("dark")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(model.loading)
            }
            NativeSettingRow(label: "Width") {
                Picker("Width", selection: Binding(get: { model.width }, set: { model.saveString(NativeIslandSettingsModel.widthKey, $0) })) {
                    Text("Compact").tag("compact")
                    Text("Standard").tag("standard")
                    Text("Wide").tag("wide")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(model.loading)
            }
            NativeSettingRow(label: "When nothing is happening") {
                Picker("When nothing is happening", selection: Binding(get: { model.quiet }, set: { model.saveString(NativeIslandSettingsModel.quietKey, $0) })) {
                    Text("Show Hoot small").tag("small")
                    Text("Hide").tag("hide")
                }
                .labelsHidden()
                .fixedSize()
                .disabled(model.loading)
            }
        }
    }

    private func toggle(_ title: String, help: String? = nil, value: Bool, action: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { value }, set: action)) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let help { Text(help).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .toggleStyle(.switch)
        .disabled(model.loading)
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
    static let quietKey = "copilot.islandQuiet"
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
        let option = [Self.lookKey: "look", Self.widthKey: "width", Self.quietKey: "whenQuiet"][key]
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

/// An illustrative preview, matching mockup 06, with no app/session content.
private struct NativeIslandSettingsPreview: View {
    let look: String
    let width: String
    let scheme: SwiftUI.ColorScheme
    private var dark: Bool { look == "dark" || scheme == .dark }
    private var pillWidth: CGFloat { width == "compact" ? 236 : width == "wide" ? 330 : 280 }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.62, green: 0.72, blue: 0.87), Color(red: 0.89, green: 0.79, blue: 0.69)], startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 12) {
                Text("Terminal Deck")
                Text("File")
                Text("Edit")
                Spacer()
                Text("Fri 10 Oct 09:41")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(Color.white.opacity(0.55))
            HStack(spacing: 8) {
                HootMark(size: 13, animated: false)
                Text("Commander").fontWeight(.semibold)
                Text("is working").foregroundStyle(.secondary)
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    ForEach(0..<3) { index in
                        Circle().fill(Color(red: 0.78, green: 0.46, blue: 0.17).opacity(0.4 + Double(index) * 0.3)).frame(width: 4, height: 4)
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(dark ? Color.white : Color.black)
            .padding(.horizontal, 12)
            .frame(width: pillWidth, height: 30)
            .background(dark ? Color.black : Color.white, in: UnevenRoundedRectangle(bottomLeadingRadius: 15, bottomTrailingRadius: 15))
            .environment(\.colorScheme, dark ? .dark : .light)
            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        }
        .frame(height: 120)
        .overlay(alignment: .bottomLeading) {
            Text(look == "dark" ? "Preview · always dark" : "Preview · matches the app (\(scheme == .dark ? "dark" : "light"))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Dynamic Island appearance preview")
    }
}

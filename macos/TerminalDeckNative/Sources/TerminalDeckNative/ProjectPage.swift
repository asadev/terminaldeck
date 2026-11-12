import UniformTypeIdentifiers
import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

enum PROJPAGETab: String, CaseIterable, Identifiable {
    case overview = "Overview", files = "Files", code = "Code", readiness = "Readiness", staysFixed = "Stays Fixed"
    var id: String { rawValue }
}

/// A project is supplied by the registry, never inferred again from a session tab.
struct ProjectPage: View {
    let project: PROJProject
    @State private var tab = PROJPAGETab.overview
    @State private var code = "Changes"
    @State private var readiness = NativeAIRReadinessModel()
    @State private var overview = PROJPAGEOverviewModel()
    @State private var setup: PROJSetupStatusModel

    init(project: PROJProject, initialTab: PROJPAGETab = .overview, setup: PROJSetupStatusModel = PROJSetupStatusModel()) {
        self.project = project
        _tab = State(initialValue: initialTab)
        _setup = State(initialValue: setup)
    }
    /// The registry's latest copy of this project (its logo or lead may have changed since the page opened).
    private var current: PROJProject { SHELLRoutes.registry.first { $0.id == project.id } ?? project }
    static func openSettings(_ project: PROJProject) { PROJPAGESettingsWindow.open(project: project) }
    static func settingsView(_ project: PROJProject) -> AnyView { AnyView(PROJPAGEProjectSettings(project: project)) }

    private var folder: String? { project.folders.first }
    /// A registered project (made through the guide or registered before), not a plain folder's stand-in.
    private var registered: Bool { SHELLRoutes.registry.contains { $0.id == project.id && $0.id != PROJProjects.independentID } }
    private var subtitle: String {
        let path = folder.map(PROJPAGEStyle.shortPath) ?? "Independent"
        guard let status = overview.git else { return path }
        return "\(path) · \(status.branchName ?? "No repository") · \(status.unstaged.count) changed"
    }

    var body: some View {
        PROJPAGEPage(title: project.name, subtitle: subtitle, project: project,
                     scrolling: tab == .overview || tab == .readiness) {
            PROJPAGESwitch(selection: $tab, items: PROJPAGETab.allCases)
        } actions: {
            Menu {
                if registered {
                    NativeSessionButton("Project settings…") { Self.openSettings(project) }
                    NativeSessionButton("Setup guide…") { PROJGuideWindow.open(project: project) }
                } else if let folder {
                    NativeSessionButton("Set up as a project…") { PROJGuideWindow.open(folder: folder) }
                }
                NativeSessionButton("Show hidden cards") { overview.hidden = [] }
                if let agents = readiness.report?.agents, !agents.isEmpty {
                    Picker("Report on", selection: $readiness.agent) {
                        Text("Any agent").tag(String?.none)
                        ForEach(agents) { DeckRowLabel.provider($0.label, id: $0.agent).tag(Optional($0.agent)) }
                    }
                }
            } label: { Image(systemName: "gearshape").frame(width: 28, height: 28) }
            .menuStyle(.borderlessButton).help("Project settings").accessibilityLabel("Project settings")
            NativeSessionButton { NativeNewSession.show(project: project) } label: { Label("New session", systemImage: "plus") }.buttonStyle(.borderedProminent)
        } content: {
            if let folder {
                switch tab {
                case .overview:
                    // Asad 11 Oct: "Setup N%" and the missing parts until the project is fully set up;
                    // a plain folder says it is not a project yet.
                    if !registered { PROJPlainFolderCard(folder: folder) }
                    else if let score = setup.score(current, agents: AGTAgentsStore.shared.profiles), !score.complete {
                        PROJSetupCard(project: current, score: score) { PROJGuideWindow.open(project: current, step: $0) }
                    }
                    if registered { DeploymentsCard(project: current) }   // DEPLOY-PIPELINE: live run + history
                    PROJPAGEOverviewContent(model: overview, project: project,
                        navigate: navigate, fixWithHoot: fixWithHoot)
                case .files: NativeFilesScreen(projectPath: folder, embedded: true)
                case .code:
                    PROJPAGECodeContent(selection: $code) {
                        if code == "Changes" { NativeGitScreen(projectPath: folder, embedded: true) }
                        else { NativeGitHubScreen(projectPath: folder, embedded: true, section: code) }
                    }
                case .readiness:
                    NativeAIRReadinessScreen(model: readiness, projectPath: folder, projectName: project.name,
                        onFixAllWithHoot: fixWithHoot, onReviewChanges: { tab = .code }, embedded: true)
                case .staysFixed: NativeSFXScreen(projectPath: folder, onReviewChanges: { tab = .code; code = "Changes" })
                }
            } else {
                ContentUnavailableView("Choose a folder", systemImage: "folder", description: Text("Open a folder to use \(project.name)’s files and code."))
            }
        }
        .task(id: project.id + tab.rawValue) {
            overview.stop()
            if tab == .overview, let folder { await overview.load(project: project, folder: folder) }
        }
        .task(id: project.id + (registered ? ":registered" : "")) { if registered { await setup.start(project.id) } }
        .onDisappear { overview.stop(); setup.stop() }
        .deployFocus(project.id) { tab = .overview }
    }

    private func navigate(_ destination: String) {
        if destination == "git" { tab = .code; code = "Changes"; return }
        if destination == "readiness" { tab = .readiness; return }
        if destination == "tasks" { TKTasksProjectScope.shared.selectProject(project) }
        AppModel.shared.select(destination)
    }
    private func fixWithHoot() {
        let prompt = "Help finish readiness for \(project.name) at \(folder ?? ""). Read the checks, explain the plan, and ask before changing files."
        let chat = NativeHootChatModel.shared
        chat.draft = chat.draft.isEmpty ? prompt : chat.draft + "\n\n" + prompt
        AppModel.shared.select("hoot")
    }
}

/// The actual Code-tab switch and layout, shared by production and detached fixtures.
struct PROJPAGECodeContent<Content: View>: View {
    @Binding var selection: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 12) {
            Picker("Code", selection: $selection) {
                ForEach(["Changes", "Pull requests", "Issues", "Actions"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().nativeUIGGreyControl().frame(maxWidth: 520)
            content()
        }.frame(minHeight: 0, maxHeight: .infinity)
    }
}

/// The project header on the shared DeckPage (READY L1-CORE): badge, name + path line,
/// centred glass switch, then settings and the one blue action.
struct PROJPAGEPage<Switcher: View, Actions: View, Content: View>: View {
    let title: String
    let subtitle: String
    let project: PROJProject
    var scrolling = true
    @ViewBuilder var switcher: () -> Switcher
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content
    var body: some View {
        DeckPage(title: title, subtitle: subtitle, scrolls: scrolling) {
            ProjectLogoView(project: project, name: title, size: 30) // logo, or a letter tile
        } switcher: { switcher() } actions: { HStack(spacing: DeckTokens.Spacing.s8) { actions() } } content: { content().padding(.top, scrolling ? 0 : 16) }
    }
}

struct PROJPAGESwitch<Value: Hashable & Identifiable & RawRepresentable>: View where Value.RawValue == String {
    @Binding var selection: Value
    let items: [Value]
    var body: some View {
        GlassSwitch(selection: $selection, items: items.map { DeckSwitchItem(id: $0, title: $0.rawValue) })
    }
}

enum PROJPAGEStyle {
    static let page = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(srgbRed: 30/255, green: 30/255, blue: 33/255, alpha: 1) : NSColor(srgbRed: 247/255, green: 247/255, blue: 249/255, alpha: 1) })
    static let switchOn = Color.accentColor
    static let card = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(srgbRed: 42/255, green: 42/255, blue: 46/255, alpha: 1) : .white })
    static func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    static func paletteName(_ name: String) -> String {
        switch name.lowercased() {
        case "slate", "blue": "blue"
        case "lavender", "purple": "purple"
        case "sage", "green": "green"
        case "sand", "orange": "orange"
        case "rose", "pink": "pink"
        case "teal": "teal"
        case "olive", "yellow": "yellow"
        default: "graphite"
        }
    }
    static func colour(_ name: String) -> Color {
        let rgb: UInt32
        switch paletteName(name) {
        case "blue": rgb = 0x0A84FF
        case "purple": rgb = 0x8E5CF7
        case "green": rgb = 0x34A853
        case "orange": rgb = 0xF08A24
        case "pink": rgb = 0xE8508A
        case "teal": rgb = 0x1AA6B7
        case "yellow": rgb = 0xD9B200
        default: rgb = 0x8E8E93
        }
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }

}

struct PROJPAGECard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content() }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(PROJPAGEStyle.card, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08), lineWidth: 1))
    }
}

@MainActor @Observable final class PROJPAGESettingsModel {
    var values: [String: Any] = [:]
    var error: String?
    var loading = true
    typealias Invoke = @MainActor (String, [Any?]) async throws -> Any
    @ObservationIgnored private let invoke: Invoke
    @ObservationIgnored let isRenderFixture: Bool
    init(values: [String: Any]? = nil, invoke: @escaping Invoke = { channel, args in try await EngineBridge.shared.invoke(channel, args) }) {
        self.values = values ?? [:]; self.loading = values == nil; self.isRenderFixture = values != nil; self.invoke = invoke
    }
    private var write: Task<Void, Never>?

    private var pending: [String: String] = [:]
    func load(_ id: String) async {
        guard !isRenderFixture else { return }
        do { let raw = try await invoke("project-settings:get", [["projectId": id]]) as? [String: Any]; values = raw?["values"] as? [String: Any] ?? [:]; loading = false }
        catch { self.error = error.localizedDescription; loading = false }
    }
    func set(_ key: String, _ value: String, projectID: String) {
        values[key] = value
        guard !isRenderFixture else { return }
        pending[key] = value
        write?.cancel()
        write = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                let patch = pending
                _ = try await invoke("project-settings:set", [["projectId": projectID, "values": patch]])
                for (key, value) in patch where pending[key] == value { pending[key] = nil }
                error = nil
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    /// The project as typed in this window until the registry holds it; nil shows the registry's own copy.
    var edited: PROJProject?
    @ObservationIgnored private var projectWrite: Task<Void, Never>?
    @ObservationIgnored private var registryCopy: PROJProject?
    /// Typing a name saves once per pause, like `set`: a newer edit cancels the waiting one, so an
    /// early, slow save can never land last and leave a cut-off name.
    func saveProject(_ next: PROJProject) {
        edited = next
        guard !isRenderFixture else { return }
        projectWrite?.cancel()
        projectWrite = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                _ = try await invoke("project-registry:save", [next.wireValue.foundation])
                guard !Task.isCancelled else { return }
                projectWrite = nil
                if registryCopy == next { edited = nil }
                error = nil
            } catch is CancellationError {} catch {
                guard !Task.isCancelled else { return }
                projectWrite = nil; self.error = error.localizedDescription
            }
        }
    }
    /// The registry's copy changed, here or elsewhere (side panel, an MCP tool): with no save
    /// waiting, the window shows it, so a later edit never writes an old name or folder back.
    func registryChanged(_ current: PROJProject) {
        registryCopy = current
        if projectWrite == nil || current == edited { edited = nil }
    }
}

@MainActor private enum PROJPAGESettingsWindow {
    static var windows: [String: NSWindow] = [:]
    static func open(project: PROJProject) {
        // Only for the person: a window is never raised over the app they are working in (NativeFront).
        NativeFront.whenPersonActs("project-settings-" + project.id) {
            if let window = windows[project.id] { window.makeKeyAndOrderFront(nil); return }
            let host = NSHostingController(rootView: PROJPAGEProjectSettings(project: project))
            let window = NSPanel(contentViewController: host)
            window.title = project.name
            window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.setContentSize(NSSize(width: 560, height: 520))
            window.setFrameAutosaveName("PROJPAGE-settings-" + project.id)
            window.isReleasedWhenClosed = false
            windows[project.id] = window
            // Reopening builds a fresh panel; a closed one never comes back with the project as it was then.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { windows[project.id] = nil }
            }
            window.makeKeyAndOrderFront(nil)
        }
    }
}

struct PROJPAGEProjectSettings: View {
    let project: PROJProject
    @State private var model = PROJPAGESettingsModel()
    @State private var section = "General"
    @State private var logoSuggestions: [URL] = []
    @State private var accountLine: String?
    @State private var logoDropTargeted = false
    init(project: PROJProject, model: PROJPAGESettingsModel = PROJPAGESettingsModel(), section: String = "General") {
        self.project = project; _model = State(initialValue: model); _section = State(initialValue: section)
    }
    /// The registry's latest copy (renamed or moved elsewhere since the window opened), else the one it opened with.
    private var live: PROJProject { SHELLRoutes.registry.first { $0.id == project.id } ?? project }
    private var shown: PROJProject { model.edited ?? live }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Project settings", selection: $section) {
                // SETTINGS-TRUTH row 41: the Agents tab held only "Agents folder", which nothing read; it is gone.
                ForEach(["General", "Server", "Tasks", "Coding AI"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).padding(16)
            Form {
                if let error = model.error { Section { HStack { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange); Text(error).foregroundStyle(.secondary) } } }
                if model.loading { Section { ProgressView("Loading settings…") } }
                else {
                    Section(section) {
                        switch section {
                        case "General":
                            NativeSessionTextField("Name", text: Binding(get: { shown.name }, set: { var next = shown; next.name = $0; save(next) }))
                            // Asad 10 Oct: a logo instead of a colour dot. Drop an image here, choose one,
                            // or pick one found in the project's folder. It is copied into the app's data.
                            LabeledContent("Logo") {
                                HStack(spacing: 8) {
                                    ProjectLogoView(project: shown, size: 28)
                                    NativeSessionButton("Choose…") { chooseLogo() }
                                    if !shown.logo.isEmpty { NativeSessionButton("Remove") { setLogo(nil) } }
                                }
                            }
                            .padding(2)
                            .background(logoDropTargeted ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .onDrop(of: [.fileURL], isTargeted: $logoDropTargeted) { providers in
                                guard let provider = providers.first else { return false }
                                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                                    guard let url else { return }
                                    Task { @MainActor in setLogo(url) }
                                }
                                return true
                            }
                            if !logoSuggestions.isEmpty {
                                LabeledContent("Found in the folder") {
                                    HStack(spacing: 6) {
                                        ForEach(logoSuggestions, id: \.self) { url in
                                            NativeSessionButton { setLogo(url) } label: {
                                                Group {
                                                    if let image = NSImage(contentsOf: url) {
                                                        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                                                    } else { Image(systemName: "photo") }
                                                }
                                                .frame(width: 26, height: 26)
                                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                                .contentShape(.rect)
                                            }
                                            .buttonStyle(.plain)
                                            .help(suggestionLabel(url))
                                            .accessibilityLabel("Use " + url.lastPathComponent)
                                        }
                                    }
                                }
                            }
                            LabeledContent("Folder") {
                                HStack { Text(shown.folders.first.map(PROJPAGEStyle.shortPath) ?? "Independent").font(.system(size: 12, design: .monospaced)).lineLimit(1)
                                    NativeSessionButton("Choose…") { chooseFolder() }
                                }
                            }
                        case "Server":
                            // SETTINGS-TRUTH row 42: named in every brief for work in this project (BackendTaskEngine.linkedServersLine).
                            field("Linked servers", "linkedServers")
                            Text("Names of your saved servers, separated by commas. Hoot and the agents are told them with each task in this project.").font(.caption).foregroundStyle(.secondary)
                        // SETTINGS-TRUTH row 43: the connected system this project's Tasks page opens on (the guide's "Task source").
                        case "Tasks": TKTaskSourcePicker(projectID: project.id, value: model.values["taskSystem"] as? String ?? "") { model.set("taskSystem", $0, projectID: project.id) }
                        default:
                            // SETTINGS-TRUTH rows 39/40: the AI is a real choice New session starts with here; "Default model" was read
                            // by nothing (models are set per AI in Settings › Agents), so it is gone.
                            codingAIPicker
                            // ACCOUNTS-SPEC §4: shown here, changed in the one place (Settings › Coding AIs).
                            LabeledContent("Account") {
                                HStack {
                                    Text(accountLine ?? "…").foregroundStyle(.secondary).lineLimit(2)
                                    NativeSessionButton("Change in Settings…") {
                                        AppModel.shared.requestSettings()
                                        AppModel.shared.selectSettingsSection("agents")
                                    }
                                }
                            }
                            .task(id: shown.folders.first) {
                                guard !model.isRenderFixture else { return }
                                accountLine = await NativeAccountLevelsModel.projectLine(folder: shown.folders.first)
                            }
                        }
                    }
                }
            }.formStyle(.grouped).frame(maxWidth: 680)
        }.task { await model.load(project.id) }
        .onChange(of: live, initial: true) { _, now in model.registryChanged(now) }
        .task(id: shown.folders.first) {
            guard !model.isRenderFixture, let folder = shown.folders.first else { logoSuggestions = []; return }
            logoSuggestions = await Task.detached(priority: .utility) { ProjectLogos.suggestions(folder: folder) }.value
        }
    }
    private func suggestionLabel(_ url: URL) -> String {
        guard let folder = shown.folders.first, url.path.hasPrefix(folder) else { return url.lastPathComponent }
        return String(url.path.dropFirst(folder.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private func chooseLogo() {
        guard !model.isRenderFixture else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .svg, .icns, .ico]
        panel.begin { response in
            MainActor.assumeIsolated { if response == .OK, let url = panel.url { setLogo(url) } }
        }
    }
    /// Copies the image into the app's own data (nil removes the logo), then saves the project.
    private func setLogo(_ url: URL?) {
        guard !model.isRenderFixture else { return }
        var next = shown
        let old = next.logo
        do {
            next.logo = try url.map { try ProjectLogos.adopt($0, projectID: next.id) } ?? ""
            save(next)
            if !old.isEmpty, old != next.logo { ProjectLogos.discard(old) }
        } catch { model.error = error.localizedDescription }
    }
    private func save(_ next: PROJProject) { model.saveProject(next) }
    private func chooseFolder() {
        guard !model.isRenderFixture else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let path = panel.url?.path else { return }
                var next = shown; next.folders = [path]; save(next)
            }
        }
    }
    /// The AI New session starts with for this project (NewSessionStart.resolve); agents keep their own.
    private var codingAIPicker: some View {
        let current = model.values["defaultCodingAI"] as? String ?? ""
        let known = ["claude", "codex", "gemini"]
        return VStack(alignment: .leading, spacing: 4) {
            Picker("Default coding AI", selection: Binding(get: { current }, set: { model.set("defaultCodingAI", $0, projectID: project.id) })) {
                Text("No default").tag("")
                ForEach(known, id: \.self) { Text(CodingAICatalog.label($0)).tag($0) }
                if !current.isEmpty && !known.contains(current) { Text(current).tag(current) }
            }
            Text("New sessions in this project start with this AI. Agents keep the AI set on their own page.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func field(_ label: String, _ key: String) -> some View {
        NativeSessionTextField(label, text: Binding(get: { model.values[key] as? String ?? "" }, set: { model.set(key, $0, projectID: project.id) }))
    }
}

import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// One window per saved server. No SSH connection is opened by the window frame.
@MainActor
enum MACHINESObjectWindows {
    private static var servers: [String: NSPanel] = [:]
    private static var devices: NSPanel?

    /// Shared object windows (READY L1-CORE): one scene per saved server and one for device access.
    static func registerShared() {
        if !ObjectWindows.hasProvider(for: ObjectRef(kind: "server", id: "probe")) {
            ObjectWindows.register(kind: "server", title: { ref in
                NativeServersModel.shared.servers.first { $0.id == ref.id }?.name ?? "Server settings"
            }, content: { ref in
                guard let server = NativeServersModel.shared.servers.first(where: { $0.id == ref.id }) else {
                    return AnyView(ContentUnavailableView("Server removed", systemImage: "server.rack",
                        description: Text("This server is no longer in the list.")))
                }
                return AnyView(MACHINESServerSettingsContent(model: .shared, server: server))
            })
        }
        if !ObjectWindows.hasProvider(for: ObjectRef(kind: "device", id: "probe")) {
            ObjectWindows.register(kind: "device", title: { _ in "Device access" }, content: { _ in
                AnyView(MACHINESDevicesAccessContent(model: RemoteSectionModel()))
            })
        }
    }

    static func openDevices() {
        registerShared()
        if ObjectWindows.open(ObjectRef(kind: "device", id: "access")) { return }
        // Fall-back panel: only for the person, like the shared door above (NativeFront).
        NativeFront.whenPersonActs("device-access") {
            if let panel = devices { panel.makeKeyAndOrderFront(nil); return }
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            panel.title = "Device access"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isReleasedWhenClosed = false
            panel.contentMinSize = NSSize(width: 520, height: 440)
            panel.contentView = NSHostingView(rootView: MACHINESDevicesAccessContent(model: RemoteSectionModel()))
            if let main = NSApp.mainWindow {
                let visible = main.screen?.visibleFrame ?? main.frame
                panel.setFrameOrigin(NSPoint(x: min(main.frame.maxX + 16, visible.maxX - 560), y: min(main.frame.maxY - 520, visible.maxY - 520)))
            } else { panel.center() }
            panel.setFrameAutosaveName("device-access")
            devices = panel
            panel.makeKeyAndOrderFront(nil)
        }
    }

    static func openServer(model: NativeServersModel, server: CodingAIServer, route: Binding<NativeServersRoute>) {
        registerShared()
        if model === NativeServersModel.shared, ObjectWindows.open(ObjectRef(kind: "server", id: server.id)) { return }
        // Fall-back panel (also reachable from a tool): only for the person, like the shared door above.
        NativeFront.whenPersonActs("server-settings-" + server.id) {
            if let panel = servers[server.id] { panel.makeKeyAndOrderFront(nil); return }
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            panel.title = server.name
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isReleasedWhenClosed = false
            panel.contentMinSize = NSSize(width: 520, height: 440)
            panel.contentView = NSHostingView(rootView: MACHINESServerSettingsContent(model: model, server: server, route: route))
            if let main = NSApp.mainWindow {
                let visible = main.screen?.visibleFrame ?? main.frame
                panel.setFrameOrigin(NSPoint(x: min(main.frame.maxX + 16, visible.maxX - 560),
                    y: min(main.frame.maxY - 520, visible.maxY - 520)))
            } else { panel.center() }
            panel.setFrameAutosaveName("server-settings-" + server.id)
            servers[server.id] = panel
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

/// Shared frame adapter can replace only this wrapper when SHELL-CORE is ready.
struct MACHINESServerSettingsContent: View {
    @Bindable var model: NativeServersModel
    let server: CodingAIServer
    @Binding var route: NativeServersRoute
    let live: Bool
    let serverFixture: NativeAppsSRV2ServerModel?
    @State private var tab = "Access"
    @State private var access: NativeServerAccessModel
    @State private var room: NativeServerRoom
    @State private var holder = NativeAppsSRV2ServerHolder()
    @State private var landingFolder = ""
    @State private var selectedAlias = ""
    @State private var aliases: [ServerSSHAlias] = []
    @State private var connectionProblem: String?
    @State private var shownApps: MACHINESShownAppsModel
    @State private var folderLimits: NativeServerFolderLimitsModel

    init(model: NativeServersModel, server: CodingAIServer, route: Binding<NativeServersRoute> = .constant(.list),
         accessFixture: NativeServerAccessModel? = nil, live: Bool = true, initialTab: String = "Access",
         serverFixture: NativeAppsSRV2ServerModel? = nil, shownAppsFixture: MACHINESShownAppsModel? = nil,
         folderLimitsFixture: NativeServerFolderLimitsModel? = nil) {
        _folderLimits = State(initialValue: folderLimitsFixture ?? NativeServerFolderLimitsModel(serverID: server.id, live: live))
        self.model = model; self.server = server; _route = route; self.live = live; self.serverFixture = serverFixture
        _tab = State(initialValue: initialTab)
        _access = State(initialValue: accessFixture ?? NativeServerAccessModel(serverId: server.id, live: live))
        _room = State(initialValue: NativeServerRoom(serverId: server.id, live: live))
        _shownApps = State(initialValue: shownAppsFixture ?? MACHINESShownAppsModel(serverID: server.id, live: live))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text(server.name).font(.system(size: 13, weight: .semibold))
                MACHINESServerSettingsTabs(selection: $tab)
            }.padding(.top, 16).padding(.bottom, 10)
            Divider()
            Group {
                switch tab {
                case "Access":
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            NativeServerAccessSection(model: access)
                            Form { MACHINESShownAppsSection(model: shownApps) }.formStyle(.grouped).scrollContentBackground(.hidden).padding(.horizontal, -20)
                                .scrollDisabled(true).frame(minHeight: CGFloat(140 + 26 * min(shownApps.names.count, 30)))
                            Form { NativeServerFolderLimitsSection(model: folderLimits) }.formStyle(.grouped).scrollContentBackground(.hidden).padding(.horizontal, -20)
                                .scrollDisabled(true).frame(minHeight: CGFloat(170 + 28 * folderLimits.folders.count))
                        }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
                    }
                case "Sign-in": signIn
                case "Apps setup": appsSettings([.setup])
                case "Alerts": appsSettings([.alerts])
                default:
                    ScrollView {
                        NativeServerAdvanced(server: server, extra: model.extra(server.id), state: model.states[server.id], now: model.now,
                            onRename: { if live { model.rename(server.id, to: $0) } },
                            onForget: { if live { model.forget(server.id, route: $route) } },
                            onGrant: { room.grant($0) }, onRevoke: { room.revoke() },
                            onDrivesWindows: { if live { model.setDrivesWindows(server.id, $0) } }, expanded: true)
                            .padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
                    }
                }
            }.frame(minHeight: 0, maxHeight: .infinity)

        }.font(.system(size: 13)).background(MACHINESTokens.page)
    }

    @ViewBuilder private func appsSettings(_ sections: Set<NativeMACHINESServerSettingsSection>) -> some View {
        if live || serverFixture != nil {
            Form {
                NativeAppsSRV2ServerSectionList(model: serverFixture ?? holder.model(serverID: server.id, serverName: server.name),
                    writesDisabled: access.lookOnly != false, sections: sections)
            }.formStyle(.grouped).frame(minHeight: 340)
        } else {
            MACHINESCard { Text("Server settings").foregroundStyle(.secondary) }
        }
    }

    private var signIn: some View {
        Form {
            Section("Sign-in") {
                LabeledContent("SSH alias", value: access.sshAlias ?? "Direct connection")
                LabeledContent("Address", value: server.address)
                LabeledContent("Sign in as", value: server.username)
                if let alias = aliases.first(where: { $0.alias == access.sshAlias }) {
                    ForEach(alias.keyNames, id: \.self) { key in LabeledContent("Key", value: key) }
                }
                Text("Your SSH settings and keys stay on this Mac.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Landing folder") {
                if live {
                    NativeServerFolderPicker(serverId: server.id, serverName: server.name, path: Binding(
                        get: { landingFolder.isEmpty ? nil : landingFolder }, set: { landingFolder = $0 ?? "" }))
                } else { LabeledContent("Folder", value: "Home") }
                Button("Open terminal here") {
                    if live { AppModel.shared.runButton(.openServerSession(serverId: server.id, serverName: server.name,
                        startIn: landingFolder.isEmpty ? nil : landingFolder)) }
                }.disabled(!live)
            }
            if let connectionProblem { Section { Text(connectionProblem).foregroundStyle(.secondary) } }
        }.formStyle(.grouped).frame(minHeight: 320)
        .task {
            guard live else { return }
            do { aliases = ServerSSHAlias.parse(CodingAIJSON(try await EngineBridge.shared.invoke("servers:ssh-aliases"))) ?? [] }
            catch { connectionProblem = "Couldn’t read SSH settings." }
        }
    }
}

struct MACHINESServerSettingsTabs: View {
    @Binding var selection: String
    private let items = [("Access", "shield"), ("Sign-in", "key"), ("Apps setup", "cube"), ("Alerts", "bell"), ("Advanced", "gearshape")]
    var body: some View {
        // Finder-Settings style (mockup 04b): icon over label, selected tab in the accent colour.
        GlassEffectContainer(spacing: 4) {
        HStack(spacing: 4) {
            ForEach(items, id: \.0) { item in
                Button { withAnimation(.smooth) { selection = item.0 } } label: {
                    VStack(spacing: 6) {
                        Image(systemName: item.1).font(.system(size: 15))
                        Text(item.0).font(.system(size: 11))
                    }.frame(maxWidth: .infinity, minHeight: 44).contentShape(.rect)
                    .background(selection == item.0 ? DeckTokens.card : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).foregroundStyle(selection == item.0 ? Color.accentColor : Color.secondary)
                    .accessibilityAddTraits(selection == item.0 ? .isSelected : [])
            }
        }.padding(4).frame(maxWidth: 450)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

// MARK: - Show only these apps (per server)

/// The owner's per-server app filter. Unticked apps are hidden everywhere: the server page,
/// Docker, and every AI/MCP read (the backend cuts them; this model only edits the list).
/// Deliberately no MCP tool: an AI app must never be able to unhide something.
@MainActor @Observable
final class MACHINESShownAppsModel {
    let serverID: String
    private let live: Bool
    /// nil = show all.
    private(set) var shown: Set<String>?
    private(set) var names: [String] = []
    private(set) var loading = false
    private(set) var problem: String?
    private static var cache: [String: Set<String>?] = [:]

    init(serverID: String, live: Bool = true, fixtureNames: [String] = [], fixtureShown: Set<String>? = nil) {
        self.serverID = serverID; self.live = live
        names = fixtureNames.sorted(); shown = fixtureShown
    }

    /// Last known list for other screens (e.g. deployed apps); nil = show all or not read yet.
    static func cachedShown(_ serverID: String) -> Set<String>? { cache[serverID] ?? nil }

    func isOn(_ name: String) -> Bool { shown?.contains(name) ?? true }
    var showsAll: Bool { shown == nil }

    func load() async {
        guard live else { return }
        loading = true; defer { loading = false }
        do {
            let raw = CodingAIJSON(try await EngineBridge.shared.invoke("servers:shown-apps:read", [serverID]))
            take(raw); problem = nil
        } catch { problem = CodingAIErrorText.from(error, fallback: "Couldn’t read which apps this server shows.") }
    }

    func toggle(_ name: String, _ on: Bool) {
        var next = shown ?? Set(names)
        if on { next.insert(name) } else { next.remove(name) }
        save(next == Set(names) ? nil : next)
    }
    func showAll() { save(nil) }

    private func save(_ next: Set<String>?) {
        shown = next; Self.cache[serverID] = next
        guard live else { return }
        Task {
            do {
                let payload: [String: Any] = ["names": next.map { Array($0).sorted() as Any } ?? NSNull()]
                take(CodingAIJSON(try await EngineBridge.shared.invoke("servers:shown-apps:set", [serverID, payload])))
                problem = nil
                NativeServersModel.shared.reread()
            } catch { problem = CodingAIErrorText.from(error, fallback: "Couldn’t save which apps this server shows.") }
        }
    }

    private func take(_ raw: CodingAIJSON) {
        let saved = raw["shown"].array.map { Set($0.compactMap(\.string)) }
        shown = saved; Self.cache[serverID] = saved
        names = Array(Set((raw["seen"].array ?? []).compactMap(\.string)).union(saved ?? [])).sorted()
    }
}

struct MACHINESShownAppsSection: View {
    @State var model: MACHINESShownAppsModel
    var body: some View {
        Section {
            if model.names.isEmpty {
                Text(model.loading ? "Reading this server’s apps…" : "No apps seen yet. Open the server once, then choose here.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(model.names, id: \.self) { name in
                    Toggle(isOn: Binding(get: { model.isOn(name) }, set: { model.toggle(name, $0) })) {
                        Text(name).font(.system(size: 13, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    }.toggleStyle(.checkbox)
                }
                if !model.showsAll { Button("Show every app") { model.showAll() } }
            }
            if let problem = model.problem { NativeMACHINESInlineNotice(text: problem) }
        } header: {
            Text("Show only these apps")
        } footer: {
            Text(model.showsAll ? "Every app on this server is shown." :
                 "Unticked apps are hidden everywhere in Terminal Deck, and AI apps can’t see or use them.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .task { await model.load() }
    }
}

// MARK: - Folders it may open (SRVFILES #120)

/// The owner's per-server folder limit for the Files view, galleries and every AI read.
/// Default: the sign-in's home folder. Owner only: no MCP tool can widen it.
@MainActor @Observable
final class NativeServerFolderLimitsModel {
    let serverID: String
    private let live: Bool
    var saved: [String]?
    var roots: [String] = []
    var draft = ""
    var problem: String?
    var busy = false
    init(serverID: String, live: Bool = true, fixtureSaved: [String]? = nil, fixtureRoots: [String] = []) {
        self.serverID = serverID; self.live = live; saved = fixtureSaved; roots = fixtureRoots
    }
    var folders: [String] { saved ?? ["~"] }
    func load() async {
        guard live else { return }
        do { take(try await NativeServerFilesAPI.call("servers:files:folders", serverID)) }
        catch { problem = NativeServerFilesAPI.message(error) }
    }
    func add() {
        let path = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        save(folders + [path], clearDraft: true)
    }
    func remove(_ path: String) {
        let next = folders.filter { $0 != path }
        save(next.isEmpty || next == ["~"] ? nil : next)
    }
    func reset() { save(nil) }
    private func save(_ next: [String]?, clearDraft: Bool = false) {
        guard live else { saved = next; if clearDraft { draft = "" }; return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let payload: [String: Any] = ["folders": next.map { $0 as Any } ?? NSNull()]
                take(try await NativeServerFilesAPI.call("servers:files:folders:set", serverID, payload))
                problem = nil
                if clearDraft { draft = "" }
            } catch { problem = NativeServerFilesAPI.message(error) }
        }
    }
    private func take(_ raw: CodingAIJSON) {
        saved = raw["saved"].array.map { $0.compactMap(\.string) }
        roots = (raw["roots"].array ?? []).compactMap(\.string)
    }
}

struct NativeServerFolderLimitsSection: View {
    @Bindable var model: NativeServerFolderLimitsModel
    var body: some View {
        Section {
            ForEach(model.folders, id: \.self) { folder in
                HStack(spacing: 8) {
                    Image(systemName: folder == "~" ? "house" : "folder").foregroundStyle(.secondary).frame(width: 18)
                    Text(folder == "~" ? "Home folder" : folder).font(.system(size: 13, design: folder == "~" ? .default : .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    if folder == "~", let home = model.roots.first { Text(home).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1) }
                    Spacer()
                    if model.saved != nil {
                        Button { model.remove(folder) } label: { Image(systemName: "minus.circle").frame(width: 24, height: 24).contentShape(.rect) }
                            .buttonStyle(.borderless).help("Stop allowing \(folder)").accessibilityLabel("Stop allowing \(folder)")
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Folder", text: $model.draft, prompt: Text("Add a folder, like /srv/media or ~/uploads")).labelsHidden().textFieldStyle(.roundedBorder)
                    .onSubmit { model.add() }
                Button("Add") { model.add() }.disabled(model.draft.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
            }
            if model.saved != nil { Button("Only the home folder") { model.reset() } }
            if let problem = model.problem { NativeMACHINESInlineNotice(text: problem) }
        } header: {
            Text("Folders it may open")
        } footer: {
            Text("Files, galleries and AI file tools can open only these folders on this server. A terminal opened on it is not limited to them.").font(.callout).foregroundStyle(.secondary)
        }
        .task { await model.load() }
    }
}

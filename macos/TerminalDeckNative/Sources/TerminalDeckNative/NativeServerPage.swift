import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// Dashboard for one server. Connection and access forms live in its own window.
struct NativeServerPage: View {
    @Bindable var model: NativeServersModel
    let server: CodingAIServer
    @Binding var route: NativeServersRoute
    let live: Bool
    let fixtureState: ServerRoomState?
    @State private var room: NativeServerRoom
    @State private var setup: NativeServerSetupModel
    @State private var access: NativeServerAccessModel
    @State private var selected = "Apps"
    @State private var filter = "All"
    @State private var showAdvanced = false
    @State private var deployedRows: [NativeAppsSummary] = []
    @State private var projectID: String
    /// SRVFILES #120: renders pass a fixture Files view.
    private let filesFixture: NativeServerFilesView?

    init(model: NativeServersModel, server: CodingAIServer, route: Binding<NativeServersRoute>,
         accessFixture: NativeServerAccessModel? = nil, live: Bool = true,
         fixtureState: ServerRoomState? = nil, projectId: String? = nil, initialFilter: String = "All", initialView: String = "Apps",
         filesFixture: NativeServerFilesView? = nil) {
        self.model = model; self.server = server; _route = route; self.filesFixture = filesFixture
        self.live = live; self.fixtureState = fixtureState
        _projectID = State(initialValue: projectId ?? "independent")
        _filter = State(initialValue: initialFilter)
        _selected = State(initialValue: initialView)
        _access = State(initialValue: accessFixture ?? NativeServerAccessModel(serverId: server.id, live: live))
        _room = State(initialValue: NativeServerRoom(serverId: server.id, live: live))
        _setup = State(initialValue: NativeServerSetupModel.forServer(server.id, live: live))
    }

    private var state: ServerRoomState? { fixtureState ?? model.states[server.id] }

    var body: some View {
        MACHINESPage(title: server.name, subtitle: server.whereLine, back: { route = .list },
            switcher: { MACHINESGlassSwitch(selection: $selected, items: ["Apps", "Coding AIs", "Websites", "Health", "Files"]) },
            actions: {
                HStack(spacing: 5) {
                    Circle().fill(NativePROJLabels.shared.projects.first { $0.id == projectID }.map(DeckTokens.projectColour) ?? Color.secondary).frame(width: 8, height: 8)
                    Text(PROJProjects.name(for: projectID)).font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.horizontal, 8).padding(.vertical, 5).background(MACHINESTokens.selection, in: RoundedRectangle(cornerRadius: 6))
                Button {
                    if live { MACHINESObjectWindows.openServer(model: model, server: server, route: $route) }
                } label: { Image(systemName: "gearshape") }
                    .help("Server settings").accessibilityLabel("Server settings")
                Button {
                    if live { AppModel.shared.runButton(.openServerSession(serverId: server.id, serverName: server.name, startIn: nil)) }
                } label: { Label("Open terminal", systemImage: "terminal") }
                    .buttonStyle(.borderedProminent)
                    .disabled(state?.link != .ready || state?.identityChanged == true || (live ? !AppModel.shared.canRun : false))
            }) {
                VStack(alignment: .leading, spacing: 28) {
                    NativeMACHINESMetricStrip(state: state, now: model.now) { selected = "Health" }
                    if let state, state.identityChanged {
                        NativeServerIdentityChanged(state: state) { route = .list }
                    } else if selected == "Files" {
                        // Files reads over its own SFTP channel; it does not wait for the page's look.
                        filesFixture ?? NativeServerFilesView(serverID: server.id, serverName: server.name, live: live)
                    } else if state?.link == .failed {
                        MACHINESCard {
                            HStack {
                                NativeMACHINESInlineNotice(text: state?.problem ?? "Couldn’t reach this server.")
                                Spacer()
                                DeckRetryButton("Try again", autoRetry: true) { room.look() }.disabled(!live) // autoRetry: re-reads the server's state
                            }
                        }
                    } else {
                        selectedContent
                    }
                }
            }
            .onAppear {
                guard live else { return }
                room.report = { state in model.remember(state) }
                access.load()
                room.look()
                // A setup left running on this page last time shows again with its terminal.
                if state?.link == .ready, setup.running != nil { setup.start() }
                Task {
                    let raw = try? await EngineBridge.shared.invoke("servers:list")
                    let rows = CodingAIJSON(raw)["servers"].array ?? CodingAIJSON(raw).array ?? []
                    if let row = rows.first(where: { $0["id"].text == server.id }) {
                        projectID = row["projectId"].text ?? row["projectID"].text ?? "independent"
                    }
                }
            }
            .onChange(of: state?.link) { _, link in if live, link == .ready { setup.start() } }
            .onDisappear { if live { setup.leave(); room.close() } }
    }

    @ViewBuilder private var selectedContent: some View {
        switch selected {
        case "Coding AIs":
            if !setup.rows.isEmpty {
                MACHINESCard { NativeServerSetupPanel(model: setup) }
            } else {
                NativeMACHINESCodingRows(facts: state?.view?.facts, checking: state == nil || state?.link == .connecting, onRefresh: { room.look() })
            }
        case "Websites":
            resourceList(title: "Websites", cards: (state?.view?.cards ?? []).filter { $0.kind == .site })
        case "Health":
            NativeMACHINESHealth(state: state, now: model.now) { room.look() }
            if live {
                NativeMACHINESHealthDuties(server: server, writesDisabled: access.lookOnly != false)
                MACHINESCard {
                    NativeServerHost(server: server, connected: state?.link == .ready)
                    DisclosureGroup("Advanced controls", isExpanded: $showAdvanced) {
                        NativeServerControlScreens.advanced(server.id).frame(minHeight: 420)
                    }
                }
            }
        default:
            let names = Set(deployedRows.map { $0.name.lowercased() })
            let cards = (state?.view?.cards ?? []).filter { $0.kind != .site && !names.contains($0.name.lowercased()) }
            HStack {
                Text("Apps").font(.system(size: 15, weight: .semibold))
                Spacer()
                Picker("Apps filter", selection: $filter) {
                    Text("All \(cards.count + deployedRows.count)").tag("All")
                    Text("Running \(cards.filter { $0.running == true }.count + deployedRows.filter { NativeAppsRules.friendlyStatus($0.status) == "Running" }.count)").tag("Running")
                    Text("Stopped \(cards.filter { $0.running == false }.count + deployedRows.filter { NativeAppsRules.friendlyStatus($0.status) == "Stopped" }.count)").tag("Stopped")
                }.pickerStyle(.segmented).labelsHidden().nativeUIGGreyControl().frame(maxWidth: 300)
            }
            resourceList(title: nil, cards: cards.filter { filter == "All" || (filter == "Running" ? $0.running == true : $0.running == false) })
            NativeMACHINESManagedApps(server: server, filter: $filter, live: live, onRows: { deployedRows = $0 })
        }
    }

    @ViewBuilder private func resourceList(title: String?, cards: [ServerCardInfo]) -> some View {
        if let title { Text(title).font(.system(size: 15, weight: .semibold)) }
        if state?.link == .connecting || state == nil {
            MACHINESCard {
                ForEach(0..<5, id: \.self) { _ in
                    HStack { RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)).frame(width: 28,height:28)
                        RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1)).frame(width:220,height:16); Spacer() }
                        .padding(.vertical, 8)
                }
            }.accessibilityLabel("Checking server")
        } else if cards.isEmpty {
            MACHINESCard {
                Label(title == "Websites" ? "No websites found" : "No apps in this view", systemImage: title == "Websites" ? "globe" : "cube")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100)
            }
        } else {
            VStack(spacing: 0) {
                ForEach(cards) { card in
                    NativeServerCard(card: card, actions: state?.previews[card.id] ?? [],
                        absent: state?.view?.absent[card.id] ?? [], room: room)
                    if card.id != cards.last?.id { Divider() }
                }
            }
            .background(MACHINESTokens.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(MACHINESTokens.hairline, lineWidth: 1))
        }
    }
}

// MARK: - Reaching the server (`useServerRoom`)

@MainActor
@Observable
final class NativeServerRoom {
    let serverId: String
    @ObservationIgnored var report: ((ServerRoomState) -> Void)?
    @ObservationIgnored private var alive = true

    private let live: Bool
    init(serverId: String, live: Bool = true) { self.serverId = serverId; self.live = live }

    private func call(_ channel: String, _ args: [Any?] = []) async throws -> CodingAIJSON {
        guard live else { throw CancellationError() }
        return CodingAIJSON(try await EngineBridge.shared.invoke(channel, args))
    }

    /// Look at the server: its view, the previews of every offered action, and the grant.
    func look() {
        guard live else { return }
        alive = true
        let id = serverId
        report?(ServerRoomState(id: id, link: .connecting))
        Task {
            let raw: CodingAIJSON
            do {
                raw = CodingAIJSON(try await EngineDeadline.invoke("servers:look", [id], what: "reaching that server", seconds: 10))
            } catch {
                guard alive else { return }
                report?(ServerRoomState(id: id, link: .failed,
                                        problem: EngineDeadline.serverText(error, fallback: "We could not reach this server.")))
                return
            }
            guard alive else { return }
            guard raw["ok"].isTrue else {
                report?(ServerRoomState.failed(id, refusal: raw))
                return
            }
            guard let view = ServerView.parse(raw["view"]) else {
                report?(ServerRoomState(id: id, link: .failed, problem: "That server answered with nothing we could read."))
                return
            }
            var previews: [String: [ServerActionPreview]] = [:]
            for card in view.cards {
                var rows: [ServerActionPreview] = []
                for actionId in view.offered[card.id] ?? [] {
                    if let reply = try? await call("servers:preview", [id, card.id, actionId]), reply["ok"].isTrue,
                       let preview = ServerActionPreview.parse(reply["preview"]) {
                        rows.append(preview)
                    }
                }
                previews[card.id] = rows
            }
            let grant = (try? await call("servers:grant-state", [id])).flatMap(ServerGrant.parse)
            guard alive else { return }
            var state = ServerRoomState(id: id, link: .ready)
            state.view = view
            state.previews = previews
            state.grant = grant
            report?(state)
        }
    }

    func close() {
        guard live else { return }
        alive = false
        let id = serverId
        Task { _ = try? await call("servers:close", [id]) }
    }

    /// Run one card action; anything but logs, open and copy reads the server again after.
    func run(_ cardId: String, _ actionId: String) async -> (ok: Bool, outcome: ServerActionOutcome, sentence: String) {
        let none = ServerActionOutcome(done: "", wayBack: nil)
        do {
            let raw = try await call("servers:act", [serverId, cardId, actionId])
            guard raw["ok"].isTrue else {
                return (false, none, raw["sentence"].text ?? "That did not work, and this server did not say why.")
            }
            if !["logs", "open", "copy-address"].contains(actionId) { look() }
            return (true, ServerActionOutcome.parse(raw["outcome"]), "")
        } catch {
            return (false, none, "That did not get an answer, so it may or may not have run.")
        }
    }

    func logs(_ cardId: String, _ lines: Int) async throws -> [String] {
        ServerWords.logLines(try await call("servers:logs", [serverId, cardId, lines]))
    }

    func grant(_ forMs: Double) {
        Task {
            _ = try? await call("servers:grant", [serverId, forMs])
            look()
        }
    }

    func revoke() {
        Task {
            _ = try? await call("servers:revoke", [serverId])
            look()
        }
    }
}

// MARK: - Open a terminal on it

// MARK: - How it is doing (`ServerHealth`)

// MARK: - A changed identity (`IdentityChanged`)

struct NativeServerIdentityChanged: View {
    let state: ServerRoomState
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(.orange)
                Text("This server answered with a different identity").font(.headline)
            }
            NativeSettingsProse(text: state.problem ?? "Every server has an identity that does not change, and this one has. We have not signed in and we have not sent your password.")
            if let identity = state.identity {
                LabeledContent("What we saw the first time") { Text(identity.expected).textSelection(.enabled) }
                LabeledContent("What answered now") { Text(identity.offered).textSelection(.enabled) }
            }
            NativeSettingsProse(text: "If you rebuilt this server yourself, forget it in this app and add it again. If you did not, ask whoever looks after it before you sign in anywhere.")
            Button("Back to machines", action: onBack)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
    }
}

// MARK: - What it keeps running (`CardGroup`, `ServerCard`)

struct NativeServerCard: View {
    let card: ServerCardInfo
    let actions: [ServerActionPreview]
    let absent: [ServerAbsentAction]
    let room: NativeServerRoom
    @State private var asking: ServerActionPreview?
    @State private var busy: String?
    @State private var said: (ok: Bool, text: String, wayBack: (actionId: String, label: String)?)?
    @State private var log: [String]?
    @State private var want = ServerWords.logsFirst
    @State private var logBusy = false

    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    if let logs = actions.first(where: { $0.actionId == "logs" }) { press(logs) }
                    else if let first = actions.first { press(first) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: card.kind == .site ? "globe" : "cube")
                            .foregroundStyle(.secondary).frame(width: 28, height: 28)
                            .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(card.name).font(.system(size: 13, weight: .semibold))
                            Text(card.detail.isEmpty ? "—" : card.detail)
                                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        HStack(spacing: 5) {
                            Circle().fill(card.running == true ? Color.green : card.running == false ? Color.red : Color.secondary).frame(width: 6, height: 6)
                            Text(ServerWords.runningWord(card.running)).foregroundStyle(.secondary)
                        }.frame(width: 100, alignment: .leading)
                    }.frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(.rect)
                }.buttonStyle(MACHINESRowStyle())
                HStack(spacing: 6) {
                    if hovered {
                        ForEach(actions.filter { ["logs", "restart"].contains($0.actionId) }) { action in
                            Button(action.label) { press(action) }.buttonStyle(.bordered).disabled(busy != nil)
                        }
                    }
                }.frame(minWidth: 100, alignment: .trailing)
                Menu {
                    actionMenu
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(.rect) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .help("Actions for \(card.name)").accessibilityLabel("Actions for \(card.name)")
            }
            if let said {
                Text(said.text).font(.callout).foregroundStyle(said.ok ? Color.secondary : Color.red)
                if let back = said.wayBack { Button(back.label) { run(back.actionId) } }
            }
            if let log {
                ScrollView {
                    Text(log.joined(separator: "\n")).font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 240)
                HStack {
                    if log.count >= want && want < ServerWords.logsMost {
                        Button("Show older") { fetchLog(min(want + ServerWords.logsMore, ServerWords.logsMost)) }.disabled(logBusy)
                    }
                    Button("Hide logs") { self.log = nil }
                }
            }
            if logBusy { ProgressView("Reading logs…").controlSize(.small) }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(hovered ? MACHINESTokens.selection : Color.clear)
        .onHover { hovered = $0 }
        .contextMenu { actionMenu }
        .alert("\(asking?.label ?? "Change") \(card.name)?", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            if let asking { Button(asking.label, role: asking.actionId == "remove" ? .destructive : nil) { run(asking.actionId) } }
            Button("Cancel", role: .cancel) { asking = nil }
        } message: {
            Text(asking?.sentence ?? "")
        }
    }

    @ViewBuilder private var actionMenu: some View {
        ForEach(actions) { action in
            if action.actionId == "open", let url = card.url.flatMap(URL.init(string:)) {
                Link(action.label, destination: url)
            } else {
                Button(action.label, role: action.actionId == "remove" ? .destructive : nil) { press(action) }.disabled(busy != nil)
            }
        }
        if actions.isEmpty { Text("No actions available") }
        ForEach(absent, id: \.actionId) { missing in Text(missing.because) }
    }

    private func press(_ action: ServerActionPreview) {
        switch action.actionId {
        case "copy-address":
            guard let url = card.url else {
                said = (false, "This build cannot reach the clipboard. Copy the address above by hand.", nil)
                return
            }
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setString(url, forType: .string) {
                run(action.actionId)
            } else {
                said = (false, "This computer would not let us use the clipboard. Copy the address above by hand.", nil)
            }
        case "logs":
            if log != nil { log = nil } else { fetchLog(ServerWords.logsFirst) }
        default:
            if action.klass == .safe { run(action.actionId) } else { asking = action }
        }
    }

    private func run(_ actionId: String) {
        asking = nil
        busy = actionId
        said = nil
        Task {
            let answer = await room.run(card.id, actionId)
            busy = nil
            said = (answer.ok, answer.ok ? answer.outcome.done : answer.sentence, answer.ok ? answer.outcome.wayBack : nil)
        }
    }

    private func fetchLog(_ lines: Int) {
        logBusy = true
        Task {
            do {
                let got = try await room.logs(card.id, lines)
                want = lines
                log = got
            } catch {
                log = ["We could not read this."]
            }
            logBusy = false
        }
    }
}

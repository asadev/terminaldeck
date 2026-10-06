import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// One server's own page (`ServerPage.tsx`): back, its name and where it is, a
/// terminal to open on it (in a folder of your choosing), how it is doing, the
/// coding agents on it, sessions on it (the host), what it keeps running —
/// grouped, each with its actions — and Advanced.
struct NativeServerPage: View {
    @Bindable var model: NativeServersModel
    let server: CodingAIServer
    @Binding var route: NativeServersRoute
    @State private var room: NativeServerRoom
    @State private var setup: NativeServerSetupModel

    init(model: NativeServersModel, server: CodingAIServer, route: Binding<NativeServersRoute>) {
        self.model = model
        self.server = server
        _route = route
        _room = State(initialValue: NativeServerRoom(serverId: server.id))
        _setup = State(initialValue: NativeServerSetupModel(serverId: server.id))
    }

    private static let order: [ServerCardInfo.Kind] = [.site, .app, .database, .other]

    var body: some View {
        let state = model.states[server.id]
        let link = state?.link ?? .connecting
        let view = state?.view
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Button("Back to machines") { route = .list }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name).font(.title3.weight(.semibold))
                        Text(server.whereLine).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if state?.identityChanged != true && link != .failed {
                    NativeServerOpenTerminal(server: server)
                }

                if let state, state.identityChanged {
                    NativeServerIdentityChanged(state: state) { route = .list }
                } else {
                    NativeServerHealth(state: state, now: model.now) { room.look() }
                    NativeServerSetupPanel(model: setup)
                    NativeServerHost(server: server, connected: link == .ready)

                    if link == .failed {
                        HStack(spacing: 8) {
                            NativeCodingAINotice(tone: .error, text: state?.problem ?? "We could not reach this server.")
                            Button("Try again") { room.look() }
                        }
                    }
                    if let view, view.cards.isEmpty {
                        NativeSettingsProse(text: ServerWords.nothingFound)
                    }
                    ForEach(Self.order, id: \.self) { kind in
                        let cards = (view?.cards ?? []).filter { $0.kind == kind }
                        if !cards.isEmpty {
                            NativeServerCardGroup(kind: kind, cards: cards, previews: state?.previews ?? [:],
                                                  absent: view?.absent ?? [:], room: room)
                        }
                    }
                    NativeServerAdvanced(
                        server: server, extra: model.extra(server.id), state: state, now: model.now,
                        onRename: { model.rename(server.id, to: $0) },
                        onForget: { model.forget(server.id, route: $route) },
                        onGrant: { room.grant($0) },
                        onRevoke: { room.revoke() },
                        onDrivesWindows: { model.setDrivesWindows(server.id, $0) })
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            room.report = { state in NativeServersModel.shared.remember(state) }
            room.look()
        }
        .onChange(of: link) { _, now in if now == .ready { setup.start() } }
        .onDisappear {
            setup.stop()
            room.close()
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

    init(serverId: String) { self.serverId = serverId }

    private func call(_ channel: String, _ args: [Any?] = []) async throws -> CodingAIJSON {
        CodingAIJSON(try await EngineBridge.shared.invoke(channel, args))
    }

    /// Look at the server: its view, the previews of every offered action, and the grant.
    func look() {
        alive = true
        let id = serverId
        report?(ServerRoomState(id: id, link: .connecting))
        Task {
            let work = Task { try await call("servers:look", [id]) }
            let timer = Task {
                try? await Task.sleep(for: .seconds(45))
                work.cancel()
            }
            let raw: CodingAIJSON
            do {
                raw = try await work.value
                timer.cancel()
            } catch {
                timer.cancel()
                guard alive else { return }
                report?(ServerRoomState(id: id, link: .failed, problem: work.isCancelled
                    ? CodingAIDeadline.overdue("reaching that server", seconds: 45)
                    : CodingAIErrorText.from(error, fallback: "We could not reach this server.")))
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

struct NativeServerOpenTerminal: View {
    let server: CodingAIServer
    @State private var folder: String?
    private let app = AppModel.shared

    var body: some View {
        if !app.canRun {
            NativeServerWhy(text: "This page is not inside a window that can hold one open.")
        } else {
            let openHere = app.sidebar?.projects.first(where: { $0.id == "server:\(server.id)" })?.sessions.count ?? 0
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button("Open a terminal") {
                        app.web.run(.openServerSession(serverId: server.id, serverName: server.name, startIn: folder))
                    }
                    .buttonStyle(.borderedProminent)
                    if openHere > 0 {
                        NativeServerWhy(text: openHere == 1 ? "One is already open on this one." : "\(openHere) are already open on this one.")
                    }
                }
                NativeServerFolderPicker(serverId: server.id, serverName: server.name, path: $folder)
                NativeServerWhy(text: "It opens like any other session: a row in the list on the left, under this server’s name, and a tab along the top. Whatever you type into it runs on this server, and nothing here checks it first.")
            }
        }
    }
}

// MARK: - How it is doing (`ServerHealth`)

struct NativeServerHealth: View {
    let state: ServerRoomState?
    let now: Double
    let onRefresh: () -> Void

    var body: some View {
        let link = state?.link ?? .connecting
        let view = state?.view
        let sentence = view.map { ServerWords.overall($0.cards) } ?? ServerWords.linkSentence(link)
        let numbers = ServerWords.readings(view?.facts)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(sentence).font(.title3)
                Spacer()
                if let view, view.measuredAt > 0 {
                    Text("as of \(ServerWords.asOf(view.measuredAt, now: now))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Check now", action: onRefresh)
                    .disabled(link == .connecting)
            }
            if !numbers.isEmpty {
                HStack(spacing: 24) {
                    ForEach(numbers) { reading in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reading.value).font(.headline)
                            Text(reading.label).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

// MARK: - A changed identity (`IdentityChanged`)

struct NativeServerIdentityChanged: View {
    let state: ServerRoomState
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This server answered with a different identity").font(.headline)
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

struct NativeServerCardGroup: View {
    let kind: ServerCardInfo.Kind
    let cards: [ServerCardInfo]
    let previews: [String: [ServerActionPreview]]
    let absent: [String: [ServerAbsentAction]]
    let room: NativeServerRoom
    @State private var open: Bool?

    var body: some View {
        let shut = kind == .other
        let isOpen = open ?? !shut
        let reasons = ServerWords.groupReasons(cards, absent: absent)
        VStack(alignment: .leading, spacing: 8) {
            if shut {
                Button(isOpen ? "Hide \(ServerWords.groupHeading(kind).lowercased())" : "\(ServerWords.groupHeading(kind)) (\(cards.count))") {
                    open = !isOpen
                }
            } else {
                Text(ServerWords.groupHeading(kind))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if isOpen {
                ForEach(reasons.shared, id: \.self) { because in
                    NativeServerWhy(text: because)
                }
                ForEach(cards) { card in
                    NativeServerCard(card: card, actions: previews[card.id] ?? [], absent: reasons.own[card.id] ?? [], room: room)
                }
            }
        }
    }
}

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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(card.name).font(.headline)
                Spacer()
                Text(ServerWords.runningWord(card.running))
                    .font(.callout)
                    .foregroundStyle(card.running == true ? Color.green : card.running == false ? Color.red : Color.secondary)
            }
            Text(card.detail.isEmpty ? ServerWords.noDetail : card.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let asking {
                VStack(alignment: .leading, spacing: 6) {
                    Text(asking.sentence).fixedSize(horizontal: false, vertical: true)
                    if let keeps = asking.keeps { NativeServerWhy(text: "We will keep \(keeps).") }
                    HStack {
                        Button(asking.label) { run(asking.actionId) }.buttonStyle(.borderedProminent)
                        Button("Cancel") { self.asking = nil }
                    }
                }
            } else if !actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(actions) { action in
                        if action.actionId == "open", let url = card.url.flatMap(URL.init(string:)) {
                            Link(action.label, destination: url)
                                .buttonStyle(.bordered)
                        } else {
                            Button(busy == action.actionId ? "Working…" : action.label) { press(action) }
                                .disabled(busy != nil)
                                .help(action.klass == .safe ? "" : action.sentence)
                        }
                    }
                }
            }

            ForEach(absent, id: \.actionId) { missing in
                NativeServerWhy(text: missing.because)
            }

            if let said {
                VStack(alignment: .leading, spacing: 6) {
                    Text(said.text)
                        .foregroundStyle(said.ok ? Color.primary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if let back = said.wayBack {
                        Button(back.label) { run(back.actionId) }
                    }
                }
            }

            if logBusy && log == nil { NativeServerWhy(text: "Reading…") }
            if let log {
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView {
                        Text(log.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                    HStack {
                        if log.count >= want && want < ServerWords.logsMost {
                            Button(logBusy ? "Reading…" : "Show older") {
                                fetchLog(min(want + ServerWords.logsMore, ServerWords.logsMost))
                            }
                            .disabled(logBusy)
                        }
                        Button("Hide") { self.log = nil }
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
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

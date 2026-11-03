import SwiftUI
import TerminalDeckNativeCore

struct NativeMACHINESServersDashboard: View {
    @Bindable var model: NativeServersModel
    @Binding var route: NativeServersRoute
    var live = true
    var fixtureProjects: [String: String] = [:]
    var onReview: ((String) -> Void)? = nil
    var onOpen: ((String) -> Void)? = nil
    @AppStorage("machines.servers.project") private var project = "all"
    @State private var links: [String: String] = [:]
    @State private var rooms: [String: NativeServerRoom] = [:]
    @State private var removing: CodingAIServer?
    @State private var showAdd = false

    static func filtered(_ servers: [CodingAIServer], project: String, links: [String: String]) -> [CodingAIServer] {
        project == "all" ? servers : servers.filter { (links[$0.id] ?? "independent") == project }
    }
    static func stopped(_ state: ServerRoomState?) -> Int {
        state?.view?.cards.filter { $0.running == false }.count ?? 0
    }
    private var projectLinks: [String: String] { live ? links : fixtureProjects }
    private var visible: [CodingAIServer] { Self.filtered(model.servers, project: project, links: projectLinks) }
    private var attention: [CodingAIServer] { visible.filter { Self.stopped(model.states[$0.id]) > 0 || model.states[$0.id]?.link == .failed } }

    var body: some View {
        MACHINESPage(title: "Servers", subtitle: "\(visible.count) servers" + (attention.isEmpty ? "" : " · \(attention.count) needs a look"), switcher: { EmptyView() }, actions: {
            projectPicker
            Button("Add a server", systemImage: "plus") { add() }.buttonStyle(.borderedProminent)
        }) {
            VStack(alignment: .leading, spacing: 12) {
                if SHELLRoutes.asked(SHELLRoutes.serverAddressAction) {
                    // Arrived from a phone's server address link (NativeWidgetNavigation); goes with the next place.
                    Label(SHELLRoutes.serverAddressLine, systemImage: "iphone")
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("servers.addressLinkNote")
                }
                if let problem = model.problem, model.servers.isEmpty {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    DeckRetryButton("Try Again", autoRetry: true) { model.reread() } // autoRetry: re-reads the servers dashboard
                } else if model.reading && model.servers.isEmpty {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(0..<2) { _ in MACHINESCard { skeleton }.accessibilityLabel("Checking server") }
                    }
                } else if model.servers.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "server.rack").font(.system(size: 34)).foregroundStyle(.tertiary)
                        Text("No servers yet").font(.headline)
                        Text("Pick a saved sign-in, or type an address.").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.top, 120)
                } else {
                    ForEach(attention) { server in
                        MACHINESCard {
                            HStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                Text(Self.stopped(model.states[server.id]) > 0
                                     ? "\(Self.stopped(model.states[server.id])) apps stopped on \(server.name)"
                                     : "\(server.name) is not answering").fontWeight(.semibold)
                                Spacer()
                                Button("Review") {
                                    if let onReview { onReview(server.id) } else { route = .server(server.id) }
                                }.buttonStyle(.bordered)
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.35), lineWidth: 1))
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(visible) { server in serverCard(server) }
                        Button(action: add) {
                            VStack(spacing: 8) {
                                Image(systemName: "plus").font(.system(size: 20)).foregroundStyle(.secondary)
                                Text("Add a server").fontWeight(.semibold)
                                Text("Pick a saved sign-in from your SSH settings, or type an address.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 174)
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(MACHINESTokens.hairline,
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        }.buttonStyle(MACHINESRowStyle())
                    }
                }
                if NativeServerControlRelease.enabled {
                    NativeServerControlLocalEntry { route = .thisMac }
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            MACHINESAddServerSheet(model: model, route: $route) { showAdd = false; route = .list }
        }
        .onAppear { if route == .add { showAdd = true } }
        .onChange(of: route) { _, next in if next != .list { showAdd = false } }
        .task { guard live else { return }; NativePROJLabels.shared.start(); model.start(); await readProjects(); checkNewServers() }
        .onChange(of: model.servers.map(\.id)) { _, _ in if live { checkNewServers() } }
        .onDisappear { rooms.values.forEach { $0.close() }; rooms = [:] }
        .alert("Remove \(removing?.name ?? "server")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) { if let server = removing { model.forget(server.id, route: $route) }; removing = nil }
        } message: { Text("This removes the saved connection from Terminal Deck.") }
    }

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 360), spacing: 12)] }
    /// The shared project picker (READY L1-CORE). nil = All projects; remembered per page.
    private var projectPicker: some View {
        ProjectPicker(projects: NativePROJLabels.shared.projects,
                      selection: Binding(get: { project == "all" ? nil : project }, set: { project = $0 ?? "all" }),
                      openProject: { AppModel.shared.openProject() })
    }

    private func serverCard(_ server: CodingAIServer) -> some View {
        let state = model.states[server.id]
        return Button {
            if let onOpen { onOpen(server.id) } else { route = .server(server.id) }
        } label: {
            MACHINESCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "server.rack").font(.system(size: 15)).foregroundStyle(.secondary)
                            .frame(width: 32, height: 32).background(MACHINESTokens.selection, in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name).font(.system(size: 13, weight: .semibold))
                            Text(server.atLine)
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        HStack(spacing: 5) {
                            Circle().fill(state?.link == .ready ? Color.green : state?.link == .failed ? .red : .secondary).frame(width: 6, height: 6)
                            Text(state?.link == .ready ? "Running" : state?.link == .failed ? "Not answering" : "Checking")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    if state?.link == .connecting || state == nil { metricSkeleton }
                    else { metrics(state) }
                    Divider()
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { chips(server, state) }
                        VStack(alignment: .leading, spacing: 6) { chips(server, state) }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
            }.contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(MACHINESRowStyle())
        .contextMenu {
            Button("Open terminal") { AppModel.shared.runButton(.openServerSession(serverId: server.id, serverName: server.name, startIn: nil)) }
            Button("Settings…") { MACHINESObjectWindows.openServer(model: model, server: server, route: $route) }
            Button("Check now") { rooms[server.id]?.look() }
            Divider()
            Button("Remove…", role: .destructive) { removing = server }
        }
    }

    @ViewBuilder private func chips(_ server: CodingAIServer, _ state: ServerRoomState?) -> some View {
        let id = projectLinks[server.id] ?? "independent"
        chip(PROJProjects.name(for: id), dot: projectColor(id))
        let cards = state?.view?.cards ?? []
        if state?.view != nil {
            chip("\(cards.filter { $0.running == true }.count) running" + (Self.stopped(state) == 0 ? "" : " · \(Self.stopped(state)) stopped"), symbol: "shippingbox")
        }
        if let agents = state?.view?.facts["agents"]?.value,
           let parsed = CodingAIAgentOnServer.parseList(agents), let agent = parsed.first {
            chip(CodingAICatalog.label(agent.id), dot: agent.signedIn == .yes ? .green : .secondary)
        }
    }
    private func chip(_ text: String, dot: Color? = nil, symbol: String? = nil) -> some View {
        HStack(spacing: 5) {
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            if let symbol { Image(systemName: symbol) }
            Text(text).lineLimit(1)
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 7).frame(height: 22)
            .background(MACHINESTokens.selection, in: RoundedRectangle(cornerRadius: 6))
    }
    /// The real numbers under each value: "Storage · 280 / 400 GB", "Load · 1.2 / 4 cores".
    static func caption(_ id: String, facts: ServerFacts?) -> String {
        switch id {
        case "disk", "memory":
            let label = id == "disk" ? "Storage" : "Memory"
            guard let amount = facts?[id]?.value, let used = amount["usedKb"].number, let total = amount["totalKb"].number, total > 0 else { return label }
            return label + " · " + gigabytes(used: used, total: total)
        case "load":
            guard let load = facts?["load"]?.value?.number, let cpus = facts?["cpus"]?.value?.number else { return "Load" }
            return "Load · " + load.formatted(.number.precision(.fractionLength(1))) + " / \(Int(cpus)) cores"
        default: return "Up"
        }
    }
    /// "7.2 of 16 GB"; small totals in MB.
    static func gigabytes(used: Double, total: Double) -> String {
        let gb = 1_048_576.0
        if total < gb { return "\(Int((used / 1024).rounded())) / \(Int((total / 1024).rounded())) MB" }
        func g(_ kb: Double) -> String { let v = kb / gb; return v >= 100 ? "\(Int(v.rounded()))" : v.formatted(.number.precision(.fractionLength(0...1))) }
        return g(used) + " / " + g(total) + " GB"
    }
    /// One line per metric value, as in the mockup: "70%", "Light", "167 d", from the
    /// measured facts like the server page's tiles (never re-read from their sentences).
    static func cardValue(_ id: String, facts: ServerFacts?) -> String {
        switch id {
        case "disk", "memory": return ServerWords.percent(id, facts)
        case "load": return ServerWords.workload(facts)
        default: return ServerWords.onFor(facts, compact: true)
        }
    }
    private func metrics(_ state: ServerRoomState?) -> some View {
        let facts = state?.view?.facts
        return HStack(spacing: 16) {
            ForEach(["disk", "memory", "load", "uptime"], id: \.self) { id in
                VStack(alignment: .leading, spacing: 5) {
                    Text(Self.cardValue(id, facts: facts))
                        .font(.system(size: 22, weight: .semibold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(Self.caption(id, facts: facts))
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.75)
                    if id != "uptime" {
                        GeometryReader { geometry in
                            let proportion = (id == "load" ? ServerWords.loadShare(facts) : ServerWords.share(id, facts)) ?? 0
                            Capsule().fill(MACHINESTokens.selection)
                                .overlay(alignment: .leading) { Capsule().fill(proportion >= 0.7 ? Color.orange : Color.secondary)
                                    .frame(width: geometry.size.width * min(max(proportion, 0), 1)) }
                        }.frame(height: 4)
                    } else { Color.clear.frame(height: 4) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private var metricSkeleton: some View {
        HStack(spacing: 16) {
            ForEach(0..<4) { _ in VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(MACHINESTokens.selection).frame(width: 46, height: 20)
                RoundedRectangle(cornerRadius: 3).fill(MACHINESTokens.selection).frame(height: 11)
                Capsule().fill(MACHINESTokens.selection).frame(height: 4)
            }.frame(maxWidth: .infinity) }
        }
    }
    private var skeleton: some View { VStack(spacing: 24) { metricSkeleton; metricSkeleton }.frame(height: 150) }
    private func projectColor(_ id: String) -> Color {
        // The project's own saved colour (no project id is built in).
        NativePROJLabels.shared.projects.first { $0.id == id }.map(DeckTokens.projectColour) ?? .secondary
    }
    private func add() { model.clearAddError(); showAdd = true }
    private func checkNewServers() {
        // U143 (#214): a removed server's room closes now, not when the page goes.
        let ids = Set(model.servers.map(\.id))
        for (id, room) in rooms where !ids.contains(id) { room.close(); rooms[id] = nil }
        for server in model.servers where rooms[server.id] == nil {
            let room = NativeServerRoom(serverId: server.id)
            room.report = { model.remember($0) }; rooms[server.id] = room; room.look()
        }
    }
    private func readProjects() async {
        guard let raw = try? await EngineBridge.shared.invoke("servers:list") else { return }
        links = Self.projectLinks(CodingAIJSON(raw))
    }
    /// Each server's project. A server listed twice (a damaged or hand-edited file) keeps its first row, never a crash.
    static func projectLinks(_ list: CodingAIJSON) -> [String: String] {
        Dictionary((list.array ?? []).compactMap { row in
            guard let id = row["id"].text else { return nil }
            return (id, row["projectId"].text ?? row["projectID"].text ?? "independent")
        }, uniquingKeysWith: { first, _ in first })
    }
}

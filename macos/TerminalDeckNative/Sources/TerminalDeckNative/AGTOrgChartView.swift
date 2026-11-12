import AppKit
import SwiftUI
import Observation
import UniformTypeIdentifiers
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Content only: AGFRAME owns the page header, project picker and view switch.
/// The layout is pure; profile writes keep using the existing narrowed save path.
struct AGTOrgChartView: View {
    var projectID: String? = nil
    @State private var zoom: CGFloat = 1
    @State private var pan = CGSize.zero
    @State private var pinchBase: CGFloat = 1
    @State private var selectedID: String?
    @State private var draggingID: String?
    @State private var dragPoint = CGPoint.zero
    @State private var targetID: String?
    @State private var clearing = false
    @State private var spaceDown = false
    @State private var dropModel = ORGManagerDropModel()
    /// The person has moved or zoomed the board: stop fitting it by itself (until Fit is pressed again).
    @State private var touched = false
    @State private var dragGeneration = 0
    @State private var findPresented = false
    @FocusState private var findFocused: Bool
    private var store: AGTAgentsStore { .shared }
    private var savingID: String? { dropModel.busyID }
    private var changing: Bool { savingID != nil || store.busy || TasksStore.shared.busy }

    private var agents: [AGTAgent] {
        // Hoot → leads → agents: a lead that is not running, and a vacant seat that still holds
        // memory, show as quiet rows (the seat is what keeps the memory, not the hire).
        var rows = AGTLeads.orgAgents(store.agents).filter { agent in
            agent.status != "archived" &&
                !agent.isHoot && (projectID == nil || project(for: agent) == projectID)
        }
        let scopedIDs = Set(rows.compactMap(\.profileID))
        let delegated = AGTTeamChatHistory.shared.rows.contains {
            $0["job"]["fromID"].string == "hoot" && scopedIDs.contains($0["job"]["agentID"].string ?? "")
        }
        let reports = rows.contains { AGTLeads.manager(of: $0, in: rows) == AGTDirectory.hootID }
        if (reports || delegated), let hoot = store.agents.first(where: \.isHoot) { rows.insert(hoot, at: 0) }
        for agent in rows where agent.kind == .profile {
            // A session already on the chart (one that works as the lead hangs under it) is not drawn twice.
            for var hand in AGTLeads.handRows(for: agent) where !rows.contains(where: { $0.id == hand.id || ($0.kind == .session && !AGTLeads.isHand($0) && $0.sessionID != nil && $0.sessionID == hand.sessionID) }) {
                hand.reportsTo = agent.id
                rows.append(hand)
            }
        }
        return rows
    }

    private var searching: Bool { !store.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var matches: Set<String> { Set(store.visible.map(\.id)) }

    private func project(for agent: AGTAgent) -> String {
        PROJProjects.resolve(projectID: agent.projectID,
                             folder: agent.project, projects: NativePROJLabels.shared.projects)
    }

    private func layout(_ agents: [AGTAgent]) -> AGTOrgLayout.Result {
        AGTOrgLayout.layout(nodes: agents.map {
            .init(id: $0.id, parentID: AGTLeads.manager(of: $0, in: agents), projectID: $0.isHoot ? nil : project(for: $0))
        }, projectOrder: NativePROJLabels.shared.projects.map(\.id), showProjectRegions: projectID == nil)
    }

    var body: some View {
        GeometryReader { geometry in
            let rows = agents
            let tree = layout(rows)
            let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            ZStack(alignment: .topLeading) {
                chart(tree, byID: byID)
                    .frame(width: tree.canvasSize.width, height: tree.canvasSize.height, alignment: .topLeading)
                    .scaleEffect(zoom, anchor: .topLeading)
                    .offset(pan)
                if let id = draggingID, let agent = byID[id] {
                    ghost(agent: agent, byID: byID).position(dragPoint).allowsHitTesting(false)
                }
                VStack {
                    Spacer(minLength: 0)
                    HStack(alignment: .bottom, spacing: 12) {
                        independent(tree.independentIDs.compactMap { byID[$0] }, tree: tree, viewport: geometry.size)
                        zoomControl(tree, viewport: geometry.size)
                    }.padding(16)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
            .coordinateSpace(name: "ORGViewport")
            .background {
                ORGCanvasInput(space: { spaceDown = $0; if $0 { cancelDrag() } },
                    move: { delta in touched = true; pan.width += delta.width; pan.height += delta.height },
                    command: { key in
                        switch key {
                        case "+", "=": setZoom(zoom + 0.1, in: geometry.size)
                        case "-": setZoom(zoom - 0.1, in: geometry.size)
                        case "0": fit(tree, in: geometry.size); touched = false
                        case "1": setZoom(1, in: geometry.size)
                        default: break
                        }
                    })
            }
            .simultaneousGesture(MagnificationGesture().onChanged { value in
                setZoom(pinchBase * value, in: geometry.size, updatePinchBase: false)
            }.onEnded { _ in pinchBase = zoom })
            .onAppear { if !touched { fit(tree, in: geometry.size) } }
            .onChange(of: geometry.size) { _, size in if !touched { fit(tree, in: size) } }
            .onChange(of: tree.canvasSize) { _, _ in if !touched { fit(tree, in: geometry.size) } }
            .background(ORGStyle.page)
            .onAppear { if store.fixture == nil { AGTSeatsStore.shared.start(); AGTHandsStore.shared.start() } }
            .onReceive(NotificationCenter.default.publisher(for: .init("AGFRAME.focusSearch"))) { note in
                if note.object as? String == "org" { findPresented = true }
            }
            .popover(isPresented: $findPresented, arrowEdge: .top) { findPanel }
            .accessibilityLabel("Organisation chart. Drag a card onto its manager, or onto Independent to clear. Hold Space and drag to pan.")
        }
    }

    private var findPanel: some View {
        @Bindable var bound = AGTAgentsStore.shared
        return VStack(alignment: .leading, spacing: 12) {
            NativeSessionTextField("Find an agent, role or model", text: $bound.search)
                .textFieldStyle(.roundedBorder).sessionFocused($findFocused)
            HStack {
                let count = agents.filter { matches.contains($0.id) }.count
                Text(searching ? "\(count) \(count == 1 ? "match" : "matches")" : "The whole team stays on the chart.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if searching { NativeSessionButton("Clear") { store.search = "" }.buttonStyle(.borderless) }
                NativeSessionButton("Done") { findPresented = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 340)
        .onAppear { findFocused = true }
        .sessionOnExitCommand { findPresented = false }
    }

    private func chart(_ tree: AGTOrgLayout.Result, byID: [String: AGTAgent]) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(tree.projectRegions, id: \.id) { region in
                projectRegion(region).frame(width: region.frame.width, height: region.frame.height)
                    .position(x: region.frame.midX, y: region.frame.midY)   // only its "Lead:" menu takes clicks
            }
            Canvas { context, _ in
                for connector in tree.connectors {
                    context.stroke(roundedLine(connector.points), with: .color(ORGStyle.tertiary), lineWidth: 1.4)
                }
            }.accessibilityHidden(true).allowsHitTesting(false)
            ForEach(byID.values.filter { tree.frames[$0.id] != nil }.sorted { $0.id < $1.id }) { agent in
                if let frame = tree.frames[agent.id] {
                    node(agent, width: frame.width)
                        .opacity(draggingID == agent.id ? 0.25 : 1)
                        .modifier(AGTDragDrop(agent: agent, enabled: !spaceDown && !changing,
                                              targeted: targetID == agent.id, valid: validTarget(agent.id),
                                              changed: { value in updateDrag(agent, value: value, tree: tree) },
                                              ended: { value in finishDrag(agent, value: value, tree: tree) },
                                              take: { id in acceptDrop(id, manager: agent.id) }))
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
    }

    private func projectRegion(_ region: AGTOrgLayout.ProjectRegion) -> some View {
        let id = region.projectID ?? "independent"
        return RoundedRectangle(cornerRadius: 18).fill(Color.primary.opacity(0.035))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(ORGStyle.tertiary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .allowsHitTesting(false)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    ProjectLogoView(project: NativePROJLabels.shared.projects.first { $0.id == id },
                                    name: NativePROJLabels.shared.name(for: id), size: 14)
                    Text(NativePROJLabels.shared.name(for: id)).font(.system(size: 12, weight: .semibold))
                    if let project = NativePROJLabels.shared.projects.first(where: { $0.id == id }), id != PROJProjects.independentID {
                        leadMenu(project)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 3).background(ORGStyle.page, in: Capsule())
                .padding(.leading, 14).offset(y: -10)
            }
    }

    private func open(_ agent: AGTAgent) {
        if agent.isHoot { HootProfileRoute.open(); return }
        if let seat = AGTLeads.vacantSeat(agent) { hire(into: seat); return }
        if AGTLeads.isHand(agent) { store.openSession(agent); return }
        store.openProfile = agent.id
    }
    /// Hiring into a seat: the New agent page opens with the project and the role already chosen.
    private func hire(into seat: AGTSeat) {
        AGTLeads.pendingHire = seat
        store.openProfile = "new"
    }
    /// A vacant seat that still holds memory: hire someone new into it, or seat an existing agent.
    @ViewBuilder private func vacantMenu(_ seat: AGTSeat) -> some View {
        NativeSessionButton { hire(into: seat) } label: { Label("Hire a new agent into this seat…", systemImage: "person.badge.plus") }
        let members = store.agents.filter { $0.kind == .profile && $0.status != "archived" && (seat.projectID == nil || project(for: $0) == seat.projectID) }
        Menu("Put an existing agent in this seat") {
            ForEach(members) { agent in
                NativeSessionButton {
                    Task {
                        if case .lead(let id) = seat, let project = NativePROJLabels.shared.projects.first(where: { $0.id == id }) { await AGTLeads.setLead(agent, of: project) }
                        else if let role = seat.role { await AGTLeads.setRole(role, title: nil, for: agent) }
                    }
                } label: { DeckRowLabel(agent.name, image: DeckRowIcon.agent(agent)) }
            }
            if members.isEmpty { Text("No saved agents here yet") }
        }
        .disabled(changing)
        Divider()
        NativeSessionButton {
            Task {
                let root = await DeckMemory.store.location().root
                NSWorkspace.shared.open(root.appendingPathComponent(seat.owner.folder))
            }
        } label: { Label("Show its memory folder", systemImage: "folder") }
    }

    /// The project's lead, chosen at the project: any of its agents or running sessions, or no lead.
    private func leadMenu(_ project: PROJProject) -> some View {
        let current = AGTSeats.lead(of: project)
        let members = store.scopedAgents(projectID: project.id)
        return Menu {
            ForEach(members) { agent in
                Toggle(isOn: Binding(get: { AGTLeads.madeLead(agent)?.id == project.id },
                                     set: { _ in Task { await AGTLeads.setLead(agent, of: project) } })) {
                    DeckRowLabel(agent.name, image: DeckRowIcon.agent(agent))
                }
            }
            if members.isEmpty { Text("No agents or sessions in \(project.name) yet") }
            Divider()
            Toggle(isOn: Binding(get: { current == nil }, set: { _ in Task { await AGTLeads.setLead(nil, of: project) } })) {
                DeckRowLabel("No lead (Hoot assigns directly)", image: DeckRowIcon.hoot)
            }
        } label: {
            Text(current.map { "Lead: " + $0.name } ?? "No lead").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(changing)
        .help("Choose who leads \(project.name). Hoot gives the lead goals; with no lead Hoot assigns agents directly.")
        .accessibilityLabel("Lead of \(project.name)")
    }

    private func node(_ agent: AGTAgent, width: CGFloat = 172, mini: Bool = false) -> some View {
        let highlighted = selectedID == agent.id || targetID == agent.id
        let ring = highlighted ? Color.accentColor : agent.isHoot ? ORGStyle.hoot.opacity(0.5) : ORGStyle.hairline
        return HStack(spacing: mini ? 7 : 9) {
            if AGTLeads.isHand(agent) {
                AGTHandCard(hand: agent).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ORGAvatar(agent: agent, size: mini ? 22 : 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(agent.name).font(.system(size: mini ? 12 : 12.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        if !mini, !agent.isHoot { AGTHandsBadge(agent: agent) }
                    }
                    if !mini { ORGStatus(agent: agent) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if savingID == agent.id { ProgressView().controlSize(.mini).accessibilityLabel("Saving manager") }
            }
        }
        .padding(.horizontal, mini ? 9 : 10)
        .frame(width: width, height: mini ? 44 : 56)
        .background(ORGStyle.card, in: RoundedRectangle(cornerRadius: mini ? 10 : 12))
        .overlay(RoundedRectangle(cornerRadius: mini ? 10 : 12).strokeBorder(ring, lineWidth: highlighted ? 2 : 1))
        .overlay(RoundedRectangle(cornerRadius: mini ? 10 : 12).strokeBorder(Color.accentColor.opacity(validTarget(agent.id) ? 0.22 : 0), lineWidth: 3).padding(-3))
        .shadow(color: Color.black.opacity(0.035), radius: 2, y: 1)
        .opacity(searching && !agent.isHoot && !matches.contains(agent.id) ? 0.35 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            if AGTLeads.isVacant(agent) {
                RoundedRectangle(cornerRadius: mini ? 10 : 12).strokeBorder(ORGStyle.tertiary.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .onTapGesture(count: 2) { cancelDrag(); open(agent) }
        .onTapGesture { selectedID = agent.id }
        .contextMenu {
            if let seat = AGTLeads.vacantSeat(agent) { vacantMenu(seat) }
            else if AGTLeads.isHand(agent) { NativeSessionButton("Open its session") { store.openSession(agent) } }
            else { ORGAgentMenu(agent: agent) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.name), \(agent.statusLabel), \(NativePROJLabels.shared.name(for: project(for: agent)))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: AGTLeads.isVacant(agent) ? "Hire into this seat" : AGTLeads.isHand(agent) ? "Open its session" : "Open profile") { open(agent) }
        .help(AGTLeads.isVacant(agent)
              ? "\(agent.name): nobody is in this seat. Its memory is kept. Double-click to hire into it."
              : AGTLeads.isHand(agent) ? "\(agent.name): \(agent.activity). Double-click to open its session."
              : "\(agent.name) · \(NativePROJLabels.shared.name(for: project(for: agent))). Double-click to open the profile.")
    }

    private func independent(_ rows: [AGTAgent], tree: AGTOrgLayout.Result, viewport: CGSize) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Independent · \(rows.count)").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(clearing ? "Release to clear" : "Drop here to clear").font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(width: 122, alignment: .leading)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(rows) { agent in
                        node(agent, width: max(100, min(172, CGFloat(agent.name.count) * 6.8 + 54)), mini: true)
                            .opacity(draggingID == agent.id ? 0.25 : 1)
                            .modifier(AGTDragDrop(agent: agent, enabled: !spaceDown && !changing, targeted: false, valid: false,
                                                 changed: { value in updateDrag(agent, value: value, tree: tree) },
                                                 ended: { value in finishDrag(agent, value: value, tree: tree) }, take: { _ in false }))
                    }
                }.padding(3)
            }.scrollIndicators(.hidden).frame(minWidth: 0, maxWidth: .infinity)
        }
        .padding(12).frame(height: 62)
        // Solid bar, no glass: in a real window the frost composited over the chips and labels (10 Oct walk).
        .background { ORGBar() }
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.accentColor.opacity(clearing ? 1 : 0), lineWidth: 2))
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first else { return false }; return acceptDrop(id, manager: nil)
        } isTargeted: { clearing = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("ORGViewport")) } action: { shelfFrame = $0 }
        .accessibilityElement(children: .contain).accessibilityLabel("Independent. Drop here to clear the manager.")
    }

    @State private var shelfFrame = CGRect.zero

    private func zoomControl(_ tree: AGTOrgLayout.Result, viewport: CGSize) -> some View {
        HStack(spacing: 4) {
            NativeSessionButton { setZoom(zoom - 0.1, in: viewport) } label: { Image(systemName: "minus").frame(width: 28, height: 28).contentShape(Rectangle()) }.help("Zoom out (Command minus)")
                .disabled(zoom <= 0.25)
            NativeSessionButton { setZoom(1, in: viewport) } label: {
                Text("\(Int((zoom * 100).rounded()))%").monospacedDigit().frame(width: 44, height: 28).contentShape(Rectangle())
            }.help("Actual size (Command 1)")
            NativeSessionButton { setZoom(zoom + 0.1, in: viewport) } label: { Image(systemName: "plus").frame(width: 28, height: 28).contentShape(Rectangle()) }.help("Zoom in (Command plus)")
                .disabled(zoom >= 2)
            Divider().frame(height: 20).padding(.horizontal, 4)
            NativeSessionButton { fit(tree, in: viewport); touched = false } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 28, height: 28).contentShape(Rectangle()) }.help("Fit (Command 0)")
        }
        .font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(.primary)
        .padding(12).frame(width: 192, height: 62)
        .background { ORGBar() }
        .accessibilityElement(children: .contain).accessibilityLabel("Canvas zoom")
    }

    private func ghost(agent: AGTAgent, byID: [String: AGTAgent]) -> some View {
        node(agent).rotationEffect(.degrees(-2)).shadow(color: Color.black.opacity(0.18), radius: 12, y: 8)
        .overlay(alignment: .bottom) {
            Group {
            if let boss = targetID.flatMap({ byID[$0] }) {
                Label("\(agent.name) will report to \(boss.name)", systemImage: "arrow.right")
                    .font(.system(size: 12)).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.accentColor, in: Capsule()).fixedSize()
            } else if clearing {
                Text("\(agent.name) will be independent").font(.system(size: 12)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6).background(Color.accentColor, in: Capsule()).fixedSize()
            }
            }.offset(y: 38)
        }
    }

    private func validTarget(_ id: String) -> Bool {
        guard let draggingID, id != draggingID else { return false }
        return AGTOrgChart.refusal(id: draggingID, reportsTo: id, managers: store.managers) == nil
    }

    private func updateDrag(_ agent: AGTAgent, value: DragGesture.Value, tree: AGTOrgLayout.Result) {
        guard !spaceDown, agent.kind == .profile, !changing else { return }
        dragGeneration += 1
        draggingID = agent.id; selectedID = agent.id; dragPoint = value.location
        let target = AGTOrgDrop.resolve(point: dragPoint, scale: zoom, pan: pan, frames: tree.frames, shelf: shelfFrame)
        clearing = target == .independent
        if case .manager(let id) = target, validTarget(id) { targetID = id } else { targetID = nil }
    }

    private func finishDrag(_ agent: AGTAgent, value: DragGesture.Value, tree: AGTOrgLayout.Result) {
        guard draggingID == agent.id else { return }
        guard !spaceDown, !changing else { cancelDrag(); return }
        let target = AGTOrgDrop.resolve(point: value.location, scale: zoom, pan: pan, frames: tree.frames, shelf: shelfFrame)
        let candidate: String?
        if case .manager(let id) = target { candidate = id } else { candidate = nil }
        let shouldClear = target == .independent
        if shouldClear { _ = acceptDrop(agent.id, manager: nil) }
        else if let candidate {
            if !acceptDrop(agent.id, manager: candidate) { withAnimation(.spring(duration: 0.2)) { dragPoint = value.startLocation } }
        }
        if candidate != nil && !shouldClear && savingID == nil {
            let generation = dragGeneration
            Task {
                try? await Task.sleep(for: .milliseconds(220))
                if generation == dragGeneration { cancelDrag() }
            }
        } else { cancelDrag() }
    }

    @discardableResult private func acceptDrop(_ id: String, manager: String?) -> Bool {
        guard !changing else { return false }
        return dropModel.accept(id: id, manager: manager)
    }

    private func cancelDrag() { draggingID = nil; targetID = nil; clearing = false }

    private func setZoom(_ value: CGFloat, in size: CGSize, updatePinchBase: Bool = true) {
        touched = true
        let next = AGTOrgViewport.clampedScale(value)
        let anchor = CGPoint(x: size.width / 2, y: max(0, size.height - 94) / 2)
        let result = AGTOrgViewport.zoom(scale: zoom, offset: CGPoint(x: pan.width, y: pan.height), to: next, anchor: anchor)
        pan = CGSize(width: result.offset.x, height: result.offset.y)
        zoom = result.scale
        if updatePinchBase { pinchBase = next }
    }

    /// The whole chart, centred above the bottom bars, its top card fully visible (AGTOrgViewport.fitAboveBars).
    private func fit(_ tree: AGTOrgLayout.Result, in size: CGSize) {
        guard let fitted = AGTOrgViewport.fitAboveBars(canvasSize: tree.canvasSize, viewportSize: size, bottomInset: Self.barsHeight) else { return }
        zoom = fitted.scale
        pinchBase = zoom
        pan = CGSize(width: fitted.offset.x, height: fitted.offset.y)
    }
    /// The Independent strip and the zoom bar (62 tall, 16 padding): they stay put while the board moves.
    static let barsHeight: CGFloat = 94

    private func roundedLine(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for index in 1..<points.count {
            guard index < points.count - 1 else { path.addLine(to: points[index]); continue }
            let before = points[index - 1], corner = points[index], after = points[index + 1]
            let incoming = hypot(corner.x - before.x, corner.y - before.y)
            let outgoing = hypot(after.x - corner.x, after.y - corner.y)
            guard incoming > 0, outgoing > 0 else { path.addLine(to: corner); continue }
            let radius = min(8, min(incoming / 2, outgoing / 2))
            let a = CGPoint(x: corner.x + (before.x - corner.x) * radius / incoming, y: corner.y + (before.y - corner.y) * radius / incoming)
            let b = CGPoint(x: corner.x + (after.x - corner.x) * radius / outgoing, y: corner.y + (after.y - corner.y) * radius / outgoing)
            path.addLine(to: a); path.addQuadCurve(to: b, control: corner)
        }
        return path
    }
}

/// The exact save handler used by the canvas. Tests inject memory-only closures;
/// production keeps the existing profile save, validation and error messages.
@MainActor @Observable
final class ORGManagerDropModel {
    private(set) var busyID: String?
    private(set) var message: String?
    @ObservationIgnored private let kind: (String) -> AGTKind?
    @ObservationIgnored private let managers: () -> [String: String?]
    @ObservationIgnored private let names: () -> [String: String]
    @ObservationIgnored private let save: (String, String?) async -> Bool
    @ObservationIgnored private let failure: () -> String?
    @ObservationIgnored private let publish: (String?) -> Void
    @ObservationIgnored private var inFlight: Task<Bool, Never>?

    init(kind: @escaping (String) -> AGTKind? = { AGTAgentsStore.shared.agent($0)?.kind },
         managers: @escaping () -> [String: String?] = { AGTAgentsStore.shared.managers },
         names: @escaping () -> [String: String] = {
             Dictionary(AGTAgentsStore.shared.agents.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
         },
         save: @escaping (String, String?) async -> Bool = { id, manager in
             guard !AGTAgentsStore.shared.busy, !TasksStore.shared.busy else { return false }
             return await AGTAgentsStore.shared.setReportsTo(id, manager)
         },
         failure: @escaping () -> String? = { AGTAgentsStore.shared.message },
         publish: @escaping (String?) -> Void = { AGTAgentsStore.shared.message = $0 }) {
        self.kind = kind; self.managers = managers; self.names = names
        self.save = save; self.failure = failure; self.publish = publish
    }

    @discardableResult func accept(id: String, manager: String?) -> Bool {
        guard busyID == nil else { return false }
        guard kind(id) == .profile else {
            report("Only saved agents can have a place in the chart. Open it and choose Save as an agent.")
            return false
        }
        let current = managers()
        if let refusal = AGTOrgChart.refusal(id: id, reportsTo: manager, managers: current, names: names()) {
            let isLoop = manager != id && manager.map { current.keys.contains($0) } == true
            report(isLoop ? "That would make a loop — \(refusal)" : refusal)
            return false
        }
        busyID = id; report(nil)
        inFlight = Task {
            let saved = await save(id, manager)
            busyID = nil
            report(saved ? nil : failure() ?? "That did not save.")
            return saved
        }
        return true
    }

    /// Await the actual handler's result in tests, without events or an app launch.
    func waitForSave() async -> Bool { await inFlight?.value ?? false }
    private func report(_ text: String?) { message = text; publish(text) }
}

/// Internal canvas dragging plus the standard string drop seam used by AGT.
private struct AGTDragDrop: ViewModifier {
    let agent: AGTAgent
    let enabled: Bool
    let targeted: Bool
    let valid: Bool
    let changed: (DragGesture.Value) -> Void
    let ended: (DragGesture.Value) -> Void
    let take: (String) -> Bool
    func body(content: Content) -> some View {
        content.gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("ORGViewport"))
            .onChanged { if enabled && agent.kind == .profile { changed($0) } }
            .onEnded { if agent.kind == .profile { ended($0) } })
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.first, enabled else { return false }; return take(id)
            }
    }
}

// Shared shell and agent kit adapters.
private typealias ORGAvatar = AgentAvatar
private typealias ORGStatus = ORGSharedStatus
private typealias ORGAgentMenu = AgentMenu
private typealias ORGPalette = DeckTokens
@MainActor private enum ORGStyle {
    static let page = ORGPalette.page
    static let card = ORGPalette.card
    static let tertiary = ORGPalette.textTertiary
    static let hairline = ORGPalette.hairline
    static let hoot = DeckTokens.hoot
}

private struct ORGSharedStatus: View {
    let agent: AGTAgent
    var body: some View {
        StatusLabel(state, text: text, fontSize: 11)
    }
    /// Hoot leads all; a lead says so; a vacant seat and a lead that is not running say that instead of a status.
    private var text: String {
        if agent.isHoot { return "\(agent.statusLabel) · leads all" }
        if AGTLeads.isVacant(agent) { return "Vacant, has memory" }
        let status = agent.id.hasPrefix(AGTLeads.placeholderPrefix) ? "Not running" : agent.statusLabel
        return AGTLeads.isLead(agent) ? status + " · lead" : status
    }
    private var state: StatusLabel.State {
        if agent.live == .working { return .working }
        if agent.live == .waiting { return .waiting }
        if agent.status == "paused" { return .paused }
        if agent.status == "failed" { return .failed }
        return agent.isHoot ? .idle : .ready
    }
}

/// The shelf and zoom bars: a solid card with a hairline and a soft lift, legible in light and dark.
private struct ORGBar: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(DeckTokens.card)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(DeckTokens.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
    }
}

/// Listen only inside this chart's window. Cards retain their own clicks and drag handlers.
struct ORGCanvasInput: NSViewRepresentable {
    @Environment(\.nativeScreenActive) private var active
    let space: (Bool) -> Void
    let move: (CGSize) -> Void
    let command: (String) -> Void

    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) {
        view.space = space; view.move = move; view.command = command
        view.active = active
    }
    static func dismantleNSView(_ view: InputView, coordinator: ()) { view.stop() }

    final class InputView: NSView {
        var space: (Bool) -> Void = { _ in }
        var move: (CGSize) -> Void = { _ in }
        var command: (String) -> Void = { _ in }
        var active = true { didSet { if !active { releaseSpace() } } }
        private var held = false
        private var dragLocation: CGPoint?
        override var isFlipped: Bool { true }
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .scrollWheel]) { [weak self] event in
                guard let self else { return event }
                return self.filter(event)
            }
        }
        func filter(_ event: NSEvent) -> NSEvent? {
            guard active, let window, event.window === window, window.isKeyWindow,
              window.attachedSheet == nil, !isHiddenOrHasHiddenAncestor else { releaseSpace(); return event }
            if event.type == .keyDown || event.type == .keyUp {
                guard !NativeKeyboardFocus.isTyping(window.firstResponder) else { releaseSpace(); return event }
                return handleKey(event) ? nil : event
            }
            let point = convert(event.locationInWindow, from: nil)
            if event.type == .leftMouseUp { dragLocation = nil; return event }
            guard bounds.contains(point) else { return event }
            if event.type == .leftMouseDown {
                dragLocation = point
                return held ? nil : event
            }
            if event.type == .scrollWheel {
                move(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)); return nil
            }
            if held, let previous = dragLocation {
                move(CGSize(width: point.x - previous.x, height: point.y - previous.y))
                dragLocation = point
                return nil
            }
            return event
        }
        private func releaseSpace() {
            if held { held = false; space(false) }
            dragLocation = nil
        }
        func handleKey(_ event: NSEvent) -> Bool {
            if event.keyCode == 49 {
                held = event.type == .keyDown; space(held); return true
            }
            guard event.type == .keyDown, event.modifierFlags.contains(.command),
                  let key = event.charactersIgnoringModifiers, ["+", "=", "-", "0", "1"].contains(key) else { return false }
            command(key); return true
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            releaseSpace()
        }
    }
}

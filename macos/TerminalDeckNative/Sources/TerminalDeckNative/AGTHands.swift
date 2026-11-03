import SwiftUI
import Observation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Deck Memory on the Agents side (MEMORY-SPEC §3b): several hands on one seat, seen in the app.
/// The numbers come from the one registry (`BackendAGTHands`); the result state of each hand
/// (attempted / reported / verified) from M1's board. Event-driven: no timer.
@MainActor @Observable final class AGTHandsStore {
    static let shared = AGTHandsStore()
    private(set) var hands: [BackendAGTHands.Hand] = []
    /// Session id → the board's result state for that hand's job.
    private(set) var results: [String: DeckMemoryResultState] = [:]
    /// The agent whose "Add a hand…" sheet is open.
    var adding: AGTAgent?
    /// Set by offscreen fixtures instead of reading the registry.
    var fixture: [BackendAGTHands.Hand]?
    var fixtureResults: [String: DeckMemoryResultState] = [:]
    @ObservationIgnored private var watching: Task<Void, Never>?
    @ObservationIgnored private var board: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored var readBoard: @MainActor (String) async throws -> [DeckMemoryBoardRow] = { try await DeckMemory.store.board(.init(session: $0)) }
    init(hands: [BackendAGTHands.Hand] = []) { self.hands = hands }

    private var rows: [BackendAGTHands.Hand] { fixture ?? hands }
    func hands(on seat: DeckMemoryOwner) -> [BackendAGTHands.Hand] { rows.filter { $0.seat == seat }.sorted { $0.number < $1.number } }
    /// Helper seats under a role seat, with their hands.
    func helpers(under seat: DeckMemoryOwner) -> [BackendAGTHands.Hand] {
        rows.filter { BackendAGTHelperSeats.parent(of: $0.seat) == seat }.sorted { ($0.seat.key, $0.number) < ($1.seat.key, $1.number) }
    }
    func hand(session: String?) -> BackendAGTHands.Hand? { session.flatMap { id in rows.first { $0.sessionID == id } } }
    /// Session id → the key of the seat the app put that session in (its hand), for the agents list.
    var sessionSeats: [String: String] {
        Dictionary(rows.map { ($0.sessionID, AGTSeat(owner: $0.seat)?.key ?? "") }.filter { !$0.1.isEmpty }, uniquingKeysWith: { first, _ in first })
    }
    func result(session: String) -> DeckMemoryResultState? { fixture == nil ? results[session] : fixtureResults[session] }

    func start() {
        guard fixture == nil, watching == nil else { return }
        watching = Task { [weak self] in
            await self?.refresh()
            for await _ in BackendAGTHands.shared.changes() { await self?.refresh() }
        }
        board = Task { [weak self] in
            let memory = await DeckMemory.ready()
            for await change in memory.changes() where change.area == .board { await self?.refreshResults() }
        }
    }
    func refresh() async {
        guard fixture == nil else { return }
        hands = await BackendAGTHands.shared.all()
        await refreshResults()
    }
    func refreshResults() async {
        generation += 1
        let current = generation
        var next: [String: DeckMemoryResultState] = [:]
        for hand in hands {
            guard let rows = try? await readBoard(hand.sessionID) else { continue }
            if let state = rows.compactMap(\.state).max() { next[hand.sessionID] = state }
        }
        guard current == generation else { return }
        results = next
    }
}

extension AGTLeads {
    /// Short-lived helper seats under an agent. Its own sessions stay on its one card and page;
    /// they never become extra agent nodes, even when several fill the seat.
    static func handRows(for agent: AGTAgent) -> [AGTAgent] {
        guard agent.kind == .profile, seat(agent) != nil, let role = roleSeat(agent)?.owner else { return [] }
        let store = AGTHandsStore.shared
        let helpers = store.helpers(under: role)
        let live = AGTAgentsStore.shared.live
        let project = project(agent)
        func row(_ hand: BackendAGTHands.Hand) -> AGTAgent {
            let watch = live.first { $0.sessionID == hand.sessionID }
            return AGTDirectory.handRow(sessionID: hand.sessionID, number: hand.number, job: hand.job.isEmpty ? (watch?.taskTitle ?? watch?.action ?? "") : hand.job,
                                        helper: true, state: watch?.state, project: project, liveID: watch?.id)
        }
        return helpers.map(row)
    }
    static func isHand(_ agent: AGTAgent) -> Bool { agent.id.hasPrefix(AGTDirectory.handPrefix) }
    /// "×3" beside a seat with several hands.
    static func handCount(_ agent: AGTAgent) -> Int {
        guard agent.kind == .profile, !isVacant(agent), let seat = seat(agent)?.owner else { return 0 }
        return AGTHandsStore.shared.hands(on: seat).count
    }
}

/// "×3" on a seat that several hands fill.
struct AGTHandsBadge: View {
    let agent: AGTAgent
    var body: some View {
        let count = AGTLeads.handCount(agent)
        if count > 1 {
            Text("×\(count)").font(.system(size: 10, weight: .bold)).monospacedDigit()
                .padding(.horizontal, 5).frame(height: 18)
                .background(Color.primary.opacity(0.08), in: Capsule())
                .help("\(count) hands are working in this seat at once. They share its memory; each has its own job.")
                .accessibilityLabel("\(count) hands")
        }
    }
}

/// One hand under its seat: number, job in one line, status dot, result state. Click opens its session.
struct AGTHandCard: View {
    let hand: AGTAgent
    var body: some View {
        let result = hand.sessionID.flatMap { AGTHandsStore.shared.result(session: $0) }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(hand.name).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                if let result {
                    Text(result.title).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(result == .verified ? DeckTokens.good : Color.secondary)
                        .help("How far this job's result has got: attempted, reported or verified")
                }
            }
            Text(hand.activity).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(hand.name), \(hand.activity)" + (result.map { ", " + $0.title } ?? ""))
    }
    private var dot: Color {
        switch hand.live {
        case .working?: DeckTokens.good
        case .waiting?: DeckTokens.warn
        default: Color.secondary.opacity(0.6)
        }
    }
}

/// "Add a hand…": one more session on this agent's seat with its own job, or a short-lived helper
/// under it. A lead decides this (the person, here). Refused above the template's limit.
struct AGTAddHandSheet: View {
    let agent: AGTAgent
    @Environment(\.dismiss) private var dismiss
    @State private var job = ""
    @State private var details = ""
    @State private var helper = false
    @State private var busy = false
    @State private var problem: String?
    @State private var limit: Int?

    var body: some View {
        let seat = AGTLeads.seat(agent)
        let count = seat.map { AGTHandsStore.shared.hands(on: $0.owner).count } ?? 0
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Add a hand").font(.system(size: 17, weight: .semibold))
                Text((seat.map(AGTLeads.seatTitle) ?? agent.name) + " · " + (limit.map { "\(count) of \($0) hands at work" } ?? "\(count) at work"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Its job, in one line").font(.caption).foregroundStyle(.secondary)
                TextField("For example: fix the failing import for March", text: $job).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Details (optional)").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $details).font(.system(size: 12)).frame(height: 96)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DeckTokens.hairline, lineWidth: 1))
            }
            Toggle(isOn: $helper) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("A short-lived helper instead")
                    Text("It works on its own small seat under this one. Its notes fold back into this seat when it closes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Every hand starts from the same seat memory and writes back into it. A second hand on code works in its own folder.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem { Text(problem).font(.callout).foregroundStyle(DeckTokens.bad).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button { add() } label: { HStack(spacing: 6) { if busy { ProgressView().controlSize(.mini) }; Text(helper ? "Start the helper" : "Add the hand") } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(busy || job.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 480)
        .task { if let template = try? await DeckMemory.store.template(.agent) { limit = template.handsPerSeat } }
    }

    private func add() {
        guard let profile = agent.profileID, let service = BackendAGTHandsService.shared else { problem = "Agents are still starting. Try again in a moment."; return }
        busy = true; problem = nil
        Task {
            defer { busy = false }
            do {
                _ = try await service.addHand(agentID: profile, job: job, details: details, helper: helper, by: "me")
                dismiss()
            } catch { problem = error.localizedDescription }
        }
    }
}

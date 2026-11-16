import Foundation
import Observation
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

// Live use from another Mac (Sessions seat, 15 Nov 2026; plan macos/night/codex/live-use-plan.md, steps 2-3).
// He sits at one Mac and uses a session that runs on another of his Macs, live, while it keeps running there: the
// "Runs on <machine>" page becomes the live session by itself when that machine is on. The Mac reaches his other
// machines by sign-in (BackendReachGuest), as his phones do; the link goes into the same list as a paired machine's,
// so the existing live terminal of another machine (`machine <link> <session>`) draws it unchanged.

/// Joins this Mac's sign-in (the reach guest) and its machine links (the coordinator), and dials on request.
@MainActor @Observable final class NativeReachLive {
    static let shared = NativeReachLive()
    /// One plain line for the Runs on page when this Mac cannot reach his other Macs at all (its key was refused).
    private(set) var problem: String?
    @ObservationIgnored private var guest: BackendReachGuest?
    /// The last dial asked for each machine name (a page that opens again within 20 s does not dial again).
    @ObservationIgnored private var asked: [String: Date] = [:]

    /// Signed in (NativeReachAccount.assemble): his other machines can be reached from here.
    func signedIn(_ guest: BackendReachGuest) { self.guest = guest; problem = nil; push() }
    /// Signed out: every machine reached by sign-in is let go at once.
    func signedOut() {
        let old = guest
        guest = nil; asked = [:]; problem = nil; push()
        if let old { Task { await old.forget() } }
    }
    /// The machine links exist (production composition).
    func machinesReady() { push() }

    private func push() {
        guard let coordinator = NativeRemoteMacs.shared.coordinator else { return }
        let guest = self.guest
        Task { await coordinator.setReachGuest(guest) }
    }

    /// A Cloud page of a session on `machine` opened while that machine is on: dial it (by sign-in, no question).
    func want(machine name: String?) {
        // The page follows the machine links (a paired machine's live twin counts too).
        NativeMachineLinks.shared.start()
        guard guest != nil, let coordinator = NativeRemoteMacs.shared.coordinator else { return }
        let key = name ?? ""
        if let at = asked[key], Date().timeIntervalSince(at) < 20 { return }
        asked[key] = Date()
        let guest = self.guest
        Task {
            _ = try? await coordinator.openReach(name: name)
            let refused = await guest?.keyRefused == true
            guard self.guest === guest else { return }
            problem = refused ? BackendReachGuest.keyRefusedLine : nil
        }
    }
}

/// What the "Runs on <machine>" page shows (pure, tested): the Cloud copy, the live terminal (its tab), or the live chat.
enum NativeCloudLiveChoice: Equatable {
    case cloud
    case terminal(tabId: String)
    case chat(machineId: String, chatId: String)

    /// The page's one extra line: only while it shows the Cloud copy of a session on a machine that is on.
    static func problemLine(_ choice: NativeCloudLiveChoice, row: BackendCloudSessionsRead.Row?, problem: String?) -> String? {
        guard choice == .cloud, let row, row.machineOn != false, row.closedAt == nil else { return nil }
        return problem
    }

    static func choose(row: BackendCloudSessionsRead.Row?, links: MachinesSnapshot) -> NativeCloudLiveChoice {
        guard let row, row.closedAt == nil, row.machineOn != false,
              let twin = links.liveTwin(sessionId: row.sessionId, machineRef: row.machine, machineName: row.machineName) else { return .cloud }
        // An exited session is history: the Cloud copy says it all.
        guard twin.session.exitCode == nil, twin.session.status != "exited" else { return .cloud }
        if twin.session.chat || row.kind == "chat" { return .chat(machineId: twin.machineId, chatId: twin.session.id) }
        return .terminal(tabId: twin.tabId)
    }

    /// The side panel's one-row rule: a Cloud row whose live twin is already open here (its own row) is not listed.
    static func shownOthers(_ others: [BackendCloudSessionsRead.Row], ownIDs: Set<String>, links: MachinesSnapshot) -> [BackendCloudSessionsRead.Row] {
        others.filter { row in
            guard let twin = links.liveTwin(sessionId: row.sessionId, machineRef: row.machine, machineName: row.machineName) else { return true }
            return !ownIDs.contains(twin.tabId)
        }
    }
}

/// A chat session of another Mac, live: the same messages its phones get (chats.watch), a box to write in, Stop while
/// it works, and Allow / Deny for what it asks (that Mac decides whether this one may answer, as for a phone).
@MainActor @Observable
final class NativeMachineChatLive {
    private(set) var events: [HootChatEvent] = []
    private(set) var busy = false
    private(set) var problem: String?
    @ObservationIgnored private var subscription: EngineSubscription?
    @ObservationIgnored private(set) var machineId = ""
    @ObservationIgnored private(set) var chatId = ""
    @ObservationIgnored var send: @MainActor (_ args: [Any?]) async throws -> Void = { args in _ = try await RemoteCall.invoke("machines:chats", args) }

    func open(machineId: String, chatId: String) async {
        close()
        self.machineId = machineId; self.chatId = chatId
        subscription = EngineBridge.shared.on("machines:chats:events") { [weak self] args in
            guard let self, let raw = args.first as? [String: Any] else { return }
            self.receive(raw)
        }
        await call("watch")
    }
    func close() {
        subscription?.cancel(); subscription = nil
        guard !chatId.isEmpty else { return }
        let args: [Any?] = [machineId, "unwatch", chatId]
        let send = self.send
        Task { try? await send(args) }
        chatId = ""
    }

    /// One `machines:chats:events` push: {machineId, frame}. A reset frame replaces what is shown; an older page goes first.
    func receive(_ raw: [String: Any]) {
        guard raw["machineId"] as? String == machineId, let frame = raw["frame"] as? [String: Any], frame["id"] as? String == chatId else { return }
        let parsed = (frame["events"] as? [Any] ?? []).compactMap { item -> HootChatEvent? in
            guard let value = try? NativeRPCValue.fromFoundation(item) else { return nil }
            return try? HootChatEvent(wire: value)
        }
        if frame["older"] as? Bool == true {
            let known = Set(events.map(\.id))
            events = parsed.filter { !known.contains($0.id) } + events
        } else if frame["reset"] as? Bool == false {
            let known = Set(events.map(\.id))
            events += parsed.filter { !known.contains($0.id) }
        } else {
            events = parsed
        }
        busy = frame["busy"] as? Bool == true
    }

    /// The question it waits on: an approval with no answer after it (its id is the request the answer names).
    var waiting: HootChatEvent? { Self.waiting(events) }
    /// What it waits on, as the local chat's cards take it: each unanswered question's own request (an approval event's
    /// value is that request), newest last.
    var pending: [NativeRPCValue] { Self.pending(events) }
    static func pending(_ events: [HootChatEvent]) -> [NativeRPCValue] {
        let answered = Set(events.filter { $0.record.kind == .approvalResolved }.map(\.record.messageID))
        return events.filter { $0.record.kind == .approval && !$0.record.messageID.isEmpty && !answered.contains($0.record.messageID) }
            .map { event in event.record.value["requestId"].string == nil ? event.record.value.setting("requestId", .string(event.record.messageID)) : event.record.value }
    }
    static func requestID(_ request: NativeRPCValue) -> String { request["requestId"].string ?? "" }
    /// An answer is on its way (the card's buttons wait).
    private(set) var answering = false
    static func waiting(_ events: [HootChatEvent]) -> HootChatEvent? {
        let answered = Set(events.filter { $0.record.kind == .approvalResolved }.map(\.record.messageID))
        return events.last { $0.record.kind == .approval && !$0.record.messageID.isEmpty && !answered.contains($0.record.messageID) }
    }
    /// What he reads: his messages and its answers, an answer growing as it is written (its pieces joined).
    var shown: [HootChatRow] { Self.shown(events) }
    static func shown(_ events: [HootChatEvent]) -> [HootChatRow] {
        HootChatProjection.rows(events).filter { [.user, .message, .textDelta, .error].contains($0.kind) && !($0.value["text"].string ?? "").isEmpty }
    }

    func say(_ text: String) async { await call("say", text) }
    func stop() async { await call("interrupt") }
    func answer(_ request: String, allowed: Bool) async {
        answering = true
        await call("answer", request, allowed)
        answering = false
    }

    private func call(_ op: String, _ more: Any?...) async {
        problem = nil
        do { try await send(([machineId, op, chatId] as [Any?]) + more) }
        catch { problem = RemoteCall.text(error, "That Mac did not take it. Check that it is still on.") }
    }
}

/// Pictures only: the "Runs on" page's row, links and readers, drawn without reading the account or dialling.
struct NativeCloudLivePreview {
    var row: BackendCloudSessionsRead.Row
    var links: MachinesSnapshot
    var reader: NativeCloudChatReader
    var live: NativeMachineChatLive?
    var problem: String? = nil
}

/// The live chat of another Mac's session, under the page's "Runs on" line.
struct NativeMachineChatLivePage: View {
    let machineId: String
    let chatId: String
    /// Pictures only: a filled chat drawn as is (nothing is watched or sent).
    var preview: NativeMachineChatLive? = nil
    @State private var own = NativeMachineChatLive()
    @State private var draft = HootComposerDraft()
    private var live: NativeMachineChatLive { preview ?? own }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(live.shown) { row in NativeMachineChatRow(row: row) }
                }
                .padding(.horizontal, 24).padding(.bottom, 16)
                .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            // The app's own chat parts (Decker, 15 Nov): what it asks drawn with the local chat's question card, in the
            // same place (right above the box), and the local chat's composer (its arrow is Stop while it answers).
            // No model, effort or permission menus: the other Mac does not take them from here.
            VStack(spacing: DeckTokens.Spacing.s4) {
                let pending = live.pending
                if !pending.isEmpty {
                    VStack(spacing: DeckTokens.Spacing.s4) {
                        ForEach(pending, id: \.compact) { request in
                            NativeChatApprovalCard(request: request, disabled: live.answering, onlyAllowOrDeny: true) { allowed, _ in
                                Task { await live.answer(NativeMachineChatLive.requestID(request), allowed: allowed) }
                            }.id(NativeMachineChatLive.requestID(request))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .background(DeckTokens.card, in: RoundedRectangle(cornerRadius: 8))
                    // Exactly as tall as what it asks (its own inner scroll stops it at 240 pt for a long one); the
                    // messages keep the rest of the room (Decker, 15 Nov: a priority here stretched it over the chat).
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let problem = live.problem {
                    Text(problem).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                HootComposer(draft: $draft, ownerID: "machine " + machineId + "/" + chatId, showMeta: false,
                             busy: live.busy, placeholder: "Message the AI on that Mac", agentName: "the AI",
                             onSend: { sent in send(sent) }, onStop: { Task { await live.stop() } },
                             canStop: live.busy, showsPermission: false)
            }
            .padding(.horizontal, 24).padding(.bottom, 12)
            .hootColumn(false)
        }
        .task(id: machineId + " " + chatId) { if preview == nil { await live.open(machineId: machineId, chatId: chatId) } }
        .onDisappear { if preview == nil { live.close() } }
    }

    private func send(_ sent: HootComposerDraft) {
        let text = sent.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = HootComposerDraft()
        Task { await live.say(text) }
    }
}

/// One message of the live chat, drawn as the Cloud page draws them (his in a tinted bubble, its answer as markdown).
struct NativeMachineChatRow: View {
    let row: HootChatRow
    var body: some View {
        let text = row.value["text"].string ?? ""
        switch row.kind {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(text).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.14), in: .rect(cornerRadius: 12))
            }
        case .error:
            Text(text).font(.callout).foregroundStyle(.secondary)
        default:
            NativeChatMarkdown(text: text).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

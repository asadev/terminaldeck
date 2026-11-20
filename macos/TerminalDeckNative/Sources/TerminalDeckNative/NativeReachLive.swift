import AppKit
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
    @ObservationIgnored private var wanted: Set<String> = []
    @ObservationIgnored private var asked: [String: Date] = [:]
    @ObservationIgnored private var dialing: Set<String> = []
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var epoch = UUID()
    /// 19 Nov free plan (Decker, 20 Nov: "He started in Windows. He can see and control from Mac"): a free account's
    /// side panel lists its other computers' sessions from live links (its Cloud rows are refused), so every computer
    /// that is on is dialled and its link kept while the account is free.
    @ObservationIgnored private(set) var keepsAll = false
    @ObservationIgnored private var activeWatch: NSObjectProtocol?

    init() {
        keepsAll = CloudSubscriptionOffers.shared.limitsRemoteToSessions
        if keepsAll { wanted.insert("") }
        CloudSubscriptionOffers.shared.watchRemoteLimit(owner: "reach-live") { limited in
            Task { @MainActor in NativeReachLive.shared.freePlan(limited) }
        }
        // No timer: a computer switched on later is dialled when this app comes to the front again (20 s apart at most).
        activeWatch = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NativeReachLive.shared.becameActive() }
        }
    }
    func freePlan(_ limited: Bool) {
        keepsAll = limited
        if limited { wanted.insert("") }
        push()
    }
    private func becameActive() { if keepsAll { push() } }

    func signedIn(_ guest: BackendReachGuest) {
        epoch = UUID(); asked = [:]; dialing = []
        self.guest = guest; problem = nil; push()
    }
    func signedOut() {
        let old = guest
        guest = nil; asked = [:]; dialing = []; wanted = keepsAll ? [""] : []; problem = nil; epoch = UUID(); push()
        if let old { Task { await old.forget() } }
    }
    /// Called after the machine coordinator is open, not merely constructed.
    func machinesReady() { ready = true; push() }
    /// Retry unresolved demand on the existing Cloud list refresh; no extra timer or session polling.
    func accountRefreshed() { if !wanted.isEmpty { push() } }

    private func push() {
        guard let coordinator = NativeRemoteMacs.shared.coordinator else { return }
        let guest = self.guest, epoch = self.epoch, keep = keepsAll
        if keep { NativeMachineLinks.shared.start() }
        Task {
            guard epoch == self.epoch else { return }
            await coordinator.setReachGuest(guest)
            await coordinator.setKeepReach(keep)
            guard epoch == self.epoch, ready, guest != nil else { return }
            for name in wanted { dial(name, coordinator: coordinator) }
        }
    }

    /// Preserve demand while sign-in and machine composition finish. They replay it once their doors are ready.
    func want(machine name: String?) {
        guard NativeCloudOffers.shows(.otherComputerSessions) else { return }
        // The page follows the machine links (a paired machine's live twin counts too).
        NativeMachineLinks.shared.start()
        let key = name ?? ""
        wanted.insert(key)
        guard ready, guest != nil else { return }
        push()
    }

    private func dial(_ name: String, coordinator: BackendMachineCoordinator) {
        guard !dialing.contains(name), asked[name].map({ Date().timeIntervalSince($0) < 20 }) != true else { return }
        dialing.insert(name)
        asked[name] = Date()
        let guest = self.guest, epoch = self.epoch
        Task {
            var failure: String?
            do {
                let ids = try await coordinator.openReach(name: name.isEmpty ? nil : name)
                if ids.isEmpty { failure = "That Mac is not reachable yet. Its saved conversation is shown here." }
            } catch { failure = RemoteCall.text(error, "That Mac could not be reached. Its saved conversation is shown here.") }
            let refused = await guest?.keyRefused == true
            guard epoch == self.epoch, self.guest === guest else { return }
            dialing.remove(name)
            problem = refused ? BackendReachGuest.keyRefusedLine : failure
            // A free account has no "Runs on" page to show this line: the log keeps it (no names of his, no keys).
            if keepsAll, let line = problem { NativeCloudAccount.log("reach: other computers not reached: " + line) }
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
        guard let row, row.closedAt == nil,
              let twin = links.liveTwin(sessionId: row.sessionId, machineRef: row.machine, machineName: row.machineName) else { return .cloud }
        // An exited session is history: the Cloud copy says it all.
        guard twin.session.exitCode == nil, twin.session.status != "exited" else { return .cloud }
        if twin.session.chat { return .chat(machineId: twin.machineId, chatId: twin.session.id) }
        return .terminal(tabId: twin.tabId)
    }

    var tabId: String? {
        switch self {
        case .cloud: return nil
        case .terminal(let tabId): return tabId
        case .chat(let machine, let chat): return MachinesRules.tabId(machineId: machine, sessionId: chat)
        }
    }

    /// The side panel's one-row rule: a Cloud row whose live twin is already open here (its own row) is not listed.
    static func shownOthers(_ others: [BackendCloudSessionsRead.Row], ownIDs: Set<String>, links: MachinesSnapshot, liveRefs: [String: String] = [:]) -> [BackendCloudSessionsRead.Row] {
        others.filter { row in
            if ownIDs.contains(where: { liveRefs[$0] == row.ref }) { return false }
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
    private(set) var options: NativeRPCValue = .object([])
    private(set) var sending = false
    private(set) var unsentText: String?
    @ObservationIgnored private var linked = false
    @ObservationIgnored private var pendingText: [String: String] = [:]
    @ObservationIgnored private var stateSubscription: EngineSubscription?
    @ObservationIgnored private var subscription: EngineSubscription?
    @ObservationIgnored private(set) var machineId = ""
    @ObservationIgnored private(set) var chatId = ""
    @ObservationIgnored var send: @MainActor (_ args: [Any?]) async throws -> Void = { args in _ = try await RemoteCall.invoke("machines:chats", args) }

    @ObservationIgnored var readOptions: @MainActor (_ args: [Any?]) async throws -> NativeRPCValue = { args in
        try NativeRPCValue.fromFoundation(await RemoteCall.invoke("machines:chats", args))
    }

    func open(machineId: String, chatId: String) async {
        if self.machineId == machineId, self.chatId == chatId, subscription != nil { return }
        close()
        events = []; busy = false; options = .object([]); problem = nil; unsentText = nil; pendingText = [:]
        self.machineId = machineId; self.chatId = chatId
        subscription = EngineBridge.shared.on("machines:chats:events") { [weak self] args in
            guard let self, let raw = args.first as? [String: Any] else { return }
            self.receive(raw)
        }
        stateSubscription = EngineBridge.shared.on("machines:state") { [weak self] args in
            guard let self, let snapshot = MachinesSnapshot.decode(args.first) else { return }
            self.connectionChanged(snapshot.links[self.machineId]?.state == .online)
        }
        linked = true
        await watch()
    }
    func connectionChanged(_ online: Bool) {
        let before = linked
        linked = online
        if !online { busy = false; problem = "Reconnecting to that Mac…" }
        if online, !before { Task { await watch() } }
    }
    private func watch() async {
        await call("watch")
        await loadOptions()
    }
    func loadOptions(patch: NativeRPCValue? = nil) async {
        let machine = machineId, chat = chatId
        guard !chat.isEmpty else { return }
        problem = nil
        do {
            let next = try await readOptions([machine, patch == nil ? "options" : "set", chat, patch?.foundation])
            guard machine == machineId, chat == chatId else { return }
            options = next
        } catch { problem = RemoteCall.text(error, "That Mac could not read or change this chat’s choices.") }
    }
    func close() {
        subscription?.cancel(); subscription = nil
        stateSubscription?.cancel(); stateSubscription = nil
        guard !chatId.isEmpty else { return }
        let args: [Any?] = [machineId, "unwatch", chatId]
        let send = self.send
        Task { try? await send(args) }
        chatId = ""
    }

    /// One `machines:chats:events` push: {machineId, frame}. A reset frame replaces what is shown; an older page goes first.
    func receive(_ raw: [String: Any]) {
        guard raw["machineId"] as? String == machineId, let frame = raw["frame"] as? [String: Any] else { return }
        if frame["t"] as? String == "error" {
            guard let rid = frame["rid"] as? String, let text = pendingText.removeValue(forKey: rid) else { return }
            unsentText = text
            problem = frame["message"] as? String ?? "That Mac did not take the message."
            return
        }
        guard frame["id"] as? String == chatId else { return }
        if frame["t"] as? String == "chats.options" {
            if let value = frame["options"], let next = try? NativeRPCValue.fromFoundation(value) { options = next }
            return
        }
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
        if frame["older"] as? Bool != true { busy = frame["busy"] as? Bool == true }
        // A user event is the receipt the phone also observes. Retain only unresolved sends, bounded below.
        let heard = Set(events.filter { $0.record.kind == .user }.compactMap { $0.record.value["text"].string })
        pendingText = pendingText.filter { !heard.contains($0.value) }
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

    @discardableResult
    func say(_ text: String) async -> Bool {
        guard !sending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        sending = true
        defer { sending = false }
        let rid = UUID().uuidString.lowercased()
        if pendingText.count >= 32 { problem = "That Mac has not confirmed the earlier messages yet."; return false }
        pendingText[rid] = text
        problem = nil; unsentText = nil
        do { try await send([machineId, "say", chatId, text, nil, rid]); return true }
        catch { pendingText[rid] = nil; problem = RemoteCall.text(error, "That Mac did not take the message."); return false }
    }
    func stop() async { await call("interrupt") }
    func answer(_ request: String, allowed: Bool) async {
        answering = true
        await call("answer", request, allowed)
        answering = false
    }

    private func call(_ op: String, _ more: Any?...) async {
        let machine = machineId, chat = chatId
        guard !chat.isEmpty else { return }
        problem = nil
        do { try await send(([machine, op, chat] as [Any?]) + more) }
        catch {
            guard machine == machineId, chat == chatId else { return }
            problem = RemoteCall.text(error, "That Mac did not take it. Check that it is still on.")
        }
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
    var model: NativeMachineChatLive? = nil
    var enabled = true
    @State private var own = NativeMachineChatLive()
    @State private var draft = HootComposerDraft()
    private var live: NativeMachineChatLive { preview ?? model ?? own }
    private var catalogue: HootComposerCatalogue {
        var result = HootComposerCatalogue()
        result.models = (live.options["models"].elements ?? []).compactMap { row in
            guard let id = row["id"].string else { return nil }
            return HootComposerModel(id: id, provider: row["provider"].string ?? "", name: row["name"].string ?? id)
        }
        result.efforts = (live.options["efforts"].elements ?? []).compactMap(\.string)
        return result
    }

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
            // Choices are the same chats.options / chats.set requests the phone uses.
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
                HootComposer(draft: $draft, ownerID: "machine " + machineId + "/" + chatId, catalogue: catalogue, showMeta: !catalogue.models.isEmpty,
                             busy: live.busy, enabled: enabled && !live.sending, placeholder: "Message the AI on that Mac", agentName: "the AI",
                             onSend: { sent in send(sent) }, onStop: { Task { await live.stop() } },
                             onModelChange: { id in Task {
                                 await live.loadOptions(patch: .object([.init("model", .string(id))]))
                                 draft.modelID = live.options["model"].string ?? ""
                             } },
                             onEffortChange: { effort in Task {
                                 await live.loadOptions(patch: .object([.init("effort", .string(effort))]))
                                 draft.effort = live.options["effort"].string ?? ""
                             } },
                             canStop: enabled && live.busy, showsPermission: false)
            }
            .padding(.horizontal, 24).padding(.bottom, 12)
            .hootColumn(false)
        }
        .task(id: machineId + " " + chatId) { if preview == nil { await live.open(machineId: machineId, chatId: chatId) } }
        .onDisappear { if preview == nil, model == nil { live.close() } }
        .onChange(of: live.options, initial: true) { _, next in
            draft.modelID = next["model"].string ?? ""
            draft.effort = next["effort"].string ?? ""
        }
        .onChange(of: live.unsentText) { _, text in
            if let text, draft.plainText.isEmpty { draft.text = text }
        }
    }

    private func send(_ sent: HootComposerDraft) {
        let text = sent.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !text.isEmpty else { return }
        Task {
            if await live.say(text), draft.plainText.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                draft.text = ""
            }
        }
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

/// Cloud rows and account-switch replacements use the explicit machine action, which first creates its tab.
@MainActor
enum NativeMachineSessionRoute {
    static func open(tabId: String, perform: @MainActor (PageCommand) -> Void = { AppModel.shared.runButton($0) }) {
        guard case .machine = SessionTarget(tabId: tabId) else { return }
        perform(.selectTab(tabId))
    }
}

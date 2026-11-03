import AppKit
import Foundation
import Observation
import TerminalDeckNativeCore

/// Connected task systems for the window (Tasks → the system's own section, Settings →
/// Tasks): the systems, each one's last read list, and every call on `connected-tasks:*`.
/// Reads happen when asked: the section opens, the app comes forward (if the last read
/// is over two minutes old), Refresh, and after each change. There is no timer.
@MainActor
@Observable
final class ConnectedTasksStore {
    static let shared = ConnectedTasksStore()
    static let staleAfter: Double = 2 * 60_000

    private(set) var systems: [ConnectedTaskSystem] = []
    private(set) var lists: [String: ConnectedTaskList] = [:]
    private(set) var loaded = false
    private(set) var refreshing: Set<String> = []
    /// The system whose section is on screen, so coming forward reads only that one.
    var visible: String?
    var problem: String?
    /// The task open over the Tasks page.
    var open: (system: String, task: String)?
    /// The order the section shows, for the popup's previous / next.
    var order: [String] = []
    /// A change waiting for the owner's yes (Ask each time, or a destructive one).
    private(set) var asking: Ask?
    struct Ask { let id = UUID(); let sentence: String; let system: String; let destructive: Bool; let resolve: (Answer) -> Void }
    enum Answer { case send, always, cancel }
    /// Popups the owner already said yes to (Ask each time asks once per opened task).
    @ObservationIgnored private var approved: Set<String> = []
    /// Offscreen renders only: canned popup answers.
    @ObservationIgnored var popupFixture: ((String, [NativeRPCValue]) -> NativeRPCValue?)?

    /// The popup already asked for these itself ("Delete?", "Merge", "Convert", delete a tag).
    static let askedInPopup: Set<String> = ["mergeTaskInto", "convertToSubtask", "deleteTask", "deleteLabelEverywhere"]
    static let destructive: Set<String> = ["setArchived", "mergeTaskInto", "convertToSubtask", "deleteTask", "deleteLabelEverywhere"]

    /// A yes/no question in the same bar (handing a task to an agent).
    func requestYes(_ sentence: String, system: String, _ reply: @escaping (Bool) -> Void) {
        asking?.resolve(.cancel)
        asking = Ask(sentence: sentence, system: system, destructive: false, resolve: { reply($0 != .cancel) })
    }

    func answer(_ answer: Answer) {
        guard let asking else { return }
        self.asking = nil
        asking.resolve(answer)
    }

    /// One call of the task popup on a connected task, asking the owner when the system's gate wants a yes.
    func popupCall(_ connection: String, _ fn: String, _ args: [NativeRPCValue]) async -> NativeRPCValue {
        if let popupFixture { return popupFixture(fn, args) ?? .object([.init("ok", .bool(false)), .init("error", .string("Not in this preview."))]) }
        let session = connection + "|" + (open?.task ?? "")
        var confirmed = Self.askedInPopup.contains(fn) || approved.contains(session) && !Self.destructive.contains(fn)
        for _ in 0..<2 {
            let answer: NativeRPCValue
            switch await call("detail", [connection, fn, NativeRPCValue.array(args).foundation ?? [], confirmed]) {
            case .success(let value): answer = value
            case .failure(let error): return .object([.init("ok", .bool(false)), .init("error", .string(error.message))])
            }
            guard answer["needsConfirmation"].bool == true, !confirmed else { return answer }
            let name = systems.first { $0.id == connection }?.name ?? "the system"
            let destructive = Self.destructive.contains(fn)
            let sentence = answer["error"].string ?? "Send this to \(name)?"
            let reply: Answer = await withCheckedContinuation { done in
                asking?.resolve(.cancel)
                asking = Ask(sentence: sentence, system: name, destructive: destructive, resolve: { done.resume(returning: $0) })
            }
            switch reply {
            case .cancel: return .object([.init("ok", .bool(false)), .init("error", .string("Not sent to \(name)."))])
            case .always:
                _ = await call("update", [connection, ["changes": "allow"]])
                await reload()
                fallthrough
            case .send:
                if !destructive { approved.insert(session) }
                confirmed = true
            }
        }
        return .object([.init("ok", .bool(false)), .init("error", .string("Not sent."))])
    }

    @ObservationIgnored private var started = false
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var activation: NSObjectProtocol?

    init() {}

    func start() {
        if !started {
            started = true
            subscriptions.append(EngineBridge.shared.on("connected-tasks:changed") { _ in
                Task { @MainActor in await ConnectedTasksStore.shared.reload() }
            })
            activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    let store = ConnectedTasksStore.shared
                    guard let id = store.visible, store.isStale(id) else { return }
                    await store.refresh(id)
                }
            }
        }
        Task { await reload() }
    }

    func isStale(_ id: String) -> Bool {
        guard let at = systems.first(where: { $0.id == id })?.refreshedAt else { return true }
        return Date().timeIntervalSince1970 * 1000 - at > Self.staleAfter
    }

    /// Adopts a pre-built state (offscreen renders; never the engine).
    func preview(systems: [ConnectedTaskSystem], lists: [ConnectedTaskList]) {
        started = true; loaded = true
        self.systems = systems
        self.lists = Dictionary(lists.map { ($0.system.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func reload() async {
        guard EngineBridge.shared.isReady else { return }
        guard let raw = try? await EngineBridge.shared.invoke("connected-tasks:state"),
              let value = try? NativeRPCValue.fromFoundation(raw) else { return }
        systems = (value["connections"].elements ?? []).compactMap(ConnectedTaskSystem.init)
        loaded = true
        for system in systems { await loadList(system.id) }
        lists = lists.filter { id, _ in systems.contains { $0.id == id } }
    }

    private func loadList(_ id: String) async {
        guard let raw = try? await EngineBridge.shared.invoke("connected-tasks:list", [id]),
              let value = try? NativeRPCValue.fromFoundation(raw), let list = ConnectedTaskList(value) else { return }
        lists[id] = list
        await readCreationDates(id, list: list)
    }

    @ObservationIgnored private var creationReads = Set<String>()
    static let creationBatch = 4
    /// This system's list may omit creation metadata; its existing read-only
    /// task-detail tool supplies it. Read once per task (the engine keeps a date once read),
    /// a few tasks at a time, each few shown in one update, without opening an editor.
    private func readCreationDates(_ id: String, list: ConnectedTaskList) async {
        let listed = Set(list.tasks.map { id + "|" + $0.id })
        creationReads = creationReads.filter { !$0.hasPrefix(id + "|") || listed.contains($0) }
        var missing: [String] = []
        for row in list.tasks where row.createdAt?.isEmpty != false && creationReads.insert(id + "|" + row.id).inserted { missing.append(row.id) }
        for start in stride(from: 0, to: missing.count, by: Self.creationBatch) {
            let batch = Array(missing[start..<min(start + Self.creationBatch, missing.count)])
            let reads = batch.map { task in
                Task { () -> String? in
                    guard case .success(let detail) = await self.call("get", [id, task]) else { return nil }
                    return detail["createdAt"].string
                }
            }
            var stamps: [String: String] = [:]
            for (task, read) in zip(batch, reads) { if let stamp = await read.value, !stamp.isEmpty { stamps[task] = stamp } }
            guard !stamps.isEmpty, var current = lists[id] else { continue }
            for index in current.tasks.indices { if let stamp = stamps[current.tasks[index].id] { current.tasks[index].createdAt = stamp } }
            lists[id] = current
        }
    }

    /// One call, as a value or the sentence it was refused with.
    func call(_ channel: String, _ args: [Any?]) async -> Result<NativeRPCValue, NativeRPCError> {
        guard EngineBridge.shared.isReady else { return .failure(.init(code: "unavailable", message: "Terminal Deck is still starting.")) }
        do {
            let raw = try await EngineBridge.shared.invoke("connected-tasks:" + channel, args)
            return .success(try NativeRPCValue.fromFoundation(raw))
        } catch let error as NativeRPCError {
            return .failure(error)
        } catch {
            return .failure(Self.error(error))
        }
    }

    /// The engine's refusal code survives the bridge as `code: message` or as the message alone.
    static func error(_ error: Error) -> NativeRPCError {
        let text = error.localizedDescription
        for code in ["needs-confirmation", "confirm-needed", "read-only", "unauthorized", "rate-limited", "not-offered", "refused", "off"] {
            if text.hasPrefix(code + ": ") { return .init(code: code, message: String(text.dropFirst(code.count + 2))) }
        }
        let code = text.hasPrefix("Send this to ") && text.hasSuffix("?") ? "needs-confirmation" : "failed"
        return .init(code: code, message: text)
    }

    func refresh(_ id: String) async {
        refreshing.insert(id)
        defer { refreshing.remove(id) }
        switch await call("refresh", [id]) {
        case .success(let value):
            if let list = ConnectedTaskList(value) { lists[id] = list; problem = nil }
            await reload()
        case .failure(let error):
            problem = error.message
            await reload()
        }
    }

    func foundation(_ value: NativeRPCValue) -> Any { value.foundation ?? NSNull() }
}

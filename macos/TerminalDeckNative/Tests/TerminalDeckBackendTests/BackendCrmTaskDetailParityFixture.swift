import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

func crmParityValue(_ value: Any) -> NativeRPCValue { try! NativeRPCValue.fromFoundation(value) }
func crmParityOK() -> NativeRPCValue { crmParityValue(["ok": true]) }
func crmParityFailure(_ text: String) -> NativeRPCValue { crmParityValue(["ok": false, "error": text]) }
func crmParityEqual(_ a: NativeRPCValue, _ b: NativeRPCValue) -> Bool { BackendCrmWire.crm(a) == BackendCrmWire.crm(b) }
func crmParityMatches(_ a: NativeRPCValue, _ b: NativeRPCValue) -> Bool {
    if let fields = b.fields { return fields.allSatisfy { a.has($0.key) && crmParityMatches(a[$0.key], $0.value) } }
    if let values = b.elements { guard let actual = a.elements, actual.count == values.count else { return false }; return zip(actual, values).allSatisfy { crmParityMatches($0.0, $0.1) } }
    return a == b
}
func crmParityStrings(_ rows: NativeRPCValue, _ key: String) -> [String] { (rows.elements ?? []).compactMap { $0[key].string } }

actor BackendCrmTaskDetailParityChanges { var count = 0; func note() { count += 1 }; func reset() { count = 0 } }
actor BackendCrmTaskDetailParityRecorder: BackendTaskExecuting {
    let store: BackendTaskStore
    var started: [String] = [], reassigned: [NativeRPCValue] = [], replies: [NativeRPCValue] = [], notices: [NativeRPCValue] = []
    let changeCounter: BackendCrmTaskDetailParityChanges
    var changes: Int { get async { await changeCounter.count } }
    var delivery = BackendTaskReminderDelivery(delivered: true)
    init(store: BackendTaskStore, changes: BackendCrmTaskDetailParityChanges) { self.store = store; changeCounter = changes }
    func accept(_ id: String) async throws {
        if try await store.byID(id)?.assigneeKind == "agent" { started.append(id) }
        _ = try await store.update(id, patch: crmParityValue(["process": "idle"]))
    }
    func reassign(_ id: String, assignee: NativeRPCValue) async throws {
        reassigned.append(crmParityValue(["id": id, "to": assignee["identity"].string ?? ""]))
        if assignee["kind"].string == "agent" { started.append(id) }
        _ = try await store.update(id, patch: .object([.init("assignee", assignee), .init("mainAssignee", assignee["identity"])]))
    }
    func reply(_ id: String, text: String) { replies.append(crmParityValue(["id": id, "text": text])) }
    func cancel(_ id: String, reason: String) {}
    func resetChanges() async { await changeCounter.reset() }
    func setDelivery(_ value: BackendTaskReminderDelivery) { delivery = value }
    func notify(_ id: String, _ title: String, _ body: String) -> BackendTaskReminderDelivery {
        notices.append(crmParityValue(["taskId": id, "title": title, "body": body])); return delivery
    }
}

/// Real memory stores/local/detail; fake execution, people and notification.
/// Every call binds the injected task clock. Schedulers may start only inside
/// that context, so their timers remain recorded fake callbacks.
struct BackendCrmTaskDetailParityFixture: Sendable {
    let store: BackendTaskStore, config: BackendTaskConfiguration, goals: BackendGoalStore
    let local: BackendTaskLocalService, detail: BackendTaskDetailService
    let recorder: BackendCrmTaskDetailParityRecorder
    let clock: BackendCrmTaskClockParityVirtualClock
    static func make(notify: Bool = false, clock providedClock: BackendCrmTaskClockParityVirtualClock? = nil,
                     files: BackendTaskAttachments? = nil, desktop: BackendTaskDetailDesktop? = nil, settings: BackendTaskPersistence? = nil) async throws -> Self {
        let clock = providedClock ?? (BackendTaskClockContext.clock as? BackendCrmTaskClockParityVirtualClock) ?? BackendCrmTaskClockParityVirtualClock()
        if providedClock == nil && !(BackendTaskClockContext.clock is BackendCrmTaskClockParityVirtualClock) {
            clock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000); clock.setReadStep(1000)
        }
        return try await BackendTaskClockContext.withClock(clock) {
        let persistence = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/private/tmp/crm-parity-inert"), ownership: .memory)
        let changes = BackendCrmTaskDetailParityChanges()
        let store = BackendTaskStore(persistence: persistence, changed: { await changes.note() })
        let recorder = BackendCrmTaskDetailParityRecorder(store: store, changes: changes)
        let config = try BackendTaskConfiguration(persistence: persistence), goals = BackendGoalStore(persistence: persistence)
        try await store.start(); try await config.start(); try await goals.start()
        for (id, name) in [("builder", "Builder"), ("tester", "Tester")] {
            _ = try await config.saveAgent(crmParityValue(["id": id, "name": name, "maxRunMinutes": 0, "keepAliveMinutes": 0]))
        }
        let local = BackendTaskLocalService(store: store, configuration: config, goals: goals, engine: recorder)
        let people = BackendTaskDetailPeople(named: { id in
            let names = ["me": "You", "hoot": "Hoot", "builder": "Builder", "tester": "Tester", "app:Claude Desktop": "Claude Desktop"]
            guard let name = names[id] else { throw NativeRPCError.invalidArguments("That task person no longer exists.") }
            return BackendCrmWire.person(BackendCrmPeople.localPerson(id, name))
        }, known: { ["me", "hoot", "builder", "tester"].contains($0) })
        let delivery: (@Sendable (String, String, String) async throws -> BackendTaskReminderDelivery)?
        if notify {
            delivery = { @Sendable (a: String, b: String, c: String) async throws -> BackendTaskReminderDelivery in await recorder.notify(a, b, c) }
        } else { delivery = nil }
        let detail = BackendTaskDetailService(store: store, local: local, people: people, notify: delivery, files: files, desktop: desktop, settingsPersistence: settings, problem: { _ in })
        await local.setUpdateObserver { before, after, notes, actor in
            do { try await detail.noteUpdated(before: before, after: after, notes: notes, by: actor) }
            catch { #expect(false, "Update observer: \(error.localizedDescription)") }
        }
        return Self(store: store, config: config, goals: goals, local: local, detail: detail, recorder: recorder, clock: clock)
        }
    }
    func make(_ title: String, _ extra: NativeRPCValue = .object([]), by: String = "me") async throws -> String {
        try await BackendTaskClockContext.withClock(clock) { try await local.create(crmParityValue(["title": title, "assignee": "me", "status": "To-Do"]).merging(extra), by: by).id }
    }
    func call(_ function: String, _ args: NativeRPCValue...) async -> NativeRPCValue { await BackendTaskClockContext.withClock(clock) { await detail.call(function, arguments: args, by: "me") } }
    func ok(_ function: String, _ args: NativeRPCValue...) async throws -> NativeRPCValue {
        let answer = await BackendTaskClockContext.withClock(clock) { await detail.call(function, arguments: args, by: "me") }
        #expect(answer["ok"].bool == true, "\(function): \(answer.compact)")
        return answer
    }
    func row(_ id: String) async throws -> NativeRPCValue { try #require(try await store.byID(id)).value }
    func rows(_ id: String) async -> [NativeRPCValue] { await call("listTaskActivity", .string(id))["rows"].elements ?? [] }
    func bundle(_ id: String) async -> NativeRPCValue { await call("fetchTaskDetailBundle", .string(id))["bundle"] }
    func copyIDs(_ root: String) async throws -> [String] { try await store.all().filter { $0.value["detail"]["routine"]["rootTaskId"].string == root }.map(\.id) }
}

/// Existing production clock/status lifecycle, with one still-missing public
/// receipt for completion of the private reminder/comment dueJob.
protocol BackendCrmTaskDueParityDriver: Sendable {
    var fixture: BackendCrmTaskDetailParityFixture { get }
    func setNow(_ milliseconds: Double) async
    func runDue() async throws
    func settled() async throws
    func noteStatus(_ id: String) async throws
}
enum BackendCrmTaskDueParityBinding {
    static let make: (@Sendable (Bool) async throws -> any BackendCrmTaskDueParityDriver)? = { notify in
        let f = try await BackendCrmTaskDetailParityFixture.make(notify: notify)
        try await BackendTaskClockContext.withClock(f.clock) { try await f.detail.start() }
        return BackendCrmTaskDueParityNativeDriver(fixture: f)
    }
}
enum BackendCrmTaskDueParityCompletionBinding {
    /// task-detail-local.ts settled(): everything queued has run. The Swift service's settled() now joins the due job as well as the status queue.
    static let join: (@Sendable (BackendTaskDetailService) async throws -> Void)? = { detail in await detail.settled() }
}
struct BackendCrmTaskDueParityNativeDriver: BackendCrmTaskDueParityDriver {
    let fixture: BackendCrmTaskDetailParityFixture
    func setNow(_ milliseconds: Double) async { fixture.clock.setReadStep(0); fixture.clock.set(milliseconds) }
    func runDue() async throws {
        let all = try await fixture.store.all()
        if all.contains(where: { $0.value["detail"]["routine"]["trigger"].string == "schedule" }) {
            try await BackendTaskClockContext.withClock(fixture.clock) { try await fixture.detail.runRepeatSchedules(by: "me") }
            return
        }
        if try await fixture.detail.nextDueAt() == nil {
            await BackendTaskClockContext.withClock(fixture.clock) { await fixture.detail.wake(); await fixture.detail.poke() }
            return
        }
        let join = try #require(BackendCrmTaskDueParityCompletionBinding.join, "Need causal completion receipt for production private dueJob")
        try await BackendTaskClockContext.withClock(fixture.clock) { await fixture.detail.wake(); try await join(fixture.detail) }
    }
    func settled() async throws { await BackendTaskClockContext.withClock(fixture.clock) { await fixture.detail.settled() } }
    func noteStatus(_ id: String) async throws { await BackendTaskClockContext.withClock(fixture.clock) { await fixture.detail.noteStatus(id) } }
}
protocol BackendCrmTaskDetailParityIODriver: Sendable {
    var fixture: BackendCrmTaskDetailParityFixture { get }
    func putFile(_ path: String, bytes: Data) async throws
    func readFile(_ storagePath: String) async throws -> Data
    func exists(_ storagePath: String) async -> Bool
    func pathForFile(_ storagePath: String) -> String
    func chooseFiles(_ paths: [String]) async
    func chooseFolder(_ path: String?) async
    func openAnswer(_ text: String) async
    func opened() async -> [String]
    func freshDetail() async throws -> BackendTaskDetailService
    func hasSettingsFile() async -> Bool
}
enum BackendCrmTaskDetailParityIOBinding {
    static let make: (@Sendable () async throws -> any BackendCrmTaskDetailParityIODriver)? = { try await BackendCrmTaskDetailParityNativeIO.make() }
}
actor BackendCrmTaskDetailParityDesktopState {
    var picked: [String] = [], folder: String?, answer = "", paths: [String] = []
    func setPicked(_ paths: [String]) { picked = paths }; func setFolder(_ path: String?) { folder = path }; func setAnswer(_ text: String) { answer = text }
    func open(_ path: String) -> String { paths.append(path); return answer }
}
final class BackendCrmTaskDetailParityNativeIO: BackendCrmTaskDetailParityIODriver, @unchecked Sendable {
    let fixture: BackendCrmTaskDetailParityFixture
    let root: URL, filesRoot: URL, files: BackendTaskAttachments, settings: BackendTaskPersistence
    let desktop: BackendTaskDetailDesktop, state: BackendCrmTaskDetailParityDesktopState
    init(fixture: BackendCrmTaskDetailParityFixture, root: URL, filesRoot: URL, files: BackendTaskAttachments, settings: BackendTaskPersistence, desktop: BackendTaskDetailDesktop, state: BackendCrmTaskDetailParityDesktopState) { self.fixture = fixture; self.root = root; self.filesRoot = filesRoot; self.files = files; self.settings = settings; self.desktop = desktop; self.state = state }
    static func make(notify: Bool = false) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendCrmTaskParity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let filesRoot = root.appendingPathComponent("remote/task-files"), filePersistence = try BackendTaskPersistence(directory: filesRoot, ownership: .exclusive)
            let files = BackendTaskAttachments(persistence: filePersistence, authorizeSource: { path in
                guard path.hasPrefix("/picked/") || path.hasPrefix("/work/app/") else { throw NativeRPCError.invalidArguments("The file is not inside a folder Terminal Deck has open") }
                return root.appendingPathComponent("picked").appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
            })
            let state = BackendCrmTaskDetailParityDesktopState(), desktop = BackendTaskDetailDesktop(chooseFiles: { await state.picked }, chooseFolder: { await state.folder }, openPath: { await state.open($0) })
            let settings = try BackendTaskPersistence(directory: root.appendingPathComponent("remote"), ownership: .exclusive)
            let f = try await BackendCrmTaskDetailParityFixture.make(notify: notify, files: files, desktop: desktop, settings: settings)
            return Self(fixture: f, root: root, filesRoot: filesRoot, files: files, settings: settings, desktop: desktop, state: state)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func putFile(_ path: String, bytes: Data) async throws { let dir = root.appendingPathComponent("picked"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); try bytes.write(to: dir.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)) }
    func readFile(_ path: String) async throws -> Data { try Data(contentsOf: filesRoot.appendingPathComponent(path)) }
    func exists(_ path: String) async -> Bool { FileManager.default.fileExists(atPath: pathForFile(path)) }
    /// The service opens the descriptor-resolved real path (F_GETPATH: /private/var…), so the expectation is the real path too.
    func pathForFile(_ path: String) -> String { let plain = filesRoot.appendingPathComponent(path).path; var buffer = [CChar](repeating: 0, count: Int(PATH_MAX)); return realpath(plain, &buffer) == nil ? plain : String(cString: buffer) }
    func chooseFiles(_ paths: [String]) async { await state.setPicked(paths) }
    func chooseFolder(_ path: String?) async { await state.setFolder(path) }
    func openAnswer(_ text: String) async { await state.setAnswer(text) }
    func opened() async -> [String] { await state.paths }
    func freshDetail() async throws -> BackendTaskDetailService { BackendTaskDetailService(store: fixture.store, local: fixture.local, people: .native(configuration: fixture.config), files: files, desktop: desktop, settingsPersistence: settings, problem: { _ in }) }
    func hasSettingsFile() async -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("remote/task-detail.json").path) }
}

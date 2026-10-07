import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

func routinesTaskObject(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(fields.map { .init($0.0, $0.1) }) }
func routinesTaskText(_ values: [String]) -> NativeRPCValue { .array(values.map(NativeRPCValue.string)) }
func routinesTaskScratch() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendRoutinesTaskParity-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
}
func routinesTaskMatches(_ actual: NativeRPCValue, _ expected: NativeRPCValue) {
    if let fields = expected.fields {
        #expect(actual.fields != nil)
        if fields.isEmpty { #expect(actual.fields?.isEmpty == true) }
        for field in fields { routinesTaskMatches(actual[field.key], field.value) }
    }
    else { #expect(actual == expected) }
}
func routinesTaskError(_ body: () async throws -> Void) async -> String {
    do { try await body(); return "" } catch { return error.localizedDescription }
}
func routinesTaskErrorCode(_ body: () async throws -> Void) async -> String {
    do { try await body(); return "" } catch let error as NativeRPCError { return error.code } catch { return "unexpected-error" }
}

actor BackendRoutinesTaskStoreParityRecorder: BackendTaskExecuting {
    let store: BackendTaskStore
    var accepted: [String] = [], cancelled: [String] = [], replies: [(String, String)] = [], reassigned: [String] = []
    init(store: BackendTaskStore) { self.store = store }
    func accept(_ id: String) async throws { accepted.append(id); _ = try await store.update(id, patch: routinesTaskObject([("process", .string("idle"))])) }
    func cancel(_ id: String, reason: String) async throws { cancelled.append(id); _ = try await store.update(id, patch: routinesTaskObject([("sessionId", .null), ("process", .string("exited")), ("stopped", .bool(true))])) }
    func reassign(_ id: String, assignee: NativeRPCValue) async throws { reassigned.append(id); _ = try await store.update(id, patch: routinesTaskObject([("assignee", assignee), ("mainAssignee", assignee["identity"])])) }
    func reply(_ id: String, text: String) async throws { replies.append((id, text)) }
    func clearAccepted() { accepted = [] }
}

actor BackendRoutinesTaskStoreParitySignal {
    var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func hit() { count += 1; var kept: [(Int, CheckedContinuation<Void, Never>)] = []; for (target, waiter) in waiters { if count >= target { waiter.resume() } else { kept.append((target, waiter)) } }; waiters = kept }
    func wait(_ target: Int) async { if count >= target { return }; await withCheckedContinuation { waiters.append((target, $0)) } }
}

struct BackendRoutinesTaskStoreParityRig: Sendable {
    let root: URL, persistence: BackendTaskPersistence, store: BackendTaskStore, config: BackendTaskConfiguration, goals: BackendGoalStore
    let recorder: BackendRoutinesTaskStoreParityRecorder, local: BackendTaskLocalService, detail: BackendTaskDetailService, notices: BackendRoutinesTaskStoreParitySignal
    let engine: BackendTaskEngine, outbox: BackendTaskOutbox, view: BackendTaskStateView, registry: NativeChannelRegistry
    static let key = "k1"
    static let secret = "whsec_" + Data(repeating: 0, count: 32).base64EncodedString()
    static func make(root: URL? = nil, memory: Bool = false,
                     changed: @escaping @Sendable () async -> Void = {},
                     makeKey: (@Sendable (String) async throws -> (id: String, key: String))? = nil,
                     keyViews: (@Sendable () async throws -> [NativeRPCValue])? = nil) async throws -> Self {
        let root = try root ?? routinesTaskScratch()
        let persistence = try BackendTaskPersistence(directory: root, ownership: memory ? .memory : .exclusive)
        if !memory, !FileManager.default.fileExists(atPath: root.appendingPathComponent("task-config.json").path) {
            let connection = routinesTaskObject([("keyId", .string(key)), ("enabled", .bool(false)), ("eventsUrl", .null), ("eventsSecret", .string(secret)),
                ("statuses", BackendTaskConfiguration.defaultStatuses), ("hootIdentity", .null), ("identities", .object([])),
                ("allowedSenders", .array([])), ("folders", .array([])), ("maxHops", .number(3))])
            try persistence.write("task-config.json", value: routinesTaskObject([("v", .number(1)), ("agents", .array([routinesTaskObject([("id", .string("builder")), ("name", .string("Builder"))]), routinesTaskObject([("id", .string("tester")), ("name", .string("Tester"))])])), ("connections", .array([connection]))]))
        }
        let store = BackendTaskStore(persistence: persistence, changed: changed), goals = BackendGoalStore(persistence: persistence, changed: changed)
        let config = try BackendTaskConfiguration(persistence: persistence)
        try await store.start(); try await goals.start(); try await config.start()
        if memory { _ = try await config.saveAgent(routinesTaskObject([("id", .string("builder")), ("name", .string("Builder"))])); _ = try await config.saveAgent(routinesTaskObject([("id", .string("tester")), ("name", .string("Tester"))])) }
        let recorder = BackendRoutinesTaskStoreParityRecorder(store: store), local = BackendTaskLocalService(store: store, configuration: config, goals: goals, engine: recorder)
        let people = BackendTaskDetailPeople(named: { id in routinesTaskObject([("id", .string(id)), ("name", .string(id == "me" ? "Me" : id)), ("initials", .string("M")), ("color", .string("blue"))]) }, known: { ["me", "hoot", "builder", "tester"].contains($0) })
        let notices = BackendRoutinesTaskStoreParitySignal()
        let filePersistence = try BackendTaskPersistence(directory: root.appendingPathComponent("task-files"), ownership: .exclusive)
        let files = BackendTaskAttachments(persistence: filePersistence, authorizeSource: { path in
            let source = URL(fileURLWithPath: path).standardizedFileURL
            guard source.path.hasPrefix(root.path + "/") else { throw NativeRPCError(code: "test-path", message: "Only this disposable fixture's files may be copied") }; return source
        })
        let desktop = BackendTaskDetailDesktop(chooseFiles: { [] }, chooseFolder: { nil }, openPath: { _ in "" })
        let detail = BackendTaskDetailService(store: store, local: local, people: people, notify: { _, _, _ in await notices.hit(); return .init(delivered: true) }, files: files, desktop: desktop, settingsPersistence: persistence, problem: { _ in })
        let access = BackendTaskSessionAccess(readiness: .ready, sessions: { [] },
            start: { _, _, _, _, _ in throw NativeRPCError(code: "fake-session", message: "No process is started by this test fixture") },
            send: { _, _ in }, stop: { _ in }, setControl: { _, _, _ in }, check: { _, _ in (true, "fake check") }, tellHoot: { _ in })
        // Kept inert: current API/channel concrete-engine requirement is a test
        // seam gap. The local service uses the recording protocol implementation.
        let engine = try BackendTaskEngine(store: store, configuration: config, goals: goals, access: access,
            workspace: { $0.project }, outgoing: { _, _ in }, problem: { _ in })
        let outbox = BackendTaskOutbox(persistence: persistence, target: { _ in nil }, post: { _, _ in .init(status: 200, body: "{}") }, onCommentID: { _, _ in }, problem: { _ in })
        let keys = keyViews ?? { [routinesTaskObject([("id", .string(key)), ("name", .string("CRM"))])] }
        let view = BackendTaskStateView(store: store, configuration: config, goals: goals, outbox: outbox, keyViews: keys)
        let registry = NativeChannelRegistry()
        _ = try await BackendTaskChannels.register(registry: registry, ownerID: "parity", view: view, local: local, engine: engine, detail: detail,
            dependencies: .init(keyViews: keys, makeCRMKey: makeKey))
        return .init(root: root, persistence: persistence, store: store, config: config, goals: goals, recorder: recorder, local: local, detail: detail, notices: notices, engine: engine, outbox: outbox, view: view, registry: registry)
    }
    func call(_ channel: String, _ args: [NativeRPCValue] = [], stranger: Bool = false) async throws -> NativeRPCValue {
        try await registry.invoke(channel, context: .init(caller: stranger ? .page : .nativeApp, ownerID: "parity"), arguments: args)
    }
    func task(_ title: String, fields: [(String, NativeRPCValue)] = []) async throws -> BackendTaskRecord {
        try await local.create(routinesTaskObject([("title", .string(title)), ("assignee", .string("me"))] + fields))
    }
    func cleanup() async { await detail.stop(); try? await outbox.stop(); await registry.shutdown(); try? FileManager.default.removeItem(at: root) }
}

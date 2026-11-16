import XCTest
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor CloudSecretsFixtureTaskOwner {
    let store: BackendConnectedTasksMemorySecrets
    init(_ store: BackendConnectedTasksMemorySecrets) { self.store = store }
    func insert(_ id: String, _ token: String) throws -> CloudApplyStatus {
        if let existing = try store.read(id) { return existing == token ? .alreadyPresent : .keptBoth }
        try store.write(id, token: token); return .applied
    }
}
private actor CloudSecretsFixtureSSHOwner {
    var rows: [String: BackendCloudSecretsSSHValue] = [:]
    func read(_ id: String) -> BackendCloudSecretsSSHValue? { rows[id] }
    func merge(_ id: String, _ value: BackendCloudSecretsSSHValue) -> CloudApplyStatus {
        if let existing = rows[id] { return existing == value ? .alreadyPresent : .keptBoth }
        rows[id] = value; return .applied
    }
}
@MainActor
final class CloudSecretsOwnerAdapterTests: XCTestCase {
    var assertions = 0
    override func tearDown() async throws { print("CloudSecretsOwnerAdapterTests assertions=\(assertions)") }
    func check(_ condition: Bool, file: StaticString = #filePath, line: UInt = #line) { assertions += 1; XCTAssertTrue(condition, "Store-owner assertion", file: file, line: line) }
    func testConnectedTaskTokensUseOwnerAndKeepLocalValue() async throws {
        let local = BackendConnectedTasksMemorySecrets(), remote = BackendConnectedTasksMemorySecrets()
        let owner = CloudSecretsFixtureTaskOwner(local), remoteOwner = CloudSecretsFixtureTaskOwner(remote)
        try remote.write("one", token: "remote-fixture-token")
        let source = BackendCloudSecretsTaskStore(sourceId: "tasks", tokens: remote, connectionIds: { ["one"] }, insertIfAbsent: { try await remoteOwner.insert($0, $1) })
        let target = BackendCloudSecretsTaskStore(sourceId: "tasks", tokens: local, connectionIds: { ["one"] }, insertIfAbsent: { try await owner.insert($0, $1) })
        let rows = try await source.capture()
        check(rows.count == 1)
        check(try await target.merge(rows[0]) == .applied)
        check(try await target.verify(rows[0], outcome: .applied))
        try local.write("one", token: "local-fixture-token")
        check(try await target.merge(rows[0]) == .keptBoth)
        check(try local.read("one") == "local-fixture-token")
    }
    func testSSHSelectionsRetainAllKindsWithoutCopyingAHome() async throws {
        let owner = CloudSecretsFixtureSSHOwner()
        let kinds: [BackendCloudSecretsSSHSelection.Kind] = [.configuration, .privateKey, .publicKey, .hostTrust]
        let choices = kinds.enumerated().map { index, kind in BackendCloudSecretsSSHSelection(id: String(index), file: URL(fileURLWithPath: "/fixture/selected/" + String(index)), kind: kind) }
        let adapter = BackendCloudSecretsSSHStore(sourceId: "ssh", selections: { choices }, read: { file in Data(("fixture-" + file.kind.rawValue).utf8) },
            importRecord: { await owner.merge($0, $1) }, readImported: { await owner.read($0) })
        let rows = try await adapter.capture()
        check(rows.count == 4)
        for row in rows {
            check(try await adapter.merge(row) == .applied)
            check(try await adapter.verify(row, outcome: .applied))
            check(try await adapter.merge(row) == .alreadyPresent)
        }
        let changed = try BackendCloudSecretsRecords.record("ssh", "0", .ssh, BackendCloudSecretsSSHValue(kind: .configuration, bytes: Data("different-fixture".utf8)))
        check(try await adapter.merge(changed) == .keptBoth)
    }
    func testMCPRawDefinitionsKeepVariablesAndUnknownSecretFields() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-mcp-" + UUID().uuidString.lowercased()).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = BackendMcpClientConfiguration(home: root.path, environment: [:])
        let definition = NativeRPCValue.object([.init("command", .string("fixture-command")),
            .init("args", .array([.string("${SECRET}")])), .init("env", .object([.init("SECRET", .string("${SECRET}"))])),
            .init("headers", .object([.init("Authorization", .string("fixture-header"))])), .init("unknownFutureField", .string("fixture-private-value"))])
        let raw = NativeRPCValue.object([.init("mcpServers", .object([.init("fixture", definition)])), .init("providerAuth", .string("must-not-export-fixture"))])
        try raw.encodedJSON().write(to: URL(fileURLWithPath: configuration.claudeJSONPath))
        let adapter = try BackendCloudSecretsMCPStore(sourceId: "mcp-user", configuration: configuration, scope: "user", project: nil,
            mergeDefinition: { _, _ in .alreadyPresent })
        let rows = try await adapter.capture()
        check(rows.count == 1)
        check(try CloudSecretsCanonical.encode(CloudValue(rows[0].payload.raw["definition"])) == CloudSecretsCanonical.encode(CloudValue(definition)))
        check(try CloudSecretsCanonical.encode(rows).range(of: Data("must-not-export-fixture".utf8)) == nil)
        check(rows[0].payload.raw["definition"]["args"].elements?.first?.string == "${SECRET}")
        check(try await adapter.verify(rows[0], outcome: .alreadyPresent))
        // Malformed source is an error, never an empty successful inventory.
        try Data("broken fixture".utf8).write(to: URL(fileURLWithPath: configuration.claudeJSONPath))
        do { _ = try await adapter.capture(); check(false) } catch { check(true) }
    }
    func testReceiverSecretsImportOnlyIntoInertEmptyOwner() async throws {
        let sourceStore = BackendRCVStore(persistence: nil, cipher: nil), targetStore = BackendRCVStore(persistence: nil, cipher: nil)
        try await sourceStore.start(); try await targetStore.start()
        _ = try await sourceStore.update { state in state.secrets["fixture"] = .init(secret: "fixture-token", reply: "fixture-reply") }
        let source = BackendCloudSecretsReceiverStore(sourceId: "receiver", store: sourceStore, requireInert: {})
        let target = BackendCloudSecretsReceiverStore(sourceId: "receiver", store: targetStore, requireInert: {})
        let rows = try await source.capture()
        check(try await target.merge(rows[0]) == .applied)
        check(try await target.verify(rows[0], outcome: .applied))
        check(try await target.merge(rows[0]) == .alreadyPresent)
        let blocked = BackendCloudSecretsReceiverStore(sourceId: "receiver", store: targetStore, requireInert: { throw CloudFailure.unavailable })
        do { _ = try await blocked.merge(rows[0]); check(false) } catch { check(true) }
    }
}

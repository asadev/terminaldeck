import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendAppsRecoveryDatabaseTests: XCTestCase, @unchecked Sendable {
    func testCaptureUsesExactExistingAuthenticatedProbeAndSavedIdentity() async throws {
        for kind in ["postgres", "mysql", "redis", "mongodb"] {
            let h = try await harness(kind: kind)
            XCTAssertEqual(h.baseline.kind, kind)
            XCTAssertEqual(h.baseline.authenticatedHealthTest, ["CMD-SHELL", try BackendAppsDataDatabases.authenticatedHealthcheck(kind: kind)])
            XCTAssertEqual(h.baseline.originalID, BackendAppsRecoveryDatabaseFake.originalID)
            let saved = await h.fake.record(), original = try await h.fake.original(scope: h.scope)
            let wrongImage = saved.setting("database", saved["database"].setting("imageId", .string("sha256:" + String(repeating: "e", count: 64))))
            let wrongProbe = original.setting("Config", original["Config"].setting("Healthcheck", .object([.init("Test", .array([.string("CMD-SHELL"), .string("pg_isready")]))])))
            let selfWitness = original.setting("Config", original["Config"].setting("Labels", original["Config"]["Labels"].setting("io.terminaldeck.transaction", .string(h.scope.ownerToken))))
            XCTAssertThrowsError(try BackendAppsRecoveryDatabase.capture(scope: h.scope, originalID: BackendAppsRecoveryDatabaseFake.originalID,
                                                                         record: wrongImage, original: original))
            XCTAssertThrowsError(try BackendAppsRecoveryDatabase.capture(scope: h.scope, originalID: BackendAppsRecoveryDatabaseFake.originalID, record: saved,
                                                                         original: wrongProbe))
            XCTAssertThrowsError(try BackendAppsRecoveryDatabase.capture(scope: h.scope, originalID: BackendAppsRecoveryDatabaseFake.originalID, record: saved, original: selfWitness))
            await h.kernel.finish(h.transaction)
        }
    }

    func testSuccessfulRecoveryQuiescesCandidateBeforeRestoringAuthenticatedOriginal() async throws {
        let h = try await harness()
        await h.fake.beginRestore()
        let recovered = try await recover(h)
        let state = await h.fake.snapshot()
        XCTAssertTrue(recovered)
        XCTAssertTrue(state.original.running && state.original.connected)
        XCTAssertEqual(state.original.health, "healthy")
        XCTAssertEqual(state.original.aliases, BackendAppsRecoveryDatabaseFake.originalAliases)
        XCTAssertFalse(state.candidate.running || state.candidate.connected)
        XCTAssertTrue(state.events.firstIndex(of: "candidate-detached")! < state.events.firstIndex(of: "original-connected")!)
        XCTAssertTrue(state.originalHealthReads > 0)
        assertDataPreserved(state)
        await h.kernel.finish(h.transaction)
    }

    func testNoOpStopIsDetectedAndUsableCandidateRemainsUnchanged() async throws {
        let h = try await harness(mode: .noOpCandidateStop)
        await h.fake.beginRestore()
        let recovered = try await recover(h)
        XCTAssertFalse(recovered)
        let state = await h.fake.snapshot()
        XCTAssertTrue(state.candidate.running && state.candidate.connected)
        XCTAssertEqual(state.candidate.aliases, BackendAppsRecoveryDatabaseFake.candidateAliases)
        XCTAssertFalse(state.events.contains("original-connected"))
        assertDataPreserved(state)
        await h.kernel.finish(h.transaction)
    }

    func testLostCandidateDisconnectReplyReattachesAndRestartsCapturedCandidate() async throws {
        let h = try await harness(mode: .lostCandidateDisconnectReply)
        await h.fake.beginRestore()
        let recovered = try await recover(h)
        XCTAssertFalse(recovered)
        let state = await h.fake.snapshot()
        XCTAssertTrue(state.candidate.running && state.candidate.connected)
        XCTAssertEqual(state.candidate.aliases, BackendAppsRecoveryDatabaseFake.candidateAliases)
        XCTAssertTrue(state.events.contains("candidate-connected"))
        XCTAssertTrue(state.candidateHealthReads > 0)
        assertDataPreserved(state)
        await h.kernel.finish(h.transaction)
    }

    func testCandidateQuiesceFailureNeverChangesAnUntouchedHealthyOriginal() async throws {
        let h = try await harness(mode: .noOpCandidateStop)
        let recovered = try await recover(h)
        let state = await h.fake.snapshot()
        XCTAssertFalse(recovered)
        XCTAssertTrue(state.original.running && state.original.connected)
        XCTAssertEqual(state.original.aliases, BackendAppsRecoveryDatabaseFake.originalAliases)
        XCTAssertFalse(state.events.contains("original-stopped"))
        XCTAssertTrue(state.candidate.running && state.candidate.connected)
        assertDataPreserved(state)
        await h.kernel.finish(h.transaction)
    }

    func testNoOpOriginalNetworkRestoreResumesCapturedCandidate() async throws {
        let h = try await harness(mode: .noOpOriginalConnect)
        await h.fake.beginRestore()
        let recovered = try await recover(h)
        XCTAssertFalse(recovered)
        let state = await h.fake.snapshot()
        XCTAssertTrue(state.candidate.running && state.candidate.connected)
        XCTAssertFalse(state.original.connected)
        XCTAssertEqual(state.candidate.aliases, BackendAppsRecoveryDatabaseFake.candidateAliases)
        assertDataPreserved(state)
        await h.kernel.finish(h.transaction)
    }

    func testLostOriginalStartReplyReturnsFalseAndRestoresCandidateEvenIfOriginalStarted() async throws {
        let h = try await harness(mode: .lostOriginalStartReply)
        await h.fake.beginRestore()
        let recovered = try await recover(h)
        XCTAssertFalse(recovered)
        let state = await h.fake.snapshot()
        XCTAssertTrue(state.candidate.running && state.candidate.connected)
        XCTAssertFalse(state.original.running || state.original.connected)
        XCTAssertTrue(state.events.contains("original-started"))
        XCTAssertTrue(state.events.contains("original-stopped"))
        assertDataPreserved(state)
        await h.kernel.finish(h.transaction)
    }

    func testRunningButFailedAuthenticatedHealthNeverCountsAsOriginalRecovery() async throws {
        let h = try await harness(mode: .originalUnhealthy)
        await h.fake.beginRestore()
        let recovered = try await recover(h)
        XCTAssertFalse(recovered)
        let state = await h.fake.snapshot()
        XCTAssertTrue(state.originalHealthReads > 0)
        XCTAssertTrue(state.candidate.running && state.candidate.connected)
        XCTAssertFalse(state.original.running || state.original.connected)
        XCTAssertEqual(state.candidate.health, "healthy")
        assertDataPreserved(state)
        await h.kernel.finish(h.transaction)
    }

    func testMultipleOrForeignTransactionCandidatesRefuseWithoutMutation() async throws {
        for invalid in [BackendAppsRecoveryDatabaseFake.Mode.multipleCandidates, .foreignCandidate] {
            let h = try await harness(mode: invalid)
            await h.fake.beginRestore()
            let recovered = try await recover(h)
            XCTAssertFalse(recovered)
            let state = await h.fake.snapshot()
            XCTAssertTrue(state.events.isEmpty)
            XCTAssertTrue(state.candidate.running && state.candidate.connected)
            assertDataPreserved(state)
            await h.kernel.finish(h.transaction)
        }
    }

    func testUnverifiedOriginalQuiesceNeverReactivatesCandidateAliases() async throws {
        for mode in [BackendAppsRecoveryDatabaseFake.Mode.noOpOriginalStopAfterHealthFailure, .noOpOriginalDetachAfterHealthFailure] {
            let h = try await harness(mode: mode)
            await h.fake.beginRestore()
            let recovered = try await recover(h)
            let state = await h.fake.snapshot()
            XCTAssertFalse(recovered)
            XCTAssertFalse(state.events.contains("candidate-connected"))
            XCTAssertFalse(state.events.contains("candidate-started"))
            XCTAssertFalse(state.candidate.running || state.candidate.connected)
            assertDataPreserved(state)
            await h.kernel.finish(h.transaction)
        }
    }

    private struct Harness {
        let fake: BackendAppsRecoveryDatabaseFake
        let scope: BackendAppsRecoveryScope
        let baseline: BackendAppsRecoveryDatabaseBaseline
        let kernel: BackendAppsRecovery
        let transaction: BackendAppsRecoveryTransaction
    }
    private func harness(kind: String = "postgres", mode: BackendAppsRecoveryDatabaseFake.Mode = .normal) async throws -> Harness {
        let fake = BackendAppsRecoveryDatabaseFake(kind: kind, mode: mode)
        let kernel = BackendAppsRecovery(capture: { _, _ in
            BackendAppsRecoveryTransport(execute: { _, _, _, _, _ in throw NativeRPCError(code: "fixture", message: "Database helper does not use shell") },
                                         docker: { _, method, path, body in try await fake.request(method, path, body) },
                                         caddy: { _, _, _, _ in .init(status: 404) }, authorizeRegistration: { _ in }, validateBinding: { }, close: { })
        }, audit: { _ in })
        let runtime = BackendAppsRuntime(execute: { _, _, _, _, _ in throw NativeRPCError(code: "fixture", message: "No ordinary transport") }, recovery: kernel)
        let transaction = try await kernel.begin(runtime: runtime, serverID: "fixture", appID: "database")
        await fake.configure(transaction.scope)
        let record = await fake.record(), original = try await fake.original(scope: transaction.scope)
        let baseline = try BackendAppsRecoveryDatabase.capture(scope: transaction.scope, originalID: BackendAppsRecoveryDatabaseFake.originalID, record: record, original: original)
        return .init(fake: fake, scope: transaction.scope, baseline: baseline, kernel: kernel, transaction: transaction)
    }
    private func recover(_ h: Harness) async throws -> Bool {
        try await BackendAppsRecoveryDatabase.recover(scope: h.scope, baseline: h.baseline, docker: { method, path, body in
            try await h.fake.request(method, path, body)
        }, healthAttempts: 2, healthDelayNanoseconds: 0)
    }
    private func assertDataPreserved(_ state: BackendAppsRecoveryDatabaseFake.Snapshot, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(state.volumes, ["original-data", "candidate-data"], file: file, line: line)
        XCTAssertFalse(state.requests.contains { $0.hasPrefix("DELETE ") || $0.contains("/volumes/") && !$0.hasPrefix("GET ") }, file: file, line: line)
        XCTAssertEqual(state.containerIDs, [BackendAppsRecoveryDatabaseFake.originalID, BackendAppsRecoveryDatabaseFake.candidateID], file: file, line: line)
    }
}

private actor BackendAppsRecoveryDatabaseFake {
    enum Mode: Sendable, Equatable { case normal, noOpCandidateStop, lostCandidateDisconnectReply, noOpOriginalConnect, lostOriginalStartReply, originalUnhealthy, multipleCandidates, foreignCandidate, noOpOriginalStopAfterHealthFailure, noOpOriginalDetachAfterHealthFailure }
    struct Node: Sendable { var running: Bool; var connected: Bool; var aliases: [String]; var health: String }
    struct Snapshot: Sendable {
        let original: Node, candidate: Node, events: [String], requests: [String]
        let volumes: Set<String>, containerIDs: Set<String>
        let originalHealthReads: Int, candidateHealthReads: Int
    }
    static let originalID = String(repeating: "a", count: 64), candidateID = String(repeating: "b", count: 64)
    static let imageID = "sha256:" + String(repeating: "d", count: 64)
    static let originalAliases = ["terminaldeck-database", "original-address"]
    static let candidateAliases = ["terminaldeck-database", "candidate-address"]
    let kind: String
    var mode: Mode
    var scope: BackendAppsRecoveryScope?
    var old = Node(running: true, connected: true, aliases: BackendAppsRecoveryDatabaseFake.originalAliases, health: "healthy")
    var next = Node(running: true, connected: true, aliases: BackendAppsRecoveryDatabaseFake.candidateAliases, health: "healthy")
    var events: [String] = [], requests: [String] = []
    var originalHealthReads = 0, candidateHealthReads = 0
    init(kind: String, mode: Mode) { self.kind = kind; self.mode = mode }
    func configure(_ scope: BackendAppsRecoveryScope) { self.scope = scope }
    func beginRestore() { old.running = false; old.connected = false; old.aliases = [] }
    func snapshot() -> Snapshot { .init(original: old, candidate: next, events: events, requests: requests, volumes: ["original-data", "candidate-data"], containerIDs: [Self.originalID, Self.candidateID], originalHealthReads: originalHealthReads, candidateHealthReads: candidateHealthReads) }
    func record() -> NativeRPCValue {
        let path = (try? BackendAppsDatabaseSpec(kind: kind, version: nil).dataPath) ?? "invalid"
        return .object([.init("id", .string("database")), .init("kind", .string(kind)), .init("containerId", .string(Self.originalID)),
                 .init("database", .object([.init("kind", .string(kind)), .init("containerId", .string(Self.originalID)),
                                            .init("imageId", .string(Self.imageID)), .init("network", .string("terminaldeck-apps")),
                                            .init("volumeName", .string("original-data")), .init("dataPath", .string(path))]))])
    }
    func original(scope: BackendAppsRecoveryScope) throws -> NativeRPCValue { try detail(Self.originalID, node: old, scope: scope) }
    func request(_ method: String, _ path: String, _ body: Data?) throws -> BackendAppsHTTPResponse {
        guard let scope else { throw failure() }
        requests.append(method + " " + path)
        if path.hasPrefix("/containers/json?") {
            let row = NativeRPCValue.object([.init("Id", .string(Self.candidateID)), .init("Labels", labels(candidate: true, scope: scope))])
            return try response(.array(mode == .multipleCandidates ? [row, row] : [row]))
        }
        if path.hasPrefix("/volumes/"), method == "GET" {
            let name = String(path.dropFirst("/volumes/".count))
            let storageLabels = labels(candidate: name == "candidate-data", scope: scope)
            return try response(.object([.init("Name", .string(name)), .init("Driver", .string("local")), .init("Labels", storageLabels), .init("Options", .object([]))]))
        }
        if method == "GET", path.hasSuffix("/json") {
            if path.contains(Self.originalID) { if old.running { originalHealthReads += 1 }; return try response(detail(Self.originalID, node: old, scope: scope)) }
            if path.contains(Self.candidateID) { if next.running { candidateHealthReads += 1 }; return try response(detail(Self.candidateID, node: next, scope: scope)) }
        }
        if path.hasPrefix("/networks/"), let body {
            let value = try NativeRPCValue.parseJSON(body), original = value["Container"].string == Self.originalID
            if path.hasSuffix("/disconnect") {
                if original {
                    if mode != .noOpOriginalDetachAfterHealthFailure { old.connected = false; old.aliases = []; events.append("original-detached") }
                }
                else { next.connected = false; next.aliases = []; events.append("candidate-detached"); if mode == .lostCandidateDisconnectReply { mode = .normal; throw failure() } }
            } else {
                let aliases = (value["EndpointConfig"]["Aliases"].elements ?? []).compactMap(\.string)
                if original { if mode != .noOpOriginalConnect { old.connected = true; old.aliases = aliases; events.append("original-connected") } }
                else { next.connected = true; next.aliases = aliases; events.append("candidate-connected") }
            }
            return .init(status: 200)
        }
        if path.hasPrefix("/containers/"), method == "POST" {
            let original = path.contains(Self.originalID), starting = path.hasSuffix("/start")
            if original {
                if starting || mode != .noOpOriginalStopAfterHealthFailure {
                    old.running = starting; events.append(starting ? "original-started" : "original-stopped")
                }
                if starting { old.health = [.originalUnhealthy, .noOpOriginalStopAfterHealthFailure, .noOpOriginalDetachAfterHealthFailure].contains(mode) ? "unhealthy" : "healthy" }
                if starting, mode == .lostOriginalStartReply { mode = .normal; throw failure() }
            } else {
                if !(mode == .noOpCandidateStop && !starting) { next.running = starting; events.append(starting ? "candidate-started" : "candidate-stopped") }
            }
            return .init(status: 204)
        }
        return .init(status: 404)
    }
    private func detail(_ id: String, node: Node, scope: BackendAppsRecoveryScope) throws -> NativeRPCValue {
        let candidate = id == Self.candidateID
        let spec = try BackendAppsDatabaseSpec(kind: kind, version: nil)
        let test = ["CMD-SHELL", try BackendAppsDataDatabases.authenticatedHealthcheck(kind: kind)]
        let network = node.connected ? NativeRPCValue.object([.init(scope.privateNetwork, .object([.init("Aliases", .array(node.aliases.map(NativeRPCValue.string))), .init("IPAddress", .string(candidate ? "172.19.0.3" : "172.19.0.2"))]))]) : .object([])
        return .object([.init("Id", .string(id)), .init("Image", .string(Self.imageID)),
                        .init("Mounts", .array([.object([.init("Type", .string("volume")), .init("Name", .string(candidate ? "candidate-data" : "original-data")), .init("Destination", .string(spec.dataPath)), .init("RW", .bool(true))])])),
                        .init("Config", .object([.init("Labels", labels(candidate: candidate, scope: scope)), .init("Healthcheck", .object([.init("Test", .array(test.map(NativeRPCValue.string)))]))])),
                        .init("State", .object([.init("Running", .bool(node.running)), .init("Restarting", .bool(false)), .init("Health", .object([.init("Status", .string(node.health))]))])),
                        .init("NetworkSettings", .object([.init("Networks", network)]))])
    }
    private func labels(candidate: Bool, scope: BackendAppsRecoveryScope) -> NativeRPCValue {
        var value = NativeRPCValue.object([.init("io.terminaldeck.app", .string(scope.appID)), .init("io.terminaldeck.managed", .string("true"))])
        if candidate { value = value.setting("io.terminaldeck.transaction", .string(mode == .foreignCandidate ? UUID().uuidString : scope.ownerToken)) }
        return value
    }
    private func response(_ value: NativeRPCValue) throws -> BackendAppsHTTPResponse { .init(status: 200, body: try value.encodedJSON()) }
    private func failure() -> NativeRPCError { .init(code: "fixture", message: "A synthetic database response was lost") }
}

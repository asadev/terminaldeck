import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("APE recovery: every Caddy server must prove a candidate is unserved")
struct BackendAppsRecoveryRoutesTests {
    @Test(arguments: ["tcp", "tcp4", "tcp6"])
    func networkPrefixedForeignRouteRetainsCandidate(network: String) async throws {
        let servers = Self.servers(foreign: Self.route(dial: network + "/172.18.0.7:3000"))
        let result = try await exercise(servers: servers)
        #expect(!result.outcome.completed)
        #expect(result.snapshot.deleted.isEmpty && result.snapshot.candidatePresent)
        #expect(result.snapshot.caddyCalls == ["GET /config/apps/http/servers"])
        #expect(result.snapshot.opened == 1 && result.snapshot.closed == 1)
    }

    @Test func foreignServerAndUnmanagedRouteCanKeepOwnedCandidateServing() async throws {
        let servers = Self.servers(foreign: Self.route(dial: "172.18.0.7:8080", id: "outside-the-fleet"))
        let result = try await exercise(servers: servers)
        #expect(!result.outcome.completed)
        #expect(result.snapshot.deleted.isEmpty)
        #expect(result.snapshot.servers == servers)
        #expect(!result.snapshot.caddyCalls.contains { $0.hasPrefix("PATCH") || $0.hasPrefix("DELETE") })
    }

    @Test func dynamicUpstreamsWithoutDialCannotProveCandidateUnused() async throws {
        let dynamic = BackendAppsValidation.object([
            ("@id", .string("foreign-dynamic-route")),
            ("handle", .array([BackendAppsValidation.object([
                ("handler", .string("reverse_proxy")),
                ("dynamic_upstreams", BackendAppsValidation.object([
                    ("source", .string("a")), ("name", .string("app.example.test")), ("port", .string("3000"))
                ]))
            ])]))
        ])
        let result = try await exercise(servers: Self.servers(foreign: dynamic))
        #expect(!result.outcome.completed)
        #expect(result.snapshot.deleted.isEmpty && result.snapshot.candidatePresent)
    }

    @Test(arguments: ["{env.APP_UPSTREAM}:3000", "app.example.test:3000", "udp/172.18.0.7:3000", "unix//tmp/app.sock", "[::1]:3000", "not-an-address"])
    func unresolvedOrUnsupportedDialRetainsCandidate(dial: String) async throws {
        let result = try await exercise(servers: Self.servers(foreign: Self.route(dial: dial)))
        #expect(!result.outcome.completed)
        #expect(result.snapshot.deleted.isEmpty)
    }

    @Test func malformedServersNamespaceIsNotAnUnusedCandidateProof() async throws {
        let malformed: [NativeRPCValue] = [
            .array([]),
            BackendAppsValidation.object([("foreign-server", .string("malformed"))]),
            BackendAppsValidation.object([("foreign-server", BackendAppsValidation.object([("routes", .array([.string("malformed")]))]))])
        ]
        for servers in malformed {
            let result = try await exercise(servers: servers)
            #expect(!result.outcome.completed)
            #expect(result.snapshot.deleted.isEmpty && result.snapshot.candidatePresent)
        }
    }

    @Test func missingCandidatePrivateNamespaceIsNotAnUnusedCandidateProof() async throws {
        let result = try await exercise(servers: .object([]), privateNamespace: "td-test-unrelated-network")
        #expect(!result.outcome.completed)
        #expect(result.snapshot.deleted.isEmpty)
    }

    @Test func unknownCaddyResponseRetainsCandidate() async throws {
        let result = try await exercise(servers: .object([]), caddyStatus: 503)
        #expect(!result.outcome.completed)
        #expect(result.snapshot.deleted.isEmpty && result.snapshot.candidatePresent)
    }

    @Test func distinctNumericForeignUpstreamAllowsOnlyOwnedUnservedDeletion() async throws {
        let servers = Self.servers(foreign: Self.route(dial: "tcp4/172.18.0.99:3000"))
        let result = try await exercise(servers: servers)
        #expect(result.outcome.completed)
        #expect(result.snapshot.deleted == ["td-test-candidate"])
        #expect(!result.snapshot.candidatePresent)
        #expect(result.snapshot.servers == servers)
        #expect(result.snapshot.dockerCalls.last == "DELETE /containers/td-test-candidate?force=true&v=false")
    }

    @Test func revokedOrdinaryReceiptDoesNotBecomeARecoveryIOGrant() async throws {
        let fake = BackendAppsRecoveryRoutesFixture(servers: Self.servers(foreign: Self.route(dial: "172.18.0.99:3000")))
        let context = Self.context()
        await fake.approve(context)
        let kernel = await fake.kernel(), runtime = await fake.runtime(recovery: kernel)
        let transaction = try await NativeCompositionCallContext.$rpc.withValue(context) {
            try await kernel.begin(runtime: runtime, serverID: "td-test-server", appID: "td-test-app")
        }
        await fake.seed(transaction.scope)
        let handle = try await NativeCompositionCallContext.$rpc.withValue(context) {
            try await transaction.register(.removeCreatedContainers)
        }
        await fake.revoke()
        do {
            _ = try await NativeCompositionCallContext.$rpc.withValue(context) { try await runtime.run("td-test-server", "ordinary mutation") }
            Issue.record("Revocation renewed ordinary server authority.")
        } catch { }
        do {
            let outcome = try await transaction.perform(handle)
            await kernel.finish(transaction)
            let snapshot = await fake.snapshot()
            #expect(outcome.completed)
            #expect(snapshot.ordinaryEffects == 0)
            #expect(snapshot.deleted == ["td-test-candidate"])
            #expect(snapshot.closed == 1)
        } catch { await kernel.finish(transaction); throw error }
    }

    private struct Result: Sendable {
        let outcome: BackendAppsRecoveryOutcome
        let snapshot: BackendAppsRecoveryRoutesFixture.Snapshot
    }

    private func exercise(servers: NativeRPCValue, privateNamespace: String = "td-test-apps", caddyStatus: Int = 200) async throws -> Result {
        let fake = BackendAppsRecoveryRoutesFixture(servers: servers, privateNamespace: privateNamespace, caddyStatus: caddyStatus)
        let context = Self.context()
        await fake.approve(context)
        let kernel = await fake.kernel(), runtime = await fake.runtime(recovery: kernel)
        let transaction = try await NativeCompositionCallContext.$rpc.withValue(context) {
            try await kernel.begin(runtime: runtime, serverID: "td-test-server", appID: "td-test-app")
        }
        do {
            await fake.seed(transaction.scope)
            let handle = try await NativeCompositionCallContext.$rpc.withValue(context) {
                try await transaction.register(.removeCreatedContainers)
            }
            let outcome = try await transaction.perform(handle)
            await kernel.finish(transaction)
            return Result(outcome: outcome, snapshot: await fake.snapshot())
        } catch {
            await kernel.finish(transaction)
            throw error
        }
    }

    private static func context() -> NativeRPCContext { .init(caller: .page, ownerID: "td-test-owner", capabilities: ["projects.read"]) }
    private static func servers(foreign: NativeRPCValue) -> NativeRPCValue {
        BackendAppsValidation.object([
            ("terminaldeck", BackendAppsValidation.object([("routes", .array([]))])),
            ("foreign-server", BackendAppsValidation.object([("routes", .array([foreign]))]))
        ])
    }
    private static func route(dial: String, id: String = "foreign-route") -> NativeRPCValue {
        BackendAppsValidation.object([
            ("@id", .string(id)),
            ("handle", .array([BackendAppsValidation.object([
                ("handler", .string("reverse_proxy")),
                ("upstreams", .array([BackendAppsValidation.object([("dial", .string(dial))])]))
            ])]))
        ])
    }
}

/// One semantic Swift server fake: receipt admission is separate from its
/// pinned-generation transport. No command, socket, timer or process runs.
private actor BackendAppsRecoveryRoutesFixture {
    struct Snapshot: Sendable {
        let servers: NativeRPCValue
        let deleted: [String]
        let caddyCalls: [String]
        let dockerCalls: [String]
        let candidatePresent: Bool
        let opened: Int, closed: Int, ordinaryEffects: Int
    }
    private let servers: NativeRPCValue
    private let privateNamespace: String
    private let caddyStatus: Int
    private var accepted: NativeRPCContext?
    private var receiptLive = false
    private var generation = 1
    private var pins: [UUID: Int] = [:]
    private var lockOwner: String?
    private var state = NativeRPCValue.object([])
    private var candidatePresent = true
    private var opened = 0, closed = 0, ordinaryEffects = 0
    private var deleted: [String] = [], caddyCalls: [String] = [], dockerCalls: [String] = []
    private var audits: [BackendAppsRecoveryAudit] = []

    init(servers: NativeRPCValue, privateNamespace: String = "td-test-apps", caddyStatus: Int = 200) {
        self.servers = servers; self.privateNamespace = privateNamespace; self.caddyStatus = caddyStatus
    }
    func approve(_ context: NativeRPCContext) { accepted = context; receiptLive = true }
    func revoke() { receiptLive = false }
    func seed(_ scope: BackendAppsRecoveryScope) {
        lockOwner = scope.ownerToken
        state = BackendAppsValidation.object([
            ("id", .string(scope.appID)), ("name", .string("Test app")), ("kind", .string("app")),
            ("status", .string("stopped")), ("containerId", .null), ("activeDeploymentId", .null), ("deployments", .array([]))
        ])
    }
    func runtime(recovery: BackendAppsRecovery) -> BackendAppsRuntime {
        .init(execute: { server, _, _, _, _ in try await self.ordinary(server) },
              privateNetwork: "td-test-apps", resourcePrefix: "td-test", stateRoot: "/var/lib/td-test-apps", recovery: recovery)
    }
    func kernel() -> BackendAppsRecovery {
        BackendAppsRecovery(capture: { scope, context in try await self.capture(scope, context) },
                            audit: { event in await self.audit(event) }, monotonic: { 100 })
    }
    func snapshot() -> Snapshot {
        .init(servers: servers, deleted: deleted, caddyCalls: caddyCalls, dockerCalls: dockerCalls,
              candidatePresent: candidatePresent, opened: opened, closed: closed, ordinaryEffects: ordinaryEffects)
    }
    private func authorize(_ scope: BackendAppsRecoveryScope, _ context: NativeRPCContext?) throws {
        guard receiptLive, let accepted, let context, context.caller == .page,
              context.ownerID == accepted.ownerID, context.requestID == accepted.requestID,
              scope.ownerID == context.ownerID, scope.requestID == context.requestID,
              scope.serverID == "td-test-server", scope.appID == "td-test-app",
              scope.resourcePrefix == "td-test", scope.stateRoot == "/var/lib/td-test-apps",
              scope.privateNetwork == "td-test-apps" else {
            throw NativeRPCError(code: "access-denied", message: "This fixture has no matching accepted app receipt.")
        }
    }
    private func capture(_ scope: BackendAppsRecoveryScope, _ context: NativeRPCContext?) throws -> BackendAppsRecoveryTransport {
        try authorize(scope, context)
        pins[scope.transactionID] = generation; opened += 1
        return .init(execute: { server, command, _, _, _ in try await self.execute(server, command, scope) },
                     docker: { server, method, path, body in try await self.docker(server, method, path, body, scope) },
                     caddy: { server, method, path, body in try await self.caddy(server, method, path, body, scope) },
                     authorizeRegistration: { context in try await self.authorize(scope, context) },
                     validateBinding: { try await self.pinned(scope.serverID, scope) },
                     close: { await self.close(scope.transactionID) })
    }
    private func pinned(_ server: String, _ scope: BackendAppsRecoveryScope) throws {
        guard server == scope.serverID, pins[scope.transactionID] == generation else {
            throw NativeRPCError(code: "unavailable", message: "The captured fixture server generation ended.")
        }
    }
    private func ordinary(_ server: String) throws -> BackendServersRunResult {
        guard receiptLive, let accepted, let context = NativeCompositionCallContext.rpc,
              server == "td-test-server", context.requestID == accepted.requestID, context.ownerID == accepted.ownerID else {
            throw NativeRPCError(code: "access-denied", message: "Ordinary fixture authority is revoked.")
        }
        ordinaryEffects += 1
        return .init(code: 0, stdout: "")
    }
    private func close(_ id: UUID) { if pins.removeValue(forKey: id) != nil { closed += 1 } }
    private func audit(_ event: BackendAppsRecoveryAudit) { audits.append(event) }
    private func execute(_ server: String, _ command: String, _ scope: BackendAppsRecoveryScope) throws -> BackendServersRunResult {
        try pinned(server, scope)
        if command.contains(scope.appDirectory + "/.lock"), command.contains("/owner") {
            return .init(code: lockOwner == scope.ownerToken ? 0 : 45, stdout: "")
        }
        if command.contains(scope.appDirectory + "/state.json"), command.contains("cat --") {
            return .init(code: 0, stdout: state.compact)
        }
        throw NativeRPCError(code: "unavailable", message: "The fixture rejected an unknown recovery command.")
    }
    private func labels(_ scope: BackendAppsRecoveryScope) -> NativeRPCValue {
        BackendAppsValidation.object([
            ("io.terminaldeck.app", .string(scope.appID)), ("io.terminaldeck.managed", .string("true")),
            ("io.terminaldeck.transaction", .string(scope.ownerToken))
        ])
    }
    private func docker(_ server: String, _ method: String, _ path: String, _ body: Data?, _ scope: BackendAppsRecoveryScope) throws -> BackendAppsHTTPResponse {
        try pinned(server, scope); dockerCalls.append(method + " " + path)
        if method == "GET", path.hasPrefix("/containers/json?all=true&filters=") {
            let rows: [NativeRPCValue] = candidatePresent ? [BackendAppsValidation.object([("Id", .string("td-test-candidate")), ("Labels", labels(scope))])] : []
            return .init(status: 200, body: try NativeRPCValue.array(rows).encodedJSON())
        }
        if method == "GET", path == "/containers/td-test-candidate/json", candidatePresent {
            let value = BackendAppsValidation.object([
                ("Id", .string("td-test-candidate")), ("Config", BackendAppsValidation.object([("Labels", labels(scope))])),
                ("State", BackendAppsValidation.object([("Running", .bool(true))])),
                ("NetworkSettings", BackendAppsValidation.object([("Networks", BackendAppsValidation.object([
                    (privateNamespace, BackendAppsValidation.object([("IPAddress", .string("172.18.0.7")), ("Aliases", .array([.string("td-test-app")]))]))
                ]))]))
            ])
            return .init(status: 200, body: try value.encodedJSON())
        }
        if method == "DELETE", path == "/containers/td-test-candidate?force=true&v=false", body == nil, candidatePresent {
            candidatePresent = false; deleted.append("td-test-candidate")
            return .init(status: 204)
        }
        throw NativeRPCError(code: "unavailable", message: "The fixture rejected an unknown Docker recovery request.")
    }
    private func caddy(_ server: String, _ method: String, _ path: String, _ body: Data?, _ scope: BackendAppsRecoveryScope) throws -> BackendAppsHTTPResponse {
        try pinned(server, scope); caddyCalls.append(method + " " + path)
        guard method == "GET", path == "/config/apps/http/servers", body == nil else {
            throw NativeRPCError(code: "access-denied", message: "Candidate proof cannot mutate a route or inspect only its own route.")
        }
        let data = try servers.encodedJSON()
        return .init(status: caddyStatus, body: caddyStatus == 200 ? data : Data())
    }
}

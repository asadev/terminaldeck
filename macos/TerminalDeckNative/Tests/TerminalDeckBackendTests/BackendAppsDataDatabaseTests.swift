import Foundation
import CryptoKit
@preconcurrency import JavaScriptCore
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("APD database provisioning and resource ownership: in-memory fakes")
struct BackendAppsDataDatabaseTests {
    @Test(arguments: ["postgres", "mysql", "redis", "mongodb"])
    func provisionsAllFourWithAuthenticatedHealthAndProtectedState(kind: String) async throws {
        let fake = BackendAppsDataDatabaseFixture(), runtime = fake.runtime()
        let store = BackendAppsStore(runtime: runtime), service = BackendAppsDataDatabases(runtime: runtime, store: store)
        let result = try await service.create(serverID: "fake-server", appID: "td-test-data", name: "Test data", kind: kind, version: nil)
        #expect(result["status"].string == "running")
        #expect(result["backupPolicy"]["enabled"].bool == false)
        #expect(result["database"] == .missing)
        let state = try await store.read("fake-server", "td-test-data")
        #expect(state["database"]["provisionPhase"].string == "ready")
        #expect(state["database"]["imageId"].string == BackendAppsDataDatabaseFixture.imageID)
        let env = try await store.environment("fake-server", "td-test-data")
        let password = try #require(env.first(where: { $0.key.contains("PASSWORD") })?.value)
        #expect(password.count == 64)
        let connection = try await service.connection(serverID: "fake-server", appID: "td-test-data")
        #expect(connection["host"].string == "td-test-td-test-data")
        #expect(connection["password"].string == "••••••••")
        #expect(connection["scope"].string == "private-network")
        #expect(connection["database"] == (kind == "redis" ? .null : .string("terminaldeck")))
        #expect(!result.compact.contains(password))
        #expect(!connection.compact.contains(password))
        #expect(!state.compact.contains(password))
        let body = try #require(await fake.containerBody)
        #expect(body["Image"].string == BackendAppsDataDatabaseFixture.imageID)
        #expect(body["HostConfig"]["PortBindings"].fields?.isEmpty == true)
        #expect(body["HostConfig"]["NetworkMode"].string == "td-test-apps")
        let health = try #require(body["Healthcheck"]["Test"].elements?.last?.string)
        #expect(health == (try BackendAppsDataDatabases.authenticatedHealthcheck(kind: kind)))
        #expect(!health.contains(password))
        #expect(!(await fake.commands).contains(where: { $0.contains(password) }))
        let events = await fake.events
        let intent = try #require(events.firstIndex(of: "state:planned"))
        let volume = try #require(events.firstIndex(of: "POST:/volumes/create"))
        let serviceCreate = try #require(events.firstIndex(where: { $0.hasPrefix("POST:/containers/create?") }))
        #expect(intent < volume && volume < serviceCreate)
        #expect(!events.contains(where: { $0.hasPrefix("DELETE:") }))
    }

    @Test(arguments: ["existing-volume", "existing-service"])
    func existingSavedResourceIsPreservedWithoutDockerWrites(fault: String) async throws {
        let fake = BackendAppsDataDatabaseFixture(fault: fault), runtime = fake.runtime()
        do {
            _ = try await BackendAppsDataDatabases(runtime: runtime, store: BackendAppsStore(runtime: runtime)).create(serverID: "fake-server", appID: "td-test-data", name: "Test data", kind: "postgres", version: nil)
            Issue.record("Existing saved resource was accepted")
        } catch let error as NativeRPCError { #expect(error.code == "conflict") }
        #expect(!(await fake.events).contains(where: { $0.hasPrefix("POST:") || $0.hasPrefix("DELETE:") }))
        #expect(!(await fake.events).contains(where: { $0.hasPrefix("state:") }))
    }

    @Test func volumeCreationRaceCannotAttachForeignSavedData() async throws {
        let fake = BackendAppsDataDatabaseFixture(fault: "volume-race"), runtime = fake.runtime()
        let store = BackendAppsStore(runtime: runtime)
        do {
            _ = try await BackendAppsDataDatabases(runtime: runtime, store: store).create(serverID: "fake-server", appID: "td-test-data", name: "Test data", kind: "postgres", version: nil)
            Issue.record("A volume created by another action was attached")
        } catch let error as NativeRPCError { #expect(error.code == "conflict") }
        let state = try await store.read("fake-server", "td-test-data")
        #expect(state["status"].string == "failed")
        #expect(state["database"]["provisionPhase"].string == "planned")
        #expect(!(await fake.events).contains(where: { $0.hasPrefix("POST:/containers/create") || $0.hasPrefix("DELETE:") }))
    }

    @Test(arguments: ["foreign-label", "wrong-image", "wrong-mount", "extra-bind", "published-port", "privileged", "extra-network", "volume-driver", "volume-options"])
    func unsafeResourceInspectionPreventsStart(fault: String) async throws {
        let fake = BackendAppsDataDatabaseFixture(fault: fault), runtime = fake.runtime()
        let store = BackendAppsStore(runtime: runtime)
        do {
            _ = try await BackendAppsDataDatabases(runtime: runtime, store: store).create(serverID: "fake-server", appID: "td-test-data", name: "Test data", kind: "postgres", version: nil)
            Issue.record("Unsafe resources were accepted: \(fault)")
        } catch let error as NativeRPCError { #expect(error.code == "conflict") }
        #expect(!(await fake.events).contains(where: { $0.contains("/start") || $0.hasPrefix("DELETE:") }))
        #expect(try await store.read("fake-server", "td-test-data")["status"].string == "failed")
    }

    @Test func startupFailureKeepsSavedDataAndRecordsRecoverableIdentity() async throws {
        let fake = BackendAppsDataDatabaseFixture(fault: "unhealthy"), runtime = fake.runtime()
        let store = BackendAppsStore(runtime: runtime)
        do {
            _ = try await BackendAppsDataDatabases(runtime: runtime, store: store).create(serverID: "fake-server", appID: "td-test-data", name: "Test data", kind: "mysql", version: nil)
            Issue.record("Failed health became running")
        } catch let error as NativeRPCError { #expect(error.code == "health-failed") }
        let state = try await store.read("fake-server", "td-test-data")
        #expect(state["status"].string == "failed")
        #expect(state["database"]["containerId"].string == BackendAppsDataDatabaseFixture.containerID)
        #expect(state["database"]["volumeName"].string == "td-test-td-test-data-data")
        #expect(!(await fake.events).contains(where: { $0.hasPrefix("DELETE:") }))
    }

    @Test(arguments: ["environment-write", "state-commit"])
    func failedProtectedWriteCannotBecomeSuccess(fault: String) async throws {
        let fake = BackendAppsDataDatabaseFixture(fault: fault), runtime = fake.runtime()
        let store = BackendAppsStore(runtime: runtime)
        do {
            _ = try await BackendAppsDataDatabases(runtime: runtime, store: store).create(serverID: "fake-server", appID: "td-test-data", name: "Test data", kind: "postgres", version: nil)
            Issue.record("Failed protected write became a successful setup")
        } catch let error as NativeRPCError {
            #expect(error.code == "state-failed")
            #expect(!error.message.contains("fake-state-secret"))
        }
        let state = try await store.read("fake-server", "td-test-data")
        #expect(state["status"].string == "failed")
        #expect(!(await fake.events).contains(where: { $0.hasPrefix("DELETE:") }))
        if fault == "environment-write" {
            #expect(!(await fake.events).contains(where: { $0.hasPrefix("POST:") }))
        } else {
            #expect(state["database"]["containerId"].string == BackendAppsDataDatabaseFixture.containerID)
        }
    }

    @Test func missingTestImageRefusesUpstreamPull() async throws {
        let fake = BackendAppsDataDatabaseFixture(fault: "missing-image"), runtime = fake.runtime()
        do {
            _ = try await BackendAppsDataDatabases(runtime: runtime, store: BackendAppsStore(runtime: runtime)).create(serverID: "fake-server", appID: "td-test-data", name: "Test data", kind: "redis", version: nil)
            Issue.record("Upstream pull was allowed in the test namespace")
        } catch let error as NativeRPCError { #expect(error.code == "unavailable") }
        #expect(!(await fake.events).contains(where: { $0.hasPrefix("POST:") }))
    }

    @Test func invalidInputAndNamespaceNeverReachServer() async throws {
        let fake = BackendAppsDataDatabaseFixture(), runtime = fake.runtime()
        let service = BackendAppsDataDatabases(runtime: runtime, store: BackendAppsStore(runtime: runtime))
        for (appID, name, kind, version) in [("production", "Test", "postgres", "17"), ("td-test-data\n", "Test", "postgres", "17"), ("td-test-data", "Test\nsecond line", "mysql", "8.4"), ("td-test-data", "Test", "sqlite", "1"), ("td-test-data", "Test", "postgres", "18"), ("td-test-data", "Test", "redis", "7;bad"), ("td-test-data", "Test", "postgres", "17\n")] {
            do {
                _ = try await service.create(serverID: "fake-server", appID: appID, name: name, kind: kind, version: version)
                Issue.record("Invalid provisioning request was accepted")
            } catch let error as NativeRPCError { #expect(["invalid-arguments", "unavailable"].contains(error.code)) }
        }
        #expect((await fake.commands).isEmpty)
        #expect((await fake.events).isEmpty)
    }

    @Test(arguments: ["prefix", "network"])
    func malformedRuntimeNamesNeverReachServer(field: String) async throws {
        let fake = BackendAppsDataDatabaseFixture(), normal = fake.runtime()
        let runtime = BackendAppsRuntime(execute: normal.execute, docker: normal.docker,
                                         privateNetwork: field == "network" ? "td-test-apps\n" : "td-test-apps",
                                         resourcePrefix: field == "prefix" ? "td-test\n" : "td-test", stateRoot: "/var/lib/td-test-apps")
        do {
            _ = try await BackendAppsDataDatabases(runtime: runtime, store: BackendAppsStore(runtime: runtime)).create(serverID: "fake-server", appID: "td-test-data", name: "Test data", kind: "postgres", version: nil)
            Issue.record("A runtime name with a trailing newline was accepted")
        } catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        #expect((await fake.commands).isEmpty)
        #expect((await fake.events).isEmpty)
    }

    @Test(arguments: ["container", "volume", "image"])
    func malformedSavedIdentitiesNeverReachEngine(field: String) async throws {
        let fake = BackendAppsDataDatabaseFixture(), runtime = fake.runtime()
        do {
            _ = try await BackendAppsDataDatabases.inspectOwned(runtime: runtime, serverID: "fake-server", appID: "td-test-data",
                                                              containerID: BackendAppsDataDatabaseFixture.containerID + (field == "container" ? "\n" : ""),
                                                              volumeName: "td-test-td-test-data-data" + (field == "volume" ? "\n" : ""),
                                                              expectedImageID: BackendAppsDataDatabaseFixture.imageID + (field == "image" ? "\n" : ""), kind: "postgres")
            Issue.record("A saved resource identity with a trailing newline was accepted")
        } catch let error as NativeRPCError { #expect(error.code == "state-failed") }
        #expect((await fake.events).isEmpty)
    }

    @Test func unreadableOrThrowingEngineResponsesDoNotExposeSecrets() async throws {
        for fault in ["malformed-image", "transport-secret"] {
            let fake = BackendAppsDataDatabaseFixture(fault: fault), runtime = fake.runtime()
            do {
                _ = try await BackendAppsDataDatabases(runtime: runtime, store: BackendAppsStore(runtime: runtime)).create(serverID: "fake-server", appID: "td-test-data", name: "Test data", kind: "postgres", version: nil)
                Issue.record("Unreadable Engine response became success")
            } catch let error as NativeRPCError {
                #expect(error.code == "unavailable")
                #expect(!error.message.contains("fake-wire-secret"))
            }
        }
    }

    @Test func legacyWeakHealthCannotBecomeTrustedReady() async throws {
        let fake = BackendAppsDataDatabaseFixture(fault: "weak-health"), runtime = fake.runtime()
        do {
            _ = try await BackendAppsDataDatabases(runtime: runtime, store: BackendAppsStore(runtime: runtime)).create(serverID: "fake-server", appID: "td-test-data", name: "Test data", kind: "postgres", version: nil)
            Issue.record("Legacy unauthenticated readiness became trusted")
        } catch let error as NativeRPCError { #expect(error.code == "health-failed") }
    }

    @Test func publicConnectionRejectsTamperedPrivateMetadata() throws {
        let fake = BackendAppsDataDatabaseFixture(), runtime = fake.runtime()
        let record = BackendAppsValidation.object([
            ("id", .string("td-test-data")), ("kind", .string("mongodb")), ("status", .string("running")),
            ("database", BackendAppsValidation.object([("kind", .string("mongodb")), ("network", .string("td-test-apps")), ("port", .number(27017)), ("databaseName", .string("terminaldeck"))]))
        ])
        let connection = try BackendAppsDataDatabases.publicConnection(record, runtime: runtime)
        #expect(connection["authenticationDatabase"].string == "admin")
        #expect(connection["passwordKey"].string == "MONGO_INITDB_ROOT_PASSWORD")
        do {
            _ = try BackendAppsDataDatabases.publicConnection(record.setting("database", record["database"].setting("network", .string("host"))), runtime: runtime)
            Issue.record("Tampered network was exposed as trusted connection help")
        } catch let error as NativeRPCError { #expect(error.code == "state-failed") }
    }

    @Test(arguments: ["1", "{ok:1}", "0", "{ok:0}", "null"])
    func emittedMongoSignInAcceptsOnlyDocumentedSuccessShapes(authResult: String) throws {
        let command = try BackendAppsDataDatabases.authenticatedHealthcheck(kind: "mongodb")
        let start = try #require(command.range(of: "--eval '")), end = try #require(command.range(of: "' >/dev/null", range: start.upperBound..<command.endIndex))
        let script = String(command[start.upperBound..<end.lowerBound])
        let context = try #require(JSContext())
        // Swift fixture evaluates the emitted server expression; no mongosh process or database starts.
        context.evaluateScript("var exitCode=0; var pinged=false; var process={env:{MONGO_INITDB_ROOT_USERNAME:'user',MONGO_INITDB_ROOT_PASSWORD:'fake-password'}}; var db={getSiblingDB:function(){return {auth:function(){return " + authResult + ";}};},adminCommand:function(){pinged=true;return {ok:1};}}; function quit(code){exitCode=code;throw new Error('stopped');}")
        context.evaluateScript(script)
        let succeeds = authResult == "1" || authResult == "{ok:1}"
        #expect(context.objectForKeyedSubscript("exitCode")?.toInt32() == (succeeds ? 0 : 1))
        #expect(context.objectForKeyedSubscript("pinged")?.toBool() == succeeds)
        #expect((context.exception == nil) == succeeds)
    }
}

/// Models only known Store shell requests and Engine JSON. No socket, process or server is used.
actor BackendAppsDataDatabaseFixture {
    static let imageID = "sha256:" + String(repeating: "a", count: 64)
    static let containerID = String(repeating: "b", count: 64)
    private let fault: String
    private var files: [String: Data] = [:]
    private var volume: NativeRPCValue?
    private var started = false
    private var bindingFaultFired = false
    private var recoveryReceipt: NativeRPCContext?
    private var recoveryApps: Set<String> = []
    private var receiptRevoked = false
    private var leases: Set<UUID> = []
    private var lockOwners: [String: String] = [:]
    private var bindingPause: BackendAppsDataDatabaseRecoveryPause?
    private var startPause: BackendAppsDataDatabaseRecoveryPause?
    private(set) var recoveryScopes: [BackendAppsRecoveryScope] = []
    private(set) var recoveryAudits: [BackendAppsRecoveryAudit] = []
    private(set) var closedRecoveryScopes: Set<UUID> = []
    private(set) var containerBody: NativeRPCValue?
    private(set) var commands: [String] = []
    private(set) var events: [String] = []
    init(fault: String = "") { self.fault = fault }
    func savedFile(_ path: String) -> Data? { files[path] }
    func seedFile(_ path: String, contents: Data) { files[path] = contents }
    func replaceRunningEnvironment(_ environment: [String: String]) {
        if let body = containerBody { containerBody = body.setting("Env", .array(environment.keys.sorted().map { .string($0 + "=" + environment[$0]!) })) }
    }
    func approveRecovery(_ context: NativeRPCContext, apps: Set<String>) { recoveryReceipt = context; recoveryApps = apps; receiptRevoked = false }
    func revokeRecoveryReceipt() { receiptRevoked = true }
    func pauseBindingAtEnvironmentWrite(_ pause: BackendAppsDataDatabaseRecoveryPause) { bindingPause = pause }
    func pauseProvisioningAtStart(_ pause: BackendAppsDataDatabaseRecoveryPause) { startPause = pause }
    func heldLocks() -> [String: String] { lockOwners }
    nonisolated func recoveryKernel() -> BackendAppsRecovery {
        BackendAppsRecovery(capture: { [self] scope, context in try await captureRecovery(scope, context: context) },
                            audit: { [self] event in await recordRecoveryAudit(event) })
    }
    nonisolated func runtime(recovery: BackendAppsRecovery? = nil) -> BackendAppsRuntime {
        BackendAppsRuntime(execute: { [self] _, command, stdin, _, _ in try await execute(command, stdin: stdin) },
                           docker: { [self] _, method, path, body in try await docker(method, path: path, body: body) },
                           privateNetwork: "td-test-apps", resourcePrefix: "td-test", stateRoot: "/var/lib/td-test-apps",
                           recovery: recovery,
                           now: { 1_797_000_000_000 })
    }
    private func authorizeOrdinary(_ context: NativeRPCContext?) throws {
        guard let accepted = recoveryReceipt else { return }
        guard !receiptRevoked, let context, context.ownerID == accepted.ownerID, context.requestID == accepted.requestID,
              context.caller == accepted.caller, accepted.capabilities.contains("apps.write"), context.capabilities.contains("apps.write") else {
            throw NativeRPCError(code: "access-denied", message: "The fake original write receipt expired.")
        }
    }
    private func authorizeRecovery(_ scope: BackendAppsRecoveryScope, context: NativeRPCContext?) throws {
        guard recoveryReceipt != nil else { throw NativeRPCError(code: "access-denied", message: "No fake approved recovery receipt") }
        try authorizeOrdinary(context)
        guard let context, scope.serverID == "fake-server", recoveryApps.contains(scope.appID),
              scope.ownerID == context.ownerID, scope.requestID == context.requestID,
              scope.stateRoot == "/var/lib/td-test-apps", scope.resourcePrefix == "td-test", scope.privateNetwork == "td-test-apps" else {
            throw NativeRPCError(code: "access-denied", message: "The fake receipt does not approve this server/app pair.")
        }
    }
    private func captureRecovery(_ scope: BackendAppsRecoveryScope, context: NativeRPCContext?) throws -> BackendAppsRecoveryTransport {
        try authorizeRecovery(scope, context: context)
        leases.insert(scope.transactionID); recoveryScopes.append(scope)
        return .init(execute: { [self] server, command, input, _, _ in
            try await validatePinned(scope, server: server)
            return try await execute(command, stdin: input, pinned: scope)
        }, docker: { [self] server, method, path, body in
            try await validatePinned(scope, server: server)
            return try await docker(method, path: path, body: body, pinned: scope)
        }, caddy: { _, _, _, _ in .init(status: 404) },
        authorizeRegistration: { [self] context in try await authorizeRecovery(scope, context: context) },
        validateBinding: { [self] in try await validatePinned(scope, server: scope.serverID) },
        close: { [self] in await closeRecovery(scope.transactionID) })
    }
    private func validatePinned(_ scope: BackendAppsRecoveryScope, server: String) throws {
        guard server == scope.serverID, leases.contains(scope.transactionID) else { throw NativeRPCError(code: "access-denied", message: "The fake pinned server is unavailable.") }
    }
    private func closeRecovery(_ id: UUID) { if leases.remove(id) != nil { closedRecoveryScopes.insert(id) } }
    private func recordRecoveryAudit(_ event: BackendAppsRecoveryAudit) { recoveryAudits.append(event) }
    private func execute(_ command: String, stdin: Data?, pinned: BackendAppsRecoveryScope? = nil) async throws -> BackendServersRunResult {
        if pinned == nil { try authorizeOrdinary(NativeCompositionCallContext.rpc) }
        commands.append(command)
        guard command.hasPrefix("sh -c '"), command.hasSuffix("'") else { throw NativeRPCError(code: "fake-unexpected", message: "Unexpected fake command") }
        let script = String(command.dropFirst(7).dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        if let pinned, script.contains("/.lock"), script.contains("/owner") {
            let lock = pinned.appDirectory + "/.lock"
            if script.contains("rmdir --"), lockOwners[lock] == nil { return .init(code: 0, stdout: "") }
            guard lockOwners[lock] == pinned.ownerToken else { return .init(code: 1, stdout: "") }
            if script.contains("rmdir --") { lockOwners[lock] = nil }
            return .init(code: 0, stdout: "")
        }
        if let path = Self.capture(#"sha256sum -- '([^']+)'"#, in: script), let data = files[path] {
            return .init(code: 0, stdout: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + "\n")
        }
        if let stdin, let target = Self.capture(#"(?:^|;|\n)\s*mv -f -- '[^']+' '([^']+)'"#, in: script) {
            if fault == "environment-write", target.hasSuffix("/.env") { return .init(code: 45, stdout: "", stderr: "fake-state-secret") }
            if fault == "state-commit", target.hasSuffix("/state.json"),
               let value = try? NativeRPCValue.parseJSON(stdin), value["status"].string == "running" {
                return .init(code: 45, stdout: "", stderr: "fake-state-secret")
            }
            if target.contains("/td-test-above/"), target.hasSuffix("/.env") {
                let text = String(decoding: stdin, as: UTF8.self)
                if ["binding-env-once", "binding-env-uncertain", "binding-recovery-failed", "binding-recovery-denied"].contains(fault), !bindingFaultFired, text.contains("://") {
                    bindingFaultFired = true
                    if fault != "binding-env-once" { files[target] = stdin }
                    return .init(code: 45, stdout: "", stderr: "fake-binding-secret")
                }
                if ["binding-recovery-failed", "binding-recovery-denied"].contains(fault), bindingFaultFired { return .init(code: 45, stdout: "", stderr: "fake-binding-secret") }
            }
            if fault == "binding-recovery-denied", bindingFaultFired, target.contains("/td-test-above/") { return .init(code: 45, stdout: "", stderr: "fake-binding-secret") }
            if fault == "binding-record-once", !bindingFaultFired, target.contains("/td-test-above/"), target.hasSuffix("/state.json"),
               let value = try? NativeRPCValue.parseJSON(stdin), value["updatedAt"].number == 1_797_000_000_000 {
                bindingFaultFired = true; files[target] = stdin
                return .init(code: 45, stdout: "", stderr: "fake-binding-secret")
            }
            files[target] = stdin
            if pinned == nil, target.hasSuffix("/.env"), String(decoding: stdin, as: UTF8.self).contains("://"), let pause = bindingPause {
                bindingPause = nil; await pause.pause(); try Task.checkCancellation()
            }
            if target.hasSuffix("/state.json"), let state = try? NativeRPCValue.parseJSON(stdin) {
                events.append("state:" + (state["database"]["provisionPhase"].string ?? "unknown"))
            }
            return .init(code: 0, stdout: "")
        }
        if let path = Self.capture(#"cat -- '([^']+)'$"#, in: script), stdin == nil {
            guard let data = files[path] else { return .init(code: 44, stdout: "") }
            return .init(code: 0, stdout: String(decoding: data, as: UTF8.self))
        }
        if script.contains("rm -- "), script.contains("/data-binding-intent.json'") {
            let paths = files.keys.filter { script.contains("'" + $0 + "'") && ($0.contains("/.data-binding-") || $0.hasSuffix("/data-binding-intent.json")) }
            for path in paths { files[path] = nil }
            return .init(code: 0, stdout: "")
        }
        if script.contains("rm -f --"), let path = Self.capture(#"rm -f -- '([^']+)'"#, in: script) {
            files[path] = nil; return .init(code: 0, stdout: "")
        }
        if script.contains("mkdir -- ") && script.contains("/.lock'") {
            if let path = Self.capture(#"mkdir -- '([^']+/\.lock)'"#, in: script) {
                if lockOwners[path] != nil { return .init(code: 73, stdout: "") }
                if let stdin { lockOwners[path] = String(decoding: stdin, as: UTF8.self) }
                events.append("lock:" + path)
            }
            return .init(code: 0, stdout: "")
        }
        if script.contains("rmdir -- ") && script.contains("/.lock'"), let path = Self.capture(#"rmdir -- '([^']+/\.lock)'"#, in: script) { lockOwners[path] = nil; return .init(code: 0, stdout: "") }
        throw NativeRPCError(code: "fake-unexpected", message: "Unexpected fake state command")
    }
    private func docker(_ method: String, path: String, body: Data?, pinned: BackendAppsRecoveryScope? = nil) async throws -> BackendAppsHTTPResponse {
        if pinned == nil { try authorizeOrdinary(NativeCompositionCallContext.rpc) }
        events.append(method + ":" + path)
        if fault == "transport-secret" { throw NativeRPCError(code: "wire-failed", message: "fake-wire-secret") }
        let value = try body.map { try NativeRPCValue.parseJSON($0) }
        if method == "GET", path.hasPrefix("/images/") {
            if fault == "missing-image" { return .init(status: 404) }
            if fault == "malformed-image" { return .init(status: 200, body: Data("fake-wire-secret not JSON".utf8)) }
            return try response(200, BackendAppsValidation.object([("Id", .string(Self.imageID))]))
        }
        if method == "GET", path.hasPrefix("/volumes/") {
            if let volume { return try response(200, volume) }
            return .init(status: fault == "existing-volume" ? 200 : 404)
        }
        if method == "POST", path == "/volumes/create", var value {
            if fault == "volume-race" { value = value.setting("Labels", value["Labels"].setting("io.terminaldeck.provision", .string("other-owner"))) }
            if fault == "volume-driver" { value = value.setting("Driver", .string("nfs")) }
            if fault == "volume-options" { value = value.setting("Options", BackendAppsValidation.object([("device", .string("/host/data"))])) }
            volume = value
            return try response(201, value)
        }
        if method == "GET", path.hasPrefix("/networks/") {
            return try response(200, BackendAppsValidation.object([
                ("Name", .string("td-test-apps")), ("Driver", .string("bridge")), ("Ingress", .bool(false)),
                ("Labels", BackendAppsValidation.object([("io.terminaldeck.managed", .string("true"))]))
            ]))
        }
        if method == "GET", path == "/containers/td-test-td-test-data/json" { return .init(status: fault == "existing-service" ? 200 : 404) }
        if method == "POST", path.hasPrefix("/containers/create?"), let value {
            containerBody = value
            return try response(201, BackendAppsValidation.object([("Id", .string(Self.containerID))]))
        }
        if method == "POST", path == "/containers/\(Self.containerID)/start" {
            started = true
            if pinned == nil, let pause = startPause { startPause = nil; await pause.pause(); try Task.checkCancellation() }
            return .init(status: 204)
        }
        if method == "GET", path == "/containers/\(Self.containerID)/json", let body = containerBody {
            var labels = body["Labels"], host = body["HostConfig"].setting("Privileged", .bool(false)).setting("PublishAllPorts", .bool(false)), health = body["Healthcheck"]
            var networks = BackendAppsValidation.object([("td-test-apps", BackendAppsValidation.object([("Aliases", .array([.string("td-test-td-test-data")]))]))])
            let sourceMount = try #require(body["HostConfig"]["Mounts"].elements?.first)
            var mounts = [BackendAppsValidation.object([
                ("Type", .string("volume")), ("Name", sourceMount["Source"]), ("Destination", sourceMount["Target"]), ("RW", .bool(true))
            ])]
            if fault == "foreign-label" { labels = labels.setting("io.terminaldeck.app", .string("different-app")) }
            if fault == "wrong-mount" { mounts[0] = mounts[0].setting("Name", .string("foreign-volume")) }
            if fault == "extra-bind" { mounts.append(BackendAppsValidation.object([("Type", .string("bind")), ("Source", .string("/etc")), ("Destination", .string("/host")), ("RW", .bool(true))])) }
            if fault == "privileged" { host = host.setting("Privileged", .bool(true)) }
            if fault == "published-port" { host = host.setting("PortBindings", BackendAppsValidation.object([("5432/tcp", .array([BackendAppsValidation.object([("HostPort", .string("5432"))])]))])) }
            if fault == "extra-network" { networks = networks.setting("public", .object([])) }
            if fault == "weak-health" { health = health.setting("Test", .array([.string("CMD-SHELL"), .string("pg_isready")])) }
            return try response(200, BackendAppsValidation.object([
                ("Id", .string(Self.containerID)), ("Image", .string(fault == "wrong-image" ? "sha256:" + String(repeating: "c", count: 64) : Self.imageID)),
                ("Config", BackendAppsValidation.object([("Labels", labels), ("Healthcheck", health), ("Env", body["Env"])])),
                ("HostConfig", host), ("Mounts", .array(mounts)),
                ("NetworkSettings", BackendAppsValidation.object([("Networks", networks), ("Ports", .object([]))])),
                ("State", BackendAppsValidation.object([("Running", .bool(started)), ("Restarting", .bool(false)), ("Health", BackendAppsValidation.object([("Status", .string(fault == "unhealthy" ? "unhealthy" : "healthy"))]))]))
            ]))
        }
        throw NativeRPCError(code: "fake-unexpected", message: "Unexpected fake Engine request")
    }
    private func response(_ status: Int, _ value: NativeRPCValue) throws -> BackendAppsHTTPResponse {
        .init(status: status, body: try value.encodedJSON())
    }
    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// Shared pause is colocated with its fixture so serial SwiftPM source discovery cannot split the dependency.
actor BackendAppsDataDatabaseRecoveryPause {
    private var entered = false
    private var ended = false
    private var readers: [CheckedContinuation<Bool, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; let waiting = readers; readers.removeAll(); waiting.forEach { $0.resume(returning: true) }
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async -> Bool { if entered { return true }; if ended { return false }; return await withCheckedContinuation { readers.append($0) } }
    func finished() { ended = true; let waiting = readers; readers.removeAll(); waiting.forEach { $0.resume(returning: false) } }
    func release() { continuation?.resume(); continuation = nil }
}

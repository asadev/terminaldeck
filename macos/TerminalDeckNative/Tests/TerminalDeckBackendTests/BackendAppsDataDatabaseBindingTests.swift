import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("APD protected database binding: same-server fakes")
struct BackendAppsDataDatabaseBindingTests {
    @Test(arguments: ["postgres", "mysql", "redis", "mongodb"])
    func bindsAllFourWithoutExposingSecretsOrDeploying(kind: String) async throws {
        let setup = try await fixture(kind: kind)
        let result = try await BackendAppsDataDatabaseBinding(runtime: setup.runtime, store: setup.store)
            .bind(serverID: "fake-server", appID: "td-test-data", targetAppID: "td-test-above", key: nil)
        let expectedKey = kind == "redis" ? "REDIS_URL" : "DATABASE_URL"
        #expect(result == BackendAppsValidation.object([
            ("bound", .bool(true)), ("appId", .string("td-test-data")), ("targetAppId", .string("td-test-above")),
            ("key", .string(expectedKey)), ("value", .string("••••••••")), ("secret", .bool(true)), ("requiresDeploy", .bool(true))
        ]))
        let environment = try await setup.store.environment("fake-server", "td-test-above")
        #expect(environment["UNRELATED"] == "keep-me")
        let uri = try #require(environment[expectedKey])
        let sourceEnvironment = try await setup.store.environment("fake-server", "td-test-data")
        let password = try #require(sourceEnvironment.first(where: { $0.key.contains("PASSWORD") })?.value)
        #expect(uri.contains(password))
        #expect(uri.contains("@td-test-td-test-data:"))
        #expect(!result.compact.contains(password))
        #expect(!result.compact.contains(uri))
        if kind == "mongodb" { #expect(uri.hasSuffix("/terminaldeck?authSource=admin")) }
        if kind == "redis" { #expect(uri.hasPrefix("redis://default:") && uri.hasSuffix("/0")) }
        let record = try await setup.store.read("fake-server", "td-test-above")
        #expect(record["envKeys"].elements?.contains(.string(expectedKey)) == true)
        #expect(record["updatedAt"].number == 1_797_000_000_000)
        #expect(!record.compact.contains(password))
        #expect(await setup.fake.savedFile("/var/lib/td-test-apps/td-test-above/data-binding-intent.json") == nil)
        let events = Array((await setup.fake.events).dropFirst(setup.priorEvents))
        let locks = events.filter { $0.hasPrefix("lock:") }
        #expect(locks == ["lock:/var/lib/td-test-apps/td-test-above/.lock", "lock:/var/lib/td-test-apps/td-test-data/.lock"])
        #expect(events.filter { $0.hasPrefix("GET:") || $0.hasPrefix("POST:") || $0.hasPrefix("DELETE:") }.allSatisfy { $0.hasPrefix("GET:") })
        #expect(!(await setup.fake.commands).contains(where: { $0.contains(password) || $0.contains(uri) }))
    }

    @Test func percentEncodesProtectedCredentialsRatherThanChangingURIFields() async throws {
        let setup = try await fixture(kind: "postgres")
        let original = try await setup.store.environment("fake-server", "td-test-data")
        let password = "p@ss:/?#%+ ü"
        // The fixture's running Env follows its create body. Change both protected and inspected input deliberately.
        await setup.fake.replaceRunningEnvironment(original.merging(["POSTGRES_PASSWORD": password]) { _, new in new })
        try await setup.store.applyEnvironment("fake-server", "td-test-data", original.merging(["POSTGRES_PASSWORD": password]) { _, new in new })
        let result = try await BackendAppsDataDatabaseBinding(runtime: setup.runtime, store: setup.store)
            .bind(serverID: "fake-server", appID: "td-test-data", targetAppID: "td-test-above", key: "APP_DATABASE")
        let uri = try #require(try await setup.store.environment("fake-server", "td-test-above")["APP_DATABASE"])
        #expect(uri.contains("p%40ss%3A%2F%3F%23%25%2B%20%C3%BC"))
        #expect(!uri.contains(password))
        #expect(result["key"].string == "APP_DATABASE")
        #expect(!result.compact.contains("%40"))
    }

    @Test(arguments: ["binding-env-once", "binding-env-uncertain", "binding-record-once"])
    func uncertainSettingWriteRestoresBothSettingsAndSummary(fault: String) async throws {
        let setup = try await fixture(kind: "postgres", fault: fault)
        let beforeEnvironment = try await setup.store.environment("fake-server", "td-test-above")
        let beforeRecord = try await setup.store.read("fake-server", "td-test-above")
        do {
            _ = try await BackendAppsDataDatabaseBinding(runtime: setup.runtime, store: setup.store)
                .bind(serverID: "fake-server", appID: "td-test-data", targetAppID: "td-test-above", key: nil)
            Issue.record("Uncertain protected write became success")
        } catch let error as NativeRPCError {
            #expect(error.code == "state-failed")
            #expect(error.message.contains("previous settings were restored"))
            #expect(!error.message.contains("fake-binding-secret"))
        }
        #expect(try await setup.store.environment("fake-server", "td-test-above") == beforeEnvironment)
        #expect(try await setup.store.read("fake-server", "td-test-above") == beforeRecord)
        #expect(await setup.fake.savedFile("/var/lib/td-test-apps/td-test-above/data-binding-intent.json") == nil)
    }

    @Test func failedCompensationPreservesProtectedRecoverySnapshots() async throws {
        let setup = try await fixture(kind: "postgres", fault: "binding-recovery-failed")
        do {
            _ = try await BackendAppsDataDatabaseBinding(runtime: setup.runtime, store: setup.store)
                .bind(serverID: "fake-server", appID: "td-test-data", targetAppID: "td-test-above", key: nil)
            Issue.record("Failed compensation became success")
        } catch let error as NativeRPCError {
            #expect(error.code == "state-failed")
            #expect(error.message.contains("needs recovery"))
            #expect(!error.message.contains("fake-binding-secret"))
        }
        let bytes = try #require(await setup.fake.savedFile("/var/lib/td-test-apps/td-test-above/data-binding-intent.json"))
        let intent = try NativeRPCValue.parseJSON(bytes)
        #expect(intent["phase"].string == "recovery-required")
        let envPath = try #require(intent["environmentSnapshot"].string)
        #expect(await setup.fake.savedFile(envPath) != nil)
        #expect(!intent.compact.contains("postgresql://"))
        do {
            _ = try await BackendAppsDataDatabaseBinding(runtime: setup.runtime, store: setup.store)
                .bind(serverID: "fake-server", appID: "td-test-data", targetAppID: "td-test-above", key: nil)
            Issue.record("Recovery note did not prevent another bind")
        } catch let error as NativeRPCError { #expect(error.code == "conflict") }
    }

    @Test func changedProtectedPasswordCannotBindStaleCredentials() async throws {
        let setup = try await fixture(kind: "postgres")
        var env = try await setup.store.environment("fake-server", "td-test-data")
        env["POSTGRES_PASSWORD"] = "different-password"
        try await setup.store.applyEnvironment("fake-server", "td-test-data", env)
        do {
            _ = try await BackendAppsDataDatabaseBinding(runtime: setup.runtime, store: setup.store)
                .bind(serverID: "fake-server", appID: "td-test-data", targetAppID: "td-test-above", key: nil)
            Issue.record("Stale saved credentials were bound")
        } catch let error as NativeRPCError {
            #expect(error.code == "conflict")
            #expect(!error.message.contains("different-password"))
        }
        #expect(try await setup.store.environment("fake-server", "td-test-above") == ["UNRELATED": "keep-me"])
    }

    @Test func deniedRecoveryDoesNotClaimPreviousSettingsWereRestored() async throws {
        let setup = try await fixture(kind: "postgres", fault: "binding-recovery-denied")
        do {
            _ = try await BackendAppsDataDatabaseBinding(runtime: setup.runtime, store: setup.store)
                .bind(serverID: "fake-server", appID: "td-test-data", targetAppID: "td-test-above", key: nil)
            Issue.record("Denied recovery became success")
        } catch let error as NativeRPCError {
            #expect(error.code == "state-failed")
            #expect(error.message.contains("needs recovery"))
            #expect(!error.message.contains("previous settings were restored"))
        }
        let bytes = try #require(await setup.fake.savedFile("/var/lib/td-test-apps/td-test-above/data-binding-intent.json"))
        let intent = try NativeRPCValue.parseJSON(bytes)
        #expect(intent["phase"].string == "binding")
        let snapshot = try #require(intent["environmentSnapshot"].string)
        #expect(await setup.fake.savedFile(snapshot) != nil)
    }

    @Test func invalidBindingArgumentsNeverReachServer() async throws {
        let fake = BackendAppsDataDatabaseFixture(), runtime = fake.runtime()
        let binding = BackendAppsDataDatabaseBinding(runtime: runtime, store: BackendAppsStore(runtime: runtime))
        for (source, target, key) in [("td-test-data", "td-test-data", "DATABASE_URL"), ("td-test-data", "td-test-above", "••••••••"), ("td-test-data", "td-test-above", "DATABASE_URL\n"), ("td-test-data", "production", "DATABASE_URL")] {
            do {
                _ = try await binding.bind(serverID: "fake-server", appID: source, targetAppID: target, key: key)
                Issue.record("Invalid binding was accepted")
            } catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        }
        #expect((await fake.commands).isEmpty)
        #expect((await fake.events).isEmpty)
    }

    @Test(arguments: ["kind", "pending", "recovery"])
    func ineligibleTargetIsRefusedBeforeSecretsOrDockerAreRead(reason: String) async throws {
        let setup = try await fixture(kind: "postgres")
        let target = try await setup.store.read("fake-server", "td-test-above")
        if reason == "kind" { try await setup.store.write("fake-server", "td-test-above", target.setting("kind", .string("postgres"))) }
        if reason == "pending" { try await setup.store.write("fake-server", "td-test-above", target.setting("pendingDeploymentId", .string("pending-change"))) }
        if reason == "recovery" {
            try await setup.store.writeFile("fake-server", path: "/var/lib/td-test-apps/td-test-above/data-binding-intent.json", contents: Data("{}".utf8))
        }
        let before = await setup.fake.events.count
        do {
            _ = try await BackendAppsDataDatabaseBinding(runtime: setup.runtime, store: setup.store)
                .bind(serverID: "fake-server", appID: "td-test-data", targetAppID: "td-test-above", key: nil)
            Issue.record("Ineligible target was bound")
        } catch let error as NativeRPCError { #expect(error.code == "conflict") }
        #expect(Array((await setup.fake.events).dropFirst(before)).allSatisfy { $0.hasPrefix("lock:") })
        #expect(try await setup.store.environment("fake-server", "td-test-above") == ["UNRELATED": "keep-me"])
    }

    @Test func boundURICredentialsAreAvailableToExistingLogRedaction() {
        let uri = "postgresql://terminaldeck:p%40ss%25@td-test-td-test-data:5432/terminaldeck"
        let secrets = BackendAppsDataDatabaseBinding.redactionSecrets(in: ["DATABASE_URL": uri, "OTHER": "unchanged-value"])
        #expect(secrets.contains(uri))
        #expect(secrets.contains("p@ss%"))
        #expect(secrets.contains("p%40ss%25"))
        let log = BackendAppsValidation.mask("Connection failed for password p@ss%; encoded p%40ss%25; uri " + uri, secrets: secrets)
        #expect(!log.contains("p@ss%") && !log.contains("p%40ss%25") && !log.contains(uri))
        let combined = BackendAppsDataDatabaseBinding.redactionSecrets(values: ["mysql://root:new-secret@private:3306/terminaldeck", uri])
        #expect(combined.contains("new-secret") && combined.contains("p@ss%"))
    }

    private func fixture(kind: String, fault: String = "") async throws -> (fake: BackendAppsDataDatabaseFixture, runtime: BackendAppsRuntime, store: BackendAppsStore, priorEvents: Int) {
        let fake = BackendAppsDataDatabaseFixture(fault: fault), runtime = fake.runtime()
        let store = BackendAppsStore(runtime: runtime)
        _ = try await BackendAppsDataDatabases(runtime: runtime, store: store).create(serverID: "fake-server", appID: "td-test-data", name: "Test data", kind: kind, version: nil)
        let target = BackendAppsValidation.object([
            ("id", .string("td-test-above")), ("name", .string("Website")), ("kind", .string("app")),
            ("status", .string("stopped")), ("source", BackendAppsValidation.object([("kind", .string("github")), ("repository", .string("owner/repo"))])),
            ("envKeys", .array([.string("UNRELATED")])), ("updatedAt", .number(1))
        ])
        try await store.applyEnvironment("fake-server", "td-test-above", ["UNRELATED": "keep-me"])
        try await store.write("fake-server", "td-test-above", target)
        return (fake, runtime, store, await fake.events.count)
    }
}

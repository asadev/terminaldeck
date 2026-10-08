import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("APE backup safety: Swift fakes, no servers")
struct BackendAppsBackupsTests {
    private func seeded(_ fixture: BackendAppsDatabaseFixture) async throws -> (BackendAppsRuntime, BackendAppsStore) {
        let runtime = fixture.runtime(), store = BackendAppsStore(runtime: runtime)
        let dir = try BackendAppsStore.directory("td-test-data")
        try await fixture.seed(dir + "/state.json", BackendAppsDatabaseFixture.app())
        try await fixture.seed(dir + "/backups/td-test-backup/manifest.json", BackendAppsDatabaseFixture.manifest())
        await fixture.seedEnvironment(dir + "/.env", "POSTGRES_USER=terminaldeck\nPOSTGRES_PASSWORD=fake-database-password\nPOSTGRES_DB=terminaldeck\n")
        return (runtime, store)
    }

    @Test func restoreRequiresExactNameBeforeDockerMutation() async throws {
        let fake = BackendAppsDatabaseFixture(), (runtime, store) = try await seeded(fake)
        do {
            _ = try await BackendAppsBackups(runtime: runtime, store: store).restore(serverID: "fake-server", appID: "td-test-data", backupID: "td-test-backup", confirmation: "test data")
            Issue.record("Restore accepted a different name")
        } catch let error as NativeRPCError { #expect(error.code == "confirmation-required") }
        #expect((await fake.apiCalls).isEmpty)
        #expect(!(await fake.commands).contains(where: { $0.contains("sha256sum") }))
    }

    @Test func corruptBackupDoesNotStopOriginalDatabase() async throws {
        let fake = BackendAppsDatabaseFixture(), (runtime, store) = try await seeded(fake)
        await fake.setChecksumFailure(true)
        do {
            _ = try await BackendAppsBackups(runtime: runtime, store: store).restore(serverID: "fake-server", appID: "td-test-data", backupID: "td-test-backup", confirmation: "Test data")
            Issue.record("Corrupt backup became a successful restore")
        } catch let error as NativeRPCError { #expect(error.code == "restore-failed") }
        #expect((await fake.apiCalls).isEmpty)
    }

    @Test func successfulRestorePreservesOriginalVolumeAndRecordsRecovery() async throws {
        let fake = BackendAppsDatabaseFixture(), (runtime, store) = try await seeded(fake)
        let result = try await BackendAppsBackups(runtime: runtime, store: store).restore(serverID: "fake-server", appID: "td-test-data", backupID: "td-test-backup", confirmation: "Test data")
        #expect(result["restored"].bool == true)
        #expect(result["recoveryPreserved"].bool == true)
        let stored = try await store.read("fake-server", "td-test-data")
        #expect(stored["database"]["containerId"].string == BackendAppsDatabaseFixture.candidateID)
        #expect(stored["databaseRecovery"].elements?.first?["volumeName"].string == "td-test-original")
        #expect(!(await fake.apiCalls).contains(where: { $0.method == "DELETE" }))
        #expect(!(await fake.commands).contains(where: { $0.contains("fake-database-password") }))
    }

    @Test func restoreFailureRestartsOriginalAndPreservesBothVolumes() async throws {
        let fake = BackendAppsDatabaseFixture(), (runtime, store) = try await seeded(fake)
        await fake.setRestoreFailure(true)
        do {
            _ = try await BackendAppsBackups(runtime: runtime, store: store).restore(serverID: "fake-server", appID: "td-test-data", backupID: "td-test-backup", confirmation: "Test data")
            Issue.record("Failed data restore returned success")
        } catch let error as NativeRPCError { #expect(error.code == "restore-failed") }
        let calls = await fake.apiCalls
        #expect(calls.contains(where: { $0.path == "/containers/\(BackendAppsDatabaseFixture.sourceID)/start" }))
        #expect(!calls.contains(where: { $0.method == "DELETE" }))
        let record = try await store.read("fake-server", "td-test-data")
        #expect(record["containerId"].string == BackendAppsDatabaseFixture.sourceID)
        #expect(record["databaseRecovery"].elements?.last?["reason"].string == "failed-restore")
    }

    @Test func unavailableBackupToolsReturnClearFailure() async throws {
        let fake = BackendAppsDatabaseFixture(), (runtime, store) = try await seeded(fake)
        await fake.setDependenciesUnavailable(true)
        do {
            _ = try await BackendAppsBackups(runtime: runtime, store: store).create(serverID: "fake-server", appID: "td-test-data")
            Issue.record("Missing backup tools returned success")
        } catch let error as NativeRPCError {
            #expect(error.code == "unavailable")
            #expect(!error.message.contains("fake-secret"))
        }
        #expect((await fake.apiCalls).isEmpty)
    }

    @Test func uploadCredentialsStayInProtectedFileAndOutOfCommandsAndPolicy() async throws {
        let fake = BackendAppsDatabaseFixture(), (runtime, store) = try await seeded(fake)
        let request = BackendAppsValidation.object([("schedule", .string("daily")), ("retention", .number(7)), ("upload", BackendAppsValidation.object([("endpoint", .string("https://s3.example.invalid")), ("bucket", .string("td-test-backups")), ("accessKey", .string("fake-access-key")), ("secretKey", .string("fake-secret-key"))]))])
        let result = try await BackendAppsBackups(runtime: runtime, store: store).policy(serverID: "fake-server", appID: "td-test-data", request: request)
        #expect(result["enabled"].bool == true)
        #expect(result["upload"]["accessKey"] == .missing)
        #expect(result["upload"]["secretKey"] == .missing)
        #expect(!(await fake.commands).contains(where: { $0.contains("fake-access-key") || $0.contains("fake-secret-key") }))
        let path = try BackendAppsStore.directory("td-test-data") + "/.backup-s3-credentials"
        let files = await fake.files
        #expect(String(decoding: try #require(files[path]), as: UTF8.self).contains("fake-secret-key"))
    }

    @Test func disablingPolicyStopsOnlyItsOwnTimer() async throws {
        let fake = BackendAppsDatabaseFixture(), (runtime, store) = try await seeded(fake)
        let result = try await BackendAppsBackups(runtime: runtime, store: store).policy(serverID: "fake-server", appID: "td-test-data", request: BackendAppsValidation.object([("enabled", .bool(false))]))
        #expect(result["enabled"].bool == false)
        let commands = await fake.commands
        #expect(commands.contains(where: { $0.contains("systemctl disable --now") && $0.contains("td-test-td-test-data-backup.timer") }))
        #expect(!commands.contains(where: { $0.contains("docker stop") || $0.contains("rm -rf") }))
    }

    @Test func invalidPolicyCannotReachServer() async throws {
        let fake = BackendAppsDatabaseFixture()
        let runtime = fake.runtime()
        do {
            _ = try await BackendAppsBackups(runtime: runtime, store: BackendAppsStore(runtime: runtime)).policy(serverID: "fake-server", appID: "td-test-data", request: BackendAppsValidation.object([("schedule", .string("daily\nExecStart=/tmp/nope")), ("retention", .number(0))]))
            Issue.record("Invalid policy was accepted")
        } catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        #expect((await fake.commands).isEmpty)
    }

    @Test func serverRunnerPublishesBeforeRetentionAndDoesNotSourceSecrets() throws {
        let script = BackendAppsBackups.runner(directory: "/var/lib/terminaldeck/apps/td-test-data", appID: "td-test-data", prefix: "td-test")
        #expect(script.contains("mkdir \"$dir/.lock\""))
        #expect(script.contains("umask 077"))
        #expect(!script.contains("source "))
        #expect(!script.contains(". \"$dir/.env\""))
        #expect(script.contains("AWS_SHARED_CREDENTIALS_FILE="))
        #expect(!script.contains("--password"))
        let publication = try #require(script.range(of: "mv \"$work\" \"$dir/backups/$id\""))
        let retention = try #require(script.range(of: "# Retention runs only"))
        #expect(publication.lowerBound < retention.lowerBound)
        #expect(script.contains("head-object"))
        #expect(script.contains(".Metadata.sha256"))
        #expect(script.contains("trap 'exit 130'"))
    }
}

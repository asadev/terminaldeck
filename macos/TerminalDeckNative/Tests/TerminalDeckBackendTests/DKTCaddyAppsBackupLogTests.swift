import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("DKT registered Apps backup, settings and log lifetime contracts")
struct DKTCaddyAppsBackupLogTests {
    @Test("confirmed restore verifies bytes, restores a separate volume, and retains original recovery data", arguments: DKTAppsDataRegistrar.allCases)
    func confirmedRestore(registrar: DKTAppsDataRegistrar) async throws {
        let fixture = try await DKTAppsBackupFixture.make(registrar: registrar)
        defer { fixture.stop() }
        let result = try await fixture.restore()
        #expect(result["restored"].bool == true)
        #expect(result["recoveryPreserved"].bool == true)
        let state = try await fixture.store.read(DKTAppsFixtures.serverID, DKTAppsFixtures.appID)
        #expect(state["containerId"].string != fixture.originalContainerID)
        #expect(state["databaseRecovery"].elements?.first?["volumeName"].string == DKTAppsFixtures.originalDatabaseVolumeName)
        #expect(state["databaseRecovery"].elements?.first?["reason"].string == "before-restore")
        let events = await fixture.files.boundaryEvents
        let verified = try #require(events.firstIndex(of: "backup-verified"))
        let stopped = try #require(events.firstIndex(of: "docker:POST /containers/" + fixture.originalContainerID + "/stop?t=30"))
        #expect(verified < stopped)
        let create = try #require(fixture.docker.requests.first { $0.path == "/containers/create" })
        let candidate = try NativeRPCValue.parseJSON(create.body)
        #expect(candidate["HostConfig"]["PortBindings"].fields?.isEmpty == true)
        #expect(candidate["HostConfig"]["Mounts"].elements?.first?["Source"].string != DKTAppsFixtures.originalDatabaseVolumeName)
        #expect(candidate["Image"].string == DKTAppsFixtures.databaseImageID)
        #expect(fixture.docker.requests.allSatisfy { $0.method != "DELETE" })
        let originalVolume = try DKTUnixHTTPClient.request(socketPath: fixture.docker.socketPath, target: "/volumes/" + DKTAppsFixtures.originalDatabaseVolumeName)
        #expect(originalVolume.statusCode == 200)
        #expect(await fixture.files.lockPaths().isEmpty)
        #expect(await fixture.files.unsupportedCommands.isEmpty)
    }

    @Test("restore wrong name and damaged checksum fail before database mutation", arguments: DKTAppsDataRegistrar.allCases)
    func refusedRestore(registrar: DKTAppsDataRegistrar) async throws {
        let fixture = try await DKTAppsBackupFixture.make(registrar: registrar)
        defer { fixture.stop() }
        do { _ = try await fixture.restore(confirmation: "wrong name"); Issue.record("wrong restore confirmation was accepted") }
        catch let error as NativeRPCError { #expect(error.code == "confirmation-required") }
        #expect(fixture.docker.requests.isEmpty)
        let directory = try fixture.store.directory(DKTAppsFixtures.appID)
        await fixture.files.seed(path: directory + "/backups/" + DKTAppsFixtures.backupID + "/data", data: Data("corrupt synthetic bytes".utf8))
        do { _ = try await fixture.restore(); Issue.record("damaged backup was restored") }
        catch let error as NativeRPCError { #expect(error.code == "restore-failed") }
        #expect(fixture.docker.requests.isEmpty)
        #expect(try await fixture.store.read(DKTAppsFixtures.serverID, DKTAppsFixtures.appID) == fixture.originalRecord)
        #expect(await fixture.files.lockPaths().isEmpty)
    }

    @Test("failed restore command restarts original database and preserves both volumes", arguments: DKTAppsDataRegistrar.allCases)
    func failedRestorePreservesData(registrar: DKTAppsDataRegistrar) async throws {
        let fixture = try await DKTAppsBackupFixture.make(restoreCode: 1, registrar: registrar)
        defer { fixture.stop() }
        do { _ = try await fixture.restore(); Issue.record("failed restore command returned success") }
        catch let error as NativeRPCError {
            #expect(error.code == "restore-failed")
            #expect(!error.message.contains(DKTAppsFixtures.dummyPassword))
        }
        let state = try await fixture.store.read(DKTAppsFixtures.serverID, DKTAppsFixtures.appID)
        #expect(state["containerId"].string == fixture.originalContainerID)
        #expect(state["database"]["volumeName"].string == DKTAppsFixtures.originalDatabaseVolumeName)
        if registrar == .appsData {
            // The sealed APD path restores the exact captured state rather
            // than writing new recovery rows after caller authority expires.
            #expect(state == fixture.originalRecord)
            let audit = await fixture.files.recoveryAudit
            #expect(audit.contains { $0.operation == "recover-owned-database-pair" && $0.successful == true })
            let journal = try fixture.store.directory(DKTAppsFixtures.appID) + "/data-restore-intent.json"
            #expect(await fixture.files.contents(path: journal) == nil)
        } else {
            #expect(state["databaseRecovery"].elements?.first?["reason"].string == "failed-restore")
        }
        let original = try DKTUnixHTTPClient.request(socketPath: fixture.docker.socketPath,
                                                     target: "/containers/" + fixture.originalContainerID + "/json")
        #expect(try NativeRPCValue.parseJSON(original.body)["State"]["Running"].bool == true)
        #expect(fixture.docker.requests.allSatisfy { $0.method != "DELETE" })
        #expect(await fixture.files.lockPaths().isEmpty)
    }

    @Test("failed restore state save reconnects and restarts original database", arguments: DKTAppsDataRegistrar.allCases)
    func failedRestoreStateCommit(registrar: DKTAppsDataRegistrar) async throws {
        let fixture = try await DKTAppsBackupFixture.make(registrar: registrar)
        defer { fixture.stop() }
        let path = try fixture.store.directory(DKTAppsFixtures.appID) + "/state.json"
        await fixture.files.failNextWrite(path: path)
        do { _ = try await fixture.restore(); Issue.record("failed restore state commit returned success") }
        catch let error as NativeRPCError { #expect(error.code == "restore-failed") }
        let state = try await fixture.store.read(DKTAppsFixtures.serverID, DKTAppsFixtures.appID)
        #expect(state["database"]["containerId"].string == fixture.originalContainerID)
        #expect(state["database"]["volumeName"].string == DKTAppsFixtures.originalDatabaseVolumeName)
        #expect(fixture.docker.requests.contains { $0.method == "POST" && $0.path == "/containers/" + fixture.originalContainerID + "/start" })
        #expect(fixture.docker.requests.allSatisfy { $0.method != "DELETE" })
        #expect(await fixture.files.lockPaths().isEmpty)
    }

    @Test("failed backup reports backup-failed and retains earlier synthetic backup bytes", arguments: DKTAppsDataRegistrar.allCases)
    func failedBackupDoesNotClaimSuccess(registrar: DKTAppsDataRegistrar) async throws {
        let fixture = try await DKTAppsBackupFixture.make(registrar: registrar)
        defer { fixture.stop() }
        await fixture.files.replyToScript(containing: "backup-run.sh' --already-locked", code: 1,
                                           stderr: DKTAppsFixtures.dummyPassword)
        do {
            _ = try await fixture.invoke("apps:backups:create", request: identity())
            Issue.record("failed backup returned success")
        } catch let error as NativeRPCError {
            #expect(error.code == "backup-failed")
            #expect(!error.message.contains(DKTAppsFixtures.dummyPassword))
        }
        let path = try fixture.store.directory(DKTAppsFixtures.appID) + "/backups/" + DKTAppsFixtures.backupID + "/data"
        #expect(await fixture.files.contents(path: path) == fixture.backupData)
        #expect(fixture.docker.requests.allSatisfy { $0.method == "GET" })
        #expect(await fixture.files.lockPaths().isEmpty)
        #expect(await fixture.files.unsupportedCommands.isEmpty)
    }

    @Test("generated server backup runner verifies and publishes before retention can delete")
    func retentionAfterVerifiedPublication() throws {
        let script = BackendAppsBackups.runner(directory: try BackendAppsStore.directory(DKTAppsFixtures.appID),
                                               appID: DKTAppsFixtures.appID, prefix: "td-test")
        let dumpVerified = try #require(script.range(of: "pg_restore --list"))
        let dataChecksum = try #require(script.range(of: "sum=$(sha256sum"))
        let uploadVerified = try #require(script.range(of: ".ContentLength"))
        let published = try #require(script.range(of: "mv \"$work\" \"$dir/backups/$id\""))
        let retention = try #require(script.range(of: ".[$keep:][] | .id"))
        let removeOld = try #require(script.range(of: "rm -rf -- \"$dir/backups/$old\""))
        #expect(dumpVerified.lowerBound < dataChecksum.lowerBound)
        #expect(dataChecksum.lowerBound < published.lowerBound && uploadVerified.lowerBound < published.lowerBound)
        #expect(published.lowerBound < retention.lowerBound && retention.lowerBound < removeOld.lowerBound)
        #expect(script.contains("set -eu"))
        #expect(script.contains("test \"$old\" != \"$id\" || continue"))
        #expect(script.contains(".verified == true and .appId == $app and .kind == $kind"))
    }

    @Test("env patch preserves hidden values, removes requested keys and refuses masked replacements")
    func patchEnvironment() async throws {
        let files = DKTAppsServerFiles()
        let path = try BackendAppsStore.directory(DKTAppsFixtures.appID)
        await files.seed(path: path + "/state.json", data: try DKTAppsFixtures.appRecord().encodedJSON())
        await files.seed(path: path + "/.env", data: Data(("API_TOKEN=" + DKTAppsFixtures.dummySecret + "\nOLD_KEY=old\n").utf8))
        let service = BackendAppsChannels(runtime: files.runtime(), authorize: { _, _ in })
        let registry = NativeChannelRegistry()
        try await BackendAppsChannels.register(registry: registry, service: service, ownerID: "dkt-apps")
        let request = identity().setting("set", BackendAppsValidation.object([("NEW_KEY", .string("synthetic-new"))]))
            .setting("remove", .array([.string("OLD_KEY")]))
        let result = try await registry.invoke("apps:env:patch", context: context(), arguments: [request])
        #expect(result.elements?.map { $0["key"].string } == ["API_TOKEN", "NEW_KEY"])
        #expect(result.elements?.allSatisfy { $0["value"].string == "••••••••" } == true)
        let environment = try await BackendAppsStore(runtime: files.runtime()).environment(DKTAppsFixtures.serverID, DKTAppsFixtures.appID)
        #expect(environment == ["API_TOKEN": DKTAppsFixtures.dummySecret, "NEW_KEY": "synthetic-new"])
        do {
            _ = try await registry.invoke("apps:env:patch", context: context(), arguments: [identity().setting("set", BackendAppsValidation.object([("API_TOKEN", .string("••••••••"))]))])
            Issue.record("masked placeholder overwrote a real hidden setting")
        } catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        #expect(try await BackendAppsStore(runtime: files.runtime()).environment(DKTAppsFixtures.serverID, DKTAppsFixtures.appID) == environment)
    }

    @Test("failed env patch state save restores the previous protected environment")
    func patchEnvironmentCompensates() async throws {
        let files = DKTAppsServerFiles()
        let path = try BackendAppsStore.directory(DKTAppsFixtures.appID)
        await files.seed(path: path + "/state.json", data: try DKTAppsFixtures.appRecord().encodedJSON())
        let old = Data(("API_TOKEN=" + DKTAppsFixtures.dummySecret + "\n").utf8)
        await files.seed(path: path + "/.env", data: old)
        await files.failNextWrite(path: path + "/state.json")
        let service = BackendAppsChannels(runtime: files.runtime(), authorize: { _, _ in })
        do {
            _ = try await service.invoke("apps:env:patch", request: identity().setting("set", BackendAppsValidation.object([("API_TOKEN", .string("replacement"))])), context: context())
            Issue.record("failed settings state save returned success")
        } catch let error as NativeRPCError { #expect(error.code == "state-failed") }
        #expect(await files.contents(path: path + "/.env") == old)
        #expect(await files.lockPaths().isEmpty)
    }

    @Test("backup policy read and disable use saved state and only the owned managed timer", arguments: DKTAppsDataRegistrar.allCases)
    func readAndDisableBackupPolicy(registrar: DKTAppsDataRegistrar) async throws {
        let fixture = try await DKTAppsBackupFixture.make(registrar: registrar)
        defer { fixture.stop() }
        let files = fixture.files
        let path = try fixture.store.directory(DKTAppsFixtures.appID)
        await files.seed(path: path + "/state.json", data: try fixture.originalRecord
            .setting("backupPolicy", BackendAppsValidation.object([("enabled", .bool(true)), ("schedule", .string("daily")), ("retention", .number(7))])).encodedJSON())
        await files.replyToScript(containing: "systemctl disable --now")
        let old = try await fixture.invoke("apps:backups:policy:read", request: identity())
        #expect(old["enabled"].bool == true)
        let result = try await fixture.invoke("apps:backups:policy", request: identity().setting("enabled", .bool(false)))
        #expect(result["enabled"].bool == false)
        let after = try await fixture.invoke("apps:backups:policy:read", request: identity())
        #expect(after["enabled"].bool == false)
        let requests = await files.invocations
        let disable = try #require(requests.first { $0.script.contains("systemctl disable --now") })
        #expect(disable.script.contains("# Terminal Deck managed backup for " + DKTAppsFixtures.appID))
        let unit = "td-test-" + DKTAppsFixtures.appID + "-backup"
        #expect(disable.script.contains(unit + ".timer") || disable.script.contains("unit='" + unit + "'"))
        #expect(await files.unsupportedCommands.isEmpty)
    }

    @Test("split log secrets are masked before owner output and unwatch cancels only the owner's stream")
    func logOwnerAndSplitSecrets() async throws {
        let files = DKTAppsServerFiles()
        let logs = DKTAppsLogSource()
        let events = DKTAppsEventRecorder()
        let docker = DKTDockerFake()
        docker.seedContainer(id: DKTAppsFixtures.databaseContainerID, name: "td-test-logs", labels: ["io.terminaldeck.app": DKTAppsFixtures.appID, "io.terminaldeck.managed": "true"])
        let path = try BackendAppsStore.directory(DKTAppsFixtures.appID)
        await files.seed(path: path + "/state.json", data: try DKTAppsFixtures.appRecord().setting("containerId", .string(DKTAppsFixtures.databaseContainerID)).encodedJSON())
        await files.seed(path: path + "/.env", data: Data(("API_TOKEN=" + DKTAppsFixtures.dummySecret + "\n").utf8))
        let service = BackendAppsChannels(runtime: files.runtime(docker: docker, logSource: logs), publish: { channel, value, owner in
            await events.record(channel: channel, value: value, owner: owner)
        })
        #expect(await logs.watchCount == 0)
        let watch = identity().setting("streamId", .string("dkt-stream"))
        _ = try await service.invoke("apps:logs:watch", request: watch, context: context())
        let split = DKTAppsFixtures.dummySecret.index(DKTAppsFixtures.dummySecret.startIndex, offsetBy: 12)
        await logs.send(String(DKTAppsFixtures.dummySecret[..<split]))
        #expect(await events.events.isEmpty)
        await logs.send(String(DKTAppsFixtures.dummySecret[split...]) + "\n")
        let output = await events.events
        #expect(output.count == 1)
        #expect(output.first?.owner == "dkt-owner")
        #expect(output.first?.channel == "apps:logs")
        #expect(output.first?.value["text"].string == "[redacted]\n")
        do {
            _ = try await service.invoke("apps:logs:unwatch", request: watch, context: context(owner: "other-owner"))
            Issue.record("another owner stopped this log stream")
        } catch let error as NativeRPCError { #expect(error.code == "access-denied") }
        #expect(await logs.listenerCount == 1)
        _ = try await service.invoke("apps:logs:unwatch", request: watch, context: context())
        #expect(await logs.listenerCount == 0)
        #expect(await logs.cancellationCount == 1)
        await service.shutdown()
        #expect(await logs.cancellationCount == 1)
    }

    @Test("owner disconnect cancels all its log transports while another window keeps streaming")
    func disconnectLogOwner() async throws {
        let files = DKTAppsServerFiles()
        let logs = DKTAppsLogSource()
        let docker = DKTDockerFake()
        docker.seedContainer(id: DKTAppsFixtures.databaseContainerID, name: "td-test-logs", labels: ["io.terminaldeck.app": DKTAppsFixtures.appID, "io.terminaldeck.managed": "true"])
        let path = try BackendAppsStore.directory(DKTAppsFixtures.appID)
        await files.seed(path: path + "/state.json", data: try DKTAppsFixtures.appRecord().setting("containerId", .string(DKTAppsFixtures.databaseContainerID)).encodedJSON())
        let service = BackendAppsChannels(runtime: files.runtime(docker: docker, logSource: logs), publish: { _, _, _ in })
        _ = try await service.invoke("apps:logs:watch", request: identity().setting("streamId", .string("dkt-first")), context: context())
        _ = try await service.invoke("apps:logs:watch", request: identity().setting("streamId", .string("dkt-second")), context: context())
        _ = try await service.invoke("apps:logs:watch", request: identity().setting("streamId", .string("dkt-other")), context: context(owner: "other-owner"))
        #expect(await logs.listenerCount == 3)
        await service.disconnect(ownerID: "dkt-owner")
        #expect(await logs.listenerCount == 1)
        #expect(await logs.cancellationCount == 2)
        await service.shutdown()
        #expect(await logs.listenerCount == 0)
        #expect(await logs.cancellationCount == 3)
    }

    @Test("log EOF flushes an incomplete masked line and cancels the transport")
    func logEOF() async throws {
        let files = DKTAppsServerFiles(), logs = DKTAppsLogSource(), events = DKTAppsEventRecorder()
        let docker = DKTDockerFake()
        docker.seedContainer(id: DKTAppsFixtures.databaseContainerID, name: "td-test-logs",
                             environment: ["API_TOKEN": DKTAppsFixtures.dummySecret],
                             labels: ["io.terminaldeck.app": DKTAppsFixtures.appID, "io.terminaldeck.managed": "true"])
        let path = try BackendAppsStore.directory(DKTAppsFixtures.appID)
        await files.seed(path: path + "/state.json", data: try DKTAppsFixtures.appRecord()
            .setting("containerId", .string(DKTAppsFixtures.databaseContainerID)).encodedJSON())
        let service = BackendAppsChannels(runtime: files.runtime(docker: docker, logSource: logs), publish: { channel, value, owner in
            await events.record(channel: channel, value: value, owner: owner)
        })
        _ = try await service.invoke("apps:logs:watch", request: identity().setting("streamId", .string("dkt-eof")), context: context())
        await logs.send(DKTAppsFixtures.dummySecret)
        #expect(await events.events.isEmpty)
        await logs.finish()
        try await logs.waitForCancellationCount(1)
        let output = await events.events
        #expect(output.map(\.channel) == ["apps:logs", "apps:logs:end"])
        #expect(output.first?.value["text"].string == "[redacted]")
        #expect(output.last?.value["reason"].string == "eof")
        #expect(await logs.listenerCount == 0)
        #expect(await logs.cancellationCount == 1)
    }

    private func identity() -> NativeRPCValue {
        BackendAppsValidation.object([("serverId", .string(DKTAppsFixtures.serverID)), ("appId", .string(DKTAppsFixtures.appID))])
    }
    private func context(owner: String = "dkt-owner") -> NativeRPCContext {
        .init(caller: .nativeApp, ownerID: owner, capabilities: ["apps.read", "apps.write"])
    }
}

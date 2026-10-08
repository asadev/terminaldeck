import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// APD's new registrar is exercised independently of inherited APE handlers.
@Suite("DKT APD data contract safety")
struct DKTAppsDataContractTests {
    @Test("all APD writes require owner approval before server I/O", arguments: BackendAppsDataChannels.writeChannels.sorted())
    func defaultDenial(channel: String) async throws {
        let files = DKTAppsServerFiles()
        let captures = DKTDataApprovalTrace()
        let service = BackendAppsDataChannels(runtime: approvalReadyRuntime(files: files, captures: captures))
        do {
            _ = try await service.invoke(channel, request: request(channel), context: context())
            Issue.record("APD write bypassed the default approval gate.")
        } catch let error as NativeRPCError { #expect(error.code == "approval-required") }
        #expect(await files.invocations.isEmpty)
        #expect(await captures.count == 0)
    }

    @Test("unavailable recovery refuses every data write before approval or server I/O", arguments: BackendAppsDataChannels.writeChannels.sorted())
    func unavailableBeforeApproval(channel: String) async throws {
        let files = DKTAppsServerFiles()
        let approvals = DKTDataApprovalTrace()
        let service = BackendAppsDataChannels(runtime: files.runtime(), authorize: { _, _ in await approvals.add() })
        do {
            _ = try await service.invoke(channel, request: request(channel), context: context())
            Issue.record("Unavailable APD recovery accepted a write.")
        } catch let error as NativeRPCError { #expect(error.code == "unavailable") }
        #expect(await approvals.count == 0)
        #expect(await files.invocations.isEmpty)
    }

    @Test("forged approvals, duplicate fields and payload namespaces fail before approval or I/O")
    func closedPayloads() async throws {
        let files = DKTAppsServerFiles()
        let calls = DKTDataApprovalTrace()
        let service = BackendAppsDataChannels(runtime: files.runtime(), authorize: { _, _ in await calls.add() })
        let base = request("apps:backups:create")
        for forged in [base.setting("approved", .bool(true)), base.setting("stateRoot", .string("/etc")),
                       base.setting("host", .string("terminaldeck-store")),
                       .object((base.fields ?? []) + [.init("appId", .string("other"))])] {
            do { _ = try await service.invoke("apps:backups:create", request: forged, context: context()); Issue.record("Forged APD payload accepted.") }
            catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        }
        #expect(await files.invocations.isEmpty)
        #expect(await calls.count == 0)
    }

    @Test("a read-only caller cannot restore or create a database")
    func readOnlyCaller() async throws {
        let files = DKTAppsServerFiles()
        let calls = DKTDataApprovalTrace()
        let service = BackendAppsDataChannels(runtime: files.runtime(), authorize: { _, _ in await calls.add() })
        for channel in ["apps:databases:create", "apps:backups:restore"] {
            do { _ = try await service.invoke(channel, request: request(channel), context: context(readOnly: true)); Issue.record("Read-only data caller wrote.") }
            catch let error as NativeRPCError { #expect(error.code == "access-denied") }
        }
        #expect(await calls.count == 0)
        #expect(await files.invocations.isEmpty)
    }

    @Test("restore requires a named confirmation even before the approval adapter")
    func unnamedRestore() async throws {
        let files = DKTAppsServerFiles()
        let calls = DKTDataApprovalTrace()
        let service = BackendAppsDataChannels(runtime: files.runtime(), authorize: { _, _ in await calls.add() })
        let fields = (request("apps:backups:restore").fields ?? []).filter { $0.key != "confirmation" }
        do { _ = try await service.invoke("apps:backups:restore", request: .object(fields), context: context()); Issue.record("Unnamed restore accepted.") }
        catch let error as NativeRPCError { #expect(error.code == "confirmation-required") }
        #expect(await calls.count == 0)
        #expect(await files.invocations.isEmpty)
    }

    @Test("duplicate APD registration rolls back only the new registrar handlers")
    func duplicateRegistration() async throws {
        let files = DKTAppsServerFiles()
        let service = BackendAppsDataChannels(runtime: files.runtime())
        let registry = NativeChannelRegistry()
        try await registry.register("apps:templates:deploy", ownerID: "preserved") { _, _ in .string("preserved") }
        do { try await BackendAppsDataChannels.register(registry: registry, service: service, ownerID: "data"); Issue.record("Duplicate handler silently replaced.") }
        catch {}
        #expect(await registry.channels() == ["apps:templates:deploy"])
        #expect(try await registry.invoke("apps:templates:deploy", context: context(), arguments: []) == .string("preserved"))
        #expect(await files.invocations.isEmpty)
        await registry.shutdown()
    }

    @Test("database coordinates stay private and passwords stay masked", arguments: ["postgres", "mysql", "redis", "mongodb"])
    func connectionPrivacy(kind: String) throws {
        let runtime = DKTAppsServerFiles().runtime(privateNetwork: "td-test-apps", resourcePrefix: "td-test", stateRoot: "/var/lib/td-test-apps")
        let spec = try BackendAppsDatabaseSpec(kind: kind, version: nil)
        let record = BackendAppsValidation.object([
            ("id", .string("td-test-db")), ("name", .string("td-test-db")), ("kind", .string(kind)),
            ("env", BackendAppsValidation.object([("PASSWORD", .string(DKTAppsFixtures.dummyPassword))])),
            ("database", BackendAppsValidation.object([("kind", .string(kind)), ("port", .number(Double(spec.port))),
                ("databaseName", .string("terminaldeck")), ("network", .string(runtime.privateNetwork))]))
        ])
        let value = try BackendAppsDataDatabases.publicConnection(record, runtime: runtime)
        #expect(value["scope"].string == "private-network")
        #expect(value["network"].string == "td-test-apps")
        #expect(value["password"].string == "••••••••")
        #expect(value["passwordKey"].string != nil)
        #expect(!value.compact.contains(DKTAppsFixtures.dummyPassword))
        #expect(value["uri"].isNullish && value["publicPort"].isNullish)
        #expect(kind != "redis" || value["database"] == .null)
        let wrong = record.setting("database", record["database"].setting("network", .string("unmanaged")))
        #expect(throws: NativeRPCError.self) { try BackendAppsDataDatabases.publicConnection(wrong, runtime: runtime) }
    }

    @Test("backup policy requires an explicit switch and integer retention within bounds")
    func policyValidation() throws {
        for count in [Double.nan, Double.infinity, 0, 366, 1.5] {
            let value = BackendAppsValidation.object([("enabled", .bool(true)), ("schedule", .string("daily")), ("retention", .number(count))])
            #expect(throws: NativeRPCError.self) { try BackendAppsDataBackupPolicy(request: value) }
        }
        #expect(throws: NativeRPCError.self) { try BackendAppsDataBackupPolicy(request: .object([])) }
        let disabled = try BackendAppsDataBackupPolicy(request: .object([.init("enabled", .bool(false))]))
        #expect(disabled.publicValue == .object([.init("enabled", .bool(false))]))
        let enabled = try BackendAppsDataBackupPolicy(request: .object([.init("enabled", .bool(true)), .init("schedule", .string("daily")), .init("retention", .number(7))]))
        #expect(enabled.publicValue["retention"] == .number(7))
    }

    @Test("S3 credentials are in protected input only and unsafe configuration values fail closed")
    func uploadPrivacy() throws {
        let input = BackendAppsValidation.object([
            ("endpoint", .string("https://s3.example.invalid")), ("bucket", .string("td-test-bucket")), ("prefix", .string("td-test-backups")),
            ("accessKey", .string("DKT_DUMMY_ACCESS_KEY")), ("secretKey", .string(DKTAppsFixtures.dummySecret))
        ])
        let upload = try BackendAppsDataS3Upload(input)
        #expect(!upload.publicValue.compact.contains("DKT_DUMMY_ACCESS_KEY"))
        #expect(!upload.publicValue.compact.contains(DKTAppsFixtures.dummySecret))
        #expect(String(decoding: upload.protectedCredentials, as: UTF8.self).contains(DKTAppsFixtures.dummySecret))
        for unsafe in [input.setting("secretKey", .string("secret\n[default]")), input.setting("endpoint", .string("http://s3.example.invalid")),
                       input.setting("endpoint", .string("https://user:password@s3.example.invalid")), input.setting("prefix", .string("../other"))] {
            #expect(throws: NativeRPCError.self) { try BackendAppsDataS3Upload(unsafe) }
        }
    }

    private func context(readOnly: Bool = false) -> NativeRPCContext {
        .init(caller: readOnly ? .page : .nativeApp, ownerID: "dkt-data-owner", capabilities: readOnly ? ["apps.read"] : ["apps.read", "apps.write"])
    }
    private func request(_ channel: String) -> NativeRPCValue {
        var value = BackendAppsValidation.object([("serverId", .string(DKTAppsFixtures.serverID)), ("appId", .string(DKTAppsFixtures.appID))])
        switch channel {
        case "apps:databases:create": value = value.setting("name", .string("td-test-db")).setting("kind", .string("postgres"))
        case "apps:databases:bind": value = value.setting("targetAppId", .string("td-test-target"))
        case "apps:backups:policy": value = value.setting("enabled", .bool(true)).setting("schedule", .string("daily")).setting("retention", .number(7))
        case "apps:backups:restore": value = value.setting("backupId", .string("td-test-backup")).setting("confirmation", .string(DKTAppsFixtures.appName))
        case "apps:templates:deploy": value = value.setting("name", .string("td-test-template")).setting("templateId", .string("td-test-unknown"))
        default: break
        }
        return value
    }

    /// The feature is available, but a denied approval must never reach the
    /// recovery issuer or I/O. This is not a permissive recovery implementation.
    private func approvalReadyRuntime(files: DKTAppsServerFiles, captures: DKTDataApprovalTrace) -> BackendAppsRuntime {
        let recovery = BackendAppsRecovery(capture: { _, _ in
            await captures.add()
            throw NativeRPCError(code: "access-denied", message: "The test must stop at approval before capturing a recovery transport.")
        }, audit: { _ in })
        return BackendAppsRuntime(execute: { server, command, stdin, timeout, maximum in
            try await files.execute(serverID: server, command: command, stdin: stdin, timeoutMS: timeout, maximumBytes: maximum)
        }, features: [BackendAppsDataChannels.recoveryFeature], recovery: recovery)
    }
}

private actor DKTDataApprovalTrace {
    var count = 0
    func add() { count += 1 }
}

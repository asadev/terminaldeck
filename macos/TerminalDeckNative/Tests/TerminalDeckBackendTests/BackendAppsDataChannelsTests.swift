import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendAppsDataChannelsTests: XCTestCase, @unchecked Sendable {
    func testDefaultDataWritesDenyBeforeServerIO() async throws {
        let fake = BackendAppsDataChannelFixture()
        let service = BackendAppsDataChannels(runtime: await fake.runtime(features: [BackendAppsDataChannels.recoveryFeature], withInertRecovery: true))
        for channel in BackendAppsDataChannels.writeChannels {
            var payload = identity()
            if channel == "apps:backups:restore" { payload = payload.setting("confirmation", .string("Demo")) }
            do {
                _ = try await service.invoke(channel, request: payload, context: native())
                XCTFail("Write ran without the existing approval: " + channel)
            } catch let error as NativeRPCError { XCTAssertEqual(error.code, "approval-required") }
        }
        let calls = await fake.calls
        XCTAssertEqual(calls, 0)
    }

    func testInjectedAuthorizerCannotExpandCallerGrants() async throws {
        let fake = BackendAppsDataChannelFixture()
        let service = BackendAppsDataChannels(runtime: await fake.runtime(), authorize: { _, _ in })
        let context = NativeRPCContext(caller: .pairedDevice, ownerID: "reader", capabilities: ["apps.read"])
        do {
            _ = try await service.invoke("apps:backups:create", request: identity(), context: context)
            XCTFail("Read-only caller changed data")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "access-denied") }
        let calls = await fake.calls
        XCTAssertEqual(calls, 0)
    }

    func testUnavailableRecoveryNeverAsksForApprovalOrTouchesServer() async throws {
        let fake = BackendAppsDataChannelFixture()
        let service = BackendAppsDataChannels(runtime: await fake.runtime(), authorize: { action, _ in await fake.preview(action.preview) })
        do {
            _ = try await service.invoke("apps:backups:create", request: identity(), context: native())
            XCTFail("Approved mutation ran without safe cancellation recovery")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "unavailable") }
        let calls = await fake.calls
        XCTAssertEqual(calls, 0)
        let previews = await fake.previews
        XCTAssertTrue(previews.isEmpty)
    }

    func testFeatureFlagCannotEnableWritesWithoutAnInjectedRecoveryKernel() async throws {
        let fake = BackendAppsDataChannelFixture()
        let service = BackendAppsDataChannels(runtime: await fake.runtime(features: [BackendAppsDataChannels.recoveryFeature]), authorize: { action, _ in
            await fake.preview(action.preview)
        })
        do {
            _ = try await service.invoke("apps:backups:create", request: identity(), context: native())
            XCTFail("The feature flag substituted for a recovery kernel")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "unavailable") }
        let calls = await fake.calls, previews = await fake.previews
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(previews.isEmpty)
    }

    func testBindingPreviewNamesTargetAndSettingWithoutReadingSecrets() async throws {
        let fake = BackendAppsDataChannelFixture()
        let service = BackendAppsDataChannels(runtime: await fake.runtime(features: [BackendAppsDataChannels.recoveryFeature], withInertRecovery: true), authorize: { action, _ in
            await fake.preview(action.preview)
            throw NativeRPCError(code: "approval-required", message: "Denied")
        })
        do {
            _ = try await service.invoke("apps:databases:bind", request: identity().setting("targetAppId", .string("web"))
                .setting("key", .string("DATABASE_URL")), context: native())
            XCTFail("Binding bypassed approval")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "approval-required") }
        let previews = await fake.previews
        XCTAssertEqual(previews.first?["targetAppId"].string, "web")
        XCTAssertEqual(previews.first?["key"].string, "DATABASE_URL")
        XCTAssertFalse(previews.first?.has("value") ?? true)
        let calls = await fake.calls
        XCTAssertEqual(calls, 0)
    }

    func testUploadSecretsNeverReachApprovalPreview() async throws {
        let fake = BackendAppsDataChannelFixture()
        let service = BackendAppsDataChannels(runtime: await fake.runtime(features: [BackendAppsDataChannels.recoveryFeature], withInertRecovery: true), authorize: { action, _ in
            await fake.preview(action.preview)
            throw NativeRPCError(code: "approval-required", message: "Denied")
        })
        let upload = NativeRPCValue.object([
            .init("endpoint", .string("https://storage.example.test")), .init("bucket", .string("backups")),
            .init("accessKey", .string("private-access")), .init("secretKey", .string("private-secret"))
        ])
        let payload = identity().setting("enabled", .bool(true)).setting("schedule", .string("daily"))
            .setting("retention", .number(7)).setting("upload", upload)
        do {
            _ = try await service.invoke("apps:backups:policy", request: payload, context: native())
            XCTFail("Approval was bypassed")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "approval-required") }
        let previews = await fake.previews
        XCTAssertEqual(previews.count, 1)
        XCTAssertFalse(previews[0].compact.contains("private-access"))
        XCTAssertFalse(previews[0].compact.contains("private-secret"))
        let calls = await fake.calls
        XCTAssertEqual(calls, 0)
    }

    func testCallerCannotInjectApprovalOrRuntimeNamespace() async throws {
        let fake = BackendAppsDataChannelFixture()
        let service = BackendAppsDataChannels(runtime: await fake.runtime(), authorize: { _, _ in })
        for key in ["approved", "stateRoot", "resourcePrefix", "privateNetwork"] {
            do {
                _ = try await service.invoke("apps:backups:create", request: identity().setting(key, .bool(true)), context: native())
                XCTFail("Caller injected " + key)
            } catch let error as NativeRPCError { XCTAssertEqual(error.code, "invalid-arguments") }
        }
        let calls = await fake.calls
        XCTAssertEqual(calls, 0)
    }

    func testRestoreRequiresNamedConfirmationBeforeIO() async throws {
        let fake = BackendAppsDataChannelFixture()
        let service = BackendAppsDataChannels(runtime: await fake.runtime(), authorize: { _, _ in })
        do {
            _ = try await service.invoke("apps:backups:restore", request: identity().setting("backupId", .string("backup-1")), context: native())
            XCTFail("Restore accepted no name")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "confirmation-required") }
        let calls = await fake.calls
        XCTAssertEqual(calls, 0)
    }

    func testFailedRegistrationRollsBackOnlyNewHandlers() async throws {
        let registry = NativeChannelRegistry()
        try await registry.register("apps:databases:create", ownerID: "existing") { _, _ in .bool(true) }
        try await registry.register("unrelated:read", ownerID: "other") { _, _ in .bool(true) }
        let fake = BackendAppsDataChannelFixture()
        let service = BackendAppsDataChannels(runtime: await fake.runtime())
        do {
            try await BackendAppsDataChannels.register(registry: registry, service: service, ownerID: "apd")
            XCTFail("Duplicate registration replaced an owner")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "duplicate-handler") }
        let channels = await registry.channels()
        XCTAssertEqual(channels, ["apps:databases:create", "unrelated:read"])
        let owner = await registry.registrationOwner(of: "apps:databases:create")
        XCTAssertEqual(owner, "existing")
    }

    func testConnectionReturnsOnlyPrivateCoordinatesAndMasksCredential() throws {
        let runtime = BackendAppsRuntime(execute: { _, _, _, _, _ in .init(code: 0, stdout: "") })
        let record = database().setting("env", .object([.init("POSTGRES_PASSWORD", .string("must-stay-hidden"))]))
        let connection = try BackendAppsDataDatabases.publicConnection(record, runtime: runtime)
        XCTAssertEqual(connection["host"].string, "terminaldeck-demo")
        XCTAssertEqual(connection["port"].number, 5432)
        XCTAssertEqual(connection["scope"].string, "private-network")
        XCTAssertEqual(connection["password"].string, "••••••••")
        XCTAssertFalse(connection.compact.contains("must-stay-hidden"))
        XCTAssertFalse(connection.has("address"))
    }

    func testConnectionRejectsCrossNetworkAndInvalidPortState() throws {
        let runtime = BackendAppsRuntime(execute: { _, _, _, _, _ in .init(code: 0, stdout: "") })
        var record = database()
        record = record.setting("database", record["database"].setting("network", .string("unmanaged")))
        XCTAssertThrowsError(try BackendAppsDataDatabases.publicConnection(record, runtime: runtime))
        record = database().setting("database", database()["database"].setting("port", .number(22)))
        XCTAssertThrowsError(try BackendAppsDataDatabases.publicConnection(record, runtime: runtime))
    }

    func testNullableUploadAcceptsRemovalAndKeepsCredentialsOptionalAsAPair() throws {
        try BackendAppsDataTools.validateBackupUpload(.null)
        let upload = NativeRPCValue.object([
            .init("endpoint", .string("https://storage.example.test")), .init("bucket", .string("backups"))
        ])
        try BackendAppsDataTools.validateBackupUpload(upload)
        XCTAssertThrowsError(try BackendAppsDataTools.validateBackupUpload(upload.setting("accessKey", .string("only-one-key"))))
    }

    func testUploadSchemaRejectsUnknownFieldsAndCredentialURLs() throws {
        let upload = NativeRPCValue.object([
            .init("endpoint", .string("https://storage.example.test")), .init("bucket", .string("backups"))
        ])
        XCTAssertThrowsError(try BackendAppsDataTools.validateBackupUpload(upload.setting("approved", .bool(true))))
        XCTAssertThrowsError(try BackendAppsDataTools.validateBackupUpload(upload.setting("endpoint", .string("https://user:secret@storage.example.test"))))
        XCTAssertThrowsError(try BackendAppsDataTools.validateBackupUpload(.string("remove")))
    }

    private func native() -> NativeRPCContext { .init(caller: .nativeApp, ownerID: "window") }
    private func identity() -> NativeRPCValue { .object([.init("serverId", .string("fixture")), .init("appId", .string("demo"))]) }
    private func database() -> NativeRPCValue {
        .object([.init("id", .string("demo")), .init("kind", .string("postgres")), .init("database", .object([
            .init("kind", .string("postgres")), .init("network", .string("terminaldeck-apps")),
            .init("port", .number(5432)), .init("databaseName", .string("terminaldeck"))
        ]))])
    }
}

private actor BackendAppsDataChannelFixture {
    var calls = 0
    var previews: [NativeRPCValue] = []
    func preview(_ value: NativeRPCValue) { previews.append(value) }
    func command() -> BackendServersRunResult { calls += 1; return .init(code: 0, stdout: "") }
    func runtime(features: Set<String> = [], withInertRecovery: Bool = false) -> BackendAppsRuntime {
        let recovery: BackendAppsRecovery? = withInertRecovery ? BackendAppsRecovery(capture: { _, _ in
            throw BackendAppsRuntime.unavailable("No recovery transport should be captured in this approval test.")
        }, audit: { _ in }) : nil
        return BackendAppsRuntime(execute: { _, _, _, _, _ in await self.command() }, features: features, recovery: recovery)
    }
}

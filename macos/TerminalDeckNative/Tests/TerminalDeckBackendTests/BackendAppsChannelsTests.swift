import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendAppsChannelsTests: XCTestCase, @unchecked Sendable {
    func testEveryDefaultWriteRefusesBeforeAnyServerIO() async throws {
        let fake = BackendAppsChannelFake()
        let runtime = BackendAppsRuntime(execute: { _, _, _, _, _ in await fake.command() })
        let service = BackendAppsChannels(runtime: runtime)
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "window")
        for channel in BackendAppsChannels.writeChannels {
            do { _ = try await service.invoke(channel, request: request(), context: context); XCTFail("Write was allowed: " + channel) }
            catch let error as NativeRPCError { XCTAssertEqual(error.code, "approval-required") }
        }
        let calls = await fake.calls
        XCTAssertEqual(calls, 0)
    }
    func testReadOnlyCallerCannotWriteAndCapabilitiesAreHonest() async throws {
        let runtime = BackendAppsRuntime(execute: { _, _, _, _, _ in throw BackendAppsRuntime.unavailable("Not connected") })
        let service = BackendAppsChannels(runtime: runtime)
        let context = NativeRPCContext(caller: .pairedDevice, ownerID: "device", capabilities: ["apps.read"])
        let value = try await service.invoke("apps:capabilities", request: request(), context: context)
        XCTAssertEqual(value["available"].bool, false)
        XCTAssertNotNil(value["unavailableReason"].string)
        do { _ = try await service.invoke("apps:restart", request: request(), context: context); XCTFail("Read grant authorized a write") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "access-denied") }
    }
    func testEnvPatchPreservesHiddenSecretsAndRejectsMaskReplacement() async throws {
        let fake = BackendAppsChannelFake()
        let service = BackendAppsChannels(runtime: await fake.runtime(), authorize: { _, _ in })
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "window")
        let result = try await service.invoke("apps:env:patch", request: request().setting("set", .object([.init("NEW", .string("value"))])).setting("remove", .array([.string("DROP")])), context: context)
        let env = await fake.env
        XCTAssertTrue(env.contains("TOKEN=hidden-credential"))
        XCTAssertTrue(env.contains("NEW=value"))
        XCTAssertFalse(env.contains("DROP="))
        XCTAssertFalse(result.compact.contains("hidden-credential"))
        do { _ = try await service.invoke("apps:env:patch", request: request().setting("set", .object([.init("TOKEN", .string("••••••••"))])), context: context); XCTFail("Saved masking bullets as a secret") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "invalid-arguments") }
    }
    func testLiveLogsMaskSecretsAcrossChunksAndCloseOnlyForTheirOwner() async throws {
        let fake = BackendAppsChannelFake()
        let service = BackendAppsChannels(runtime: await fake.runtime(), authorize: { _, _ in }, publish: { channel, value, owner in await fake.event(channel, value, owner) })
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "window")
        let payload = request().setting("streamId", .string("view-1"))
        _ = try await service.invoke("apps:logs:watch", request: payload, context: context)
        await fake.emit(.text("hello hidden-cred"))
        let before = await fake.events
        XCTAssertTrue(before.isEmpty)
        await fake.emit(.text("ential and image-secret\n"))
        let events = await fake.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].owner, "window")
        XCTAssertFalse(events[0].value.compact.contains("hidden-credential"))
        XCTAssertFalse(events[0].value.compact.contains("image-secret"))
        do { _ = try await service.invoke("apps:logs:unwatch", request: payload, context: .init(caller: .nativeApp, ownerID: "other")); XCTFail("Another owner closed the stream") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "access-denied") }
        await service.disconnect(ownerID: "window")
        let closed = await fake.closed
        XCTAssertEqual(closed, 1)
    }
    func testMissingEventConnectionDoesNotPretendToWatch() async throws {
        let fake = BackendAppsChannelFake()
        let service = BackendAppsChannels(runtime: await fake.runtime(), authorize: { _, _ in })
        do { _ = try await service.invoke("apps:logs:watch", request: request().setting("streamId", .string("view")), context: .init(caller: .nativeApp, ownerID: "window")); XCTFail("Watch without an event transport succeeded") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "unavailable") }
        let calls = await fake.calls
        XCTAssertEqual(calls, 0)
    }
    func testPublicStateOmitsCredentialMapsAndUnknownSourceFields() throws {
        let record = NativeRPCValue.object([.init("id", .string("demo")), .init("name", .string("Demo")), .init("env", .object([.init("TOKEN", .string("hidden"))])), .init("source", .object([.init("kind", .string("github")), .init("repository", .string("owner/repo")), .init("apiKey", .string("hidden"))])), .init("backupPolicy", .object([.init("enabled", .bool(true)), .init("upload", .object([.init("secretKey", .string("hidden")), .init("bucket", .string("saved"))]))]))])
        let result = BackendAppsStore.publicRecord(record)
        XCTAssertFalse(result.compact.contains("hidden"))
        XCTAssertEqual(result["backupPolicy"]["upload"]["bucket"].string, "saved")
        XCTAssertTrue(result["env"].isNullish)
        let damaged = record.setting("source", .object([.init("branch", .object([.init("apiKey", .string("hidden"))])), .init("repository", .string("owner/repo"))]))
        XCTAssertFalse(BackendAppsStore.publicRecord(damaged).compact.contains("hidden"))
    }
    private func request() -> NativeRPCValue { .object([.init("serverId", .string("fixture")), .init("appId", .string("demo"))]) }
}

private actor BackendAppsChannelFake {
    struct Event: Sendable { let channel: String, value: NativeRPCValue, owner: String }
    var calls = 0, closed = 0
    var env = "TOKEN=hidden-credential\nDROP=old\n"
    var record: NativeRPCValue = .object([.init("id", .string("demo")), .init("name", .string("Demo")), .init("kind", .string("app")), .init("containerId", .string("aaaaaaaaaaaa"))])
    var events: [Event] = []
    var emitLog: (@Sendable (BackendAppsLogEvent) async -> Void)?
    func command() -> BackendServersRunResult { calls += 1; return .init(code: 0, stdout: "") }
    func execute(_ command: String, _ input: Data?) throws -> BackendServersRunResult {
        calls += 1
        if let input, command.contains("sync -f") {
            if command.contains("state.json") { record = try NativeRPCValue.parseJSON(input) }
            else if command.contains("/.env") { env = String(decoding: input, as: UTF8.self) }
        }
        if command.contains("cat --") && command.contains("state.json") { return .init(code: 0, stdout: record.compact) }
        if command.contains("cat --") && command.contains("/.env") { return .init(code: 0, stdout: env) }
        return .init(code: 0, stdout: "")
    }
    func runtime() -> BackendAppsRuntime {
        BackendAppsRuntime(execute: { _, command, input, _, _ in try await self.execute(command, input) }, docker: { _, _, _, _ in
            let value = NativeRPCValue.object([.init("Config", .object([.init("Labels", .object([.init("io.terminaldeck.app", .string("demo")), .init("io.terminaldeck.managed", .string("true"))])), .init("Env", .array([.string("TOKEN=image-secret")]))]))])
            return .init(status: 200, body: try value.encodedJSON())
        }, watchLogs: { _, _, callback in
            await self.watch(callback)
            return NativeRPCSubscription { await self.close() }
        })
    }
    func watch(_ callback: @escaping @Sendable (BackendAppsLogEvent) async -> Void) { emitLog = callback }
    func close() { closed += 1; emitLog = nil }
    func emit(_ value: BackendAppsLogEvent) async { await emitLog?(value) }
    func event(_ channel: String, _ value: NativeRPCValue, _ owner: String) { events.append(.init(channel: channel, value: value, owner: owner)) }
}

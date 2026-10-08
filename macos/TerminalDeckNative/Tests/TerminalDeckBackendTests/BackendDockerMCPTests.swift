import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor BackendDockerMCPTestRecorder {
    private var entries: [String] = []
    private var args: NativeRPCValue = .missing
    func add(_ entry: String) { entries.append(entry) }
    func arguments(_ value: NativeRPCValue) { args = value }
    func snapshot() -> ([String], NativeRPCValue) { (entries, args) }
}

@MainActor
final class BackendDockerMCPTests: XCTestCase {
    private func context(tiers: Set<BackendMCPTier> = [.read, .act, .alter]) throws -> BackendMCPCallContext {
        .init(sessionID: "docker-test", machineID: "", projectRoot: nil, attended: true,
              allowedTools: Set(try BackendDockerMCP.definitions().flatMap { [$0.id, $0.wireName] }),
              allowedTiers: tiers, cancellation: .init())
    }
    private func args(_ fields: [NativeRPCValue.Field] = []) -> NativeRPCValue { .object([.init("target", .string("test-server"))] + fields) }
    private func access(_ recorder: BackendDockerMCPTestRecorder, denied: Bool = false) -> BackendDockerMCPAccess {
        .init(rpcContext: { _ in
            await recorder.add("rpc")
            return .init(caller: .page, ownerID: "test-owner")
        }, authorize: { _, _, value, tier, sentence, destructive in
            await recorder.add("authorize:" + tier.rawValue + ":" + String(destructive))
            await recorder.arguments(value)
            guard !sentence.isEmpty else { throw NativeRPCError.invalidArguments("missing approval summary") }
            if denied { throw NativeRPCError(code: "approval-required", message: "The person declined this action.") }
        }, noteResult: { _, _ in await recorder.add("note") })
    }

    func testCatalogueCoversContractWithReadWriteSeparation() throws {
        let tools = try BackendDockerMCP.definitions()
        XCTAssertEqual(tools.count, 31)
        XCTAssertEqual(Set(tools.map(\.id)).count, tools.count)
        XCTAssertEqual(tools.filter { $0.tier == .read }.count, 17)
        XCTAssertEqual(tools.filter { $0.tier == .alter }.count, 14)
        XCTAssertEqual(tools.filter { BackendDockerMCP.isDestructive(tool: $0.id) }.count, 4)
        for tool in tools {
            XCTAssertEqual(tool.wireName, tool.id.replacingOccurrences(of: ".", with: "_"))
            XCTAssertEqual(tool.inputSchema["additionalProperties"].bool, false)
            XCTAssertTrue(try BackendDockerMCP.channel(tool: tool.id).hasPrefix("docker:"))
        }
        let remove = try XCTUnwrap(tools.first { $0.id == "docker.containers.remove" })
        XCTAssertTrue(remove.inputSchema["required"].elements?.contains(.string("confirmName")) == true)
    }

    func testWriteConsentPrecedesRpcAndOneObjectDispatch() async throws {
        let registry = NativeChannelRegistry(), recorder = BackendDockerMCPTestRecorder()
        try await registry.register("docker:containers:start", ownerID: "fake") { _, values in
            await recorder.add("invoke")
            XCTAssertEqual(values.count, 1)
            XCTAssertEqual(values[0]["target"].string, "test-server")
            XCTAssertEqual(values[0]["id"].string, "container-1")
            return .object([.init("ok", .bool(true))])
        }
        let result = try await BackendDockerMCP.invoke(tool: "docker.containers.start", arguments: args([.init("id", .string("container-1"))]), caller: context(), registry: registry, access: access(recorder))
        XCTAssertEqual(result["ok"].bool, true)
        let recorded = await recorder.snapshot()
        XCTAssertEqual(recorded.0, ["authorize:alter:false", "rpc", "invoke", "note"])
    }

    func testDeniedWriteNeverReachesChannel() async throws {
        let registry = NativeChannelRegistry(), recorder = BackendDockerMCPTestRecorder()
        try await registry.register("docker:containers:start", ownerID: "fake") { _, _ in
            await recorder.add("invoke"); return .object([.init("ok", .bool(true))])
        }
        do {
            _ = try await BackendDockerMCP.invoke(tool: "docker.containers.start", arguments: args([.init("id", .string("container-1"))]), caller: context(), registry: registry, access: access(recorder, denied: true))
            XCTFail("A declined write succeeded")
        } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "approval-required") }
        let recorded = await recorder.snapshot()
        XCTAssertEqual(recorded.0, ["authorize:alter:false"])
    }

    func testUnavailableAndInvalidCallsDoNotAskForConsent() async throws {
        let registry = NativeChannelRegistry(), recorder = BackendDockerMCPTestRecorder()
        for (tool, arguments, code) in [
            ("docker.containers.start", args([.init("id", .string("c"))]), "unavailable"),
            ("docker.volumes.remove", args([.init("name", .string("data")), .init("confirmName", .string("other"))]), "confirmation-required"),
            ("docker.containers.start", args([.init("id", .string("c")), .init("approved", .bool(true))]), "invalid-arguments"),
            ("docker.exec.open", args([.init("id", .string("c"))]), "unavailable")
        ] {
            do {
                _ = try await BackendDockerMCP.invoke(tool: tool, arguments: arguments, caller: context(), registry: registry, access: access(recorder))
                XCTFail("An unavailable or invalid operation succeeded")
            } catch { XCTAssertEqual((error as? NativeRPCError)?.code, code) }
        }
        let recorded = await recorder.snapshot()
        XCTAssertTrue(recorded.0.isEmpty)
    }

    func testSchemaRejectsDuplicatesNonfiniteAndMalformedNestedFields() throws {
        let malformed: [NativeRPCValue] = [
            args([.init("id", .string("c")), .init("id", .string("d"))]),
            args([.init("id", .string("c")), .init("tail", .number(.nan))]),
            args([.init("id", .string("c")), .init("tail", .number(.infinity))]),
            args([.init("id", .string("c")), .init("tail", .number(1.5))]),
            args([.init("id", .string("c")), .init("tail", .number(5001))]),
            args([.init("id", .string("c\0"))])
        ]
        for arguments in malformed { XCTAssertThrowsError(try BackendDockerMCP.validate(tool: "docker.logs.open", arguments: arguments)) }
        XCTAssertThrowsError(try BackendDockerMCP.validate(tool: "docker.containers.list", arguments: args([.init("filters", .object([.init("label", .string("wrong-type"))]))])))
        XCTAssertNoThrow(try BackendDockerMCP.validate(tool: "docker.containers.list", arguments: args([.init("filters", .object([.init("label", .array([.string("owner=test")]))]))])))
        XCTAssertThrowsError(try BackendDockerMCP.validate(tool: "docker.exec.write", arguments: args([.init("sessionId", .string("s")), .init("data", .string("invalid base64"))])))
    }

    func testMaskerCoversEveryEnvValueAndRequestBytes() {
        let input = NativeRPCValue.object([
            .init("environment", .array([.object([.init("name", .string("REGION")), .init("value", .string("short"))])])),
            .init("env", .object([.init("COLOR", .string("cat"))])),
            .init("rows", .array([.object([.init("key", .string("PORT")), .init("value", .string("8000")), .init("secret", .bool(true))])])),
            .init("message", .string("short cat 8000")), .init("command", .array([.string("echo"), .string("private")])),
            .init("data", .string(Data("private".utf8).base64EncodedString())), .init("bytes", .bytes(Data("private".utf8)))
        ])
        let safe = BackendDockerMCPMasker.value(input)
        XCTAssertEqual(safe["environment"].elements?.first?["name"].string, "REGION")
        XCTAssertEqual(safe["environment"].elements?.first?["value"].string, "[redacted]")
        XCTAssertEqual(safe["rows"].elements?.first?["key"].string, "PORT")
        XCTAssertEqual(safe["rows"].elements?.first?["value"].string, "[redacted]")
        XCTAssertEqual(safe["message"].string, "[redacted] [redacted] [redacted]")
        XCTAssertEqual(safe["command"].string, "[redacted]")
        XCTAssertEqual(safe["data"].string, "[redacted]")
        XCTAssertEqual(safe["bytes"].string, "[redacted]")
        XCTAssertEqual(BackendDockerMCPMasker.text("value=abc", extraSecrets: ["abc"]), "value=[redacted]")
        XCTAssertEqual(BackendDockerMCPMasker.value(.object([.init("accessKey", .string("short-key")), .init("text", .string("short-key"))]))["text"].string, "[redacted]")
        let patch = NativeRPCValue.object([.init("serverId", .string("server")), .init("appId", .string("site")), .init("set", .object([.init("PORT", .string("8000"))])), .init("remove", .array([.string("OLD")])), .init("message", .string("port 8000"))])
        let safePatch = BackendDockerMCPMasker.arguments(patch)
        XCTAssertEqual(safePatch["set"]["PORT"].string, "[redacted]")
        XCTAssertEqual(safePatch["message"].string, "port [redacted]")
        XCTAssertEqual(BackendDockerMCPMasker.secrets(in: patch), ["8000"])
    }

    func testDestructiveSummaryNamesExactTargetAndInstallShowsFixedPreview() throws {
        let sentence = try BackendDockerMCP.summary(tool: "docker.volumes.remove", arguments: args([.init("name", .string("customer-data")), .init("confirmName", .string("customer-data"))]))
        XCTAssertTrue(sentence.contains("customer-data"))
        XCTAssertTrue(sentence.contains("test-server"))
        XCTAssertTrue(sentence.contains("delete its data"))
        let install = try BackendDockerMCP.summary(tool: "docker.install", arguments: args())
        XCTAssertTrue(install.contains("https://get.docker.com"))
        XCTAssertTrue(install.contains("Administrator access"))
    }

    func testOnlyExactEngineInstallerCommandSurvivesMasking() throws {
        let preview = BackendDockerMCPMasker.value(BackendDockerInstall.preview)
        XCTAssertEqual(preview["command"].string, BackendDockerInstall.command)
        XCTAssertEqual(preview["source"].string, BackendDockerInstall.source)
        let summary = try BackendDockerMCP.summary(tool: "docker.install", arguments: args())
        XCTAssertTrue(summary.contains(BackendDockerInstall.command))
        let changed = NativeRPCValue.object([.init("command", .string(BackendDockerInstall.command + "; echo arbitrary-input")), .init("data", .string("terminal-bytes"))])
        XCTAssertEqual(BackendDockerMCPMasker.value(changed)["command"].string, "[redacted]")
        XCTAssertEqual(BackendDockerMCPMasker.value(changed)["data"].string, "[redacted]")
        let exec = NativeRPCValue.object([.init("command", .array([.string(BackendDockerInstall.command)]))])
        XCTAssertEqual(BackendDockerMCPMasker.value(exec)["command"].string, "[redacted]")
    }

    func testPrivateDatabaseConnectionMetadataIsPreservedWithoutExposingPasswords() {
        let keys = ["postgres": "POSTGRES_PASSWORD", "mysql": "MYSQL_ROOT_PASSWORD", "redis": "REDIS_PASSWORD", "mongodb": "MONGO_INITDB_ROOT_PASSWORD"]
        for (kind, key) in keys {
            let connection = NativeRPCValue.object([.init("kind", .string(kind)), .init("scope", .string("private-network")),
                .init("password", .string("fixture-secret-value")), .init("passwordKey", .string(key)),
                .init("authenticationDatabase", kind == "mongodb" ? .string("admin") : .null), .init("instructions", .string("Connect using " + key))])
            let safe = BackendDockerMCPMasker.value(connection)
            XCTAssertEqual(safe["password"].string, "[redacted]")
            XCTAssertEqual(safe["passwordKey"].string, key)
            XCTAssertEqual(safe["authenticationDatabase"], kind == "mongodb" ? .string("admin") : .null)
            XCTAssertEqual(safe["instructions"].string, "Connect using " + key)
            XCTAssertFalse(BackendDockerMCPMasker.secrets(in: connection).contains(key))
            XCTAssertFalse(BackendDockerMCPMasker.secrets(in: connection).contains("admin"))
            XCTAssertEqual(BackendDockerMCPMasker.value(connection.setting("passwordKey", .string("arbitrary-private-value")))["passwordKey"].string, "[redacted]")
            XCTAssertEqual(BackendDockerMCPMasker.value(connection.setting("scope", .string("public")))["passwordKey"].string, "[redacted]")
            XCTAssertEqual(BackendDockerMCPMasker.value(connection.setting("authenticationDatabase", .string("arbitrary-private-value")))["authenticationDatabase"].string, "[redacted]")
        }
    }

    func testConfirmationPreflightChecksCurrentResourceName() async throws {
        let registry = NativeChannelRegistry()
        try await registry.register("docker:containers:inspect", ownerID: "fake") { _, _ in
            .object([.init("id", .string("canonical-id")), .init("name", .string("current-name"))])
        }
        let rpc = NativeRPCContext(caller: .page, ownerID: "preflight-owner")
        let valid = args([.init("id", .string("canonical-id")), .init("confirmName", .string("current-name"))])
        try await BackendDockerMCP.validateConfirmation(tool: "docker.containers.remove", arguments: valid, registry: registry, context: rpc)
        do {
            try await BackendDockerMCP.validateConfirmation(tool: "docker.containers.remove", arguments: valid.setting("confirmName", .string("old-name")), registry: registry, context: rpc)
            XCTFail("A stale resource name passed preflight")
        } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "confirmation-required") }
        try await registry.register("docker:images:list", ownerID: "fake") { _, _ in
            .object([.init("images", .array([.object([.init("id", .string("sha256:fixture")), .init("tags", .array([.string("<none>:<none>"), .string("app:current")]))])]))])
        }
        try await BackendDockerMCP.validateConfirmation(tool: "docker.images.remove", arguments: args([.init("id", .string("sha256:fixture")), .init("confirmName", .string("app:current"))]), registry: registry, context: rpc)
    }

    func testReadCannotEscalateAndCancellationBlocksWrite() async throws {
        let registry = NativeChannelRegistry(), recorder = BackendDockerMCPTestRecorder()
        try await registry.register("docker:containers:start", ownerID: "fake") { _, _ in
            await recorder.add("invoke"); return .object([.init("ok", .bool(true))])
        }
        let readOnly = try context(tiers: [.read])
        do {
            _ = try await BackendDockerMCP.invoke(tool: "docker.containers.start", arguments: args([.init("id", .string("c"))]), caller: readOnly, registry: registry, access: access(recorder))
            XCTFail("Read-only caller wrote")
        } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "forbidden") }
        let cancelled = try context(); cancelled.cancellation.cancel()
        do {
            _ = try await BackendDockerMCP.invoke(tool: "docker.containers.start", arguments: args([.init("id", .string("c"))]), caller: cancelled, registry: registry, access: access(recorder))
            XCTFail("Cancelled caller wrote")
        } catch { XCTAssertTrue(error is CancellationError) }
        let recorded = await recorder.snapshot(); XCTAssertTrue(recorded.0.isEmpty)
    }

    func testBoundedLogsCaptureEarlyFramesIgnoreOtherOwnersAndAlwaysClose() async throws {
        let registry = NativeChannelRegistry(), recorder = BackendDockerMCPTestRecorder()
        try await registry.register("docker:logs:open", ownerID: "fake") { rpc, _ in
            let base: [NativeRPCValue.Field] = [.init("target", .string("test-server")), .init("streamId", .string("stream-1")), .init("sequence", .number(1))]
            try await registry.publish("docker:logs:data", arguments: [.object(base + [.init("text", .string("other caller"))])], ownerID: "other-owner")
            try await registry.publish("docker:logs:data", arguments: [.object(base + [.init("text", .string("broadcast must be ignored"))])])
            try await registry.publish("docker:logs:data", arguments: [.object(base + [.init("text", .string("password=fixture-private-value"))])], ownerID: rpc.ownerID)
            try await registry.publish("docker:stream:end", arguments: [.object(base + [.init("reason", .string("eof"))])], ownerID: rpc.ownerID)
            return .object([.init("streamId", .string("stream-1"))])
        }
        try await registry.register("docker:stream:close", ownerID: "fake") { rpc, values in
            await recorder.add("closed")
            XCTAssertEqual(rpc.ownerID, "test-owner")
            XCTAssertEqual(values[0]["streamId"].string, "stream-1")
            return .object([.init("ok", .bool(true))])
        }
        let result = try await BackendDockerMCP.invoke(tool: "docker.logs.open", arguments: args([.init("id", .string("c"))]), caller: context(), registry: registry, access: access(recorder))
        XCTAssertEqual(result["records"].elements?.count, 1)
        XCTAssertEqual(result["records"].elements?.first?["text"].string, "password=[redacted]")
        XCTAssertEqual(result["streamClosed"].bool, true)
        let recorded = await recorder.snapshot(); XCTAssertTrue(recorded.0.contains("closed"))
    }

    func testMissingResultIsFailureNeverEmptySuccess() async throws {
        let registry = NativeChannelRegistry(), recorder = BackendDockerMCPTestRecorder()
        try await registry.register("docker:status", ownerID: "fake") { _, _ in .missing }
        let entries = try BackendDockerMCP.contribution(registry: registry, access: access(recorder))
        let handler = try XCTUnwrap(entries.first { $0.0.id == "docker.status" }).1
        let reply = try await handler(context(), args())
        XCTAssertTrue(reply.isError)
        XCTAssertEqual(reply.structuredContent?["error"]["code"].string, "unavailable")
    }

    func testMalformedSuccessAndRawDependencyErrorCannotEscape() async throws {
        let registry = NativeChannelRegistry(), recorder = BackendDockerMCPTestRecorder()
        try await registry.register("docker:status", ownerID: "fake") { _, _ in .object([]) }
        let entries = try BackendDockerMCP.contribution(registry: registry, access: access(recorder))
        let handler = try XCTUnwrap(entries.first { $0.0.id == "docker.status" }).1
        let malformed = try await handler(context(), args())
        XCTAssertTrue(malformed.isError)
        await registry.removeHandler("docker:status", ownerID: "fake")
        try await registry.register("docker:status", ownerID: "fake") { _, _ in
            throw NativeRPCError(code: "docker-api", message: "raw server credential fixture-private-value")
        }
        let failed = try await handler(context(), args())
        XCTAssertTrue(failed.isError)
        XCTAssertEqual(failed.structuredContent?["error"]["code"].string, "docker-api")
        XCTAssertFalse(failed.content.first?["text"].string?.contains("fixture-private-value") == true)
    }
}

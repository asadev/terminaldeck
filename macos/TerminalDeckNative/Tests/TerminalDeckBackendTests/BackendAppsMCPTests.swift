import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor BackendAppsMCPAudit {
    private var events: [String] = []
    private var metadata: [NativeRPCValue] = []
    func record(_ event: String, value: NativeRPCValue? = nil) {
        events.append(event)
        if let value { metadata.append(value) }
    }
    func snapshot() -> ([String], [NativeRPCValue]) { (events, metadata) }
}

@MainActor
final class BackendAppsMCPTests: XCTestCase {
    private func arguments(_ fields: [(String, NativeRPCValue)] = []) -> NativeRPCValue {
        .object([.init("serverId", .string("server-1")), .init("appId", .string("example"))] + fields.map { .init($0.0, $0.1) })
    }
    private func caller(tiers: Set<BackendMCPTier> = [.read, .alter], cancellation: BackendMCPCancellation = .init()) -> BackendMCPCallContext {
        .init(sessionID: "session-1", machineID: "", projectRoot: nil, attended: true,
              allowedTools: Set(BackendAppsMCP.definitions().map(\.id)), allowedTiers: tiers, cancellation: cancellation)
    }
    private func access(_ audit: BackendAppsMCPAudit, deny: Bool = false) -> BackendDockerMCPAccess {
        .init(rpcContext: { _ in .init(caller: .page, ownerID: "apps-mcp-test", capabilities: ["apps.read", "apps.write"]) },
              authorize: { _, _, args, tier, sentence, destructive in
                  await audit.record("approve", value: args)
                  await audit.record(sentence)
                  await audit.record(destructive ? "destructive" : "write")
                  guard tier == .alter, !deny else { throw NativeRPCError(code: "approval-required", message: "denied") }
              }, noteResult: { _, value in await audit.record("result", value: value) })
    }
    private func handler(_ tool: String, registry: NativeChannelRegistry, access: BackendDockerMCPAccess,
                         logWindowMilliseconds: Int = 5_000) async throws -> BackendNativeMCPServer.Handler {
        let entries = try BackendAppsMCP.contribution(registry: registry, access: access, logWindowMilliseconds: logWindowMilliseconds)
        return try XCTUnwrap(entries.first { $0.0.id == tool }?.1)
    }

    func testContractCatalogueCovers30UniqueChannelsAndWritesRequireAlterTier() throws {
        let definitions = BackendAppsMCP.definitions(), specifications = try BackendAppsMCP.specifications()
        XCTAssertEqual(definitions.count, 30)
        XCTAssertEqual(Set(definitions.map(\.channel)).count, 30)
        XCTAssertEqual(Set(specifications.map(\.wireName)).count, 30)
        XCTAssertEqual(definitions.filter { $0.tier == .alter }.count, 16)
        XCTAssertEqual(definitions.filter { $0.destructive }.map(\.channel), ["apps:remove", "apps:backups:restore"])
        XCTAssertEqual(definitions.first { $0.id == "apps.auto-deploy.apply" }?.channel, "apps:auto-deploy:apply")
        XCTAssertEqual(specifications.first { $0.id == "apps.auto-deploy.apply" }?.wireName, "apps_auto_deploy_apply")
    }

    func testReadRunsWithoutApprovalAndPassesOneObject() async throws {
        let registry = NativeChannelRegistry(), audit = BackendAppsMCPAudit()
        let args = arguments()
        try await registry.register("apps:read", ownerID: "test") { _, values in
            XCTAssertEqual(values, [args])
            await audit.record("dispatch")
            return .object([.init("name", .string("Example"))])
        }
        let reply = try await handler("apps.read", registry: registry, access: access(audit))(caller(), args)
        XCTAssertFalse(reply.isError)
        let snapshot = await audit.snapshot()
        XCTAssertEqual(snapshot.0, ["dispatch", "result"])
    }

    func testEveryWriteWaitsForApprovalBeforeItsChannelRuns() async throws {
        let samples: [String: [(String, NativeRPCValue)]] = [
            "apps.create": [("name", .string("Example")), ("source", .object([.init("kind", .string("github")), .init("repository", .string("owner/repo")), .init("build", .string("auto"))]))],
            "apps.deploy": [], "apps.rollback": [("deploymentId", .string("deploy-1"))], "apps.restart": [],
            "apps.remove": [("confirmation", .string("Example"))], "apps.env.apply": [("env", .object([]))],
            "apps.env.patch": [("set", .object([])), ("remove", .array([]))],
            "apps.domains.apply": [("domains", .array([.string("example.test")]))], "apps.caddy.install": [],
            "apps.databases.create": [("name", .string("Example")), ("kind", .string("postgres"))],
            "apps.databases.bind": [("targetAppId", .string("target-app")), ("key", .string("DATABASE_URL"))],
            "apps.backups.create": [], "apps.backups.policy": [("enabled", .bool(true)), ("schedule", .string("daily")), ("retention", .number(7))],
            "apps.backups.restore": [("backupId", .string("backup-1")), ("confirmation", .string("Example"))],
            "apps.templates.deploy": [("name", .string("Example")), ("templateId", .string("template-1"))],
            "apps.auto-deploy.apply": [("enabled", .bool(true))],
        ]
        for definition in BackendAppsMCP.definitions().filter({ $0.tier == .alter }) {
            let registry = NativeChannelRegistry(), audit = BackendAppsMCPAudit()
            try await registry.register("apps:read", ownerID: "test") { _, _ in .object([.init("name", .string("Example"))]) }
            try await registry.register(definition.channel, ownerID: "test") { _, _ in
                await audit.record("dispatch")
                return .object([.init("done", .bool(true))])
            }
            let args = definition.id == "apps.caddy.install"
                ? NativeRPCValue.object([.init("serverId", .string("server-1"))]) : arguments(try XCTUnwrap(samples[definition.id]))
            let reply = try await handler(definition.id, registry: registry, access: access(audit))(caller(), args)
            XCTAssertFalse(reply.isError, definition.id)
            let events = await audit.snapshot().0
            XCTAssertEqual(events.first, "approve", definition.id)
            XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "approve")), try XCTUnwrap(events.firstIndex(of: "dispatch")), definition.id)
            XCTAssertTrue(events.contains(where: { $0.contains("server-1") }), definition.id)
        }
    }

    func testDeniedApprovalAndReadOnlyGrantPreventMutations() async throws {
        let registry = NativeChannelRegistry(), audit = BackendAppsMCPAudit()
        try await registry.register("apps:restart", ownerID: "test") { _, _ in await audit.record("dispatch"); return .object([.init("restarted", .bool(true))]) }
        let denied = try await handler("apps.restart", registry: registry, access: access(audit, deny: true))(caller(), arguments())
        XCTAssertTrue(denied.isError)
        XCTAssertEqual(denied.structuredContent?["error"]["code"].string, "approval-required")
        let readOnly = try await handler("apps.restart", registry: registry, access: access(audit))(caller(tiers: [.read]), arguments())
        XCTAssertTrue(readOnly.isError)
        XCTAssertEqual(readOnly.structuredContent?["error"]["code"].string, "access-denied")
        let events = await audit.snapshot().0
        XCTAssertFalse(events.contains("dispatch"))
        XCTAssertEqual(events.filter { $0 == "approve" }.count, 1)
    }

    func testExactCurrentNameRequiredBeforeDestructiveApproval() async throws {
        for tool in ["apps.remove", "apps.backups.restore"] {
            let registry = NativeChannelRegistry(), audit = BackendAppsMCPAudit()
            let definition = try XCTUnwrap(BackendAppsMCP.definitions().first { $0.id == tool })
            try await registry.register("apps:read", ownerID: "test") { _, _ in .object([.init("name", .string("Production App"))]) }
            try await registry.register(definition.channel, ownerID: "test") { _, _ in await audit.record("dispatch"); return .object([.init("done", .bool(true))]) }
            var args = arguments([("confirmation", .string("example"))])
            if tool == "apps.backups.restore" { args = args.setting("backupId", .string("backup-1")) }
            let run = try await handler(tool, registry: registry, access: access(audit))
            let rejected = try await run(caller(), args)
            XCTAssertEqual(rejected.structuredContent?["error"]["code"].string, "confirmation-required")
            var events = await audit.snapshot().0
            XCTAssertTrue(events.isEmpty)
            let accepted = try await run(caller(), args.setting("confirmation", .string("Production App")))
            XCTAssertFalse(accepted.isError)
            events = await audit.snapshot().0
            XCTAssertTrue(events.contains(where: { $0.contains("Production App") }))
            XCTAssertTrue(events.contains("destructive"))
        }
    }

    func testMissingOperationAndMissingResultReturnUnavailableError() async throws {
        let registry = NativeChannelRegistry(), audit = BackendAppsMCPAudit()
        let absent = try await handler("apps.read", registry: registry, access: access(audit))(caller(), arguments())
        XCTAssertTrue(absent.isError)
        XCTAssertEqual(absent.structuredContent?["error"]["code"].string, "unavailable")
        for empty in [NativeRPCValue.missing, .null, .object([]), .bool(true)] {
            await registry.removeHandler("apps:read", ownerID: "test")
            try await registry.register("apps:read", ownerID: "test") { _, _ in empty }
            let missing = try await handler("apps.read", registry: registry, access: access(audit))(caller(), arguments())
            XCTAssertTrue(missing.isError)
            XCTAssertEqual(missing.structuredContent?["error"]["code"].string, "unavailable")
        }
    }

    func testEnvAndUploadSecretsDoNotReachApprovalOrReply() async throws {
        let registry = NativeChannelRegistry(), audit = BackendAppsMCPAudit(), secret = "unlabelled-private-value"
        try await registry.register("apps:env:apply", ownerID: "test") { _, values in
            XCTAssertEqual(values.first?["env"]["PLAIN"].string, secret)
            return .object([.init("env", values[0]["env"]), .init("text", .string("echo " + secret))])
        }
        let reply = try await handler("apps.env.apply", registry: registry, access: access(audit))(caller(), arguments([("env", .object([.init("PLAIN", .string(secret))]))]))
        XCTAssertFalse(reply.isError)
        XCTAssertFalse(reply.structuredContent?.compact.contains(secret) == true)
        let snapshot = await audit.snapshot()
        XCTAssertFalse(snapshot.0.joined().contains(secret))
        XCTAssertFalse(snapshot.1.map(\.compact).joined().contains(secret))
        let upload = arguments([("schedule", .string("daily")), ("retention", .number(7)),
                                ("upload", .object([.init("endpoint", .string("https://storage.test")), .init("bucket", .string("backups")), .init("prefix", .string("")), .init("accessKey", .string("private-access")), .init("secretKey", .string("private-secret"))]))])
        let masked = BackendDockerMCPMasker.arguments(upload).compact
        XCTAssertFalse(masked.contains("private-access"))
        XCTAssertFalse(masked.contains("private-secret"))
    }

    func testEnvRowsRemainMaskedEvenWhenDependencyReturnsRawValues() async throws {
        let registry = NativeChannelRegistry(), audit = BackendAppsMCPAudit()
        try await registry.register("apps:env:read", ownerID: "test") { _, _ in
            .array([.object([.init("key", .string("PLAIN")), .init("value", .string("unlabelled-value")), .init("secret", .bool(true))])])
        }
        let reply = try await handler("apps.env.read", registry: registry, access: access(audit))(caller(), arguments())
        XCTAssertFalse(reply.isError)
        XCTAssertFalse(reply.content.map(\.compact).joined().contains("unlabelled-value"))
    }

    func testSettingsPatchKeepsRawValuesOnlyInDispatch() async throws {
        let registry = NativeChannelRegistry(), audit = BackendAppsMCPAudit(), secret = "ordinary-setting-value"
        try await registry.register("apps:env:patch", ownerID: "test") { _, values in
            XCTAssertEqual(values[0]["set"]["PLAIN"].string, secret)
            XCTAssertEqual(values[0]["remove"].elements, [.string("OLD")])
            return .array([.object([.init("key", .string("PLAIN")), .init("value", .string(secret)), .init("secret", .bool(true)), .init("text", .string("echo " + secret))])])
        }
        let args = arguments([("set", .object([.init("PLAIN", .string(secret))])), ("remove", .array([.string("OLD")]))])
        let reply = try await handler("apps.env.patch", registry: registry, access: access(audit))(caller(), args)
        XCTAssertFalse(reply.isError)
        XCTAssertFalse(reply.content.map(\.compact).joined().contains(secret))
        let snapshot = await audit.snapshot()
        XCTAssertFalse(snapshot.1.map(\.compact).joined().contains(secret))
    }

    func testNestedSchemasBoundsDuplicatesAndApprovalFlagsRejected() throws {
        let env = arguments([("env", .object([.init("PLAIN", .number(1))]))])
        XCTAssertThrowsError(try BackendAppsMCP.validate(tool: "apps.env.apply", arguments: env))
        XCTAssertThrowsError(try BackendAppsMCP.validate(tool: "apps.restart", arguments: arguments().setting("approved", .bool(true))))
        XCTAssertThrowsError(try BackendAppsMCP.validate(tool: "apps.logs.read", arguments: arguments([("tail", .number(1_001))])))
        XCTAssertThrowsError(try BackendAppsMCP.validate(tool: "apps.logs.read", arguments: arguments([("tail", .number(1.5))])))
        XCTAssertThrowsError(try BackendAppsMCP.validate(tool: "apps.restart", arguments: arguments().setting("appId", .string("example\n"))))
        XCTAssertThrowsError(try BackendAppsMCP.validate(tool: "apps.restart", arguments: arguments([("appId", .string("other"))])))
        let source = NativeRPCValue.object([.init("kind", .string("github")), .init("repository", .string("owner/repo")), .init("build", .string("auto")), .init("approved", .bool(true))])
        XCTAssertThrowsError(try BackendAppsMCP.validate(tool: "apps.create", arguments: arguments([("name", .string("Example")), ("source", source)])))
        XCTAssertNoThrow(try BackendAppsMCP.validate(tool: "apps.env.apply", arguments: arguments([("env", .object([.init("PLAIN", .string(""))]))])))
        XCTAssertThrowsError(try BackendAppsMCP.validate(tool: "apps.env.patch", arguments: arguments([("set", .object([.init("PLAIN", .string("••••••••"))])), ("remove", .array([]))])))
        XCTAssertThrowsError(try BackendAppsMCP.validate(tool: "apps.backups.policy", arguments: arguments([("enabled", .bool(true))])))
        XCTAssertNoThrow(try BackendAppsMCP.validate(tool: "apps.backups.policy", arguments: arguments([("enabled", .bool(false))])))
    }

    func testCancellationBeforeDispatchAndDependencyErrorsNeverEchoSecrets() async throws {
        let registry = NativeChannelRegistry(), audit = BackendAppsMCPAudit(), cancellation = BackendMCPCancellation()
        try await registry.register("apps:read", ownerID: "test") { _, _ in
            await audit.record("dispatch")
            throw NativeRPCError(code: "invalid-arguments", message: "server stderr private-database-password")
        }
        cancellation.cancel()
        let cancelled = try await handler("apps.read", registry: registry, access: access(audit))(caller(cancellation: cancellation), arguments())
        XCTAssertEqual(cancelled.structuredContent?["error"]["code"].string, "cancelled")
        let events = await audit.snapshot().0
        XCTAssertTrue(events.isEmpty)
        let error = try await handler("apps.read", registry: registry, access: access(audit))(caller(), arguments())
        XCTAssertTrue(error.isError)
        XCTAssertFalse(error.content.map(\.compact).joined().contains("private-database-password"))
        XCTAssertEqual(error.structuredContent?["error"]["code"].string, "invalid-arguments")
    }

    func testLiveLogReadFiltersOtherOwnersAndStreamsThenStopsAtLimit() async throws {
        let registry = NativeChannelRegistry(), audit = BackendAppsMCPAudit()
        let args = arguments([("streamId", .string("stream-1"))])
        try await registry.register("apps:logs:watch", ownerID: "test") { context, values in
            await audit.record("watch")
            let payload = values[0].setting("text", .string("wrong stream"))
            try await registry.publish("apps:logs", arguments: [payload], ownerID: "somebody-else")
            try await registry.publish("apps:logs", arguments: [payload])
            try await registry.publish("apps:logs", arguments: [payload.setting("streamId", .string("different"))], ownerID: context.ownerID)
            for _ in 0..<45 {
                try await registry.publish("apps:logs", arguments: [values[0].setting("text", .string("line\n"))], ownerID: context.ownerID)
            }
            return .object([.init("streamId", values[0]["streamId"])])
        }
        try await registry.register("apps:logs:unwatch", ownerID: "test") { context, values in
            XCTAssertEqual(context.ownerID, "apps-mcp-test")
            XCTAssertEqual(values[0]["serverId"], args["serverId"])
            XCTAssertEqual(values[0]["streamId"], args["streamId"])
            await audit.record("unwatch")
            return .object([.init("stopped", .bool(true))])
        }
        let reply = try await handler("apps.logs.watch", registry: registry, access: access(audit))(caller(), args)
        XCTAssertFalse(reply.isError)
        XCTAssertEqual(reply.structuredContent?["events"].number, 40)
        XCTAssertEqual(reply.structuredContent?["stopped"].bool, true)
        XCTAssertEqual(reply.structuredContent?["truncated"].bool, true)
        XCTAssertFalse(reply.structuredContent?["text"].string?.contains("wrong") == true)
        let events = await audit.snapshot().0
        XCTAssertEqual(events, ["watch", "unwatch", "result"])
        let unwatch = try await handler("apps.logs.unwatch", registry: registry, access: access(audit))(caller(), args.removing("appId"))
        XCTAssertTrue(unwatch.isError)
        XCTAssertEqual(unwatch.structuredContent?["error"]["code"].string, "unavailable")
    }

    func testLiveLogReadRequiresCleanupAndCancellationClosesOwnedStream() async throws {
        let registry = NativeChannelRegistry(), audit = BackendAppsMCPAudit(), cancellation = BackendMCPCancellation()
        let args = arguments([("streamId", .string("stream-1"))])
        try await registry.register("apps:logs:watch", ownerID: "test") { _, values in
            await audit.record("watch")
            cancellation.cancel()
            return .object([.init("streamId", values[0]["streamId"])])
        }
        let run = try await handler("apps.logs.watch", registry: registry, access: access(audit))
        let noCleanup = try await run(caller(), args)
        XCTAssertTrue(noCleanup.isError)
        let before = await audit.snapshot().0
        XCTAssertTrue(before.isEmpty)
        try await registry.register("apps:logs:unwatch", ownerID: "test") { _, _ in
            await audit.record("unwatch")
            return .object([.init("stopped", .bool(true))])
        }
        let cancelled = try await run(caller(cancellation: cancellation), args)
        XCTAssertTrue(cancelled.isError)
        XCTAssertEqual(cancelled.structuredContent?["error"]["code"].string, "cancelled")
        let events = await audit.snapshot().0
        XCTAssertEqual(events, ["watch", "unwatch"])
    }

    func testOwnedEndBeforeWatchAcknowledgementReturnsCollectedLogsWithoutSecondUnwatch() async throws {
        let registry = NativeChannelRegistry(), audit = BackendAppsMCPAudit()
        let args = arguments([("streamId", .string("stream-1"))])
        try await registry.register("apps:logs:watch", ownerID: "test") { context, values in
            await audit.record("watch")
            try await registry.publish("apps:logs", arguments: [values[0].setting("text", .string("last line\n"))], ownerID: context.ownerID)
            try await registry.publish("apps:logs:end", arguments: [values[0].setting("reason", .string("eof"))], ownerID: context.ownerID)
            throw NativeRPCError(code: "cancelled", message: "The engine already released the ended stream.")
        }
        try await registry.register("apps:logs:unwatch", ownerID: "test") { _, _ in
            await audit.record("unwatch")
            throw NativeRPCError(code: "access-denied", message: "Already ended streams are no longer in the engine table.")
        }
        let reply = try await handler("apps.logs.watch", registry: registry, access: access(audit))(caller(), args)
        XCTAssertFalse(reply.isError)
        XCTAssertEqual(reply.structuredContent?["text"].string, "last line\n")
        XCTAssertEqual(reply.structuredContent?["endReason"].string, "eof")
        XCTAssertEqual(reply.structuredContent?["stopped"].bool, true)
        let events = await audit.snapshot().0
        XCTAssertEqual(events, ["watch", "result"])
    }

    func testOwnedStreamErrorAndOverflowReturnErrorWithMaskedPartialLogs() async throws {
        for reason in ["error", "overflow"] {
            let registry = NativeChannelRegistry(), audit = BackendAppsMCPAudit()
            let args = arguments([("streamId", .string("stream-1"))])
            try await registry.register("apps:logs:watch", ownerID: "test") { context, values in
                try await registry.publish("apps:logs", arguments: [values[0].setting("text", .string("password=private-value\n"))], ownerID: context.ownerID)
                try await registry.publish("apps:logs:end", arguments: [values[0].setting("reason", .string(reason))], ownerID: context.ownerID)
                return .object([.init("streamId", values[0]["streamId"])])
            }
            try await registry.register("apps:logs:unwatch", ownerID: "test") { _, _ in await audit.record("unwatch"); return .object([.init("stopped", .bool(true))]) }
            let reply = try await handler("apps.logs.watch", registry: registry, access: access(audit))(caller(), args)
            XCTAssertTrue(reply.isError, reason)
            XCTAssertEqual(reply.structuredContent?["endReason"].string, reason)
            XCTAssertEqual(reply.structuredContent?["error"]["code"].string, "unavailable")
            XCTAssertEqual(reply.structuredContent?["truncated"].bool, reason == "overflow")
            XCTAssertFalse(reply.content.map(\.compact).joined().contains("private-value"))
            let events = await audit.snapshot().0
            XCTAssertFalse(events.contains("unwatch"))
        }
    }

    func testUnrelatedAndUnknownEndEventsDoNotFinishOwnedLogRead() async throws {
        let registry = NativeChannelRegistry(), audit = BackendAppsMCPAudit()
        let args = arguments([("streamId", .string("stream-1"))])
        try await registry.register("apps:logs:watch", ownerID: "test") { context, values in
            let ended = values[0].setting("reason", .string("eof"))
            try await registry.publish("apps:logs:end", arguments: [ended], ownerID: "somebody-else")
            try await registry.publish("apps:logs:end", arguments: [ended])
            try await registry.publish("apps:logs:end", arguments: [ended.setting("serverId", .string("another-server"))], ownerID: context.ownerID)
            try await registry.publish("apps:logs:end", arguments: [ended.setting("appId", .string("another-app"))], ownerID: context.ownerID)
            try await registry.publish("apps:logs:end", arguments: [ended.setting("streamId", .string("another-stream"))], ownerID: context.ownerID)
            try await registry.publish("apps:logs:end", arguments: [ended.setting("reason", .string("private-arbitrary-stderr"))], ownerID: context.ownerID)
            return .object([.init("streamId", values[0]["streamId"])])
        }
        try await registry.register("apps:logs:unwatch", ownerID: "test") { _, _ in await audit.record("unwatch"); return .object([.init("stopped", .bool(true))]) }
        let reply = try await handler("apps.logs.watch", registry: registry, access: access(audit), logWindowMilliseconds: 10)(caller(), args)
        XCTAssertFalse(reply.isError)
        XCTAssertEqual(reply.structuredContent?["endReason"], .missing)
        let events = await audit.snapshot().0
        XCTAssertEqual(events, ["unwatch", "result"])
        XCTAssertFalse(reply.content.map(\.compact).joined().contains("private-arbitrary-stderr"))
    }

    func testAuthenticatedRPCProjectionAndCapabilitiesArePreserved() async throws {
        let registry = NativeChannelRegistry(), audit = BackendAppsMCPAudit()
        let projected = NativeRPCContext(caller: .page, ownerID: "restricted-session", capabilities: ["apps.read"])
        let scoped = BackendDockerMCPAccess(rpcContext: { _ in projected }, authorize: { _, _, _, _, _, _ in await audit.record("approve") })
        try await registry.register("apps:read", ownerID: "test") { context, _ in
            XCTAssertEqual(context.caller, projected.caller)
            XCTAssertEqual(context.ownerID, projected.ownerID)
            XCTAssertEqual(context.requestID, projected.requestID)
            XCTAssertEqual(context.capabilities, projected.capabilities)
            try context.require("apps.read")
            await audit.record("read")
            return .object([.init("name", .string("Example"))])
        }
        try await registry.register("apps:restart", ownerID: "test") { context, _ in
            try context.require("apps.write")
            await audit.record("write")
            return .object([.init("restarted", .bool(true))])
        }
        let read = try await handler("apps.read", registry: registry, access: scoped)(caller(), arguments())
        XCTAssertFalse(read.isError)
        let write = try await handler("apps.restart", registry: registry, access: scoped)(caller(), arguments())
        XCTAssertTrue(write.isError)
        XCTAssertEqual(write.structuredContent?["error"]["code"].string, "access-denied")
        let events = await audit.snapshot().0
        XCTAssertEqual(events, ["read", "approve"])
    }

    func testAPDConnectionReadUsesOnePayloadAndMasksPassword() async throws {
        let registry = NativeChannelRegistry(), audit = BackendAppsMCPAudit()
        let args = arguments()
        try await registry.register("apps:databases:connection", ownerID: "test") { _, values in
            XCTAssertEqual(values, [args])
            return .object([.init("kind", .string("postgres")), .init("host", .string("private-database")), .init("port", .number(5432)),
                            .init("database", .string("terminaldeck")), .init("username", .string("terminaldeck")),
                            .init("password", .string("dummy-private-db-password")), .init("passwordKey", .string("POSTGRES_PASSWORD")),
                            .init("scope", .string("private-network")), .init("network", .string("terminaldeck-apps")), .init("authenticationDatabase", .null)])
        }
        let reply = try await handler("apps.databases.connection", registry: registry, access: access(audit))(caller(tiers: [.read]), args)
        XCTAssertFalse(reply.isError)
        XCTAssertEqual(reply.structuredContent?["port"].number, 5432)
        XCTAssertEqual(reply.structuredContent?["scope"].string, "private-network")
        XCTAssertEqual(reply.structuredContent?["passwordKey"].string, "POSTGRES_PASSWORD")
        XCTAssertEqual(reply.structuredContent?["authenticationDatabase"], .null)
        XCTAssertFalse(reply.content.map(\.compact).joined().contains("dummy-private-db-password"))
        let events = await audit.snapshot().0
        XCTAssertEqual(events, ["result"])
    }

    func testCallerCannotInjectRuntimeNamespaceCaddyPathsOrPublicPorts() throws {
        let source = NativeRPCValue.object([.init("kind", .string("github")), .init("repository", .string("owner/repo")), .init("build", .string("auto"))])
        let create = arguments([("name", .string("Example")), ("source", source)])
        for field in ["stateRoot", "resourcePrefix", "privateNetwork", "caddyServerKey", "caddyAutosavePath", "approved"] {
            XCTAssertThrowsError(try BackendAppsMCP.validate(tool: "apps.create", arguments: create.setting(field, .string("caller-controlled"))), field)
        }
        XCTAssertThrowsError(try BackendAppsMCP.validate(tool: "apps.databases.connection", arguments: arguments().setting("password", .bool(true))))
        let publicPort = arguments([("name", .string("Example")), ("kind", .string("postgres")), ("publishedPort", .number(5432))])
        XCTAssertThrowsError(try BackendAppsMCP.validate(tool: "apps.databases.create", arguments: publicPort))
    }

    func testDatabaseBindingNamesBothAppsAndRejectsInvalidTargetOrSetting() throws {
        let valid = arguments([("targetAppId", .string("target-app")), ("key", .string("DATABASE_URL"))])
        XCTAssertNoThrow(try BackendAppsMCP.validate(tool: "apps.databases.bind", arguments: valid))
        let sentence = BackendAppsMCP.summary(tool: "apps.databases.bind", arguments: valid)
        for name in ["example", "target-app", "DATABASE_URL", "server-1"] { XCTAssertTrue(sentence.contains(name)) }
        XCTAssertTrue(sentence.contains("deploy the target app"))
        XCTAssertThrowsError(try BackendAppsMCP.validate(tool: "apps.databases.bind", arguments: valid.setting("targetAppId", .string("example"))))
        XCTAssertThrowsError(try BackendAppsMCP.validate(tool: "apps.databases.bind", arguments: valid.setting("targetAppId", .string("target-app\n"))))
        XCTAssertThrowsError(try BackendAppsMCP.validate(tool: "apps.databases.bind", arguments: valid.setting("key", .string("DATABASE_URL\n"))))
        XCTAssertThrowsError(try BackendAppsMCP.validate(tool: "apps.databases.bind", arguments: valid.setting("key", .string("1BAD"))))
        XCTAssertThrowsError(try BackendAppsMCP.validate(tool: "apps.databases.bind", arguments: valid.setting("value", .string("caller-supplied-uri"))))
    }

    func testBackupUploadPreservesOmissionAcceptsNullAndValidatesCredentialPairs() throws {
        let base = arguments([("enabled", .bool(true)), ("schedule", .string("daily")), ("retention", .number(7))])
        XCTAssertNoThrow(try BackendAppsMCP.validate(tool: "apps.backups.policy", arguments: base))
        XCTAssertNoThrow(try BackendAppsMCP.validate(tool: "apps.backups.policy", arguments: base.setting("upload", .null)))
        let savedCredentials = NativeRPCValue.object([.init("endpoint", .string("https://storage.example.com")), .init("bucket", .string("backups"))])
        XCTAssertNoThrow(try BackendAppsMCP.validate(tool: "apps.backups.policy", arguments: base.setting("upload", savedCredentials)))
        XCTAssertThrowsError(try BackendAppsMCP.validate(tool: "apps.backups.policy", arguments: base.setting("upload", savedCredentials.setting("accessKey", .string("dummy-access-only")))))
        XCTAssertThrowsError(try BackendAppsMCP.validate(tool: "apps.backups.policy", arguments: base.setting("upload", .string("not-an-upload-object"))))
        XCTAssertThrowsError(try BackendAppsMCP.validate(tool: "apps.backups.policy", arguments: base.setting("upload", savedCredentials.setting("approved", .bool(true)))))
    }
}

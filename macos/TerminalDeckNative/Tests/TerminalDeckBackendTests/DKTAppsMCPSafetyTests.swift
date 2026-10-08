import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Actual Apps MCP catalogue and dispatch, with synthetic registry handlers.
/// The two serving-gate tests listen only on the native MCP loopback endpoint.
/// DKA owns compilation/execution; this file opens no connection during writing.
@Suite("DKT Apps MCP safety")
struct DKTAppsMCPSafetyTests {
    @Test func catalogueMapsEveryAppsContractChannelWithUniqueNamesAndCorrectTiers() throws {
        let definitions = BackendAppsMCP.definitions()
        #expect(Set(definitions.map(\.channel)) == contractChannels)
        #expect(definitions.count == contractChannels.count)
        #expect(contractChannels.contains("apps:databases:connection"))
        #expect(contractChannels.contains("apps:databases:bind"))
        #expect(contractReadChannels.isDisjoint(with: contractWriteChannels))
        #expect(Set(definitions.map(\.id)).count == definitions.count)
        #expect(Set(definitions.map(\.wireName)).count == definitions.count)
        for entry in definitions {
            #expect(contractReadChannels.contains(entry.channel) || contractWriteChannels.contains(entry.channel))
            #expect(entry.tier == (contractWriteChannels.contains(entry.channel) ? .alter : .read))
            #expect(entry.destructive == ["apps.remove", "apps.backups.restore"].contains(entry.id))
            #expect(entry.inputSchema["additionalProperties"] == .bool(false))
            let specification = try entry.specification()
            #expect(specification.inputSchema == entry.inputSchema && specification.wireName == entry.wireName)
            try BackendAppsMCP.validate(tool: entry.id, arguments: sample(entry.id))
        }
        #expect(definitions.first { $0.id == "apps.env.patch" }?.channel == "apps:env:patch")
        #expect(definitions.first { $0.id == "apps.backups.policy.read" }?.channel == "apps:backups:policy:read")
        #expect(definitions.first { $0.id == "apps.databases.connection" }?.channel == "apps:databases:connection")
        #expect(definitions.first { $0.id == "apps.auto-deploy.apply" }?.wireName == "apps_auto_deploy_apply")
    }

    @Test func databaseConnectionHasAClosedReadSchemaAndCannotAcceptConnectionOverrides() throws {
        let definition = try #require(BackendAppsMCP.definitions().first { $0.id == "apps.databases.connection" })
        #expect(definition.channel == "apps:databases:connection" && definition.tier == .read)
        #expect(!definition.destructive)
        #expect(Set(definition.required) == ["serverId", "appId"])
        #expect(Set(definition.properties.fields?.map(\.key) ?? []) == ["serverId", "appId"])
        #expect(definition.inputSchema["additionalProperties"] == .bool(false))
        try BackendAppsMCP.validate(tool: definition.id, arguments: identity())
        for field in ["host", "port", "password", "connectionUri", "network", "approved"] {
            invalid(definition.id, identity().setting(field, .string("caller-override")))
        }
        invalid(definition.id, identity().removing("serverId"))
        invalid(definition.id, identity().removing("appId"))
    }

    @Test func databaseConnectionReadPreservesPublicCoordinatesAndMasksOnlyCredentialValues() async throws {
        let registry = NativeChannelRegistry(), trace = DKTAppsMCPTrace()
        try await registry.register("apps:databases:connection", ownerID: "dkt-apps-fixture") { context, arguments in
            #expect(context.caller == .page && context.ownerID == "dkt-apps-peer")
            #expect(arguments == [.object([.init("serverId", .string("fixture-server")), .init("appId", .string("dkt-app"))])])
            await trace.add("connection-read")
            return .object([
                .init("kind", .string("postgres")), .init("host", .string("terminaldeck-dkt-app")),
                .init("port", .number(5432)), .init("database", .string("terminaldeck")),
                .init("username", .string("terminaldeck")), .init("password", .string("ordinary-private-password")),
                .init("passwordKey", .string("POSTGRES_PASSWORD")), .init("scope", .string("private-network")),
                .init("network", .string("terminaldeck-apps")), .init("instructions", .string("Use the protected setting on this private network.")),
                .init("status", .string("running")), .init("authenticationDatabase", .null)
            ])
        }
        let reply = try await call("apps.databases.connection", arguments: identity(), registry: registry, access: access(trace), tiers: [.read])
        #expect(!reply.isError)
        let result = try #require(reply.structuredContent)
        #expect(result["host"] == .string("terminaldeck-dkt-app") && result["port"] == .number(5432))
        #expect(result["database"] == .string("terminaldeck") && result["username"] == .string("terminaldeck"))
        #expect(result["password"] == .string("[redacted]"))
        #expect(result["passwordKey"] == .string("POSTGRES_PASSWORD"))
        #expect(result["scope"] == .string("private-network") && result["network"] == .string("terminaldeck-apps"))
        #expect(result["status"] == .string("running") && result["authenticationDatabase"] == .null)
        #expect(result["connectionUri"] == .missing)
        #expect(!replyText(reply).contains("ordinary-private-password"))
        #expect(await trace.phases == ["identity", "connection-read", "result"])
        await registry.shutdown()
    }

    @Test func allActualSchemasRejectForgedApprovalsAndRuntimeOverrides() {
        for entry in BackendAppsMCP.definitions() {
            for key in ["approved", "approvalToken", "resourcePrefix", "stateRoot", "privateNetwork", "socketPath", "sshHost"] {
                invalid(entry.id, sample(entry.id).setting(key, key == "approved" ? .bool(true) : .string("injected")))
            }
            let args = sample(entry.id).setting("serverId", .string("fixture-server"))
            invalid(entry.id, .object((args.fields ?? []) + [.init("serverId", .string("duplicate-server"))]))
        }
    }

    @Test func nestedSourceAndUploadSchemasRejectUnexpectedAuthorityFields() {
        invalid("apps.create", sample("apps.create").setting("source", source().setting("approved", .bool(true))))
        invalid("apps.create", sample("apps.create").setting("source", source().setting("sshHost", .string("attacker"))))
        let upload = uploadSecrets().setting("admin", .bool(true))
        invalid("apps.backups.policy", enabledPolicy().setting("upload", upload))
        let duplicates = NativeRPCValue.object((uploadSecrets().fields ?? []) + [.init("secretKey", .string("second-secret"))])
        invalid("apps.backups.policy", enabledPolicy().setting("upload", duplicates))
    }

    @Test func realSchemasRejectBadAppIDsChoicesAndIntegerRanges() {
        for id in ["Uppercase", "1-start", "../other", "a/b", String(repeating: "a", count: 49), "bad\0id"] {
            invalid("apps.deploy", identity().setting("appId", .string(id)))
        }
        invalid("apps.databases.create", sample("apps.databases.create").setting("kind", .string("sqlite")))
        invalid("apps.create", sample("apps.create").setting("source", source().setting("port", .number(65_536))))
        for retention in [0.0, 366.0, 1.5, Double.infinity, Double.nan] {
            invalid("apps.backups.policy", enabledPolicy().setting("retention", .number(retention)))
        }
        invalid("apps.logs.read", identity().setting("tail", .number(0)))
        invalid("apps.logs.read", identity().setting("tail", .number(1_001)))
    }

    @Test func backupPolicyDisableNeedsNoScheduleAndEnableNeedsCompleteFields() throws {
        try BackendAppsMCP.validate(tool: "apps.backups.policy", arguments: identity().setting("enabled", .bool(false)))
        try BackendAppsMCP.validate(tool: "apps.backups.policy.read", arguments: identity())
        try BackendAppsMCP.validate(tool: "apps.backups.policy", arguments: enabledPolicy())
        invalid("apps.backups.policy", identity())
        invalid("apps.backups.policy", identity().setting("enabled", .bool(true)))
        invalid("apps.backups.policy", enabledPolicy().removing("schedule"))
        invalid("apps.backups.policy", enabledPolicy().removing("retention"))
    }

    @Test func envPatchPreservesTypedSetAndRemoveAndRejectsMaskedReplacementValues() throws {
        let patch = identity().setting("set", .object([.init("GREETING", .string("real-value"))]))
            .setting("remove", .array([.string("OBSOLETE")]))
        try BackendAppsMCP.validate(tool: "apps.env.patch", arguments: patch)
        for masked in ["••••••••", "••••••", "[redacted]"] {
            for tool in ["apps.env.apply", "apps.env.patch", "apps.create", "apps.templates.deploy"] {
                let key = tool == "apps.env.patch" ? "set" : "env"
                invalid(tool, sample(tool).setting(key, .object([.init("GREETING", .string(masked))])))
            }
        }
        invalid("apps.env.patch", patch.setting("remove", .array([.number(5)])))
        invalid("apps.env.patch", patch.setting("set", .object([.init("BAD-NAME", .string("value"))])))
    }

    @Test func servingGateDeniesAToolOutsideTheActualCallerGrantBeforeDispatch() async throws {
        let registry = NativeChannelRegistry(), trace = DKTAppsMCPTrace()
        try await register("apps:deploy", registry: registry, trace: trace)
        let result = try await servingCall(tool: "apps.deploy", arguments: identity(), registry: registry,
            access: access(trace), tools: ["apps.list"], tiers: [.read, .alter])
        #expect(result["result"]["isError"] == .bool(true))
        #expect(await trace.phases.isEmpty)
        await registry.shutdown()
    }

    @Test func servingGateDeniesAMutationOutsideTheActualCallerTierBeforeDispatch() async throws {
        let registry = NativeChannelRegistry(), trace = DKTAppsMCPTrace()
        try await register("apps:deploy", registry: registry, trace: trace)
        let result = try await servingCall(tool: "apps.deploy", arguments: identity(), registry: registry,
            access: access(trace), tools: ["apps.deploy"], tiers: [.read])
        #expect(result["result"]["isError"] == .bool(true))
        #expect(await trace.phases.isEmpty)
        await registry.shutdown()
    }

    @Test func missingOperationIsUnavailableWithoutApprovalOrIdentityResolution() async throws {
        let registry = NativeChannelRegistry(), trace = DKTAppsMCPTrace()
        let reply = try await call("apps.deploy", arguments: identity(), registry: registry, access: access(trace))
        failure(reply, code: "unavailable")
        #expect(await trace.phases.isEmpty)
        await registry.shutdown()
    }

    @Test func forgedApprovalIsRejectedBeforeApprovalOrChannelDispatch() async throws {
        let registry = NativeChannelRegistry(), trace = DKTAppsMCPTrace()
        try await register("apps:deploy", registry: registry, trace: trace)
        let reply = try await call("apps.deploy", arguments: identity().setting("approved", .bool(true)),
            registry: registry, access: access(trace))
        failure(reply, code: "invalid-arguments")
        #expect(await trace.phases.isEmpty)
        await registry.shutdown()
    }

    @Test func everyWriteRequestsApprovalBeforeMutationAndKeepsTheRealIdentity() async throws {
        for tool in writeTools.sorted() {
            let registry = NativeChannelRegistry(), trace = DKTAppsMCPTrace()
            let channel = try #require(BackendAppsMCP.definitions().first { $0.id == tool }?.channel)
            try await register(channel, registry: registry, trace: trace)
            if ["apps.remove", "apps.backups.restore"].contains(tool) {
                try await registry.register("apps:read", ownerID: "dkt-apps-fixture") { context, arguments in
                    #expect(context.ownerID == "dkt-apps-peer")
                    #expect(arguments.first == .object([.init("serverId", .string("fixture-server")), .init("appId", .string("dkt-app"))]))
                    await trace.add("inspect")
                    return .object([.init("name", .string("DKT app"))])
                }
            }
            let reply = try await call(tool, arguments: sample(tool), registry: registry, access: access(trace))
            #expect(!reply.isError)
            let phases = await trace.phases
            let approval = try #require(phases.firstIndex(of: "approval"))
            let dispatch = try #require(phases.firstIndex(of: "dispatch:" + channel))
            #expect(approval < dispatch)
            if !["apps.remove", "apps.backups.restore"].contains(tool) {
                #expect(phases.first == "approval" && phases.dropFirst().first == "identity")
            }
            #expect(phases.last == "result")
            await registry.shutdown()
        }
    }

    @Test func readUsesCallerScopeWithoutAskingForWriteApproval() async throws {
        let registry = NativeChannelRegistry(), trace = DKTAppsMCPTrace()
        try await register("apps:backups:policy:read", registry: registry, trace: trace)
        let reply = try await call("apps.backups.policy.read", arguments: identity(), registry: registry, access: access(trace), tiers: [.read])
        #expect(!reply.isError)
        #expect(await trace.phases == ["identity", "dispatch:apps:backups:policy:read", "result"])
        await registry.shutdown()
    }

    @Test func approvalRefusalDoesNotResolveIdentityOrDispatchAndSanitizesTheError() async throws {
        let registry = NativeChannelRegistry(), trace = DKTAppsMCPTrace()
        try await register("apps:create", registry: registry, trace: trace)
        let denied = BackendDockerMCPAccess(rpcContext: { _ in
            await trace.add("identity")
            return .init(caller: .page, ownerID: "dkt-apps-peer")
        }, authorize: { _, _, arguments, _, summary, _ in
            #expect(!arguments.compact.contains("ordinary-private"))
            #expect(!summary.contains("ordinary-private"))
            await trace.add("approval")
            throw NativeRPCError(code: "approval-required", message: "ordinary-private", details: .string("secret-detail"))
        })
        let args = sample("apps.create").setting("env", .object([.init("GREETING", .string("ordinary-private"))]))
        let reply = try await call("apps.create", arguments: args, registry: registry, access: denied)
        failure(reply, code: "approval-required")
        #expect(await trace.phases == ["approval"])
        #expect(!replyText(reply).contains("ordinary-private") && !replyText(reply).contains("secret-detail"))
        await registry.shutdown()
    }

    @Test func cancellationBeforeCallPreventsApprovalAndChannelDispatch() async throws {
        let registry = NativeChannelRegistry(), trace = DKTAppsMCPTrace()
        try await register("apps:deploy", registry: registry, trace: trace)
        let cancellation = BackendMCPCancellation()
        cancellation.cancel()
        let reply = try await call("apps.deploy", arguments: identity(), registry: registry, access: access(trace), cancellation: cancellation)
        failure(reply, code: "cancelled")
        #expect(await trace.phases.isEmpty)
        await registry.shutdown()
    }

    @Test func cancellationAtApprovalReturnPreventsIdentityAndChannelDispatch() async throws {
        let registry = NativeChannelRegistry(), trace = DKTAppsMCPTrace()
        try await register("apps:deploy", registry: registry, trace: trace)
        let cancelling = BackendDockerMCPAccess(rpcContext: { _ in
            await trace.add("identity")
            return .init(caller: .page, ownerID: "dkt-apps-peer")
        }, authorize: { context, _, _, _, _, _ in
            await trace.add("approval")
            context.cancellation.cancel()
        })
        let reply = try await call("apps.deploy", arguments: identity(), registry: registry, access: cancelling)
        failure(reply, code: "cancelled")
        #expect(await trace.phases == ["approval"])
        await registry.shutdown()
    }

    @Test func cancellationAtIdentityReturnPreventsChannelDispatch() async throws {
        let registry = NativeChannelRegistry(), trace = DKTAppsMCPTrace()
        try await register("apps:deploy", registry: registry, trace: trace)
        let cancelling = BackendDockerMCPAccess(rpcContext: { context in
            await trace.add("identity")
            context.cancellation.cancel()
            return .init(caller: .page, ownerID: "dkt-apps-peer")
        }, authorize: { _, _, _, _, _, _ in await trace.add("approval") })
        let reply = try await call("apps.deploy", arguments: identity(), registry: registry, access: cancelling)
        failure(reply, code: "cancelled")
        #expect(await trace.phases == ["approval", "identity"])
        await registry.shutdown()
    }

    @Test func destructiveNameIsReadBeforeApprovalAndStaleConfirmationCannotMutate() async throws {
        for tool in ["apps.remove", "apps.backups.restore"] {
            let registry = NativeChannelRegistry(), trace = DKTAppsMCPTrace()
            let channel = try #require(BackendAppsMCP.definitions().first { $0.id == tool }?.channel)
            try await register(channel, registry: registry, trace: trace)
            try await registry.register("apps:read", ownerID: "dkt-apps-fixture") { _, _ in
                await trace.add("inspect")
                return .object([.init("name", .string("Renamed app"))])
            }
            let reply = try await call(tool, arguments: sample(tool), registry: registry, access: access(trace))
            failure(reply, code: "confirmation-required")
            #expect(await trace.phases == ["identity", "inspect"])
            await registry.shutdown()
        }
    }

    @Test func createApplyPatchAndTemplateSecretsReachOnlyTheEngineNotMetadataOrReplies() async throws {
        for tool in ["apps.create", "apps.env.apply", "apps.env.patch", "apps.templates.deploy"] {
            let registry = NativeChannelRegistry(), trace = DKTAppsMCPTrace()
            let channel = try #require(BackendAppsMCP.definitions().first { $0.id == tool }?.channel)
            let key = tool == "apps.env.patch" ? "set" : "env"
            let args = sample(tool).setting(key, .object([.init("GREETING", .string("ordinary-private")), .init("MODE", .string("xy"))]))
            try await registry.register(channel, ownerID: "dkt-apps-fixture") { context, arguments in
                #expect(context.ownerID == "dkt-apps-peer")
                #expect(arguments.first?[key]["GREETING"] == .string("ordinary-private"))
                return .object([
                    .init("environment", .array([.object([.init("key", .string("GREETING")), .init("value", .string("ordinary-private")), .init("secret", .bool(true))])])),
                    .init("message", .string("ordinary-private / xy"))
                ])
            }
            let protected = BackendDockerMCPAccess(rpcContext: { _ in .init(caller: .page, ownerID: "dkt-apps-peer") },
                authorize: { _, _, arguments, tier, summary, _ in
                    #expect(tier == .alter)
                    #expect(!arguments.compact.contains("ordinary-private") && !arguments.compact.contains("xy"))
                    #expect(!summary.contains("ordinary-private") && !summary.contains("xy"))
                    #expect(arguments[key]["GREETING"] == .string("[redacted]"))
                }, noteResult: { _, value in
                    #expect(!value.compact.contains("ordinary-private") && !value.compact.contains("xy"))
                    await trace.add("safe-result")
                })
            let reply = try await call(tool, arguments: args, registry: registry, access: protected)
            #expect(!reply.isError)
            #expect(!replyText(reply).contains("ordinary-private") && !replyText(reply).contains("xy"))
            #expect(reply.structuredContent?["environment"].elements?.first?["key"] == .string("GREETING"))
            #expect(await trace.phases == ["safe-result"])
            await registry.shutdown()
        }
    }

    @Test func backupUploadCredentialsAreMaskedInApprovalSummaryOutputAndResultLog() async throws {
        let registry = NativeChannelRegistry(), trace = DKTAppsMCPTrace()
        let args = enabledPolicy().setting("upload", uploadSecrets())
        try await registry.register("apps:backups:policy", ownerID: "dkt-apps-fixture") { _, arguments in
            #expect(arguments.first?["upload"]["accessKey"] == .string("ordinary-access"))
            #expect(arguments.first?["upload"]["secretKey"] == .string("ordinary-secret"))
            return .object([.init("enabled", .bool(true)), .init("upload", arguments.first?["upload"] ?? .missing),
                .init("message", .string("ordinary-access ordinary-secret"))])
        }
        let protected = BackendDockerMCPAccess(rpcContext: { _ in .init(caller: .page, ownerID: "dkt-apps-peer") },
            authorize: { _, _, arguments, _, summary, _ in
                #expect(arguments["upload"]["accessKey"] == .string("[redacted]"))
                #expect(arguments["upload"]["secretKey"] == .string("[redacted]"))
                #expect(!summary.contains("ordinary-access") && !summary.contains("ordinary-secret"))
            }, noteResult: { _, value in
                #expect(!value.compact.contains("ordinary-access") && !value.compact.contains("ordinary-secret"))
                await trace.add("safe-result")
            })
        let reply = try await call("apps.backups.policy", arguments: args, registry: registry, access: protected)
        #expect(!reply.isError)
        #expect(!replyText(reply).contains("ordinary-access") && !replyText(reply).contains("ordinary-secret"))
        #expect(await trace.phases == ["safe-result"])
        await registry.shutdown()
    }

    @Test func dependencyErrorsKeepSafeCodesAndNeverReturnRawMessagesOrDetails() async throws {
        for code in ["invalid-arguments", "build-failed", "backup-failed", "restore-failed", "route-failed", "state-failed", "unavailable", "unknown-private-code"] {
            let registry = NativeChannelRegistry(), trace = DKTAppsMCPTrace()
            try await registry.register("apps:deploy", ownerID: "dkt-apps-fixture") { _, _ in
                throw NativeRPCError(code: code, message: "ordinary-private stored-secret", details: .object([.init("stderr", .string("private-details"))]))
            }
            let reply = try await call("apps.deploy", arguments: identity(), registry: registry, access: access(trace))
            failure(reply, code: code == "unknown-private-code" ? "unavailable" : code)
            #expect(!replyText(reply).contains("ordinary-private") && !replyText(reply).contains("stored-secret"))
            #expect(!replyText(reply).contains("private-details") && !replyText(reply).contains("unknown-private-code"))
            #expect(await trace.phases == ["approval", "identity"])
            await registry.shutdown()
        }
    }

    @Test func emptyContractResultsFailButARealEmptyListRemainsSuccessful() async throws {
        for value in [NativeRPCValue.null, .missing, .object([]), .array([])] {
            let registry = NativeChannelRegistry(), trace = DKTAppsMCPTrace()
            try await registry.register("apps:list", ownerID: "dkt-apps-fixture") { _, _ in value }
            let reply = try await call("apps.list", arguments: sample("apps.list"), registry: registry, access: access(trace), tiers: [.read])
            if value == .array([]) { #expect(!reply.isError) }
            else { failure(reply, code: "unavailable") }
            await registry.shutdown()
        }
    }

    @Test func liveLogReadCannotOpenWithoutOwnedCleanupAndUnwatchRefusesPhantomSuccess() async throws {
        let registry = NativeChannelRegistry(), trace = DKTAppsMCPTrace()
        try await register("apps:logs:watch", registry: registry, trace: trace)
        let watch = try await call("apps.logs.watch", arguments: sample("apps.logs.watch"), registry: registry, access: access(trace), tiers: [.read])
        failure(watch, code: "unavailable")
        #expect(await trace.phases == ["identity"])
        let unwatch = try await call("apps.logs.unwatch", arguments: sample("apps.logs.unwatch"), registry: registry, access: access(trace), tiers: [.read])
        failure(unwatch, code: "unavailable")
        #expect(await trace.phases == ["identity"])
        await registry.shutdown()
    }

    private var contractChannels: Set<String> {
        BackendAppsChannels.invokeChannels.union(BackendAppsDataChannels.invokeChannels)
    }
    private var contractReadChannels: Set<String> {
        BackendAppsChannels.readChannels.union(BackendAppsDataChannels.readChannels)
    }
    private var contractWriteChannels: Set<String> {
        BackendAppsChannels.writeChannels.union(BackendAppsDataChannels.writeChannels)
    }
    private var writeTools: Set<String> {
        Set(BackendAppsMCP.definitions().filter { contractWriteChannels.contains($0.channel) }.map(\.id))
    }
    private func identity() -> NativeRPCValue {
        .object([.init("serverId", .string("fixture-server")), .init("appId", .string("dkt-app"))])
    }
    private func source() -> NativeRPCValue {
        .object([.init("kind", .string("github")), .init("repository", .string("dkt/example")), .init("build", .string("dockerfile"))])
    }
    private func enabledPolicy() -> NativeRPCValue {
        identity().setting("enabled", .bool(true)).setting("schedule", .string("daily")).setting("retention", .number(7))
    }
    private func uploadSecrets() -> NativeRPCValue {
        .object([.init("endpoint", .string("https://objects.invalid")), .init("bucket", .string("dkt-backups")),
            .init("prefix", .string("dkt")), .init("accessKey", .string("ordinary-access")), .init("secretKey", .string("ordinary-secret"))])
    }
    private func sample(_ tool: String) -> NativeRPCValue {
        var args = identity()
        switch tool {
        case "apps.capabilities", "apps.list", "apps.caddy.plan", "apps.caddy.install": args = args.removing("appId")
        case "apps.templates.list": args = .object([])
        case "apps.create": args = args.setting("name", .string("DKT app")).setting("source", source())
        case "apps.rollback": args = args.setting("deploymentId", .string("dkt-deploy-1"))
        case "apps.remove": args = args.setting("confirmation", .string("DKT app"))
        case "apps.env.apply": args = args.setting("env", .object([]))
        case "apps.env.patch": args = args.setting("set", .object([])).setting("remove", .array([]))
        case "apps.domains.check": args = args.setting("domain", .string("dkt.invalid"))
        case "apps.domains.apply": args = args.setting("domains", .array([.string("dkt.invalid")]))
        case "apps.databases.create": args = args.setting("name", .string("DKT app")).setting("kind", .string("postgres"))
        case "apps.databases.bind": args = args.setting("targetAppId", .string("dkt-target")).setting("key", .string("DATABASE_URL"))
        case "apps.backups.policy": args = args.setting("enabled", .bool(false))
        case "apps.backups.restore": args = args.setting("backupId", .string("dkt-backup-1")).setting("confirmation", .string("DKT app"))
        case "apps.templates.deploy": args = args.setting("name", .string("DKT app")).setting("templateId", .string("dkt-template"))
        case "apps.auto-deploy.apply": args = args.setting("enabled", .bool(false))
        case "apps.logs.watch": args = args.setting("streamId", .string("dkt-stream"))
        case "apps.logs.unwatch": args = args.removing("appId").setting("streamId", .string("dkt-stream"))
        default: break
        }
        return args
    }
    private func invalid(_ tool: String, _ arguments: NativeRPCValue) {
        do {
            try BackendAppsMCP.validate(tool: tool, arguments: arguments)
            Issue.record("Unsafe Apps arguments were accepted by \(tool).")
        } catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        catch { Issue.record("Apps validation lost its public failure code.") }
    }
    private func failure(_ reply: BackendMCPToolReply, code: String) {
        #expect(reply.isError)
        #expect(reply.structuredContent?["error"]["code"] == .string(code))
    }
    private func replyText(_ reply: BackendMCPToolReply) -> String {
        reply.content.map(\.compact).joined() + (reply.structuredContent?.compact ?? "")
    }
    private func access(_ trace: DKTAppsMCPTrace) -> BackendDockerMCPAccess {
        .init(rpcContext: { _ in
            await trace.add("identity")
            return .init(caller: .page, ownerID: "dkt-apps-peer")
        }, authorize: { _, _, _, tier, _, _ in
            #expect(tier == .alter)
            await trace.add("approval")
        }, noteResult: { _, _ in await trace.add("result") })
    }
    private func register(_ channel: String, registry: NativeChannelRegistry, trace: DKTAppsMCPTrace) async throws {
        try await registry.register(channel, ownerID: "dkt-apps-fixture") { context, _ in
            #expect(context.caller == .page && context.ownerID == "dkt-apps-peer")
            await trace.add("dispatch:" + channel)
            return .object([.init("ok", .bool(true))])
        }
    }
    private func call(_ tool: String, arguments: NativeRPCValue, registry: NativeChannelRegistry,
                      access: BackendDockerMCPAccess, tiers: Set<BackendMCPTier> = [.read, .alter],
                      cancellation: BackendMCPCancellation = .init()) async throws -> BackendMCPToolReply {
        let entries = try BackendAppsMCP.contribution(registry: registry, access: access, logWindowMilliseconds: 1)
        let handler = try #require(entries.first { $0.0.id == tool }?.1)
        let caller = BackendMCPCallContext(sessionID: "dkt-apps-session", machineID: "", projectRoot: nil, attended: true,
            allowedTools: [tool], allowedTiers: tiers, cancellation: cancellation)
        return try await handler(caller, arguments)
    }
    private func servingCall(tool: String, arguments: NativeRPCValue, registry: NativeChannelRegistry,
                             access: BackendDockerMCPAccess, tools: Set<String>, tiers: Set<BackendMCPTier>) async throws -> NativeRPCValue {
        let server = BackendNativeMCPServer()
        do {
            _ = try await BackendAppsMCP.register(server: server, registry: registry, access: access)
            let endpoint = try await server.start()
            let token = String(repeating: "a", count: 64)
            let caller = try await server.register(token: token, grant: .init(attended: true, allowedTools: tools, allowedTiers: tiers))
            try await server.bind(caller, sessionID: "dkt-apps-session", machineID: "")
            var request = URLRequest(url: endpoint.url, timeoutInterval: 2)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.httpBody = try NativeRPCValue.object([
                .init("jsonrpc", .string("2.0")), .init("id", .number(1)), .init("method", .string("tools/call")),
                .init("params", .object([.init("name", .string(tool)), .init("arguments", arguments)]))
            ]).encodedJSON()
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            let value = try NativeRPCValue.parseJSON(bytes)
            await server.stop()
            return value
        } catch { await server.stop(); throw error }
    }
}

private actor DKTAppsMCPTrace {
    private(set) var phases: [String] = []
    func add(_ phase: String) { phases.append(phase) }
}

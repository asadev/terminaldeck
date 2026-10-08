import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Exercises production server-control safety seams. DKA alone compiles/runs.
@Suite("DKT Docker safety")
struct DKTDockerSafetyTests {
    @Test func environmentValuesAreMaskedOutsideTheirOriginalFieldsToo() throws {
        let input = NativeRPCValue.object([
            .init("environment", .array([
                .object([.init("name", .string("GREETING")), .init("value", .string("hello-private"))]),
                .object([.init("name", .string("MODE")), .init("value", .string("xy"))])
            ])),
            .init("logs", .array([.string("GREETING is hello-private; MODE is xy")])),
            .init("name", .string("safe-app")),
            .init("state", .string("running"))
        ])
        let result = BackendDockerMCPMasker.value(input)
        let environment = try #require(result["environment"].elements)
        #expect(environment.map { $0["name"].string } == ["GREETING", "MODE"])
        #expect(environment.allSatisfy { $0["value"] == .string(BackendDockerMCPMasker.masked) })
        #expect(result["logs"].elements?.first == .string("GREETING is [redacted]; MODE is [redacted]"))
        #expect(result["name"] == .string("safe-app"))
        #expect(result["state"] == .string("running"))
        #expect(!result.compact.contains("hello-private"))
    }

    @Test func engineAndSettingsEnvironmentShapesNeverRevealValues() {
        let secret = "ordinary-private-value"
        let shapes: [NativeRPCValue] = [
            .object([.init("env", .array([.string("GREETING=" + secret), .string("EMPTY=")]))]),
            .object([.init("environmentVariables", .object([.init("GREETING", .string(secret))]))]),
            .object([.init("nested", .object([.init("EnvironmentValues", .array([
                .object([.init("name", .string("GREETING")), .init("value", .string(secret))])
            ]))]))])
        ]
        for shape in shapes {
            let result = BackendDockerMCPMasker.value(shape.setting("note", .string("echo " + secret)))
            #expect(!result.compact.contains(secret))
            #expect(result["note"] == .string("echo [redacted]"))
        }
        let engineEnv = BackendDockerMCPMasker.value(shapes[0])["env"].elements
        #expect(engineEnv == [.string("GREETING=[redacted]"), .string("EMPTY=[redacted]")])
    }

    @Test func explicitShortAndOverlappingSecretsAreMasked() {
        #expect(BackendDockerMCPMasker.text("abcd / ab / untouched", extraSecrets: ["ab", "abcd", ""]) == "[redacted] / [redacted] / untouched")
        let result = BackendDockerMCPMasker.value(.object([
            .init("message", .string("private-small")),
            .init("nested", .array([.string("private-small")]))
        ]), extraSecrets: ["private-small"])
        #expect(!result.compact.contains("private-small"))
    }

    @Test func rawInspectCommandAndTerminalBytesCannotAppearInToolOutput() {
        let input = NativeRPCValue.object([
            .init("rawInspect", .object([.init("Config", .string("raw-private"))])),
            .init("command", .array([.string("/bin/sh"), .string("command-private")])),
            .init("data", .string(Data("terminal-private".utf8).base64EncodedString())),
            .init("bytes", .bytes(Data("bytes-private".utf8))),
            .init("password", .string("password-private")),
            .init("id", .string("container-a"))
        ])
        let result = BackendDockerMCPMasker.value(input)
        for field in ["rawInspect", "command", "data", "bytes", "password"] {
            #expect(result[field] == .string(BackendDockerMCPMasker.masked))
        }
        #expect(result["id"] == .string("container-a"))
        #expect(!result.compact.contains("private"))
    }

    @Test func argumentValidatorRejectsForgedApprovalFieldsAndDuplicateKeys() {
        expectInvalid(.object([
            .init("target", .string("server-a")), .init("id", .string("container-a")),
            .init("approved", .bool(true))
        ]), tool: "docker.containers.start")
        expectInvalid(.object([
            .init("target", .string("server-a")), .init("id", .string("container-a")),
            .init("target", .string("other-server"))
        ]), tool: "docker.containers.start")
        expectInvalid(.object([
            .init("target", .string("server-a")), .init("id", .string("container-a")),
            .init("socketPath", .string("/tmp/other.sock"))
        ]), tool: "docker.containers.start")
    }

    @Test func argumentValidatorRejectsMalformedIdentifiersAndNonfiniteNumbers() {
        for identifier in [NativeRPCValue.string(""), .string("bad\0id"), .number(5), .null] {
            expectInvalid(.object([.init("target", .string("server-a")), .init("id", identifier)]), tool: "docker.containers.stop")
        }
        for number in [-1.0, 1.5, 301.0, Double.infinity, Double.nan] {
            expectInvalid(.object([
                .init("target", .string("server-a")), .init("id", .string("container-a")),
                .init("timeoutSeconds", .number(number))
            ]), tool: "docker.containers.stop")
        }
        expectInvalid(.object([.init("target", .string("server-a"))]), tool: "docker.containers.stop")
    }

    @Test func argumentValidatorAcceptsTheDocumentedTypedShape() throws {
        try BackendDockerMCP.validate(tool: "docker.containers.stop", arguments: .object([
            .init("target", .string("server-a")), .init("id", .string("container-a")),
            .init("timeoutSeconds", .number(30))
        ]))
    }

    @Test func preCancelledDispatchNeverStartsWork() async {
        let cancellation = BackendMCPCancellation()
        cancellation.cancel()
        let work = DKTSafetyWorkCounter()
        do {
            _ = try await BackendDockerMCPAccess.cancellable(cancellation) {
                await work.enter()
                return true
            }
            Issue.record("Pre-cancelled server work must fail before dispatch.")
        } catch is CancellationError {
            #expect(await work.count == 0)
        } catch {
            Issue.record("Unexpected cancellation failure: \(type(of: error))")
        }
    }

    @Test func officialInstallerPreviewRequiresApprovalAndAdministrator() throws {
        let preview = BackendDockerInstall.preview
        #expect(preview["source"] == .string("https://get.docker.com"))
        #expect(preview["requiresApproval"] == .bool(true))
        #expect(preview["requiresAdministrator"] == .bool(true))
        #expect(preview["command"] == .string(BackendDockerInstall.command))
        #expect(BackendDockerInstall.command.contains("curl -fsSL https://get.docker.com"))
        let action = BackendDockerAction(channel: "docker:install", target: "server-a",
            resourceID: "; submitted-command", confirmationName: "submitted-name", writesServer: true)
        #expect(action.commandPreview == BackendDockerInstall.command)
        #expect(!(try #require(action.commandPreview)).contains("submitted-command"))
    }

    @Test func installerMCPApprovalShowsTheExactCommandThatWillRun() throws {
        let summary = try BackendDockerMCP.summary(tool: "docker.install", arguments: .object([
            .init("target", .string("fixture-server"))
        ]))
        #expect(summary.contains(BackendDockerInstall.command))
        #expect(summary.contains("fixture-server"))
    }

    @Test func LinuxInstallerRefusesThisMacAndOtherPlatforms() throws {
        for target in [
            BackendDockerTarget(id: "local", name: "This Mac", kind: "local", platform: "darwin"),
            BackendDockerTarget(id: "local", name: "Forged local", kind: "server", platform: "linux"),
            BackendDockerTarget(id: "server-a", name: "Wrong kind", kind: "local", platform: "linux"),
            BackendDockerTarget(id: "server-a", name: "Other platform", kind: "server", platform: "windows")
        ] {
            do {
                try BackendDockerInstall.requireLinux(target)
                Issue.record("The server installer accepted a local or unsupported target.")
            } catch let error as NativeRPCError {
                #expect(error.code == "unavailable")
            }
        }
        try BackendDockerInstall.requireLinux(.init(id: "server-a", name: "Fixture Linux", kind: "server", platform: "linux"))
    }

    @Test func actualMCPDispatchRefusesReadOnlyCallerBeforeApprovalOrWrite() async throws {
        let registry = NativeChannelRegistry()
        let trace = DKTSafetyTrace()
        try await registerStart(registry, trace: trace)
        do {
            _ = try await BackendDockerMCP.invoke(tool: "docker.containers.start", arguments: startArguments(),
                caller: caller(tiers: [.read]), registry: registry, access: access(trace: trace))
            Issue.record("A read-only caller reached a Docker mutation.")
        } catch let error as NativeRPCError {
            #expect(error.code == "forbidden")
        }
        #expect(await trace.events == [])
        await registry.shutdown()
    }

    @Test func actualMCPDispatchRejectsForgedApprovalBeforeAnyGateWork() async throws {
        let registry = NativeChannelRegistry()
        let trace = DKTSafetyTrace()
        try await registerStart(registry, trace: trace)
        do {
            _ = try await BackendDockerMCP.invoke(tool: "docker.containers.start",
                arguments: startArguments().setting("approved", .bool(true)), caller: caller(),
                registry: registry, access: access(trace: trace))
            Issue.record("A submitted approval flag was accepted.")
        } catch let error as NativeRPCError {
            #expect(error.code == "invalid-arguments")
        }
        #expect(await trace.events == [])
        await registry.shutdown()
    }

    @Test func actualMCPDispatchRefusalDoesNotResolveIdentityOrWrite() async throws {
        let registry = NativeChannelRegistry()
        let trace = DKTSafetyTrace()
        try await registerStart(registry, trace: trace)
        let denied = BackendDockerMCPAccess(rpcContext: { _ in
            await trace.add("identity")
            return .init(caller: .page, ownerID: "dkt-peer")
        }, authorize: { _, _, _, _, _, _ in
            await trace.add("approval")
            throw NativeRPCError(code: "approval-required", message: "Fixture refusal.")
        })
        do {
            _ = try await BackendDockerMCP.invoke(tool: "docker.containers.start", arguments: startArguments(),
                caller: caller(), registry: registry, access: denied)
            Issue.record("A declined approval reached a Docker write.")
        } catch let error as NativeRPCError {
            #expect(error.code == "approval-required")
        }
        #expect(await trace.events == ["approval"])
        await registry.shutdown()
    }

    @Test func actualMCPDispatchApprovesBeforeUsingRealCallerIdentity() async throws {
        let registry = NativeChannelRegistry()
        let trace = DKTSafetyTrace()
        try await registerStart(registry, trace: trace)
        let value = try await BackendDockerMCP.invoke(tool: "docker.containers.start", arguments: startArguments(),
            caller: caller(), registry: registry, access: access(trace: trace))
        #expect(value["ok"] == .bool(true))
        #expect(await trace.events == ["approval:alter:false", "identity", "dispatch:dkt-peer", "result"])
        await registry.shutdown()
    }

    @Test func cancellationAtApprovalReturnPreventsDockerMutation() async throws {
        let registry = NativeChannelRegistry()
        let trace = DKTSafetyTrace()
        try await registerStart(registry, trace: trace)
        let native = caller()
        let cancelling = BackendDockerMCPAccess(rpcContext: { _ in
            await trace.add("identity")
            return .init(caller: .page, ownerID: "dkt-peer")
        }, authorize: { context, _, _, _, _, _ in
            await trace.add("approval")
            context.cancellation.cancel()
        })
        do {
            _ = try await BackendDockerMCP.invoke(tool: "docker.containers.start", arguments: startArguments(),
                caller: native, registry: registry, access: cancelling)
            Issue.record("Cancellation during approval reached a Docker mutation.")
        } catch is CancellationError { }
        #expect(await trace.events == ["approval"])
        await registry.shutdown()
    }

    @Test func unavailableOperationCannotAskOrReturnEmptySuccess() async throws {
        let registry = NativeChannelRegistry()
        let trace = DKTSafetyTrace()
        do {
            _ = try await BackendDockerMCP.invoke(tool: "docker.containers.start", arguments: startArguments(),
                caller: caller(), registry: registry, access: access(trace: trace))
            Issue.record("An absent engine handler returned success.")
        } catch let error as NativeRPCError {
            #expect(error.code == "unavailable")
        }
        #expect(await trace.events == [])
        await registry.shutdown()
    }

    @Test func emptyEngineHandlerResultCannotBecomeMCPWriteSuccess() async throws {
        let registry = NativeChannelRegistry()
        let trace = DKTSafetyTrace()
        try await registry.register("docker:containers:start", ownerID: "dkt-fixture") { _, _ in .null }
        do {
            _ = try await BackendDockerMCP.invoke(tool: "docker.containers.start", arguments: startArguments(),
                caller: caller(), registry: registry, access: access(trace: trace))
            Issue.record("A null engine result became a successful server change.")
        } catch let error as NativeRPCError { #expect(error.code == "unavailable") }
        #expect(await trace.events == ["approval:alter:false", "identity"])
        await registry.shutdown()
    }

    @Test func boundedReadCannotOpenAStreamWithoutACloseHandler() async throws {
        let registry = NativeChannelRegistry()
        let trace = DKTSafetyTrace()
        try await registry.register("docker:stats:open", ownerID: "dkt-fixture") { _, _ in
            await trace.add("open")
            return .object([.init("streamId", .string("synthetic-stream"))])
        }
        do {
            _ = try await BackendDockerMCP.invoke(tool: "docker.stats", arguments: startArguments(),
                caller: caller(tool: "docker.stats", tiers: [.read]), registry: registry, access: access(trace: trace))
            Issue.record("A bounded read opened a stream it could not close.")
        } catch let error as NativeRPCError { #expect(error.code == "unavailable") }
        #expect(await trace.events.isEmpty)
        await registry.shutdown()
    }

    @Test func destructiveMCPApprovalNamesTheResource() async throws {
        let registry = NativeChannelRegistry()
        let trace = DKTSafetyTrace()
        try await registry.register("docker:volumes:remove", ownerID: "dkt-fixture") { _, _ in
            await trace.add("delete")
            return .object([.init("ok", .bool(true))])
        }
        let args = NativeRPCValue.object([
            .init("target", .string("server-a")), .init("name", .string("dkt-database")),
            .init("confirmName", .string("dkt-database"))
        ])
        let approved = BackendDockerMCPAccess(rpcContext: { _ in .init(caller: .page, ownerID: "dkt-peer") },
            authorize: { _, tool, arguments, tier, summary, destructive in
                #expect(tool == "docker.volumes.remove")
                #expect(tier == .alter && destructive)
                #expect(arguments["confirmName"] == .string("dkt-database"))
                #expect(summary.contains("dkt-database") && summary.contains("server-a"))
                await trace.add("named-approval")
            })
        _ = try await BackendDockerMCP.invoke(tool: "docker.volumes.remove", arguments: args,
            caller: caller(tool: "docker.volumes.remove"), registry: registry, access: approved)
        #expect(await trace.events == ["named-approval", "delete"])
        await registry.shutdown()
    }

    private func startArguments() -> NativeRPCValue {
        .object([.init("target", .string("server-a")), .init("id", .string("container-a"))])
    }
    private func caller(tool: String = "docker.containers.start", tiers: Set<BackendMCPTier> = [.read, .alter]) -> BackendMCPCallContext {
        .init(sessionID: "dkt-session", machineID: "", projectRoot: nil, attended: true,
            allowedTools: [tool], allowedTiers: tiers, cancellation: BackendMCPCancellation())
    }
    private func access(trace: DKTSafetyTrace) -> BackendDockerMCPAccess {
        .init(rpcContext: { _ in
            await trace.add("identity")
            return .init(caller: .page, ownerID: "dkt-peer")
        }, authorize: { _, _, _, tier, _, destructive in
            await trace.add("approval:\(tier.rawValue):\(destructive)")
        }, noteResult: { _, _ in await trace.add("result") })
    }
    private func registerStart(_ registry: NativeChannelRegistry, trace: DKTSafetyTrace) async throws {
        try await registry.register("docker:containers:start", ownerID: "dkt-fixture") { context, arguments in
            await trace.add("dispatch:" + context.ownerID)
            #expect(context.caller == .page)
            #expect(arguments.count == 1 && arguments[0]["target"] == .string("server-a"))
            return .object([.init("ok", .bool(true))])
        }
    }

    private func expectInvalid(_ arguments: NativeRPCValue, tool: String) {
        do {
            try BackendDockerMCP.validate(tool: tool, arguments: arguments)
            Issue.record("Unsafe server-control arguments were accepted.")
        } catch let error as NativeRPCError {
            #expect(error.code == "invalid-arguments")
        } catch {
            Issue.record("Argument rejection must keep its public error code.")
        }
    }
}

private actor DKTSafetyWorkCounter {
    private(set) var count = 0
    func enter() { count += 1 }
}

private actor DKTSafetyTrace {
    private(set) var events: [String] = []
    func add(_ event: String) { events.append(event) }
}

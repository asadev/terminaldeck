import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Real composition joins, core consent/effect receipts and caller projections.
/// The only fixtures are an inert temporary Store, consent responder and tool
/// handlers. No server, credential provider, PTY, socket or process is started.
@MainActor
final class BackendDockerMCPCompositionTests: XCTestCase {
    private struct Rig: Sendable {
        let control: BackendDeckCoreSecurityControl
        let log: BackendDeckCoreSecurityActionLog
        let joins: BackendCompositionProductionBindings
        let authority: BackendCompositionAuthority
        let approval: BackendDockerMCPServerApproval
        let questions: BackendDeckCoreSecurityTestBox<[BackendDeckCoreSecurityConsentRequest]>
        let trace: BackendDeckCoreSecurityTestBox<[String]>

        func call(_ name: String, _ arguments: NativeRPCValue,
                  caller: BackendDeckCoreSecurityCaller, attended: Bool = true) async throws -> BackendDeckCoreSecurityCallResult {
            let scope = BackendMCPCancellation()
            let grant = BackendDeckCoreSecurityGrant(attended: attended, caller: { caller })
            let result = await BackendDeckCoreSecurityServer.authenticatedCall(grant: grant, scope: scope,
                wrapper: { [joins] grant, cancellation, operation in
                    try await joins.authenticated(grant: grant, cancellation: cancellation, operation: operation)
                }, call: { [control] in
                    await control.call(name: name, arguments: arguments,
                        options: .init(caller: caller, attended: attended, cancellation: scope))
                })
            return try XCTUnwrap(result, "The actual authenticated exchange must execute the core call.")
        }
    }

    private let standingKey = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read, .act, .alter],
        keyID: "fixture-key", keyName: "Fixture AI", askFirst: false)

    private func rig(approve: Bool = false, onQuestion: @escaping @Sendable () -> Void = {}) async throws -> Rig {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackendDockerMCPComposition-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let stateFile = directory.appendingPathComponent("data", isDirectory: true).appendingPathComponent("state.json", isDirectory: false)
        let store = try NativeStateStore(file: stateFile, ownership: .readOnly)
        let data = try XCTUnwrap(store.file).deletingLastPathComponent().standardizedFileURL
        let root = try BackendCompositionRoot(dataRoot: data, state: store, environment: [:], home: directory.path)
        let state = await BackendCompositionState.make(store: store, settings: root.settings, dataRoot: data,
            registry: root.registry, copilotRoot: { _ in directory.appendingPathComponent("copilot").path })
        let configuration = try BackendAccountConfiguration(dataDirectory: data, homeDirectory: directory,
            appName: "Terminal Deck Fixture", appID: "terminaldeck", helperExecutable: directory.appendingPathComponent("never-run-helper"),
            inheritedEnvironment: root.preparedSessions.environment)
        let questions = BackendDeckCoreSecurityTestBox<[BackendDeckCoreSecurityConsentRequest]>([])
        let trace = BackendDeckCoreSecurityTestBox<[String]>([])
        let holder = BackendDeckCoreSecurityTestBox<BackendDeckCoreSecurityConsentBroker?>(nil)
        let broker = BackendDeckCoreSecurityConsentBroker(ask: { question in
            questions.edit { $0.append(question) }
            trace.edit { $0.append("consent:" + question.tool) }
            onQuestion()
            guard approve else { return false }
            let current = holder.get()
            Task { _ = await current?.respond(id: question.id, approved: true, by: "window") }
            return true
        })
        holder.set(broker)
        let log = BackendDeckCoreSecurityActionLog(directory: directory.appendingPathComponent("actions"))
        let control = try BackendDeckCoreSecurityControl(log: log, consent: broker)
        let joins = BackendCompositionProductionBindings(root: root, state: state, configuration: configuration)
        let authority = try BackendCompositionAuthority(prepared: root.preparedSessions, state: state,
            configuration: configuration, coreContexts: joins.contexts, gate: control.compositionGate(), hidden: joins.hidden)
        try joins.bind(authority: authority)
        let approval = BackendDockerMCPServerApproval(authority: authority, consent: broker, knownServer: { target in
            trace.edit { $0.append("known:" + target) }
            return target == "saved-server"
        })
        addTeardownBlock {
            await broker.stop()
            holder.set(nil)
            authority.close()
            await state.stop()
            try await root.shutdown()
        }
        return Rig(control: control, log: log, joins: joins, authority: authority,
                   approval: approval, questions: questions, trace: trace)
    }

    private func dockerTool(_ id: String) throws -> BackendMCPTool {
        try XCTUnwrap(try BackendDockerMCP.definitions().first { $0.id == id })
    }

    private func appsTool(_ id: String) throws -> BackendMCPTool {
        try XCTUnwrap(try BackendAppsMCP.specifications().first { $0.id == id })
    }

    private func dockerArguments(_ fields: [NativeRPCValue.Field] = [], target: String = "saved-server") -> NativeRPCValue {
        .object([.init("target", .string(target))] + fields)
    }

    private func appArguments(_ fields: [NativeRPCValue.Field] = []) -> NativeRPCValue {
        .object([.init("serverId", .string("saved-server")), .init("appId", .string("demo"))] + fields)
    }

    private func install(_ rig: Rig, tools: [BackendMCPTool],
                         handler: @escaping BackendNativeMCPServer.Handler) async throws -> BackendDeckCoreCatalogueBundle {
        let bundle = try BackendDockerMCPComposition.bundle(registrations: tools.map { ($0, handler) }, joins: rig.joins,
            validate: { id, arguments in
                if id.hasPrefix("docker.") { try BackendDockerMCP.validate(tool: id, arguments: arguments) }
                else { try BackendAppsMCP.validate(tool: id, arguments: arguments) }
            }, summary: { id, arguments in
                if id.hasPrefix("docker.") { return (try? BackendDockerMCP.summary(tool: id, arguments: arguments)) ?? "Use Docker" }
                return BackendAppsMCP.summary(tool: id, arguments: arguments)
            }, preflight: { [approval = rig.approval, trace = rig.trace] context, id, arguments in
                trace.edit { $0.append("preflight:" + id) }
                try await approval.checkScope(caller: context.caller,
                    target: arguments["target"].string ?? arguments["serverId"].string)
            })
        try await rig.control.register(bundle.policies)
        return bundle
    }

    func testEveryCatalogueWriteRequiresAnOwnerAnswerIncludingActTier() async throws {
        let r = try await rig()
        var tools = try BackendDockerMCP.definitions() + BackendAppsMCP.specifications()
        // Exercise a future act-tier write too: ownerMustAnswer must not only
        // cover the catalogue's current alter-tier mutations.
        tools.append(try BackendMCPTool(id: "fixture.act", wireName: "fixture_act", description: "Act fixture",
            inputSchema: .object([.init("type", .string("object"))]), tier: .act))
        let registrations: [(BackendMCPTool, BackendNativeMCPServer.Handler)] = tools.map { tool in
            (tool, { @Sendable _, _ in .value(.null) })
        }
        let bundle = try BackendDockerMCPComposition.bundle(registrations: registrations,
            joins: r.joins, validate: { _, _ in }, summary: { _, _ in "Fixture" }, preflight: { _, _, _ in })
        XCTAssertEqual(bundle.policies.count, tools.count)
        XCTAssertFalse(tools.filter { $0.tier != .read }.isEmpty)
        for policy in bundle.policies {
            XCTAssertEqual(try policy.ownerMustAnswer?(.object([])), policy.tool.tier != .read,
                           "\(policy.tool.id) must retain the composition's owner-consent policy.")
        }
    }

    func testStandingKeyPermissionStillAsksForDockerAndAppsWrites() async throws {
        let r = try await rig()
        let start = try dockerTool("docker.containers.start"), restart = try appsTool("apps.restart")
        _ = try await install(r, tools: [start, restart]) { [trace = r.trace] _, _ in
            trace.edit { $0.append("server-io") }; return .value(.bool(true))
        }
        let docker = try await r.call(start.id, dockerArguments([.init("id", .string("container"))]), caller: standingKey)
        let apps = try await r.call(restart.id, appArguments(), caller: standingKey)
        XCTAssertEqual(docker.refusal, .noApprover)
        XCTAssertEqual(apps.refusal, .noApprover)
        XCTAssertEqual(r.questions.get().map(\.tool), [start.id, restart.id])
        XCTAssertTrue(r.questions.get().allSatisfy { $0.origin == "key:fixture-key" })
        XCTAssertFalse(r.trace.get().contains("server-io"))
        let rows = await r.log.tail()
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0["confirmed"]["granted"].bool == false })
        XCTAssertTrue(rows.allSatisfy { $0["confirmed"]["by"].string?.hasPrefix("standing:") != true })
    }

    func testEachWriteAcceptsItsOwnReceiptOnceAndNeverReusesPriorConsent() async throws {
        let r = try await rig(approve: true), tool = try dockerTool("docker.containers.start")
        _ = try await install(r, tools: [tool]) { [joins = r.joins, authority = r.authority, approval = r.approval, trace = r.trace] native, arguments in
            try await joins.prepareNative(native, tier: .alter, sentence: "Start this container", ownerMustAnswer: true)
            let rpc = try await authority.rpc(native)
            try await approval.authorize(context: rpc, channel: "docker:containers:start", target: arguments["target"].string,
                                         changing: true, summary: "Start this container", arguments: arguments)
            trace.edit { $0.append("server-io") }
            return .value(.object([.init("started", .bool(true))]))
        }
        for _ in 0..<2 {
            let result = try await r.call(tool.id, dockerArguments([.init("id", .string("container"))]), caller: standingKey)
            XCTAssertTrue(result.ok, result.error ?? "")
            XCTAssertEqual(result.row["confirmed"]["by"].string, "window")
        }
        XCTAssertEqual(r.questions.get().count, 2, "The domain receipt reuses this call's accepted consent; a later call asks again.")
        XCTAssertEqual(r.trace.get().filter { $0 == "server-io" }.count, 2)
    }

    func testScopePreflightRefusesBeforeConsentOrServerIO() async throws {
        let r = try await rig(approve: true), tool = try dockerTool("docker.containers.start")
        _ = try await install(r, tools: [tool]) { [trace = r.trace] _, _ in
            trace.edit { $0.append("server-io") }; return .value(.bool(true))
        }
        let cases: [(BackendDeckCoreSecurityCaller, String)] = [
            (.init(kind: .remote, tiers: [.read, .act, .alter], deviceID: "phone"), "saved-server"),
            (.init(kind: .session, tiers: [.read, .act, .alter], sessionID: "session", machineID: "paired-machine"), "saved-server"),
            (.init(kind: .key, tiers: [.read, .act, .alter], keyID: "scoped", askFirst: false, folders: ["/fixture/project"]), "saved-server"),
            (standingKey, "unknown-server")
        ]
        for (caller, target) in cases {
            let result = try await r.call(tool.id, dockerArguments([.init("id", .string("container"))], target: target), caller: caller)
            XCTAssertFalse(result.ok)
            XCTAssertEqual(result.row["outcome"].string, "error")
        }
        XCTAssertTrue(r.questions.get().isEmpty)
        XCTAssertFalse(r.trace.get().contains("server-io"))
        XCTAssertEqual(r.trace.get().filter { $0.hasPrefix("preflight:") }.count, cases.count)
        XCTAssertEqual(r.trace.get().filter { $0.hasPrefix("known:") }, ["known:unknown-server"],
                       "Disallowed callers must fail before even looking up a saved connection.")
    }

    func testInvalidArgumentsAndApprovalFlagsFailBeforeAsyncPreflight() async throws {
        let r = try await rig(approve: true), tool = try dockerTool("docker.containers.start")
        _ = try await install(r, tools: [tool]) { [trace = r.trace] _, _ in
            trace.edit { $0.append("server-io") }; return .value(.bool(true))
        }
        for arguments in [
            dockerArguments(),
            dockerArguments([.init("id", .string("container")), .init("approved", .bool(true))]),
            dockerArguments([.init("id", .string("container")), .init("id", .string("other"))])
        ] {
            let result = try await r.call(tool.id, arguments, caller: standingKey)
            XCTAssertFalse(result.ok)
        }
        XCTAssertTrue(r.questions.get().isEmpty)
        XCTAssertTrue(r.trace.get().isEmpty, "Grammar denial must precede scope lookup, consent and the actual handler.")
    }

    func testSecretsReachHandlerButNeverConsentResultOrActionLog() async throws {
        let r = try await rig(approve: true), tool = try appsTool("apps.env.patch")
        let secret = "fixture-private-env-value"
        _ = try await install(r, tools: [tool]) { _, arguments in
            XCTAssertEqual(arguments["set"]["REGION"].string, secret, "Masking must not replace the actual mutation value.")
            return .value(.object([
                .init("env", .object([.init("REGION", .string(secret))])),
                .init("message", .string("Applied " + secret)),
                .init("data", .string(Data(secret.utf8).base64EncodedString())),
                .init("name", .string("demo"))
            ]))
        }
        let result = try await r.call(tool.id, appArguments([
            .init("set", .object([.init("REGION", .string(secret))])), .init("remove", .array([]))
        ]), caller: standingKey)
        XCTAssertTrue(result.ok, result.error ?? "")
        let question = try XCTUnwrap(r.questions.get().first)
        XCTAssertFalse(question.wireValue.compact.contains(secret))
        XCTAssertFalse(result.value.compact.contains(secret))
        XCTAssertFalse(result.value.compact.contains(Data(secret.utf8).base64EncodedString()))
        XCTAssertEqual(result.value["name"].string, "demo")
        XCTAssertTrue(result.value["message"].string?.contains("[redacted]") == true)
        let rows = await r.log.tail()
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].compact.contains(secret))
        XCTAssertFalse(rows[0].compact.contains(Data(secret.utf8).base64EncodedString()))
        XCTAssertEqual(rows[0]["result"], result.value)
    }

    func testDispatchResolvesActualKeyAndItsTicketExpiresAfterTheCall() async throws {
        let r = try await rig(), tool = try dockerTool("docker.status")
        let retained = BackendDeckCoreSecurityTestBox<NativeRPCContext?>(nil)
        _ = try await install(r, tools: [tool]) { [authority = r.authority, approval = r.approval] native, arguments in
            let current = try await authority.resolve(native)
            XCTAssertEqual(current.caller.kind, .key)
            XCTAssertEqual(current.caller.keyID, "fixture-key")
            let rpc = try await authority.rpc(native)
            XCTAssertEqual(rpc.caller, .page)
            XCTAssertTrue(rpc.ownerID.hasPrefix("core-call:"))
            XCTAssertNotEqual(rpc.ownerID, BackendCompositionRoot.appOwnerID)
            retained.set(rpc)
            let forged = NativeRPCContext(caller: .page, ownerID: "another-owner", requestID: rpc.requestID)
            do {
                try await approval.authorize(context: forged, channel: "docker:status", target: "saved-server", changing: false,
                                             summary: "Read Docker status", arguments: arguments)
                XCTFail("Knowing a request ID must not let another owner adopt the caller ticket.")
            } catch let error as NativeRPCError {
                XCTAssertEqual(error.code, "unavailable")
            }
            try await approval.authorize(context: rpc, channel: "docker:status", target: arguments["target"].string,
                                         changing: false, summary: "Read Docker status", arguments: arguments)
            return .value(.object([.init("available", .bool(true))]))
        }
        let result = try await r.call(tool.id, dockerArguments(), caller: standingKey)
        XCTAssertTrue(result.ok, result.error ?? "")
        XCTAssertTrue(r.questions.get().isEmpty)
        let stale = try XCTUnwrap(retained.get())
        do {
            try await r.approval.authorize(context: stale, channel: "docker:status", target: "saved-server", changing: false,
                                          summary: "Read again", arguments: dockerArguments())
            XCTFail("A completed call's RPC ticket cannot authorize another operation.")
        } catch let error as NativeRPCError {
            XCTAssertEqual(error.code, "unavailable")
        }
    }

    func testApprovedCoreWriteStillRequiresItsDomainMutationReceipt() async throws {
        let r = try await rig(approve: true), tool = try dockerTool("docker.containers.start")
        _ = try await install(r, tools: [tool]) { [authority = r.authority, approval = r.approval, trace = r.trace] native, arguments in
            let rpc = try await authority.rpc(native)
            // Deliberately omit joins.prepareNative: raw handlers must not get a
            // mutation capability merely because their base tool was approved.
            try await approval.authorize(context: rpc, channel: "docker:containers:start", target: arguments["target"].string,
                                         changing: true, summary: "Start this container", arguments: arguments)
            trace.edit { $0.append("server-io") }; return .value(.bool(true))
        }
        let result = try await r.call(tool.id, dockerArguments([.init("id", .string("container"))]), caller: standingKey)
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.error?.contains("no accepted mutation receipt") == true)
        XCTAssertEqual(r.questions.get().count, 1)
        XCTAssertFalse(r.trace.get().contains("server-io"))
    }

    func testNativeOwnerCancellationAlwaysFiresAfterSuccessErrorReplyAndThrow() async throws {
        let tool = try dockerTool("docker.status")
        for outcome in ["success", "error-reply", "throw"] {
            let r = try await rig()
            let closed = BackendDeckCoreSecurityTestBox<[String]>([])
            _ = try await install(r, tools: [tool]) { [authority = r.authority] native, _ in
                let rpc = try await authority.rpc(native)
                // The production owner-disconnect observer relies on this real
                // per-invocation signal. Record it synchronously so the test
                // does not infer completion from a fire-and-forget Task.
                _ = native.cancellation.observe { closed.edit { $0.append(rpc.ownerID) } }
                switch outcome {
                case "error-reply": return .failure("Fixture operation failed.")
                case "throw": throw NativeRPCError(code: "unavailable", message: "Fixture operation failed.")
                default: return .value(.object([.init("available", .bool(true))]))
                }
            }
            let result = try await r.call(tool.id, dockerArguments(), caller: standingKey)
            XCTAssertEqual(result.ok, outcome == "success")
            XCTAssertEqual(closed.get().count, 1, "Every handler exit must expire its owner once: \(outcome).")
            XCTAssertTrue(closed.get().allSatisfy { $0.hasPrefix("core-call:") })
            XCTAssertTrue(r.questions.get().isEmpty)
        }
    }

    func testNativeWindowConsentIsMaskedAndWindowIsRecheckedAfterAnswer() async throws {
        let authorityHolder = BackendDeckCoreSecurityTestBox<BackendCompositionAuthority?>(nil)
        let r = try await rig(approve: true, onQuestion: { authorityHolder.get()?.revokeLocalUI() })
        authorityHolder.set(r.authority)
        defer { authorityHolder.set(nil) }
        let context = try r.authority.localContext()
        let secret = "fixture-native-password"
        do {
            try await r.approval.authorize(context: context, channel: "apps:env:patch", target: "saved-server", changing: true,
                summary: "Change password=" + secret,
                arguments: appArguments([
                    .init("set", .object([.init("PASSWORD", .string(secret))])), .init("remove", .array([]))
                ]))
            XCTFail("Approval cannot survive the native window losing its authority.")
        } catch let error as NativeRPCError {
            XCTAssertEqual(error.code, "access-denied")
        }
        let question = try XCTUnwrap(r.questions.get().first)
        XCTAssertEqual(question.origin, "window")
        XCTAssertFalse(question.wireValue.compact.contains(secret))
        XCTAssertTrue(question.summary.contains("[redacted]"))
    }
}

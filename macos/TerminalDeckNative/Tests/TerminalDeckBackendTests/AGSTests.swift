import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

private struct AGSFakeCipher: BackendAccountVaultCipher {
    let usable: Bool
    init(usable: Bool = true) { self.usable = usable }
    func available() -> Bool { usable }
    func prepareForWrites(existingVault: Bool) throws {}
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { Data(text.utf8).map { $0 ^ 0xa5 }.withData }
    func decrypt(_ blob: Data) throws -> String { String(decoding: blob.map { $0 ^ 0xa5 }, as: UTF8.self) }
}
private extension Array where Element == UInt8 { var withData: Data { Data(self) } }
private actor AGSCalls {
    var count = 0
    func record() { count += 1 }
}
private actor AGSApproval {
    var approved = 0
    let denied: Bool
    init(denied: Bool = false) { self.denied = denied }
    func ask(owner: Bool) throws { XCTAssertTrue(owner); if denied { throw NativeRPCError(code: "approval-required", message: "Owner denied.") }; approved += 1 }
}
final class AGSTests: XCTestCase, @unchecked Sendable {
    private func memoryStore(cipher: AGSFakeCipher = .init()) throws -> BackendAGSStore {
        let persistence = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/ags-tests"), ownership: .memory)
        return BackendAGSStore(persistence: persistence, cipher: cipher)
    }
    private let claudeHelp = "--model --effort --permission-mode --tools --allowedTools --disallowedTools --strict-mcp-config --settings"
    private let codexHelp = "--model --config --sandbox --ask-for-approval"
    func testClaudePlanIsPrivateAndUsesRealOptions() throws {
        let hook = AGSCLIHook(event: "PreToolUse", command: "echo tested")
        let settings = AGSAgentSettings(model: "selected-model", effort: "high", permissionMode: "plan", allowedTools: [], deniedTools: ["Bash"], mcpServers: ["deck": false], hooks: [hook], environment: ["MY_TOKEN": "private"], workingFolder: "/tmp/folder with spaces", keepOpen: true)
        let plan = try BackendAGSLaunch.plan(settings, privateDirectory: URL(fileURLWithPath: "/tmp/ags-owned"), installedHelp: claudeHelp, knownServers: ["deck"])
        XCTAssertTrue(plan.arguments.contains("--effort")); XCTAssertTrue(plan.arguments.contains("--strict-mcp-config"))
        XCTAssertEqual(plan.environment["MY_TOKEN"], "private"); XCTAssertEqual(plan.workingFolder, "/tmp/folder with spaces")
        XCTAssertEqual(plan.arguments.suffix(2), ["--settings", "/tmp/ags-owned/ags-claude-settings.json"])
        let file = try NativeRPCValue.parseJSON(XCTUnwrap(plan.privateFiles["ags-claude-settings.json"]))
        XCTAssertEqual(file["hooks"]["PreToolUse"].elements?.first?["hooks"].elements?.first?["timeout"].number, 30)
        XCTAssertFalse(plan.arguments.joined().contains("private")); XCTAssertTrue(plan.keepOpen)
    }
    func testCodexEffortMCPAndHookTrustStayReal() throws {
        let settings = AGSAgentSettings(provider: "codex", effort: "xhigh", permissionMode: "workspace-write", allowedTools: ["mcp__deck__read"], deniedTools: ["mcp__deck__write"], mcpServers: ["deck": false], hooks: [.init(event: "Stop", command: "true")])
        let plan = try BackendAGSLaunch.plan(settings, privateDirectory: URL(fileURLWithPath: "/tmp/ags-owned"), installedHelp: codexHelp, knownServers: ["deck"])
        XCTAssertTrue(plan.arguments.contains("model_reasoning_effort=\"xhigh\""))
        XCTAssertTrue(plan.arguments.contains("mcp_servers.\"deck\".enabled=false"))
        XCTAssertTrue(plan.arguments.contains("mcp_servers.\"deck\".enabled_tools=[\"read\"]"))
        XCTAssertTrue(plan.arguments.contains { $0.hasPrefix("hooks.Stop=") })
        XCTAssertFalse(plan.arguments.contains("--dangerously-bypass-hook-trust")); XCTAssertNil(plan.environment["CODEX_HOME"])
    }
    func testCodexBuiltinRestrictionsCannotPretendToWork() throws {
        XCTAssertThrowsError(try BackendAGSLaunch.plan(.init(provider: "codex", allowedTools: ["Bash"]), privateDirectory: URL(fileURLWithPath: "/tmp/ags"), installedHelp: codexHelp, knownServers: []))
    }
    func testGeminiHelpMustExistBeforeLaunch() throws {
        XCTAssertThrowsError(try BackendAGSLaunch.plan(.init(provider: "gemini"), privateDirectory: URL(fileURLWithPath: "/tmp/ags"), installedHelp: "", knownServers: []))
    }
    func testGeminiThinkingAndHookTimeoutUseConfig() throws {
        let settings = AGSAgentSettings(provider: "gemini", model: "gemini-3-pro-preview", effort: "high", allowedTools: ["read_file"], hooks: [.init(event: "BeforeTool", command: "true", timeoutSeconds: 5)])
        let plan = try BackendAGSLaunch.plan(settings, privateDirectory: URL(fileURLWithPath: "/tmp/ags"), installedHelp: "--model --approval-mode", knownServers: [])
        XCTAssertNil(plan.environment["GEMINI_CLI_HOME"])
        XCTAssertEqual(plan.environment["GEMINI_CLI_SYSTEM_SETTINGS_PATH"], "/tmp/ags/ags-gemini-settings.json")
        let config = try NativeRPCValue.parseJSON(XCTUnwrap(plan.privateFiles["ags-gemini-settings.json"]))
        XCTAssertEqual(config["hooks"]["BeforeTool"].elements?.first?["hooks"].elements?.first?["timeout"].number, 5000)
        XCTAssertEqual(config["modelConfigs"]["customOverrides"].elements?.first?["modelConfig"]["generateContentConfig"]["thinkingConfig"]["thinkingLevel"].string, "HIGH")
        XCTAssertEqual(config["tools"]["core"].elements?.first?.string, "read_file")
    }
    func testUnsupportedSettingsAndUnknownServersRefused() throws {
        XCTAssertThrowsError(try BackendAGSLaunch.plan(.init(effort: "high"), privateDirectory: URL(fileURLWithPath: "/tmp/ags"), installedHelp: "--model", knownServers: []))
        XCTAssertThrowsError(try BackendAGSLaunch.plan(.init(mcpServers: ["unknown": true]), privateDirectory: URL(fileURLWithPath: "/tmp/ags"), installedHelp: claudeHelp, knownServers: []))
        XCTAssertThrowsError(try BackendAGSValidation.check(AGSAgentSettings(environment: ["CODEX_HOME": "override"])))
        XCTAssertThrowsError(try BackendAGSValidation.check(AGSAgentSettings(provider: "codex", hooks: [.init(event: "SessionEnd", command: "true")])))
    }
    func testDefaultsAndSessionDenyWinAndEmptyAllowMeansNone() throws {
        let defaults = AGSAgentSettings(effort: "high", allowedTools: ["Read", "Bash"], deniedTools: ["Bash"], mcpServers: ["deck": false])
        let profile = AGSAgentSettings(allowedTools: ["Read", "Write"], mcpServers: ["deck": true])
        let resolved = try BackendAGSPolicy.resolve(defaults: defaults, profile: profile)
        XCTAssertEqual(resolved.effort, "high"); XCTAssertEqual(resolved.allowedTools, ["Read"]); XCTAssertEqual(resolved.mcpServers["deck"], false)
        let empty = try BackendAGSPolicy.resolve(defaults: defaults, profile: profile, session: .init(allowedTools: []))
        XCTAssertEqual(empty.allowedTools, [])
    }
    func testKeyMayNarrowButCannotReplaceHooksSecretsOrBroadenAccess() throws {
        let owner = AGSAgentSettings(permissionMode: "acceptEdits", allowedTools: ["Read", "Bash"], deniedTools: ["Write"], mcpServers: ["deck": true, "off": false], hooks: [.init(command: "true")], environment: ["MY_TOKEN": "private"], workingFolder: "/tmp/owner", keepOpen: true)
        var narrow = owner; narrow.permissionMode = "plan"; narrow.allowedTools = ["Read"]; narrow.mcpServers["deck"] = false; narrow.workingFolder = "/tmp/owner/child"; narrow.keepOpen = false
        XCTAssertNoThrow(try BackendAGSPolicy.requireNarrowing(narrow, owner: owner))
        for field in 0..<7 {
            var bad = narrow
            switch field { case 0: bad.environment["MY_TOKEN"] = "changed"; case 1: bad.hooks = []; case 2: bad.allowedTools = nil; case 3: bad.deniedTools = []; case 4: bad.mcpServers["off"] = true; case 5: bad.workingFolder = "/tmp/owner-two"; default: bad.permissionMode = "bypassPermissions" }
            XCTAssertThrowsError(try BackendAGSPolicy.requireNarrowing(bad, owner: owner), "field \(field)")
        }
    }
    func testMaskedReadsDoNotExposeEnvironmentOrWebhook() async throws {
        let store = try memoryStore(); try await store.start()
        let settings = AGSAgentSettings(hooks: [.init(command: "echo topsecret")], environment: ["MY_TOKEN": "topsecret"])
        try await store.saveProfile("worker", settings: settings, expectedRevision: 0)
        let view = try await store.view(profile: "worker"); XCTAssertFalse(view.compact.contains("topsecret"))
        try await store.saveDefaults(.init(hooks: [.init(webhook: "https://example.com/private-token")]), expectedRevision: 1)
        let global = try await store.view(profile: nil); XCTAssertFalse(global.compact.contains("private-token"))
    }
    func testApprovalRevisionAndSecureStoreFailClosed() async throws {
        let store = try memoryStore(); try await store.start()
        try await store.saveProfile("worker", settings: .init(), expectedRevision: 0)
        do { try await store.saveProfile("worker", settings: .init(effort: "high"), expectedRevision: 0); XCTFail("stale save passed") } catch let error as NativeRPCError { XCTAssertEqual(error.code, "settings-changed") }
        let unavailable = try memoryStore(cipher: .init(usable: false)); try await unavailable.start()
        do { try await unavailable.saveDefaults(.init(), expectedRevision: 0); XCTFail("no cipher save passed") } catch let error as NativeRPCError { XCTAssertEqual(error.code, "secure-store-unavailable") }
        let revision = try await unavailable.currentRevision(); XCTAssertEqual(revision, 0)
    }
    func testPersistedStateIsEncryptedAndRestores() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ags-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = try BackendTaskPersistence(directory: directory, ownership: .exclusive)
        let store = BackendAGSStore(persistence: persistence, cipher: AGSFakeCipher()); try await store.start()
        try await store.saveProfile("worker", settings: .init(environment: ["MY_TOKEN": "secret-value"]), expectedRevision: 0)
        let data = try Data(contentsOf: directory.appendingPathComponent("ags-settings.json"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret-value"))
        let restored = BackendAGSStore(persistence: persistence, cipher: AGSFakeCipher()); try await restored.start()
        let saved = try await restored.profile("worker"); XCTAssertEqual(saved?.environment["MY_TOKEN"], "secret-value")
    }
    func testHookDeliveryIsEventDrivenDeduplicatedAndMasksFailure() async {
        let calls = AGSCalls()
        let runner = BackendAGSHookRunner(execute: { _, _ in await calls.record(); throw NativeRPCError(code: "failed", message: "private-token") })
        let event = BackendAGSHookEvent(id: "test-event", event: "session.started")
        let enabled = AGSAppHook(command: "true", enabled: true), disabled = AGSAppHook(command: "true")
        let result = await runner.deliver(event, hooks: [enabled, disabled]); XCTAssertEqual(result.count, 1); XCTAssertFalse(result[0].message.contains("private-token"))
        let repeated = await runner.deliver(event, hooks: [enabled]); XCTAssertTrue(repeated.isEmpty)
        let count = await calls.count; XCTAssertEqual(count, 1)
        let test = await runner.test(disabled); XCTAssertFalse(test.ok)
        await runner.stop(); let stopped = await runner.test(enabled); XCTAssertFalse(stopped.ok)
    }
    func testActualCommandHookReportsExitWithoutOutput() async {
        let runner = BackendAGSHookRunner(execute: BackendAGSHookRunner.local(workingFolder: "/tmp"))
        let success = await runner.test(.init(command: "printf private-output")); XCTAssertTrue(success.ok); XCTAssertFalse(success.message.contains("private-output"))
        let failure = await runner.test(.init(command: "exit 2")); XCTAssertFalse(failure.ok)
    }
    func testHookEventIsDataNeverShellInterpolation() async {
        let runner = BackendAGSHookRunner(execute: BackendAGSHookRunner.local(workingFolder: "/tmp"))
        let event = BackendAGSHookEvent(event: "receiver.event", subjectID: "$(exit 5)")
        let results = await runner.deliver(event, hooks: [.init(event: "receiver.event", command: "test -n \"$TD_HOOK_EVENT\"", enabled: true)])
        XCTAssertEqual(results.count, 1); XCTAssertTrue(results[0].ok)
    }
    private func context() -> BackendMCPCallContext { .init(sessionID: "test", machineID: "local", projectRoot: nil, attended: true, allowedTools: Set(BackendAGSMCP.toolIDs), allowedTiers: [.read, .act, .alter], cancellation: BackendMCPCancellation()) }
    private func access(_ approval: AGSApproval, kind: BackendDeckToolsAppCaller.Kind = .local, after: @escaping @Sendable () async throws -> Void = {}) -> BackendDeckToolsAppAccess {
        .init(caller: { _ in .init(kind: kind) }, knownFolder: { _, folder in folder }, session: { _, _ in .null }, runnableProject: { _, folder in folder }, rpc: { _ in .init(caller: .nativeApp, ownerID: "test") }, authorize: { _, _, _, _, _, owner in try await approval.ask(owner: owner); try await after() }, record: { _, _, _, _ in })
    }
    func testMCPReadsFreeAndEveryChangeAndTestAskOwner() async throws {
        let store = try memoryStore(); try await store.start(); let calls = AGSCalls(), approval = AGSApproval()
        let runner = BackendAGSHookRunner(execute: { _, _ in await calls.record() })
        let definitions = try BackendAGSMCP.definitions(store: store, hooks: runner, access: access(approval), scope: .init(require: { _, _, _ in }, baseProfile: { _ in .init() }))
        let read = try await definitions[0].handler(context(), .object([])); XCTAssertFalse(read.isError)
        let firstCount = await approval.approved; XCTAssertEqual(firstCount, 0)
        let hook = AGSAppHook(command: "true")
        let change = try await definitions[1].handler(context(), .object([.init("revision", .number(0)), .init("hook", try BackendAGSCodec.value(hook))])); XCTAssertFalse(change.isError)
        let test = try await definitions[2].handler(context(), .object([.init("revision", .number(1)), .init("hook", .string(hook.id))])); XCTAssertFalse(test.isError)
        let count = await approval.approved, executed = await calls.count; XCTAssertEqual(count, 2); XCTAssertEqual(executed, 1)
    }
    func testMCPDeniedApprovalDoesNotMutateOrRun() async throws {
        let store = try memoryStore(); try await store.start(); let calls = AGSCalls(), denied = AGSApproval(denied: true)
        let runner = BackendAGSHookRunner(execute: { _, _ in await calls.record() })
        let definitions = try BackendAGSMCP.definitions(store: store, hooks: runner, access: access(denied), scope: .init(require: { _, _, _ in }, baseProfile: { _ in .init() }))
        let change = try await definitions[1].handler(context(), .object([.init("revision", .number(0)), .init("profile", .string("worker")), .init("settings", try BackendAGSCodec.value(AGSAgentSettings()))])); XCTAssertTrue(change.isError)
        let revision = try await store.currentRevision(), executed = await calls.count; XCTAssertEqual(revision, 0); XCTAssertEqual(executed, 0)
    }
    func testKeyCannotSetDefaultsOrInjectHooks() async throws {
        let store = try memoryStore(); try await store.start(); let approval = AGSApproval()
        let runner = BackendAGSHookRunner(execute: { _, _ in XCTFail("key hook ran") })
        let definitions = try BackendAGSMCP.definitions(store: store, hooks: runner, access: access(approval, kind: .key), scope: .init(require: { _, _, _ in }, baseProfile: { _ in .init() }))
        let defaults = try await definitions[1].handler(context(), .object([.init("revision", .number(0)), .init("defaults", try BackendAGSCodec.value(AGSDefaults()))])); XCTAssertTrue(defaults.isError)
        let profile = try await definitions[1].handler(context(), .object([.init("revision", .number(0)), .init("profile", .string("worker")), .init("settings", try BackendAGSCodec.value(AGSAgentSettings(hooks: [.init(command: "true")])))])); XCTAssertTrue(profile.isError)
        let count = await approval.approved; XCTAssertEqual(count, 0)
    }
    func testNativeChannelsRefusePageCallerBeforePrivateRead() async throws {
        let store = try memoryStore(); try await store.start(); let registry = NativeChannelRegistry()
        let runner = BackendAGSHookRunner(execute: { _, _ in })
        try await BackendAGSChannels.register(registry: registry, ownerID: "ags", store: store, runner: runner, baseProfile: { _ in .init() }, requireOwner: { _ in }, authorize: { _, _, _ in })
        do { _ = try await registry.invoke("ags:get", context: .init(caller: .page, ownerID: "page"), arguments: [.null]); XCTFail("page read private state") } catch let error as NativeRPCError { XCTAssertEqual(error.code, "access-denied") }
    }
    func testMaskedReadKeepsIdentifiersEvenForShortValues() throws {
        let settings = AGSAgentSettings(environment: ["SHORT": "c", "FLAG": "1"])
        let view = try BackendAGSCodec.masked(settings)
        XCTAssertEqual(view["provider"].string, "claude")
        XCTAssertEqual(view["environment"]["SHORT"].string, "••••••••")
    }
    func testMaskedEditPreservesAndRemovesEnvironmentAndHooks() throws {
        let old = AGSAgentSettings(hooks: [.init(command: "echo secret")], environment: ["KEEP": "secret", "REMOVE": "gone"])
        let saved = try BackendAGSCodec.preserveMaskedEnvironment(["KEEP": "••••••••"], previous: old.environment)
        XCTAssertEqual(saved, ["KEEP": "secret"])
        var hook = old.hooks[0]; hook.command = "echo ••••••••"
        XCTAssertEqual(try BackendAGSCodec.restoreMaskedHooks([hook], previous: old), old.hooks)
        hook.command = "changed ••••••••"
        XCTAssertThrowsError(try BackendAGSCodec.restoreMaskedHooks([hook], previous: old))
    }
    func testChangedSettingsDuringApprovalCannotOverwriteNewRecord() async throws {
        let store = try memoryStore(); try await store.start(); let approval = AGSApproval()
        let runner = BackendAGSHookRunner(execute: { _, _ in XCTFail("unexpected test") })
        let authority = access(approval, after: { try await store.saveProfile("other", settings: .init(), expectedRevision: 0) })
        let definitions = try BackendAGSMCP.definitions(store: store, hooks: runner, access: authority, scope: .init(require: { _, _, _ in }, baseProfile: { _ in .init() }))
        let reply = try await definitions[1].handler(context(), .object([.init("revision", .number(0)), .init("profile", .string("worker")), .init("settings", try BackendAGSCodec.value(AGSAgentSettings()))]))
        XCTAssertTrue(reply.isError)
        let missing = try await store.profile("worker"); XCTAssertNil(missing)
        let revision = try await store.currentRevision(); XCTAssertEqual(revision, 1)
    }
    func testRevokedScopeDuringApprovalRefusesWrite() async throws {
        let store = try memoryStore(); try await store.start(); let approval = AGSApproval(), gate = AGSCalls()
        let runner = BackendAGSHookRunner(execute: { _, _ in XCTFail("unexpected test") })
        let scope = BackendAGSAccess(require: { _, _, _ in
            await gate.record(); if await gate.count > 1 { throw NativeRPCError(code: "not-permitted", message: "Scope removed.") }
        }, baseProfile: { _ in .init() })
        let definitions = try BackendAGSMCP.definitions(store: store, hooks: runner, access: access(approval), scope: scope)
        let reply = try await definitions[1].handler(context(), .object([.init("revision", .number(0)), .init("profile", .string("worker")), .init("settings", try BackendAGSCodec.value(AGSAgentSettings()))]))
        XCTAssertTrue(reply.isError)
        let revision = try await store.currentRevision(); XCTAssertEqual(revision, 0)
    }
    func testCommandTimeoutStopsExecutionAndReturnsGenericFailure() async {
        let runner = BackendAGSHookRunner(execute: BackendAGSHookRunner.local(workingFolder: "/tmp"))
        let start = Date()
        let result = await runner.test(.init(command: "sleep 30", timeoutSeconds: 1))
        XCTAssertFalse(result.ok); XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }
    func testTaskAdapterDoesNotForwardTextOrSecrets() async throws {
        let store = try memoryStore(); try await store.start()
        try await store.saveDefaults(.init(hooks: [.init(event: "task.finished", command: "true", enabled: true)]), expectedRevision: 0)
        let calls = AGSCalls()
        let delivered = expectation(description: "Accepted task event delivered once")
        let runner = BackendAGSHookRunner(execute: { _, event in
            XCTAssertEqual(event.subjectID, "task-1"); XCTAssertFalse(event.wireValue.compact.contains("private-secret")); await calls.record()
            delivered.fulfill()
        })
        let events = BackendAGSEvents(store: store, runner: runner)
        await events.task(.object([.init("id", .string("accepted-event")), .init("type", .string("task.finished")), .init("taskId", .string("task-1")), .init("body", .string("private-secret"))]))
        await fulfillment(of: [delivered], timeout: 2)
        let count = await calls.count; XCTAssertEqual(count, 1)
        await events.stop()
    }

    func testMaskedAppHookRoundTripPreservesSavedAction() throws {
        let old = AGSDefaults(providers: ["claude": .init(environment: ["TOKEN": "secret"])] , hooks: [.init(command: "echo secret"), .init(webhook: "https://example.com/secret")])
        let masked = try BackendAGSCodec.maskedDefaults(old)
        let read = try BackendAGSCodec.decode(AGSDefaults.self, masked)
        XCTAssertEqual(try BackendAGSCodec.restoreMaskedAppHooks(read.hooks, previous: old), old.hooks)
    }

}

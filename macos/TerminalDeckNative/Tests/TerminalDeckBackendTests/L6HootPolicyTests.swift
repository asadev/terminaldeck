import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Hoot's tool-call fence at the security server: only its own settings are refused; the retired "What Hoot may do"
/// switches no longer narrow anything. Stubs only.
final class L6HootPolicyTests: XCTestCase {
    private let headers = ["content-type": "application/json", "accept": "application/json, text/event-stream", "host": "127.0.0.1:40404"]
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("L6HootPolicy-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private actor Ran { var tools: [String] = []; func add(_ id: String) { tools.append(id) } }
    private func envelope(_ name: String, _ arguments: NativeRPCValue = .object([])) -> NativeRPCValue {
        .object([.init("jsonrpc", .string("2.0")), .init("id", .number(1)), .init("method", .string("tools/call")),
                 .init("params", .object([.init("name", .string(name)), .init("arguments", arguments)]))])
    }
    /// A security server whose stub tools only record that they ran.
    private func server(ran: Ran) throws -> BackendDeckCoreSecurityServer {
        let schema = NativeRPCValue.object([.init("type", .string("object")), .init("properties", .object([]))])
        let policies = try ["sessions.start", "devices.tap", "simulators.start", "projects.list", "files.read"].map { id in
            let tool = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: id, inputSchema: schema, tier: .read)
            return BackendDeckCoreSecurityToolPolicy(tool: tool, summary: { _, _ in id }, run: { _, _ in
                await ran.add(id); return .init(value: .object([.init("ok", .bool(true))]), summary: .object([]))
            })
        }
        let control = try BackendDeckCoreSecurityControl(log: .init(directory: temporary()), consent: .init(ask: { _ in false }), policies: policies)
        return BackendDeckCoreSecurityServer(control: control, ownPorts: .init())
    }
    private func hootGrant(_ policy: BackendHootPolicy) -> BackendDeckCoreSecurityGrant {
        BackendDeckCoreSecurityGrant(attended: true, caller: { .init(kind: .local, tiers: [.read, .act, .alter]) },
                                     beforeTool: { tool, arguments in try await policy.check(tool: tool, arguments: arguments) })
    }
    private func call(_ server: BackendDeckCoreSecurityServer, _ grant: BackendDeckCoreSecurityGrant, _ name: String,
                      _ arguments: NativeRPCValue = .object([])) async throws -> NativeRPCValue {
        let response = await server.serve(parsed: envelope(name, arguments), headers: headers, grant: grant, cancellation: .init())
        return try NativeRPCValue.parseJSON(response.body)["result"]
    }
    private func text(_ result: NativeRPCValue) -> String { result["content"].elements?.first?["text"].string ?? "" }

    /// Asad, 12 Oct: "What Hoot can do things should not be here completely" — Hoot can always run sessions, use
    /// simulators and phones, hand problems out and open any folder. Even an older install whose saved switches said no
    /// is not narrowed: the saved values are removed and nothing reads them.
    func testHootCanAlwaysRunSessionsUseDevicesAndOpenAnyFolder() async throws {
        let directory = try temporary()
        let settings = BackendAppSettingsStore(userData: directory, writable: true)
        _ = try await settings.patch(.object([.init("hoot.policy.runSessions", .bool(false)), .init("hoot.policy.useDevices", .bool(false)),
            .init("hoot.policy.routingMode", .string("never")), .init("hoot.policy.folders", .string("/work/crm")), .init("other.kept", .bool(true))]))
        let policy = BackendHootPolicy(settings: settings)
        let snapshot = await policy.snapshot()
        XCTAssertEqual(snapshot, HootPolicySnapshot())
        XCTAssertEqual(snapshot.routingMode, "ask")
        let ran = Ran(), server = try server(ran: ran), grant = hootGrant(policy)
        for (name, cwd) in [("sessions_start", "/anywhere/at/all"), ("devices_tap", "/work/crm-old"), ("simulators_start", "/"), ("files_read", "/work/crm/../billing")] {
            let result = try await call(server, grant, name, .object([.init("cwd", .string(cwd)), .init("path", .string(cwd))]))
            XCTAssertNotEqual(result["isError"], .bool(true), name + ": " + text(result))
        }
        let tools = await ran.tools
        XCTAssertEqual(tools, ["sessions.start", "devices.tap", "simulators.start", "files.read"])
        // The retired switches are gone from the settings file; everything else is untouched.
        for key in BackendHootPolicy.retiredKeys {
            let value = await settings.value(key)
            XCTAssertTrue(value.isNullish, key + " was not removed")
        }
        let kept = await settings.value("other.kept")
        XCTAssertEqual(kept, .bool(true))
        let reopened = await BackendAppSettingsStore(userData: directory, writable: true).value("hoot.policy.runSessions")
        XCTAssertTrue(reopened.isNullish, "Removed on disk too")
    }

    func testHootCannotChangeItsOwnSettingsButMayReadThem() throws {
        let snapshot = HootPolicySnapshot()
        XCTAssertThrowsError(try snapshot.check(tool: "hoot.routines.settings_set",
            arguments: .object([.init("field", .string("permissionMode")), .init("value", .string("plan"))])))
        XCTAssertThrowsError(try snapshot.check(tool: "hoot.routines.reset", arguments: .object([])))
        XCTAssertNoThrow(try snapshot.check(tool: "hoot.routines.settings_get", arguments: .object([])))
        XCTAssertNoThrow(try snapshot.check(tool: "hoot.route.propose", arguments: .object([])), "Handing problems out is always allowed")
        XCTAssertEqual(HootPolicySnapshot(routingMode: "never").routingMode, "ask", "There is no Never any more")
        XCTAssertEqual(HootPolicySnapshot(routingMode: "notify").routingMode, "notify")
    }

    func testSettingsServiceHasNoWhatHootMayDoSwitches() async throws {
        let directory = try temporary()
        let service = BackendROUTINESHootSettings(.init())
        let read = try await service.read()
        for name in ["runSessions", "routingMode", "useDevices", "folders"] {
            XCTAssertTrue(read[name].isNullish, name)
            XCTAssertTrue(read["capabilities"][name].isNullish, name + " is not offered at all")
            do { _ = try await service.set(field: name, value: .bool(true)); XCTFail(name + " can still be set") }
            catch { XCTAssertTrue(error.localizedDescription.contains("always"), error.localizedDescription) }
        }
        _ = directory
    }

    /// Asad, 11 Oct: "app itself will not ask any permissions at all it all depends on ai model settings directly", and
    /// "any kind of restrictions we designed for reasons they will stay". No caller gets an app card for any kind of tool
    /// (a plain change, a must-answer tool, a phone tap, a handler's own change, an agent widening); each change is
    /// recorded as a standing approval. Every refusal stays: tiers, unattended changes, Hoot's own settings, and a key
    /// asking for more access (refused, never asked).
    func testTheAppShowsNoCardForAnyToolAndEveryRefusalStays() async throws {
        let schema = NativeRPCValue.object([.init("type", .string("object"))])
        actor Asked { var count = 0; func add() { count += 1 } }
        let asked = Asked(), ran = Ran()
        final class Gate: @unchecked Sendable { var control: BackendDeckCoreSecurityControl? }
        let gate = Gate()
        func plain(_ id: String, tier: BackendMCPTier, mustAnswer: Bool) throws -> BackendDeckCoreSecurityToolPolicy {
            let must: (@Sendable (NativeRPCValue) throws -> Bool)? = mustAnswer ? { @Sendable _ in true } : nil
            return BackendDeckCoreSecurityToolPolicy(tool: try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: id, inputSchema: schema, tier: tier),
                summary: { _, _ in id }, ownerMustAnswer: must, run: { _, _ in await ran.add(id); return .init(value: .bool(true)) })
        }
        // The tools that put cards on his island on 11 Oct enter their change as the real handlers do.
        let handled = ["projects.add", "tasks.agents_import", "project_registry.set_lead", "skills.assign", "tasks.agents", "agents.edit_profile", "agents.settings_set"]
        let policies = try [plain("routines.save", tier: .alter, mustAnswer: false), plain("browser.password", tier: .alter, mustAnswer: true),
                            plain("devices.tap", tier: .act, mustAnswer: true)] + handled.map { id in
            BackendDeckCoreSecurityToolPolicy(tool: try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: id, inputSchema: schema, tier: .read),
                summary: { _, _ in id }, run: { args, context in
                    _ = try await gate.control!.prepareEffect(context: context, tool: id, arguments: args, tier: .alter, sentence: id, ownerMustAnswer: true)
                    await ran.add(id); return .init(value: .bool(true))
                })
        }
        let control = try BackendDeckCoreSecurityControl(log: .init(directory: temporary()), consent: .init(ask: { _ in await asked.add(); return false }),
            policies: policies, budgets: .init(changes: .init(limit: 500, windowMilliseconds: 300_000)))
        gate.control = control
        let callers: [(String, BackendDeckCoreSecurityCaller, String)] = [
            ("Hoot in Bypass", .init(kind: .local, tiers: [.read, .act, .alter], askFirst: false, sessionID: "hoot"), "standing:hoot-bypass"),
            ("Hoot in Ask first", .init(kind: .local, tiers: [.read, .act, .alter], sessionID: "hoot"), "standing:ai-setting"),
            ("a key set to ask", .init(kind: .key, tiers: [.read, .act, .alter], keyID: "k1", keyName: "App", askFirst: true, tasks: true), "standing:key:k1"),
            ("a key set not to ask", .init(kind: .key, tiers: [.read, .act, .alter], keyID: "k2", keyName: "App", askFirst: false, tasks: true), "standing:key:k2"),
            ("a session", .init(kind: .session, tiers: [.read, .act, .alter], sessionID: "s1"), "standing:ai-setting")]
        for (who, caller, by) in callers {
            for policy in policies {
                let result = await control.call(name: policy.tool.wireName, arguments: .object([]), options: .init(caller: caller))
                XCTAssertTrue(result.ok, who + " · " + policy.tool.id + ": " + (result.error ?? ""))
                if policy.tool.id != "devices.tap" || caller.kind != .local || caller.askFirst != false {
                    XCTAssertEqual(result.row["confirmed"]["by"], .string(by), who + " · " + policy.tool.id)
                }
            }
        }
        let cards = await asked.count
        XCTAssertEqual(cards, 0, "the app showed no card at all")
        let runs = await ran.tools
        XCTAssertEqual(runs.count, callers.count * policies.count)
        // Refusals stay. A key without Full control cannot make a must-answer change (it is a change, whoever calls).
        let work = await control.call(name: "browser_password", arguments: .object([]), options: .init(caller: .init(kind: .key, tiers: [.read, .act], keyID: "k3", askFirst: false)))
        XCTAssertEqual(work.refusal, .notGranted)
        // An unattended change is still refused.
        let unattended = await control.call(name: "routines_save", arguments: .object([]), options: .init(caller: callers[0].1, attended: false))
        XCTAssertEqual(unattended.refusal, .unattended)
        // A key asking for MORE access is refused by access.request_scope itself (TAGAccessScopeTests).
        // Hoot's own settings stay REFUSED, in every mode.
        let patch = NativeRPCValue.object([.init("scope", .string("settings")), .init("patch", .object([.init("hoot.permission.claude", .string("default"))]))])
        for hoot in [callers[0].1, callers[1].1] {
            XCTAssertThrowsError(try BackendDeckCoreCatalogueBuiltins.checkSettingsPatch(patch, caller: hoot)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Hoot's own settings"), error.localizedDescription)
            }
        }
    }

    /// The asking now lives in the AI: Hoot in Ask first gets Claude's own prompt for an app tool that changes things,
    /// even one whose own tier is a read (tasks_agents do=save), while a reading verb still never asks.
    func testAskFirstHootGetsClaudesOwnPromptForAnAppToolThatChangesThings() async throws {
        XCTAssertTrue(BackendHootChatStore.readingCall(.object([.init("do", .string("list"))])))
        XCTAssertFalse(BackendHootChatStore.readingCall(.object([.init("do", .string("save"))])))
        XCTAssertFalse(BackendHootChatStore.readingCall(.object([.init("do", .string("set")), .init("enabled", .bool(true))])))
        XCTAssertTrue(BackendHootChatStore.readingCall(.object([.init("sessionId", .string("s1"))])))
        let root = try temporary()
        let store = try BackendHootChatStore(file: root.appendingPathComponent("chat.json"))
        await store.setToolTier { name in name == "tasks_agents" ? .read : .alter }
        let ask = #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"mcp__deck-control__tools_run","input":{"name":"tasks_agents","arguments":{"do":"save","agent":{"name":"Builder"}}}}}"#
        let script = "IFS= read -r first; printf '%s\\n' '\(ask)'; IFS= read -r answer; printf '%s\\n' \"$answer\" > answer.tmp; /bin/mv answer.tmp answer.json; read more"
        try await store.attach(.init(command: "/bin/sh", arguments: ["-c", script], cwd: root.path, environment: [:]))
        _ = try await store.say("add an agent called Builder")
        var asked = false
        for _ in 0..<250 {
            let events = try (await store.snapshot(limit: 500)["events"].elements ?? []).map(HootChatEvent.init(wire:))
            if events.contains(where: { $0.record.kind == .approval }) { asked = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(asked, "Claude's own prompt is put to the person for a save")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("answer.json").path), "it was not answered by itself")
        await store.stop()
    }

    /// H10 (11 Oct): Hoot's Claude Code always gets the mode the person chose; this Mac's own Claude settings cannot
    /// turn "Ask first" into "ask nothing". Reads never ask.
    func testHootLaunchesWithTheChosenModeAndReadsNeverAsk() throws {
        let root = try temporary(), phone = root.appendingPathComponent("phone.json")
        try Data(#"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"guard"}]}]}}"#.utf8).write(to: phone)
        func settings(_ args: [String]) throws -> NativeRPCValue {
            try NativeRPCValue.parseJSON(Data((args[(args.firstIndex(of: "--settings") ?? 0) + 1]).utf8))
        }
        func mode(_ args: [String]) -> String? { args.firstIndex(of: "--permission-mode").map { args[$0 + 1] } }
        let ask = try BackendHootChatCLI.claudeArguments(sessionID: nil, extra: ["--settings", phone.path])
        // Round 2 / R68: the installed Claude control schema accepts default, not manual.
        XCTAssertEqual(mode(ask), "default")
        XCTAssertEqual(ask.filter { $0 == "--settings" }.count, 1)
        let askSettings = try settings(ask)
        XCTAssertEqual(askSettings["hooks"]["PreToolUse"].elements?.count, 1, "the existing settings are kept")
        XCTAssertEqual(askSettings["permissions"]["ask"].elements?.compactMap(\.string), ["Bash", "Edit", "Write", "MultiEdit", "NotebookEdit"])
        XCTAssertTrue(askSettings["permissions"]["allow"].elements?.contains(.string("mcp__deck-control__tools_describe")) == true)
        XCTAssertFalse(askSettings["permissions"]["allow"].elements?.contains(.string("mcp__deck-control__tools_run")) == true)
        let auto = try BackendHootChatCLI.claudeArguments(sessionID: nil, extra: ["--permission-mode", "acceptEdits"])
        XCTAssertEqual(mode(auto), "acceptEdits")
        XCTAssertEqual(try settings(auto)["permissions"]["ask"].elements?.compactMap(\.string), ["Bash"])
        let bypass = try BackendHootChatCLI.claudeArguments(sessionID: nil, extra: ["--permission-mode", "bypassPermissions"])
        XCTAssertEqual(mode(bypass), "bypassPermissions")
        XCTAssertTrue(try settings(bypass)["permissions"]["ask"].isNullish)
        XCTAssertEqual(mode(try BackendHootChatCLI.claudeArguments(sessionID: nil, extra: ["--permission-mode", "default"])), "default")

        func request(_ name: String, _ input: String = "{}") throws -> NativeRPCValue {
            .object([.init("subtype", .string("can_use_tool")), .init("name", .string(name)), .init("input", try NativeRPCValue.parseJSON(Data(input.utf8)))])
        }
        XCTAssertTrue(BackendHootChatStore.readsOnly(provider: .claude, request: try request("mcp__deck-control__tools_describe")))
        XCTAssertTrue(BackendHootChatStore.readsOnly(provider: .claude, request: try request("mcp__deck-control__tools_run", #"{"name":"memory.search"}"#)))
        XCTAssertFalse(BackendHootChatStore.readsOnly(provider: .claude, request: try request("mcp__deck-control__tools_run", #"{"name":"settings_write"}"#)))
        XCTAssertFalse(BackendHootChatStore.readsOnly(provider: .claude, request: try request("Bash", #"{"command":"date"}"#)))
    }

    /// Retest 3 (11 Oct): a deck tool's own tier decides, also through tools_run (sessions_screen is a read and never
    /// asks, nothing is recorded); a change still asks and is recorded. The island answers like the window.
    func testAReadThroughToolsRunNeverAsksAndTheIslandCanAnswer() async throws {
        let root = try temporary()
        let store = try BackendHootChatStore(file: root.appendingPathComponent("chat.json"))
        await store.setToolTier { name in name == "sessions_screen" ? .read : .alter }
        let ask = #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"mcp__deck-control__tools_run","input":{"name":"sessions_screen","arguments":{"sessionId":"s1"}}}}"#
        let script = "IFS= read -r first; printf '%s\\n' '\(ask)'; IFS= read -r answer; printf '%s\\n' \"$answer\" > answer.tmp; /bin/mv answer.tmp answer.json; read more"
        try await store.attach(.init(command: "/bin/sh", arguments: ["-c", script], cwd: root.path, environment: [:]))
        _ = try await store.say("what does session s1 show?")
        let answerFile = root.appendingPathComponent("answer.json")
        for _ in 0..<250 where !FileManager.default.fileExists(atPath: answerFile.path) { try await Task.sleep(for: .milliseconds(20)) }
        let answer = try String(contentsOf: answerFile, encoding: .utf8)
        XCTAssertTrue(answer.contains("\"behavior\":\"allow\"") && answer.contains("r1"), answer)
        let events = try (await store.snapshot(limit: 500)["events"].elements ?? []).map(HootChatEvent.init(wire:))
        XCTAssertFalse(events.contains { $0.record.kind == .approval || $0.record.kind == .approvalResolved }, "a read is not recorded as a question")
        await store.stop()
        XCTAssertTrue(BackendDeckCoreSecurityConsentBroker.mayAnswerFor(origin: "window", by: "island"))
        XCTAssertFalse(BackendDeckCoreSecurityConsentBroker.mayAnswerFor(origin: "window", by: "device:phone"))
    }

    /// Asad, 11 Oct: Hoot may change every setting except its own; outside AI apps and sessions keep today's refusals.
    func testHootMayChangeEverySettingExceptItsOwn() throws {
        let hoot = BackendDeckCoreSecurityCaller(kind: .local, tiers: [.read, .act, .alter], sessionID: "hoot-session")
        let app = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read, .act, .alter], keyID: "k")
        let session = BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read, .act], sessionID: "s1")
        func patch(_ key: String) -> NativeRPCValue {
            .object([.init("scope", .string("settings")), .init("patch", .object([.init(key, .bool(true))]))])
        }
        for key in ["remote.enabled", "deckControl.port", "security.audit", "confine.sessions", "browser.persistSession"] {
            XCTAssertNoThrow(try BackendDeckCoreCatalogueBuiltins.checkSettingsPatch(patch(key), caller: hoot), key)
            XCTAssertThrowsError(try BackendDeckCoreCatalogueBuiltins.checkSettingsPatch(patch(key), caller: app), key + " stays refused for an AI app")
            XCTAssertThrowsError(try BackendDeckCoreCatalogueBuiltins.checkSettingsPatch(patch(key), caller: session), key + " stays refused for a session")
        }
        for own in ["hoot.permission.claude", "hoot.policy.runSessions", "copilot.folder", "remote.copilotDevices", "confine.hootSandbox", "security.hootConsent"] {
            XCTAssertThrowsError(try BackendDeckCoreCatalogueBuiltins.checkSettingsPatch(patch(own), caller: hoot), own + " is Hoot's own") { error in
                XCTAssertTrue(error.localizedDescription.contains("Hoot's own settings"), error.localizedDescription)
            }
        }
        // The person's own local caller (no Hoot session) is unchanged.
        XCTAssertThrowsError(try BackendDeckCoreCatalogueBuiltins.checkSettingsPatch(patch("remote.enabled"), caller: .local))
    }

    /// Every setting that affects Hoot itself carries the mark (is in HootOwnSettings.keys by name, not only by the
    /// name rule): Hoot's real keys, and any settings definition in the remote / deck-control / security / confinement
    /// groups (or Hoot's own page) whose description is about Hoot.
    func testEverySettingThatAffectsHootIsMarkedAsItsOwn() {
        var real: [String] = [HootProviderPreference.key, RNMHootSettingsMigration.homeKey]
        for provider in HootReadyDefaults.providerOrder { real.append("hoot.permission." + provider.rawValue) }
        for key in real { XCTAssertTrue(HootOwnSettings.keys.contains(key), key + " is Hoot's own but is not in the list") }
        let groups = HootOwnSettings.sharedGroups.map { String($0.dropLast()) } + ["copilot", "remote", "security", "advanced", "ai-apps"]
        for setting in SettingsSchema.all where groups.contains(setting.section) || HootOwnSettings.sharedGroups.contains(where: setting.id.hasPrefix) {
            if HootOwnSettings.describesHoot(id: setting.id, label: setting.label, help: setting.help, more: setting.more) {
                XCTAssertTrue(HootOwnSettings.keys.contains(setting.id), setting.id + " is about Hoot: add it to HootOwnSettings.keys")
            }
        }
        // And the list is what the settings tool uses for Hoot.
        let hoot = BackendDeckCoreSecurityCaller(kind: .local, tiers: [.read, .act, .alter], sessionID: "hoot-session")
        for key in HootOwnSettings.keys { XCTAssertTrue(BackendDeckCoreCatalogueRules.isProtectedSetting(key, for: hoot), key) }
    }
}

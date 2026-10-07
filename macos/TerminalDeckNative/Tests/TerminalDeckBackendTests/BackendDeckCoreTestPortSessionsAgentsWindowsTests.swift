import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class BackendDeckCoreTestPortSessionsAgentsWindowsTests: XCTestCase {
    private typealias V = NativeRPCValue
    private typealias Area = BackendDeckToolsSessionsArea
    private func o(_ fields: [(String, V)]) -> V { .object(fields.map { .init($0.0, $0.1) }) }
    private func call(_ id: String, _ args: V, fixture: BackendDeckCoreTestPortSessionsFixture, attended: Bool = true) async throws -> BackendMCPToolReply {
        let definitions: [BackendDeckToolsDefinition]
        if id.hasPrefix("agents.") { definitions = try Area.agentDefinitions(runtime: fixture, agents: fixture) }
        else if id.hasPrefix("windows.") { definitions = try Area.windowDefinitions(runtime: fixture, windows: fixture) }
        else { definitions = try Area.accountDefinitions(runtime: fixture, accounts: fixture, sessions: fixture) }
        let handler = try XCTUnwrap(definitions.first { $0.spec.id == id }).handler
        return try await handler(BackendDeckCoreTestPortSessionsFixture.context(attended: attended), args)
    }
    private func error(_ reply: BackendMCPToolReply) -> String { reply.content.first?["text"].string ?? "" }
    func testAccountsListResolvesOpenFolderAndRejectsClosedFolder() async throws {
        let f = BackendDeckCoreTestPortSessionsFixture()
        let allowed = try await call("accounts.list", o([("projectPath", .string("/work/api"))]), fixture: f)
        XCTAssertEqual(allowed.structuredContent?["newSessionHere"], o([("id", .string("work"))]))
        XCTAssertEqual(f.calls.filter { $0.name == "resolve" }.map(\.args), [o([("projectPath", .string("/work/api")), ("provider", .null)])])
        let refused = try await call("accounts.list", o([("projectPath", .string("/etc"))]), fixture: f)
        XCTAssertTrue(refused.isError); XCTAssertTrue(error(refused).contains("not a folder this app has open"))
    }
    func testAccountResultsWithholdStoreCredentialStringsAndKeepBooleanFacts() async throws {
        let f = BackendDeckCoreTestPortSessionsFixture(); f.accountList = o([("profiles", .array([f.work.setting("token", .string("sk-ant-secret")).setting("credentialsRetained", .bool(true))]))])
        let reply = try await call("accounts.list", .object([]), fixture: f), text = reply.structuredContent?.compact ?? ""
        XCTAssertFalse(text.contains("sk-ant-secret")); XCTAssertTrue(text.contains("\"token\":\"[withheld]\"")); XCTAssertTrue(text.contains("\"credentialsRetained\":true"))
    }
    func testAccountStatusCombinesExactAccountSigninAndHistory() async throws {
        let f = BackendDeckCoreTestPortSessionsFixture(), reply = try await call("accounts.status", o([("accountId", .string("work"))]), fixture: f)
        XCTAssertEqual(reply.structuredContent?["account"], f.work)
        XCTAssertEqual(reply.structuredContent?["signIn"]["state"], .string("signed-out"))
        XCTAssertEqual(reply.structuredContent?["history"]["share"], .string("Shares 2 folders."))
    }
    func testDeleteSentenceNamesAccountAndFilesLostOrRetained() async throws {
        let f = BackendDeckCoreTestPortSessionsFixture()
        _ = try await call("accounts.delete", o([("accountId", .string("work")), ("deleteFiles", .bool(true))]), fixture: f)
        XCTAssertEqual(f.authorizations.last?.sentence, "Delete the claude account Work and its files on disk. 3 folders of history go.")
        _ = try await call("accounts.delete", o([("accountId", .string("work"))]), fixture: f)
        XCTAssertTrue(f.authorizations.last?.sentence.contains("its files stay on disk") == true)
    }
    func testAccountRenameRejectsUnknownIDBeforeStoreMutation() async throws {
        let f = BackendDeckCoreTestPortSessionsFixture(), reply = try await call("accounts.rename", o([("accountId", .string("nope")), ("name", .string("X"))]), fixture: f)
        XCTAssertTrue(reply.isError); XCTAssertTrue(error(reply).contains("no account with id nope")); XCTAssertFalse(f.calls.contains { $0.name == "rename-account" })
    }
    func testFolderAndGlobalAccountDefaultsAndClearUseExactArguments() async throws {
        let f = BackendDeckCoreTestPortSessionsFixture()
        _ = try await call("accounts.set_default", o([("accountId", .string("work"))]), fixture: f)
        _ = try await call("accounts.set_default", o([("accountId", .string("work")), ("projectPath", .string("/work/web"))]), fixture: f)
        _ = try await call("accounts.set_default", .object([]), fixture: f)
        XCTAssertEqual(f.calls.filter { $0.name == "set-default" }.map(\.args), [
            o([("accountId", .string("work")), ("projectPath", .null)]), o([("accountId", .string("work")), ("projectPath", .string("/work/web"))]), o([("accountId", .null), ("projectPath", .null)])])
        let refused = try await call("accounts.set_default", o([("accountId", .string("work")), ("projectPath", .string("/etc"))]), fixture: f)
        XCTAssertTrue(refused.isError); XCTAssertEqual(f.calls.filter { $0.name == "set-default" }.count, 3)
    }
    func testHistoryDirectionQuotesUnshareAndOnlyInvokesUnshare() async throws {
        let f = BackendDeckCoreTestPortSessionsFixture()
        _ = try await call("accounts.share_history", o([("accountId", .string("work")), ("share", .bool(false))]), fixture: f)
        XCTAssertTrue(f.authorizations.last?.sentence.contains("Gives it its own copy.") == true)
        XCTAssertEqual(f.calls.filter { $0.name == "share-history" }.map(\.args), [o([("accountId", .string("work")), ("share", .bool(false))])])
    }
    func testSignInStartsOnAccountWithSourceProvenanceAndNotesStarter() async throws {
        let f = BackendDeckCoreTestPortSessionsFixture()
        let reply = try await call("accounts.sign_in", o([("accountId", .string("work")), ("folder", .string("/work/api"))]), fixture: f)
        let start = try XCTUnwrap(f.starts.first)
        XCTAssertEqual(start.input.cwd, "/work/api"); XCTAssertEqual(start.input.provider, "claude"); XCTAssertEqual(start.input.profileId, "work")
        XCTAssertEqual(start.input.origin, .copilot); XCTAssertEqual(start.input.originRunId, "call-1"); XCTAssertNil(start.device)
        XCTAssertEqual(f.noted, ["started-1"]); XCTAssertEqual(reply.structuredContent?["sessionId"], .string("started-1")); XCTAssertEqual(reply.structuredContent?["accountId"], .string("work"))
    }
    func testSignInHoldsRemoteCallerToGrantedFolderBeforeStarting() async throws {
        let f = BackendDeckCoreTestPortSessionsFixture(); f.identity = .init(kind: .remote, deviceID: "phone-1", callID: "call-1"); f.devicePaths = ["/work/web"]
        let refused = try await call("accounts.sign_in", o([("accountId", .string("work")), ("folder", .string("/work/api"))]), fixture: f)
        XCTAssertTrue(refused.isError); XCTAssertTrue(f.starts.isEmpty)
        _ = try await call("accounts.sign_in", o([("accountId", .string("work")), ("folder", .string("/work/web"))]), fixture: f)
        XCTAssertEqual(f.starts.first?.device, "phone-1")
    }
    func testAgentListReportsExactInstalledFlagsForBuiltinsAndAdded() async throws {
        let f = BackendDeckCoreTestPortSessionsFixture(), out = try await call("agents.list", .object([]), fixture: f)
        let builtIn = out.structuredContent?["builtIn"].elements ?? []
        XCTAssertEqual(builtIn.first { $0["id"] == .string("claude") }?["installed"], .bool(true))
        XCTAssertEqual(builtIn.first { $0["id"] == .string("codex") }?["installed"], .bool(false))
        XCTAssertEqual(builtIn.first { $0["id"] == .string("shell") }?["installed"], .bool(true))
        XCTAssertEqual(out.structuredContent?["added"].elements?.first?["id"], .string("custom:aider")); XCTAssertEqual(out.structuredContent?["added"].elements?.first?["installed"], .bool(true))
    }
    func testAgentAddRefusesStoresOwnMissingCommandSentence() async throws {
        let f = BackendDeckCoreTestPortSessionsFixture(), out = try await call("agents.add", o([("label", .string("Nope")), ("command", .string("nope"))]), fixture: f)
        XCTAssertTrue(out.isError); XCTAssertTrue(error(out).contains("not on your PATH"))
    }
    func testAgentAddPassesFiveFormFieldsIncludingDefaults() async throws {
        let f = BackendDeckCoreTestPortSessionsFixture(); f.addSuccess = true
        _ = try await call("agents.add", o([("label", .string("X")), ("command", .string("x")), ("args", .string("--fast"))]), fixture: f)
        XCTAssertEqual(f.calls.first { $0.name == "add-agent" }?.args, o([("label", .string("X")), ("command", .string("x")), ("args", .string("--fast")), ("resumeArgs", .string("")), ("description", .string(""))]))
    }
    func testBuiltInAgentRemovalIsRefusedBeforeRemoveOperation() async throws {
        let f = BackendDeckCoreTestPortSessionsFixture(), out = try await call("agents.remove", o([("agentId", .string("claude"))]), fixture: f)
        XCTAssertTrue(out.isError); XCTAssertTrue(error(out).contains("Only agents added by hand")); XCTAssertFalse(f.calls.contains { $0.name == "remove-agent" })
    }
    func testControlsReadSessionOwnFolderAgentAndEntireAcceptsTable() async throws {
        let f = BackendDeckCoreTestPortSessionsFixture(), out = try await call("agents.controls", o([("sessionId", .string("theirs-1"))]), fixture: f)
        XCTAssertEqual(f.calls.first { $0.name == "controls" }?.args, o([("sessionId", .string("theirs-1")), ("cwd", .string("/work/web")), ("provider", .string("claude"))]))
        XCTAssertEqual(out.structuredContent?["accepts"], Area.controlValues)
        let gone = try await call("agents.controls", o([("sessionId", .string("gone"))]), fixture: f)
        XCTAssertTrue(gone.isError); XCTAssertTrue(error(gone).contains("not holding a session"))
    }
    func testModelPickerAndControlChangesRespectStarterAndPermissionAlwaysAlters() async throws {
        let f = BackendDeckCoreTestPortSessionsFixture()
        for id in ["agents.models", "agents.set_control"] {
            for (session, expected) in [("mine-1", BackendMCPTier.act), ("theirs-1", .alter)] {
                _ = try await call(id, o([("sessionId", .string(session)), ("control", .string("model")), ("value", .string("sonnet"))]), fixture: f)
                XCTAssertEqual(f.authorizations.last?.tier, expected, id + session)
            }
        }
        _ = try await call("agents.set_control", o([("sessionId", .string("mine-1")), ("control", .string("permission")), ("value", .string("bypass"))]), fixture: f)
        XCTAssertEqual(f.authorizations.last?.tier, .alter)
    }
    func testApplyUsesExactRequestAndBadControlIsRefusedBeforeAuthorize() async throws {
        let f = BackendDeckCoreTestPortSessionsFixture()
        _ = try await call("agents.set_control", o([("sessionId", .string("mine-1")), ("control", .string("effort")), ("value", .string("high"))]), fixture: f)
        XCTAssertEqual(f.calls.first { $0.name == "apply" }?.args, o([("sessionId", .string("mine-1")), ("cwd", .string("/work/api")), ("control", .string("effort")), ("value", .string("high")), ("provider", .string("claude"))]))
        let prior = f.authorizations.count
        let refused = try await call("agents.set_control", o([("sessionId", .string("mine-1")), ("control", .string("theme")), ("value", .string("x"))]), fixture: f)
        XCTAssertTrue(refused.isError); XCTAssertTrue(error(refused).contains("control must be one of")); XCTAssertEqual(f.authorizations.count, prior)
    }
    func testWindowListReadsOnlyViewAndRecordsExactCounts() async throws {
        let f = BackendDeckCoreTestPortSessionsFixture(), out = try await call("windows.list", .object([]), fixture: f)
        XCTAssertEqual(out.structuredContent, f.windowView)
        XCTAssertEqual(f.results.last?.summary, o([("windows", .number(1)), ("displays", .number(2))]))
        XCTAssertEqual(f.calls.map(\.name), ["window-view"]); XCTAssertEqual(f.authorizations.last?.tier, .read)
    }
    func testPopOutUsesDisplayNameAndSourceSentence() async throws {
        let f = BackendDeckCoreTestPortSessionsFixture(), out = try await call("windows.pop_out", o([("sessionId", .string("mine-1")), ("display", .string("dell u2723qe"))]), fixture: f)
        XCTAssertEqual(f.calls.last?.args, o([("sessionId", .string("mine-1")), ("displayId", .number(7))]))
        XCTAssertEqual(out.structuredContent?["display"], .string("DELL U2723QE")); XCTAssertEqual(f.authorizations.last?.tier, .act)
        _ = try await call("windows.pop_out", o([("sessionId", .string("mine-1")), ("display", .string("DELL U2723QE"))]), fixture: f)
        XCTAssertEqual(f.authorizations.last?.sentence, "Move session mine-1 into its own window on DELL U2723QE")
    }
    func testPopOutUnknownSessionNeverMovesAndRegistryRefusalStaysExact() async throws {
        let f = BackendDeckCoreTestPortSessionsFixture(), gone = try await call("windows.pop_out", o([("sessionId", .string("nope"))]), fixture: f)
        XCTAssertTrue(gone.isError); XCTAssertTrue(error(gone).contains("not holding a session")); XCTAssertFalse(f.calls.contains { $0.name == "window-open" })
        f.windowRefusal = "The copilot stays in the main window."
        let refused = try await call("windows.pop_out", o([("sessionId", .string("mine-1"))]), fixture: f)
        XCTAssertTrue(refused.isError); XCTAssertEqual(error(refused), "The copilot stays in the main window.")
    }
    func testDockNeverStopsSessionAndReturnsExactMessage() async throws {
        let f = BackendDeckCoreTestPortSessionsFixture(), definitions = try Area.windowDefinitions(runtime: f, windows: f)
        XCTAssertTrue(try XCTUnwrap(definitions.first { $0.spec.id == "windows.dock" }).spec.description.contains("never stops anything"))
        let reply = try await call("windows.dock", o([("sessionId", .string("mine-1"))]), fixture: f)
        XCTAssertEqual(f.calls.last?.args, o([("sessionId", .string("mine-1"))]))
        XCTAssertEqual(reply.structuredContent, o([("sessionId", .string("mine-1")), ("message", .string("It is back in the main window."))]))
        XCTAssertFalse(f.calls.contains { $0.name == "kill" })
    }
    func testWindowMetadataAndAllDisplaySpellingsAndMissingDisplayErrors() throws {
        let f = BackendDeckCoreTestPortSessionsFixture()
        for definition in try Area.windowDefinitions(runtime: f, windows: f) { XCTAssertGreaterThan(definition.index?.count ?? 0, 20) }
        for (value, id) in [(V.number(7), 7.0), (.string("7"), 7), (.string("Built-in Retina Display"), 1), (.string("main"), 1)] {
            XCTAssertEqual(try BackendDeckToolsSessionsRules.displayID(value, view: f.windowView), id)
        }
        XCTAssertNil(try BackendDeckToolsSessionsRules.displayID(.missing, view: f.windowView))
        XCTAssertThrowsError(try BackendDeckToolsSessionsRules.displayID(.number(42), view: f.windowView)) { XCTAssertTrue($0.localizedDescription.contains("windows.list")) }
        XCTAssertThrowsError(try BackendDeckToolsSessionsRules.displayID(.string("LG UltraFine"), view: f.windowView)) { XCTAssertTrue($0.localizedDescription.contains("no display is called")) }
    }
}

final class BackendDeckCoreTestPortSessionsFixture: BackendDeckToolsSessionsRuntime, BackendDeckToolsSessionsSurface, BackendDeckToolsSessionsAgents, BackendDeckToolsSessionsAccounts, BackendDeckToolsSessionsWindows, @unchecked Sendable {
    typealias V = NativeRPCValue
    struct Call { let name: String; let args: V }
    struct Authorization { let tier: BackendMCPTier; let sentence: String }
    struct Result { let tool: String; let summary: V }
    struct Start { let input: BackendCreateSessionInput; let device: String? }
    var calls: [Call] = [], authorizations: [Authorization] = [], results: [Result] = [], starts: [Start] = [], noted: [String] = []
    var identity = BackendDeckToolsSessionsCaller(kind: .local, callID: "call-1"), devicePaths: [String]?, owned: Set<String> = ["mine-1"]
    var addSuccess = false, windowRefusal: String?
    var rows: [V] = [], live: V?, screenText = "", files: [V] = [], messages: [V] = [], heldRows: [V] = [], accountRows: [V] = []
    var messagesByPath: [String: [V]] = [:], insightsView: V = .object([]), accountView: V?, limitsView: V = .object([]), byteCount = 1
    var retryHandler: (@Sendable (String) -> [V])?, switchHandler: (@Sendable (String, String) -> V)?
    var accountList: V = .missing
    init() {
        rows = [session("mine-1", cwd: "/work/api"), session("theirs-1", cwd: "/work/web")]
        accountRows = [work]; accountList = o([("profiles", .array([work.setting("configDir", .string("/accounts/work"))])), ("defaultProfileId", .null)])
    }
    static func context(attended: Bool = true) -> BackendMCPCallContext { .init(sessionID: "caller", machineID: "", projectRoot: nil, attended: attended, allowedTools: [], allowedTiers: [.read, .act, .alter], cancellation: .init()) }
    func o(_ fields: [(String, V)]) -> V { .object(fields.map { .init($0.0, $0.1) }) }
    var work: V { o([("id", .string("work")), ("name", .string("Work")), ("provider", .string("claude"))]) }
    var windowView: V { o([("windows", .array([o([("sessionId", .string("mine-1")), ("label", .string("api")), ("status", .string("working")), ("displayId", .number(7)), ("displayLabel", .string("DELL U2723QE")), ("bounds", o([("x", .number(2000)), ("y", .number(100)), ("width", .number(960)), ("height", .number(640))])), ("fullScreen", .bool(false)), ("minimized", .bool(false)), ("focused", .bool(true))])])), ("displays", .array([o([("id", .number(1)), ("label", .string("Built-in Retina Display")), ("primary", .bool(true)), ("width", .number(1512)), ("height", .number(982))]), o([("id", .number(7)), ("label", .string("DELL U2723QE")), ("primary", .bool(false)), ("width", .number(2560)), ("height", .number(1440))])]))]) }
    func session(_ id: String, cwd: String, exit: V = .null) -> V { o([("id", .string(id)), ("cwd", .string(cwd)), ("provider", .string("claude")), ("createdAt", .number(1000)), ("exitCode", exit), ("status", .string("waiting")), ("attention", .string("quiet")), ("attentionReason", .string("prompt-ready"))]) }
    func note(_ name: String, _ args: V = .object([])) { calls.append(.init(name: name, args: args)) }
    func caller(_ context: BackendMCPCallContext) -> BackendDeckToolsSessionsCaller { identity }
    func sessions(_ context: BackendMCPCallContext) -> [V] { rows }
    func knownFolders(_ context: BackendMCPCallContext) -> Set<String> { ["/work/api", "/work/web"] }
    func deviceFolders(deviceID: String, context: BackendMCPCallContext) -> [String]? { devicePaths }
    func startedByCaller(sessionID: String, context: BackendMCPCallContext) -> Bool { owned.contains(sessionID) }
    func noteStarted(sessionID: String, context: BackendMCPCallContext) { noted.append(sessionID); owned.insert(sessionID) }
    func authorize(tool: BackendMCPTool, tier: BackendMCPTier, summary: String, arguments: V, context: BackendMCPCallContext) { authorizations.append(.init(tier: tier, sentence: summary)) }
    func recordResult(toolID: String, summary: V, context: BackendMCPCallContext) { results.append(.init(tool: toolID, summary: summary)) }
    func browserSlots(sessionID: String, machineID: String, context: BackendMCPCallContext) -> [String] { [] }
    func status(sessionID: String, context: BackendMCPCallContext) -> V? { live }
    func screen(sessionID: String, context: BackendMCPCallContext) -> String? { screenText }
    func write(sessionID: String, data: String, context: BackendMCPCallContext) { note("write", o([("sessionId", .string(sessionID)), ("data", .string(data))])) }
    func rename(sessionID: String, title: String, context: BackendMCPCallContext) -> String? { note("rename", o([("sessionId", .string(sessionID)), ("title", .string(title))])); return title.isEmpty ? "api" : title }
    func held(context: BackendMCPCallContext) -> [V] { heldRows }
    func retryHeld(key: String, context: BackendMCPCallContext) -> [V] { if let retryHandler { return retryHandler(key) }; note("retry-held"); return heldRows }
    func forgetHeld(key: String, context: BackendMCPCallContext) -> [V] { note("forget-held"); heldRows.removeAll { $0["key"] == .string(key) }; return heldRows }
    func account(sessionID: String, context: BackendMCPCallContext) -> V { accountView ?? work }
    func limits(sessionID: String, context: BackendMCPCallContext) -> V { limitsView }
    func accountPlan(sessionID: String, profileID: String, context: BackendMCPCallContext) -> V { .object([]) }
    func switchAccount(sessionID: String, profileID: String, context: BackendMCPCallContext) -> V { note("switch", o([("sessionId", .string(sessionID)), ("profileId", .string(profileID))])); return switchHandler?(sessionID, profileID) ?? session("replacement", cwd: "/work/api") }
    func switchLater(sessionID: String, profileID: String, context: BackendMCPCallContext) -> V { .object([]) }
    func cancelSwitch(sessionID: String, context: BackendMCPCallContext) -> Bool { true }
    func armedSwitches(context: BackendMCPCallContext) -> [V] { [] }
    func accounts(context: BackendMCPCallContext) -> [V] { accountRows }
    func search(request: V, context: BackendMCPCallContext) -> V { note("search", request); return .object([.init("hits", .array([]))]) }
    func insights(transcriptPath: String, context: BackendMCPCallContext) -> V { insightsView }
    func transcripts(cwd: String, context: BackendMCPCallContext) -> [V] { files }
    func transcriptBytes(path: String, context: BackendMCPCallContext) -> Int { byteCount }
    func transcriptMessages(path: String, fromByte: Int, context: BackendMCPCallContext) -> [V] { note("read-transcript", o([("path", .string(path)), ("fromByte", .number(Double(fromByte)))])); return messagesByPath[path] ?? messages }
    func start(input: BackendCreateSessionInput, deviceID: String?, context: BackendMCPCallContext) -> V { starts.append(.init(input: input, device: deviceID)); return session("started-\(starts.count)", cwd: input.cwd) }
    func detect(context: BackendMCPCallContext) -> V { o([("claude", .bool(true)), ("codex", .bool(false)), ("gemini", .bool(false)), ("custom:aider", .bool(true))]) }
    func added(context: BackendMCPCallContext) -> [V] { [o([("id", .string("custom:aider")), ("label", .string("Aider"))])] }
    func add(draft: V, context: BackendMCPCallContext) -> V { note("add-agent", draft); return addSuccess ? o([("ok", .bool(true)), ("agent", draft.setting("id", .string("custom:x")))]) : o([("ok", .bool(false)), ("problems", o([("command", .string("`nope` is not on your PATH."))]))]) }
    func remove(agentID: String, context: BackendMCPCallContext) -> Bool { note("remove-agent", .string(agentID)); return agentID == "custom:aider" }
    func controls(sessionID: String, cwd: String, provider: String, context: BackendMCPCallContext) -> V { note("controls", o([("sessionId", .string(sessionID)), ("cwd", .string(cwd)), ("provider", .string(provider))])); return o([("live", .bool(true)), ("model", o([("value", .string("opus")), ("label", .string("Opus")), ("source", .string("screen"))]))]) }
    func models(sessionID: String, provider: String, context: BackendMCPCallContext) -> V { .object([.init("models", .array([]))]) }
    func apply(request: V, context: BackendMCPCallContext) -> V { note("apply", request); return o([("ok", .bool(true)), ("message", .string("Set model to Sonnet"))]) }
    func list(agent: String?, context: BackendMCPCallContext) -> V { accountList }
    func agents(context: BackendMCPCallContext) -> V { .object([.init("providers", .array([]))]) }
    func resolve(projectPath: String?, provider: String?, context: BackendMCPCallContext) -> V { note("resolve", o([("projectPath", projectPath.map(V.string) ?? .null), ("provider", provider.map(V.string) ?? .null)])); return .object([.init("id", .string("work"))]) }
    func find(accountID: String, context: BackendMCPCallContext) -> V? { accountID == "work" ? work : nil }
    func status(accountID: String, context: BackendMCPCallContext) -> V { .object([.init("exists", .bool(true))]) }
    func signInStatus(accountID: String, refresh: Bool, context: BackendMCPCallContext) -> V { o([("state", .string("signed-out")), ("detail", .string("Run claude to sign in."))]) }
    func history(accountID: String, context: BackendMCPCallContext) -> V { o([("state", .object([])), ("share", .string("Shares 2 folders.")), ("unshare", .string("Gives it its own copy.")), ("remove", .string("3 folders of history go."))]) }
    func create(name: String, provider: String?, context: BackendMCPCallContext) -> V { o([("id", .string("new")), ("name", .string(name))]) }
    func rename(accountID: String, name: String, context: BackendMCPCallContext) -> V { note("rename-account"); return o([("id", .string(accountID)), ("name", .string(name))]) }
    func delete(accountID: String, deleteFiles: Bool, context: BackendMCPCallContext) -> V { o([("removed", .bool(true)), ("filesDeleted", .bool(false)), ("credentialsRetained", .bool(true))]) }
    func setDefault(accountID: String?, projectPath: String?, context: BackendMCPCallContext) -> V { note("set-default", o([("accountId", accountID.map(V.string) ?? .null), ("projectPath", projectPath.map(V.string) ?? .null)])); return .object([]) }
    func signOut(accountID: String, context: BackendMCPCallContext) -> V { o([("ok", .bool(true)), ("message", .string("Signed out."))]) }
    func shareHistory(accountID: String, share: Bool, context: BackendMCPCallContext) -> V { note("share-history", o([("accountId", .string(accountID)), ("share", .bool(share))])); return .object([]) }
    func view(context: BackendMCPCallContext) -> V { note("window-view"); return windowView }
    func open(sessionID: String, displayID: Double?, context: BackendMCPCallContext) -> V { note("window-open", o([("sessionId", .string(sessionID)), ("displayId", displayID.map(V.number) ?? .null)])); return o([("ok", .bool(windowRefusal == nil)), ("message", .string(windowRefusal ?? "It is in its own window now.")), ("sessionId", .string(sessionID)), ("display", .string(displayID == 7 ? "DELL U2723QE" : "Built-in Retina Display"))]) }
    func dock(sessionID: String, context: BackendMCPCallContext) -> V { note("window-dock", .object([.init("sessionId", .string(sessionID))])); return o([("ok", .bool(true)), ("message", .string("It is back in the main window.")), ("sessionId", .string(sessionID))]) }
}

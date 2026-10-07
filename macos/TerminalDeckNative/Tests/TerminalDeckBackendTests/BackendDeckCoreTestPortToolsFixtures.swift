import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

enum BackendDeckCoreTestPortToolsFixture {
    static func json(_ text: String) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(text.utf8)) }
    static func object(_ pairs: [(String,NativeRPCValue)]) -> NativeRPCValue { .object(pairs.map { .init($0.0,$0.1) }) }
    static func caller(tiers: Set<BackendMCPTier> = [.read,.act,.alter]) -> BackendMCPCallContext {
        .init(sessionID:"test",machineID:"",projectRoot:nil,attended:true,allowedTools:[],allowedTiers:tiers,cancellation:.init())
    }
    static func access(_ audit: BackendDeckCoreTestPortToolsAudit, identity: BackendDeckToolsAppCaller = .init(kind:.local)) -> BackendDeckToolsAppAccess {
        .init(caller:{ _ in identity },knownFolder:{ _,path in
            guard ["/work/api","/work/web","/work/site"].contains(path) else { throw BackendDeckToolsAppKit.refused("\(path) is not a folder this app has open. Use projects.list to see the folders you can ask about.") }; return path
        },session:{ _,id in object([("id",.string(id)),("cwd",.string("/work/api")),("provider",.string("claude"))]) },runnableProject:{ _,path in path },rpc:{ _ in .init(caller:.internalEngine,ownerID:"test") },authorize:{ _,id,args,tier,sentence,owner in await audit.authorize(id,args:args,tier:tier,sentence:sentence,owner:owner) },record:{ _,id,args,summary in await audit.record(id,args:args,summary:summary) },now:{ 1_000_000 })
    }
    static func call(_ definitions: [BackendDeckToolsDefinition], _ id: String, _ args: String = "{}", caller: BackendMCPCallContext = BackendDeckCoreTestPortToolsFixture.caller()) async throws -> BackendMCPToolReply {
        let definition = try XCTUnwrap(definitions.first { $0.spec.id == id }); return try await definition.handler(caller,json(args))
    }
    static func value(_ reply: BackendMCPToolReply) throws -> NativeRPCValue { XCTAssertFalse(reply.isError,reply.content.first?["text"].string ?? ""); return try XCTUnwrap(reply.structuredContent) }
    static func error(_ reply: BackendMCPToolReply, contains: String) {
        XCTAssertTrue(reply.isError); XCTAssertTrue(reply.content.first?["text"].string?.contains(contains) == true,reply.content.first?["text"].string ?? "")
    }
}

actor BackendDeckCoreTestPortToolsAudit {
    private var authorizations: [NativeRPCValue] = []
    private var records: [NativeRPCValue] = []
    func authorize(_ id: String,args: NativeRPCValue,tier: BackendMCPTier,sentence: String,owner: Bool) { authorizations.append(BackendDeckCoreTestPortToolsFixture.object([("id",.string(id)),("args",args),("tier",.string(tier.rawValue)),("sentence",.string(sentence)),("owner",.bool(owner))])) }
    func record(_ id: String,args: NativeRPCValue,summary: NativeRPCValue) { records.append(BackendDeckCoreTestPortToolsFixture.object([("id",.string(id)),("args",args),("summary",summary)])) }
    func consent() -> [NativeRPCValue] { authorizations }
    func completed() -> [NativeRPCValue] { records }
}

actor BackendDeckCoreTestPortToolsApplicationFake: BackendDeckToolsAppApplicationService, BackendDeckToolsAppUpdateService, BackendDeckToolsAppSettingsService, BackendDeckToolsAppVoiceService, BackendDeckToolsAppUsageService, BackendDeckToolsAppSetupService, BackendDeckToolsAppGitHubService, BackendDeckToolsAppCopilotService, BackendDeckToolsAppSmallDoorsService, BackendDeckToolsAppUIService {
    nonisolated let fixIDs: Set<String> = ["create-gitignore","create-readme"]
    private var settings: NativeRPCValue = try! BackendDeckCoreTestPortToolsFixture.json(#"{"appearance.density":"compact","editor.font":"Mono","remote.enabled":true,"advanced.debugMode":false}"#)
    private var responses: [String:NativeRPCValue] = [:]
    private var trace: [NativeRPCValue] = []
    private var phase = "idle"
    private var updater = true
    func set(_ operation: String,_ value: NativeRPCValue) { responses[operation] = value }
    func setPhase(_ phase: String) { self.phase = phase }
    func setUpdater(_ on: Bool) { updater = on }
    func calls() -> [NativeRPCValue] { trace }
    func currentSettings() -> NativeRPCValue { settings }
    private func record(_ name: String,_ args: [NativeRPCValue] = []) { trace.append(BackendDeckCoreTestPortToolsFixture.object([("operation",.string(name)),("args",.array(args))])) }
    private func answer(_ name: String,_ fallback: String, _ args: [NativeRPCValue] = []) throws -> NativeRPCValue { record(name,args); if let response = responses[name] { return response }; return try BackendDeckCoreTestPortToolsFixture.json(fallback) }
    func about() throws -> NativeRPCValue { try answer("about",#"{"version":"0.16.0"}"#) }
    func brand() throws -> NativeRPCValue { try answer("brand",#"{"name":"Deck","tagline":"agents"}"#) }
    func paths() throws -> [NativeRPCValue] { try answer("paths",#"[{"key":"logs","label":"Logs","purpose":"","path":"/state/logs","kind":"folder","exists":true}]"#).requireArray("paths") }
    func logStatus() throws -> NativeRPCValue { try answer("logStatus",#"{"bytes":10}"#) }
    func openPath(_ key: String) throws -> NativeRPCValue { record("openPath",[.string(key)]); return BackendDeckCoreTestPortToolsFixture.object([("opened",.bool(true)),("path",.string("/state/"+key)),("message",.string("Opened."))]) }
    func openLogFolder() -> String { record("openLogFolder"); return "" }
    func diagnostics(includeClis: Bool,logLines: Int,text: Bool) throws -> NativeRPCValue { try answer("diagnostics",text ? #""report""# : #"{"app":{}}"#) }
    func recentLog(_ lines: Int) -> NativeRPCValue { record("recentLog",[.number(Double(lines))]); return BackendDeckCoreTestPortToolsFixture.object([("file",.string("/state/log.txt")),("lines",.array((0..<min(lines,3)).map { .string("line \($0)") }))]) }
    func recentCalls(_ limit: Int) throws -> [NativeRPCValue] { try answer("recentCalls",#"[{"channel":"prefs:get","ms":1,"ok":true}]"#,[.number(Double(limit))]).requireArray("calls") }
    func clearLog() { record("clearLog") }
    func clearCalls() { record("clearCalls") }
    func clearBrowserData() throws -> NativeRPCValue { try answer("clearBrowserData",#"{"cleared":true,"message":"Gone."}"#) }
    func updates() -> (any BackendDeckToolsAppUpdateService)? { updater ? self : nil }
    func state() -> NativeRPCValue { record("state"); return BackendDeckCoreTestPortToolsFixture.object([("phase",.string(phase)),("status",.string("running"))]) }
    func check(automatic: Bool) throws -> NativeRPCValue { try answer("check",#"{"phase":"available","version":"0.17.0"}"#,[.bool(automatic)]) }
    func download() throws -> NativeRPCValue { try answer("download",#"{"phase":"ready","version":"0.17.0"}"#) }
    func installNow() throws -> NativeRPCValue { try answer("installNow",#"{"phase":"ready","version":"0.17.0"}"#) }
    func readSettings() -> NativeRPCValue { BackendDeckCoreTestPortToolsFixture.object([("settings",settings)]) }
    func snapshotSettings() -> String { record("snapshot"); return "/state/settings.last-good.json" }
    func writeSettings(_ patch: NativeRPCValue) -> NativeRPCValue { record("writeSettings",[patch]); for field in patch.fields ?? [] { settings = field.value == .null ? settings.removing(field.key) : settings.setting(field.key,field.value) }; return settings }
    func applyToWindow(_ settings: NativeRPCValue) -> Bool { record("applyToWindow",[settings]); return true }
    private var claude: NativeRPCValue { try! BackendDeckCoreTestPortToolsFixture.json(#"{"id":"claude","label":"Claude Code","state":"complete","message":"Installed."}"#) }
    func hookStatus() -> [NativeRPCValue] { [claude] }
    func server() throws -> NativeRPCValue { try answer("server",#"{"address":"/state/hook/hook.sock","running":true,"error":null}"#) }
    func offer() throws -> NativeRPCValue { try answer("offer",#"{"show":false,"answered":"accepted","eligible":[],"followUps":[]}"#) }
    func install(_ provider: String,caller: BackendMCPCallContext) throws -> NativeRPCValue { record("install",[.string(provider)]); return BackendDeckCoreTestPortToolsFixture.object([("ok",.bool(true)),("message",.string("Installed.")),("status",claude)]) }
    func remove(_ provider: String,caller: BackendMCPCallContext) throws -> NativeRPCValue { record("remove",[.string(provider)]); return responses["remove"] ?? BackendDeckCoreTestPortToolsFixture.object([("ok",.bool(true)),("message",.string("Removed.")),("status",claude.setting("state",.string("none")))]) }
    func sync(_ caller: BackendMCPCallContext) -> [NativeRPCValue] { record("sync"); return [claude] }
    func acceptOffer(_ caller: BackendMCPCallContext) -> [NativeRPCValue] { record("acceptOffer"); return [BackendDeckCoreTestPortToolsFixture.object([("ok",.bool(true)),("message",.string("Installed.")),("status",claude)])] }
    func declineOffer(_ caller: BackendMCPCallContext) { record("declineOffer") }
    func providers() throws -> [NativeRPCValue] { try answer("voiceProviders",#"[{"id":"groq","label":"Groq"}]"#).requireArray("providers") }
    func status() throws -> NativeRPCValue { try answer("voiceStatus",#"{"provider":"groq","hasKey":true,"canStore":true,"reason":null}"#) }
    func save(provider: String,key: String) throws -> NativeRPCValue { try answer("save",#"{"ok":true,"message":"That key works."}"#,[.string(provider),.string(key)]) }
    func forget() { record("forget") }
    func transcribe(audio: Data,filename: String) throws -> NativeRPCValue { try answer("transcribe",#"{"ok":true,"text":"hello there","message":""}"#,[.bytes(audio),.string(filename)]) }
    func read(_ sessionID: String?,caller: BackendMCPCallContext) -> NativeRPCValue { record("usageRead",[sessionID.map(NativeRPCValue.string) ?? .null]); return BackendDeckCoreTestPortToolsFixture.object([("sessionId",sessionID.map(NativeRPCValue.string) ?? .null),("readings",.array([]))]) }
    func context(_ sessionID: String,caller: BackendMCPCallContext) throws -> NativeRPCValue { try answer("context",#"{"percent":40}"#) }
    func refresh(_ sessionID: String,force: Bool,caller: BackendMCPCallContext) throws -> NativeRPCValue { try answer("usageRefresh",#"{"refreshed":true}"#) }
    func projectCost(_ path: String,caller: BackendMCPCallContext) -> NativeRPCValue { BackendDeckCoreTestPortToolsFixture.object([("path",.string(path)),("tokens",.number(100))]) }
    func transcripts(_ path: String,caller: BackendMCPCallContext) throws -> [NativeRPCValue] { try answer("transcripts",#"[{"path":"/store/api/a.jsonl","sessionId":"a","modifiedAt":2},{"path":"/store/api/b.jsonl","sessionId":"b","modifiedAt":1}]"#).requireArray("transcripts") }
    func sessionCost(_ path: String,caller: BackendMCPCallContext) -> NativeRPCValue { record("sessionCost",[.string(path)]); return BackendDeckCoreTestPortToolsFixture.object([("path",.string(path)),("tokens",.number(7))]) }
    func setup(_ caller: BackendMCPCallContext) throws -> NativeRPCValue { try answer("setup",#"{"tools":[]}"#) }
    func scan(_ path: String,caller: BackendMCPCallContext) throws -> NativeRPCValue { try answer("scan",#"{"checks":[{"id":"gitignore","fix":{"id":"create-gitignore","label":"Create .gitignore","description":"Writes a .gitignore for this stack.","touches":[".gitignore"],"destructive":false}},{"id":"readme","fix":null}]}"#) }
    func fix(_ path: String,id: String,caller: BackendMCPCallContext) throws -> NativeRPCValue { try answer("fix",#"{"ok":true,"message":"Wrote .gitignore.","changed":[".gitignore"]}"#,[.string(path),.string(id)]) }
    func overview(_ folder: String) throws -> NativeRPCValue { try answer("overview",#"{"pulls":[]}"#,[.string(folder)]) }
    func refresh(_ folder: String) throws -> NativeRPCValue { try answer("refresh",#"{"pulls":[{"number":7}]}"#,[.string(folder)]) }
    func repo(_ folder: String) throws -> NativeRPCValue { try answer("repo",#"{"owner":"asadev","name":"site"}"#,[.string(folder)]) }
    func clearCache(_ folder: String) { record("clearCache",[.string(folder)]) }
    func authStatus(_ folder: String) throws -> NativeRPCValue { try answer("authStatus",#"{"connected":false,"pending":{"userCode":"WXYZ-1234","verificationUri":"https://github.com/login/device"}}"#,[.string(folder)]) }
    func connect() throws -> NativeRPCValue { try answer("connect",#"{"userCode":"WXYZ-1234","verificationUri":"https://github.com/login/device","expiresAt":9}"#) }
    func awaitAuth(_ folder: String) throws -> NativeRPCValue { try answer("awaitAuth",#"{"connected":true}"#,[.string(folder)]) }
    func cancel(_ folder: String) throws -> NativeRPCValue { try answer("cancel",#"{"connected":false}"#,[.string(folder)]) }
    func disconnect(_ folder: String) throws -> NativeRPCValue { try answer("disconnect",#"{"connected":false}"#,[.string(folder)]) }
    func signIn() throws -> NativeRPCValue { try answer("signIn",#"{"state":"signed-in","account":"me@example.com","plan":"max"}"#) }
    func start() throws -> NativeRPCValue { try answer("start",#"{"status":"starting"}"#) }
    func stop() throws -> NativeRPCValue { try answer("stop",#"{"status":"stopped"}"#) }
    func scaffold() throws -> NativeRPCValue { try answer("scaffold",#"{"created":[]}"#) }
    func reveal(_ place: String) throws -> NativeRPCValue { try answer("reveal",#"{"opened":true,"message":"opened"}"#,[.string(place)]) }
    func readInstructions(_ which: String) -> NativeRPCValue { BackendDeckCoreTestPortToolsFixture.object([("which",.string(which))]) }
    func writeInstructions(_ which: String,text: String) -> NativeRPCValue { record("writeInstructions",[.string(which),.string(text)]); return BackendDeckCoreTestPortToolsFixture.object([("saved",.bool(true))]) }
    func resetInstructions() throws -> NativeRPCValue { try answer("resetInstructions",#"{"error":null}"#) }
    func listMemory() throws -> NativeRPCValue { try answer("listMemory",#"{"facts":[]}"#) }
    func readMemory(_ name: String) -> NativeRPCValue { BackendDeckCoreTestPortToolsFixture.object([("name",.string(name))]) }
    func writeMemory(_ name: String,text: String) -> NativeRPCValue { record("writeMemory",[.string(name),.string(text)]); return BackendDeckCoreTestPortToolsFixture.object([("ok",.bool(true))]) }
    func deleteMemory(_ name: String) throws -> NativeRPCValue { try answer("deleteMemory",#"{"ok":true}"#,[.string(name)]) }
    func toolStatus() -> NativeRPCValue? { responses["toolStatus"] }
    func notificationSupport() throws -> NativeRPCValue { try answer("notificationSupport",#"{"settingsPane":true}"#) }
    func notificationDelivery(sinceMs: Double) -> NativeRPCValue { BackendDeckCoreTestPortToolsFixture.object([("since",.number(sinceMs))]) }
    func openNotificationSettings() throws -> NativeRPCValue { try answer("openNotificationSettings",#"{"opened":true}"#) }
    func openURL(_ url: String) -> Bool { record("openURL",[.string(url)]); return true }
    func list() -> NativeRPCValue? { responses["uiList"] }
    func perform(kind: String,target: String) -> NativeRPCValue? { record("uiPerform",[.string(kind),.string(target)]); return responses["uiPerform"] }
}

struct BackendDeckCoreTestPortToolsHookFake: BackendDeckToolsAppHookService {
    let owner: BackendDeckCoreTestPortToolsApplicationFake
    let providers = ["claude","codex","gemini"]
    func status() async throws -> [NativeRPCValue] { await owner.hookStatus() }
    func server() async throws -> NativeRPCValue { try await owner.server() }
    func offer() async throws -> NativeRPCValue { try await owner.offer() }
    func install(_ provider: String,caller: BackendMCPCallContext) async throws -> NativeRPCValue { try await owner.install(provider,caller:caller) }
    func remove(_ provider: String,caller: BackendMCPCallContext) async throws -> NativeRPCValue { try await owner.remove(provider,caller:caller) }
    func sync(_ caller: BackendMCPCallContext) async throws -> [NativeRPCValue] { await owner.sync(caller) }
    func acceptOffer(_ caller: BackendMCPCallContext) async throws -> [NativeRPCValue] { await owner.acceptOffer(caller) }
    func declineOffer(_ caller: BackendMCPCallContext) async throws { await owner.declineOffer(caller) }
}

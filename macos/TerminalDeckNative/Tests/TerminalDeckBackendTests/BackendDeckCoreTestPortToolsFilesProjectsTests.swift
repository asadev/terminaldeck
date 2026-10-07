import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

struct BackendDeckCoreTestPortToolsFilesRuntime: BackendDeckToolsFilesRuntime {
    let audit: BackendDeckCoreTestPortToolsAudit
    var held: Bool = false
    var own: Bool = false
    func rpc(_ caller: BackendMCPCallContext) -> NativeRPCContext { .init(caller:.nativeApp,ownerID:"fixture") }
    func knownFolder(_ path: String,caller: BackendMCPCallContext) throws -> String { guard ["/work/api","/work/web"].contains(path) else { throw BackendDeckToolsArgs.bad("\(path) is not a folder this app has open.") }; return path }
    func requireSession(_ id: String,caller: BackendMCPCallContext) -> NativeRPCValue { BackendDeckCoreTestPortToolsFixture.object([("id",.string(id)),("cwd",.string("/work/api"))]) }
    func startedByCopilot(_ id: String,caller: BackendMCPCallContext) -> Bool { own }
    func boundary(_ id: String) -> BackendDeviceBoundary? { held ? .init(deviceKey:"phone",folder:"/work/api",readOnlyProjects:["/work/web"]) : nil }
    func authorize(_ caller: BackendMCPCallContext,tool: String,tier: BackendMCPTier,summary: String,arguments: NativeRPCValue) async { await audit.authorize(tool,args:arguments,tier:tier,sentence:summary,owner:false) }
    func completed(_ caller: BackendMCPCallContext,tool: String,summary: NativeRPCValue) async { await audit.record(tool,args:.object([]),summary:summary) }
}
actor BackendDeckCoreTestPortToolsFilesFake: BackendDeckToolsFilesProvider {
    private var calls: [String] = []
    func trace() -> [String] { calls }
    func list(root: String,relative: String,showIgnored: Bool,withStats: Bool,context: NativeRPCContext) -> NativeRPCValue { BackendDeckCoreTestPortToolsFixture.object([("entries",.array([BackendDeckCoreTestPortToolsFixture.object([("name",.string("src")),("relPath",.string(relative.isEmpty ? "src" : relative+"/src")),("kind",.string("dir")),("symlink",.bool(false)),("blocked",.bool(false)),("bytes",.number(1))])])),("truncated",.bool(false))]) }
    func read(root: String,relative: String,context: NativeRPCContext) -> NativeRPCValue { BackendDeckCoreTestPortToolsFixture.object([("kind",.string("text")),("relPath",.string(relative)),("text",.string((1...10).map { "line \($0)" }.joined(separator:"\n"))),("bytes",.number(70)),("lines",.number(10))]) }
    func projectFiles(root: String,refresh: Bool,context: NativeRPCContext) -> NativeRPCValue { calls.append("list refresh=\(refresh)"); return try! BackendDeckCoreTestPortToolsFixture.json(#"{"files":["src/login/form.ts","src/app.ts","docs/login.md","test/login-form.test.ts"],"truncated":false,"source":"git"}"#) }
    func invalidate(root: String) { calls.append("invalidate "+root) }
    func ignore(root: String,action: String,path: String?,directory: Bool,paths: [String],context: NativeRPCContext) -> NativeRPCValue { BackendDeckCoreTestPortToolsFixture.object([("kept",.array(paths.filter { !$0.hasPrefix("dist/") }.map(NativeRPCValue.string)))]) }
    func stage(name: String,bytes: Data) -> NativeRPCValue { calls.append("stage \(name) \(bytes.count)"); return BackendDeckCoreTestPortToolsFixture.object([("ok",.bool(true)),("path",.string("/Users/me/Downloads/Terminal Deck/"+name))]) }
    func isDirectory(_ path: String,context: NativeRPCContext) -> Bool? { path.hasSuffix("/") || path == "/Users/me/folder" ? true : path.contains("missing") ? nil : false }
    func bringIn(source: String,folder: String,context: NativeRPCContext) -> String { calls.append("copy "+source); return folder+"/Terminal Deck/"+(source.components(separatedBy:"/").last ?? "") }
}
actor BackendDeckCoreTestPortToolsProjectsFake: BackendDeckToolsProjectProvider {
    nonisolated let home = "/Users/me",appDataRoot = "/state"
    private var calls: [String] = []
    func trace() -> [String] { calls }
    func listProjects() -> [NativeRPCValue] { [BackendDeckCoreTestPortToolsFixture.object([("path",.string("/work/api")),("lastOpenedAt",.number(1))])] }
    func listFolder(path: String,context: NativeRPCContext) -> NativeRPCValue { try! BackendDeckCoreTestPortToolsFixture.json(#"{"entries":[{"name":"Projects","kind":"dir","blocked":false},{"name":".config","kind":"dir","blocked":false},{"name":"notes.txt","kind":"file","blocked":false},{"name":"loop","kind":"dir","blocked":true}],"truncated":false}"#) }
    func isFolder(_ path: String,context: NativeRPCContext) -> Bool { ["/Users/me","/Users/me/Projects","/Users/me/Projects/app","/Users/me/Projects/app/.git","/work/api"].contains(path) }
    func add(path: String,context: NativeRPCContext) -> NativeRPCValue { calls.append("add "+path); return BackendDeckCoreTestPortToolsFixture.object([("path",.string(path)),("already",.bool(false)),("inWindow",.bool(false))]) }
    func remove(path: String,context: NativeRPCContext) -> NativeRPCValue { calls.append("remove "+path); return BackendDeckCoreTestPortToolsFixture.object([("path",.string(path)),("removed",.bool(true)),("stillRunning",.array([.string("s1")]))]) }
    func gitStatus(cwd: String,context: NativeRPCContext) -> NativeRPCValue { BackendDeckCoreTestPortToolsFixture.object([("repo",.bool(cwd == "/work/api")),("cwd",.string(cwd))]) }
    func gitInitialize(cwd: String,context: NativeRPCContext) -> NativeRPCValue { calls.append("init "+cwd); return BackendDeckCoreTestPortToolsFixture.object([("repo",.bool(true)),("cwd",.string(cwd))]) }
    func devStart(folder: String,context: NativeRPCContext) -> NativeRPCValue { calls.append("dev "+folder); return BackendDeckCoreTestPortToolsFixture.object([("folder",.string(folder)),("status",.string("starting"))]) }
    func devStatus(folder: String,context: NativeRPCContext) -> NativeRPCValue { BackendDeckCoreTestPortToolsFixture.object([("folder",.string(folder)),("status",.string("idle"))]) }
    func scanPorts(force: Bool) -> [NativeRPCValue] { [try! BackendDeckCoreTestPortToolsFixture.json(#"{"port":5173,"process":"node"}"#)] }
    func dashboardLoad(projectPath: String) -> NativeRPCValue { .null }
    func dashboardSave(projectPath: String,layout: NativeRPCValue) { calls.append("save "+projectPath) }
    func dashboardClear(projectPath: String) { calls.append("clear "+projectPath) }
    func artifactsList(project: String,options: BackendArtifactScanOptions,context: NativeRPCContext) -> NativeRPCValue { BackendDeckCoreTestPortToolsFixture.object([("cwd",.string(project)),("scope",.string(options.scope.rawValue)),("maxArtifacts",.number(Double(options.maxArtifacts)))]) }
    func artifactHistory(project: String,relative: String,options: BackendArtifactScanOptions,context: NativeRPCContext) -> NativeRPCValue { BackendDeckCoreTestPortToolsFixture.object([("cwd",.string(project)),("relPath",.string(relative))]) }
}

@MainActor
final class BackendDeckCoreTestPortToolsFilesProjectsTests: XCTestCase {
    private typealias F = BackendDeckCoreTestPortToolsFixture
    private func files(_ fake: BackendDeckCoreTestPortToolsFilesFake,audit: BackendDeckCoreTestPortToolsAudit = .init(),held: Bool = false) throws -> [BackendDeckToolsDefinition] { try BackendDeckToolsFiles.definitions(provider:fake,runtime:BackendDeckCoreTestPortToolsFilesRuntime(audit:audit,held:held)) }
    private func projects(_ fake: BackendDeckCoreTestPortToolsProjectsFake,audit: BackendDeckCoreTestPortToolsAudit = .init()) throws -> [BackendDeckToolsDefinition] { try BackendDeckToolsProjects.definitions(provider:fake,runtime:BackendDeckCoreTestPortToolsFilesRuntime(audit:audit)) }
    // TSCASE files-tools.test.ts:48
    func testFilesL48AllCredentialShapesAtAnyDepth() { for (path,name) in [(".env","dotenv"),("config/.env.production","dotenv"),("deploy/key.pem","private-key-file"),(".npmrc","registry-auth")] { XCTAssertEqual(BackendDeckToolsFiles.secretShape(path)?.name,name) }; XCTAssertNotNil(BackendDeckToolsFiles.secretShape("/Users/me/.ssh/id_ed25519")) }
    // TSCASE files-tools.test.ts:56
    func testFilesL56TemplatesReadable() { for path in [".env.example","src/.env.d.ts","src/environment.ts"] { XCTAssertNil(BackendDeckToolsFiles.secretShape(path),path) } }
    // TSCASE files-tools.test.ts:62
    func testFilesL62CredentialRefusedBeforeProviderAndConsent() async throws { let fake = BackendDeckCoreTestPortToolsFilesFake(),audit = BackendDeckCoreTestPortToolsAudit(); F.error(try await F.call(files(fake,audit:audit),"files.read",#"{"cwd":"/work/api","path":"server/.env"}"#),contains:"credential file"); let calls = await fake.trace(),consent = await audit.consent(); XCTAssertTrue(calls.isEmpty); XCTAssertTrue(consent.isEmpty) }
    // TSCASE files-tools.test.ts:70
    func testFilesL70ExactLinePageAndMore() async throws { let fake = BackendDeckCoreTestPortToolsFilesFake(),value = try F.value(await F.call(files(fake),"files.read",#"{"cwd":"/work/api","path":"src/app.ts","fromLine":4,"lines":3}"#)); XCTAssertEqual(value["fromLine"],.number(4)); XCTAssertEqual(value["toLine"],.number(6)); XCTAssertEqual(value["more"],.bool(true)); XCTAssertEqual(value["text"],.string("line 4\nline 5\nline 6")) }
    // TSCASE files-tools.test.ts:77
    func testFilesL77RelativeAndKnownFolderBoundaries() async throws { let defs = try files(.init()); for (args,why) in [(#"{"cwd":"/work/api","path":"../web/x.ts"}"#,"inside the project"),(#"{"cwd":"/work/api","path":"/etc/passwd"}"#,"relative"),(#"{"cwd":"/etc","path":"passwd"}"#,"not a folder this app has open")] { F.error(try await F.call(defs,"files.read",args),contains:why) } }
    // TSCASE files-tools.test.ts:85
    func testFilesL85ListProjectsAwayStatsUnlessAsked() async throws { let value = try F.value(await F.call(files(.init()),"files.list",#"{"cwd":"/work/api"}"#)); XCTAssertEqual(value["entries"].elements?.first?["bytes"],.missing) }
    // TSCASE files-tools.test.ts:92
    func testFilesL92EveryWordFilenameRankAndRefreshForwarded() async throws { XCTAssertEqual(BackendDeckToolsFiles.rankMatches(["src/login/form.ts","test/login-form.test.ts","docs/login.md"],words:["login","form"]),["test/login-form.test.ts","src/login/form.ts"]); let fake = BackendDeckCoreTestPortToolsFilesFake(); _ = try await F.call(files(fake),"files.find",#"{"cwd":"/work/api","query":"login","refresh":true}"#); let trace = await fake.trace(); XCTAssertEqual(trace,["list refresh=true"]) }
    // TSCASE files-tools.test.ts:103
    func testFilesL103RefreshIgnoreBeforeFilter() async throws { let fake = BackendDeckCoreTestPortToolsFilesFake(),value = try F.value(await F.call(files(fake),"files.ignored",#"{"action":"filter","cwd":"/work/api","paths":["dist/a.js","src/a.ts"],"refresh":true}"#)); let trace = await fake.trace(); XCTAssertEqual(trace,["invalidate /work/api"]); XCTAssertEqual(value["kept"],.array([.string("src/a.ts")])); XCTAssertEqual(value["hidden"],.array([.string("dist/a.js")])) }
    // TSCASE files-tools.test.ts:116
    func testFilesL116UploadActualBytesAndExactMention() async throws { let fake = BackendDeckCoreTestPortToolsFilesFake(),defs = try files(fake),tool = try XCTUnwrap(defs.first { $0.spec.id == "files.upload" }),value = try F.value(await tool.handler(F.caller(),F.object([("name",.string("shot.png")),("contentBase64",.string(Data("png bytes".utf8).base64EncodedString()))]))); let trace = await fake.trace(); XCTAssertEqual(trace,["stage shot.png 9"]); XCTAssertEqual(value["mention"],.string("@\"/Users/me/Downloads/Terminal Deck/shot.png\"")) }
    // TSCASE files-tools.test.ts:127
    func testFilesL127UploadTransportCapAndBadBase64BeforeStage() async throws { let fake = BackendDeckCoreTestPortToolsFilesFake(),defs = try files(fake),tool = try XCTUnwrap(defs.first { $0.spec.id == "files.upload" }); F.error(try await tool.handler(F.caller(),F.object([("name",.string("big.bin")),("contentBase64",.string(Data(repeating:0,count:BackendDeckToolsFiles.maxUploadBytes+1).base64EncodedString()))])),contains:"at most"); F.error(try await F.call(defs,"files.upload",#"{"name":"x","contentBase64":"not base64!"}"#),contains:"base64"); let trace = await fake.trace(); XCTAssertTrue(trace.isEmpty) }
    // TSCASE files-tools.test.ts:135
    func testFilesL135ExactUploadLogRedaction() async throws { let fake = BackendDeckCoreTestPortToolsFilesFake(),audit = BackendDeckCoreTestPortToolsAudit(); _ = try await F.call(files(fake,audit:audit),"files.upload",#"{"name":"a.txt","contentBase64":"aGVsbG8="}"#); let rows = await audit.consent(); XCTAssertEqual(rows[0]["args"],try F.json(#"{"name":"a.txt","contentBase64":"[8 base64 characters]"}"#)) }
    // TSCASE files-tools.test.ts:145
    func testFilesL145HeldCopiesAndOrdinaryKeepsOriginalAndDirectoryMention() async throws { let held = BackendDeckCoreTestPortToolsFilesFake(),inside = try F.value(await F.call(files(held,held:true),"sessions.attach",#"{"sessionId":"s1","paths":["/Users/me/Desktop/shot.png"]}"#)); let heldCalls = await held.trace(); XCTAssertEqual(heldCalls,["copy /Users/me/Desktop/shot.png"]); XCTAssertEqual(inside["heldInFolder"],.string("/work/api")); XCTAssertEqual(inside["attached"].elements?.first?["path"],.string("/work/api/Terminal Deck/shot.png")); XCTAssertEqual(inside["attached"].elements?.first?["mention"],.string("@\"/work/api/Terminal Deck/shot.png\"")); let plain = BackendDeckCoreTestPortToolsFilesFake(),loose = try F.value(await F.call(files(plain),"sessions.attach",#"{"sessionId":"s1","paths":["/Users/me/Desktop/shot.png","/Users/me/folder"]}"#)); let plainCalls = await plain.trace(); XCTAssertTrue(plainCalls.isEmpty); XCTAssertEqual(loose["heldInFolder"],.null); XCTAssertEqual(loose["attached"].elements?.map { $0["path"] },[.string("/Users/me/Desktop/shot.png"),.string("/Users/me/folder")]); XCTAssertEqual(loose["attached"].elements?.last?["mention"],.string("@\"/Users/me/folder/\"")) }
    // TSCASE files-tools.test.ts:168
    func testFilesL168CredentialAttachmentsRefusedWithoutCopy() async throws { let fake = BackendDeckCoreTestPortToolsFilesFake(),value = try F.value(await F.call(files(fake,held:true),"sessions.attach",#"{"sessionId":"s1","paths":["/Users/me/.ssh/id_rsa","/Users/me/app/.env"]}"#)); let calls = await fake.trace(); XCTAssertTrue(calls.isEmpty); XCTAssertEqual(value["attached"],.array([])); XCTAssertEqual(value["refused"].elements?.map { $0["why"] },[.string("it is a credential file (ssh-private-key)"),.string("it is a credential file (dotenv)")]) }
    // TSCASE files-tools.test.ts:183
    func testFilesL183SourceEscalationSuggestionDependsOnCopyAndOwnership() { XCTAssertEqual(BackendDeckToolsFiles.attachmentSuggestedTier(paths:[],owned:false),.read); XCTAssertEqual(BackendDeckToolsFiles.attachmentSuggestedTier(paths:["/a"],owned:true),.act); XCTAssertEqual(BackendDeckToolsFiles.attachmentSuggestedTier(paths:["/a"],owned:false),.alter) }
    // TSCASE project-tools.test.ts:57
    func testProjectsL57RawFolderFilteringPreservesOrderAndHiddenSwitch() async throws { let fake = BackendDeckCoreTestPortToolsProjectsFake(),defs = try projects(fake),plain = try F.value(await F.call(defs,"projects.browse")),hidden = try F.value(await F.call(defs,"projects.browse",#"{"showHidden":true}"#)); XCTAssertEqual(plain["path"],.string("/Users/me")); XCTAssertEqual(plain["folders"].elements?.map { $0["name"] },[.string("Projects")]); XCTAssertEqual(hidden["folders"].elements?.map { $0["name"] },[.string("Projects"),.string(".config")]) }
    // TSCASE project-tools.test.ts:68
    func testProjectsL68RelativeFolderNeverGuessed() async throws { F.error(try await F.call(projects(.init()),"projects.browse",#"{"path":"Projects"}"#),contains:"absolute") }
    // TSCASE project-tools.test.ts:75
    func testProjectsL75OpeningAndRemovingAlterTiers() throws { let defs = try projects(.init()); for id in ["projects.add","projects.remove"] { XCTAssertEqual(defs.first { $0.spec.id == id }?.spec.tier,.alter) } }
    // TSCASE project-tools.test.ts:80
    func testProjectsL80StorageAndRealChildrenProtectedBeforeConsent() async throws { let fake = BackendDeckCoreTestPortToolsProjectsFake(),audit = BackendDeckCoreTestPortToolsAudit(),defs = try projects(fake,audit:audit); for path in ["/state/copilot","/state"] { F.error(try await F.call(defs,"projects.add",F.object([("path",.string(path))]).compact),contains:"inside this app’s own storage") }; let consent = await audit.consent(); XCTAssertTrue(consent.isEmpty); XCTAssertNoThrow(try BackendDeckToolsProjects.refuseStorage("/state-two",root:"/state")) }
    // TSCASE project-tools.test.ts:89
    func testProjectsL89SavedProjectNoWindowTookItIsSaid() async throws { let fake = BackendDeckCoreTestPortToolsProjectsFake(),value = try F.value(await F.call(projects(fake),"projects.add",#"{"path":"/Users/me/Projects/app"}"#)); let calls = await fake.trace(); XCTAssertEqual(calls,["add /Users/me/Projects/app"]); XCTAssertEqual(value["inWindow"],.bool(false)); XCTAssertTrue(value["note"].string?.contains("once a session starts there") == true) }
    // TSCASE project-tools.test.ts:98
    func testProjectsL98RemoveDoesNotKillAndNamesSessionStillRunning() async throws { let fake = BackendDeckCoreTestPortToolsProjectsFake(),value = try F.value(await F.call(projects(fake),"projects.remove",#"{"path":"/work/api"}"#)); let calls = await fake.trace(); XCTAssertEqual(calls,["remove /work/api"]); XCTAssertEqual(value["stillRunning"],.array([.string("s1")])) }
    // TSCASE project-tools.test.ts:108
    func testProjectsL108InitOnlyWhenNoRepository() async throws { let fake = BackendDeckCoreTestPortToolsProjectsFake(),defs = try projects(fake),api = try F.value(await F.call(defs,"git.init",#"{"cwd":"/work/api"}"#)),web = try F.value(await F.call(defs,"git.init",#"{"cwd":"/work/web"}"#)); XCTAssertEqual(api["created"],.bool(false)); XCTAssertEqual(web["created"],.bool(true)); let calls = await fake.trace(); XCTAssertEqual(calls,["init /work/web"]) }
    // TSCASE project-tools.test.ts:117
    func testProjectsL117DevReadAndActWithFolderRefusalBeforeStart() async throws { let fake = BackendDeckCoreTestPortToolsProjectsFake(),audit = BackendDeckCoreTestPortToolsAudit(),defs = try projects(fake,audit:audit); _ = try F.value(await F.call(defs,"dev.servers",#"{"action":"list"}"#)); F.error(try await F.call(defs,"dev.servers",#"{"action":"start","cwd":"/tmp"}"#),contains:"not a folder this app has open"); _ = try F.value(await F.call(defs,"dev.servers",#"{"action":"start","cwd":"/work/api"}"#)); let calls = await fake.trace(),rows = await audit.consent(); XCTAssertEqual(calls,["dev /work/api"]); XCTAssertEqual(rows.map { $0["tier"] },[.string("read"),.string("act")]) }
    // TSCASE project-tools.test.ts:128
    func testProjectsL128OverviewReadResetAndSaveTiersAndMissingLayout() async throws { let fake = BackendDeckCoreTestPortToolsProjectsFake(),audit = BackendDeckCoreTestPortToolsAudit(),defs = try projects(fake,audit:audit); _ = try await F.call(defs,"dashboard.layout",#"{"action":"read","cwd":"/work/api"}"#); _ = try await F.call(defs,"dashboard.layout",#"{"action":"reset","cwd":"/work/api"}"#); F.error(try await F.call(defs,"dashboard.layout",#"{"action":"save","cwd":"/work/api"}"#),contains:"layout"); _ = try await F.call(defs,"dashboard.layout",#"{"action":"save","cwd":"/work/api","layout":{"widgets":[]}}"#); let calls = await fake.trace(),consent = await audit.consent(); XCTAssertEqual(calls,["clear /work/api","save /work/api"]); XCTAssertEqual(consent.map { $0["tier"] },[.string("read"),.string("alter"),.string("alter")]) }
    // TSCASE project-tools.test.ts:139
    func testProjectsL139ArtifactHistoryRelativeAndExactForwardedReply() async throws { let fake = BackendDeckCoreTestPortToolsProjectsFake(),defs = try projects(fake); F.error(try await F.call(defs,"artifacts.list",#"{"cwd":"/work/api","path":"../secrets.txt"}"#),contains:"relative"); let value = try F.value(await F.call(defs,"artifacts.list",#"{"cwd":"/work/api","path":"src/a.ts"}"#)); XCTAssertEqual(value,try F.json(#"{"cwd":"/work/api","relPath":"src/a.ts"}"#)) }
}

import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

struct BackendDeckCoreTestPortToolsMemoryEnvironment: BackendMemoryEnvironment { let input: BackendMemorySources; func sources() -> BackendMemorySources { input }; func trash(_ path: String) {} }
struct BackendDeckCoreTestPortToolsMemoryAdapter: BackendDeckToolsAppMemoryService {
    let owner: BackendMemoryService
    let claude: String,codex: String
    func storeOf(_ session: NativeRPCValue) -> String? { session["provider"].string == "claude" ? claude : session["provider"].string == "codex" ? codex : nil }
    func codexSpaceFor(_ store: String) async throws -> NativeRPCValue? { try await owner.codexSpaceFor(configDir:store)?.wire }
    func claudeSpaceFor(_ store: String,cwd: String) async throws -> NativeRPCValue? { try await owner.claudeSpaceFor(configDir:store,cwd:cwd)?.wire }
    func hootSpace() async throws -> NativeRPCValue? { try await owner.hootSpace()?.wire }
    func spacesForProject(_ folder: String) async throws -> [NativeRPCValue] { try await owner.spacesForProject(folder).map(\.wire) }
    func searchIn(_ query: String,spaces: [String],limit: Int) async throws -> [NativeRPCValue] { await owner.searchIn(query,spaceIDs:spaces,limit:limit) }
    func notes(_ space: String) async throws -> [NativeRPCValue] { try await owner.notes(space) }
    func graph(_ space: String) async throws -> NativeRPCValue { BackendMemoryParsing.graphWire(try await owner.graph(space)) }
    func read(_ space: String,path: String) async throws -> NativeRPCValue { await owner.read(space,path:.string(path)) }
}

struct BackendDeckCoreTestPortToolsMemoryRig: Sendable {
    let directory: URL
    let owner: BackendMemoryService
    let adapter: BackendDeckCoreTestPortToolsMemoryAdapter
    let sessions: [NativeRPCValue]
    static func make(sessions: [NativeRPCValue] = []) throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackendDeckCoreTestPortToolsMemory-"+UUID().uuidString).resolvingSymlinksInPath(),claude = directory.appendingPathComponent("claude"),codex = directory.appendingPathComponent("codex"),data = directory.appendingPathComponent("userData"),memory = data.appendingPathComponent("copilot/memory")
        func write(_ path: String,_ text: String) throws { let url = directory.appendingPathComponent(path); try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true); try Data(text.utf8).write(to:url) }
        try write("claude/projects/-work-alpha/memory/MEMORY.md","- [Rules](rules.md)\n")
        try write("claude/projects/-work-alpha/memory/rules.md","---\nname: rules\n---\nAlpha ships on Fridays. See [[missing]].\n")
        try write("claude/projects/-work-alpha/c.jsonl",#"{"type":"user","cwd":"/work/alpha"}"#+"\n")
        try write("claude/projects/-work-beta/c.jsonl",#"{"type":"user","cwd":"/work/beta"}"#+"\n")
        try FileManager.default.createSymbolicLink(atPath:claude.appendingPathComponent("projects/-work-beta/memory").path,withDestinationPath:claude.appendingPathComponent("projects/-work-alpha/memory").path)
        try write("claude/projects/-work-gamma/memory/secret.md","Gamma keeps the launch code word: zebra.\n")
        try write("claude/projects/-work-gamma/c.jsonl",#"{"type":"user","cwd":"/work/gamma"}"#+"\n")
        try write("codex/memories/memory_summary.md","Codex remembers Fridays too.\n")
        try write("userData/copilot/memory/pref.md","Hoot plans on Fridays.\n")
        try write("userData/knowledge/k/project.json",#"{"project":"/work/alpha"}"#)
        try write("userData/knowledge/k/k1.md","---\nkind: decision\n---\nAlpha decided Fridays.\n")
        let input = BackendMemorySources(stores:[.init(provider:"claude",configDir:claude.path,name:"Own"),.init(provider:"codex",configDir:codex.path,name:"Codex")],hootMemory:memory.path,userData:data.path),owner = BackendMemoryService(environment:BackendDeckCoreTestPortToolsMemoryEnvironment(input:input),watch:false)
        return Self(directory:directory,owner:owner,adapter:.init(owner:owner,claude:claude.path,codex:codex.path),sessions:sessions)
    }
    static func session(_ id: String,cwd: String,provider: String = "claude") -> NativeRPCValue { BackendDeckCoreTestPortToolsFixture.object([("id",.string(id)),("cwd",.string(cwd)),("provider",.string(provider))]) }
    func definitions(_ identity: BackendDeckToolsAppCaller = .init(kind:.local)) throws -> [BackendDeckToolsDefinition] {
        let base = BackendDeckCoreTestPortToolsFixture.access(.init(),identity:identity),rows = sessions
        let access = BackendDeckToolsAppAccess(caller:base.caller,knownFolder:{ _,path in guard path == "/work/alpha" else { throw BackendDeckToolsAppKit.refused("\(path) is not a folder this app has open.") }; return path },session:{ _,id in guard let value = rows.first(where:{ $0["id"].string == id }) else { throw BackendDeckToolsAppKit.refused("this app is not holding that session") }; return value },runnableProject:base.runnableProject,rpc:base.rpc,authorize:base.authorize,record:base.record)
        return try BackendDeckToolsAppMemory.definitions(service:adapter,access:access)
    }
    func close() async { await owner.close(); try? FileManager.default.removeItem(at:directory) }
}

@MainActor
final class BackendDeckCoreTestPortToolsMemoryTests: XCTestCase {
    private typealias F = BackendDeckCoreTestPortToolsFixture
    private typealias Rig = BackendDeckCoreTestPortToolsMemoryRig
    // TSCASE memory-tools.test.ts:97
    func testMemoryL97SessionOwnFolderOnly() async throws { let rig = try Rig.make(sessions:[Rig.session("a",cwd:"/work/alpha")]); let value = try F.value(await F.call(rig.definitions(.init(kind:.session,sessionID:"a")),"memory.search",#"{"query":"fridays"}"#)); XCTAssertEqual(value["results"].elements?.map { $0["path"] },[.string("rules.md")]); XCTAssertEqual(value["spaces"].elements?.map { $0["label"] },[.string("alpha")]); await rig.close() }
    // TSCASE memory-tools.test.ts:104
    func testMemoryL104CannotSearchOrReadForeignMemory() async throws { let rig = try Rig.make(sessions:[Rig.session("a",cwd:"/work/alpha")]),defs = try rig.definitions(.init(kind:.session,sessionID:"a")); let value = try F.value(await F.call(defs,"memory.search",#"{"query":"zebra"}"#)); XCTAssertEqual(value["results"],.array([])); let escape = try await F.call(defs,"memory.read",#"{"path":"../-work-gamma/memory/secret.md"}"#); XCTAssertTrue(escape.isError); F.error(try await F.call(defs,"memory.read",#"{"path":"secret.md"}"#),contains:"no longer there"); await rig.close() }
    // TSCASE memory-tools.test.ts:112
    func testMemoryL112SessionCannotWidenScopeByProject() async throws { let rig = try Rig.make(sessions:[Rig.session("a",cwd:"/work/alpha")]); F.error(try await F.call(rig.definitions(.init(kind:.session,sessionID:"a")),"memory.search",#"{"query":"zebra","project":"/work/gamma"}"#),contains:"cannot name another project"); await rig.close() }
    // TSCASE memory-tools.test.ts:117
    func testMemoryL117ExistingSymlinkSharedScopeIsSaid() async throws { let rig = try Rig.make(sessions:[Rig.session("b",cwd:"/work/beta")]),value = try F.value(await F.call(rig.definitions(.init(kind:.session,sessionID:"b")),"memory.search",#"{"query":"fridays"}"#)); XCTAssertEqual(value["results"].elements?.map { $0["path"] },[.string("rules.md")]); XCTAssertEqual(value["spaces"].elements?.first?["sharedWith"],.array([.string("/work/beta")])); XCTAssertTrue(value["scope"].string?.contains("shared") == true); await rig.close() }
    // TSCASE memory-tools.test.ts:125
    func testMemoryL125ExactLinksDanglingAndBacklinks() async throws { let rig = try Rig.make(sessions:[Rig.session("a",cwd:"/work/alpha")]),value = try F.value(await F.call(rig.definitions(.init(kind:.session,sessionID:"a")),"memory.read",#"{"path":"rules.md"}"#)); XCTAssertEqual(value["path"],.string("rules.md")); XCTAssertEqual(value["title"],.string("rules")); XCTAssertEqual(value["linksTo"],.array([])); XCTAssertEqual(value["linksToNothing"],.array([.string("missing")])); XCTAssertEqual(value["linkedFrom"],.array([.string("MEMORY.md")])); await rig.close() }
    // TSCASE memory-tools.test.ts:131
    func testMemoryL131OmittedPathListsOneMemoryAndBothNotes() async throws { let rig = try Rig.make(sessions:[Rig.session("a",cwd:"/work/alpha")]),value = try F.value(await F.call(rig.definitions(.init(kind:.session,sessionID:"a")),"memory.read")); XCTAssertEqual(value["memories"].elements?.count,1); XCTAssertEqual(value["memories"].elements?.first?["notes"].elements?.compactMap { $0["path"].string }.sorted(),["MEMORY.md","rules.md"]); await rig.close() }
    // TSCASE memory-tools.test.ts:138
    func testMemoryL138CodexMemoryIsNotClaudeMemory() async throws { let rig = try Rig.make(sessions:[Rig.session("x",cwd:"/work/alpha",provider:"codex")]),value = try F.value(await F.call(rig.definitions(.init(kind:.session,sessionID:"x")),"memory.search",#"{"query":"fridays"}"#)); XCTAssertEqual(value["results"].elements?.map { $0["path"] },[.string("memory_summary.md")]); await rig.close() }
    // TSCASE memory-tools.test.ts:144
    func testMemoryL144MissingMemoryIsEmptyWithReason() async throws { let rig = try Rig.make(sessions:[Rig.session("n",cwd:"/work/new")]),value = try F.value(await F.call(rig.definitions(.init(kind:.session,sessionID:"n")),"memory.search",#"{"query":"fridays"}"#)); XCTAssertEqual(value["results"],.array([])); XCTAssertTrue(value["scope"].string?.contains("No memory has been kept") == true); await rig.close() }
    // TSCASE memory-tools.test.ts:151
    func testMemoryL151RemoteAndGhostSessionsRefused() async throws { let rig = try Rig.make(sessions:[Rig.session("a",cwd:"/work/alpha")]); for identity in [BackendDeckToolsAppCaller(kind:.session,sessionID:"a",machineID:"machine-2"),.init(kind:.session,sessionID:"ghost")] { let reply = try await F.call(rig.definitions(identity),"memory.search",#"{"query":"fridays"}"#); XCTAssertTrue(reply.isError); XCTAssertEqual(reply.structuredContent?["refusal"],.string("not-permitted")) }; await rig.close() }
    // TSCASE memory-tools.test.ts:159
    func testMemoryL159HootReadsOnlyOwnWithoutProject() async throws { let rig = try Rig.make(),value = try F.value(await F.call(rig.definitions(),"memory.search",#"{"query":"fridays"}"#)); XCTAssertEqual(value["results"].elements?.map { $0["path"] },[.string("pref.md")]); await rig.close() }
    // TSCASE memory-tools.test.ts:165
    func testMemoryL165ProjectAddsMemoryAndKnowledgeButNoNeighbor() async throws { let rig = try Rig.make(),value = try F.value(await F.call(rig.definitions(),"memory.search",#"{"query":"fridays","project":"/work/alpha"}"#)); XCTAssertEqual(Set(value["results"].elements?.compactMap { $0["path"].string } ?? []),["pref.md","rules.md","k1.md"]); XCTAssertFalse(value["results"].elements?.contains { $0["path"].string == "secret.md" } == true); await rig.close() }
    // TSCASE memory-tools.test.ts:172
    func testMemoryL172UnknownProjectRefused() async throws { let rig = try Rig.make(); F.error(try await F.call(rig.definitions(),"memory.search",#"{"query":"zebra","project":"/work/gamma"}"#),contains:"not a folder this app has open"); await rig.close() }
    // TSCASE memory-tools.test.ts:177
    func testMemoryL177MultipleMemoriesRequireSpaceForPath() async throws { let rig = try Rig.make(); F.error(try await F.call(rig.definitions(),"memory.read",#"{"path":"rules.md","project":"/work/alpha"}"#),contains:"pass space"); await rig.close() }
    // TSCASE memory-tools.test.ts:184
    func testMemoryL184KeyAndPairedDeviceRefused() async throws { let rig = try Rig.make(); for identity in [BackendDeckToolsAppCaller(kind:.key),.init(kind:.remote)] { let result = try await F.call(rig.definitions(identity),"memory.search",#"{"query":"fridays"}"#); XCTAssertTrue(result.isError); XCTAssertEqual(result.structuredContent?["refusal"],.string("not-permitted")) }; await rig.close() }
    // TSCASE memory-tools.test.ts:194
    func testMemoryL194LocalSessionReadOnlyAudienceAndPositiveGrants() throws { let defs = try BackendDeckToolsAppMemory.definitions(service:nil,access:F.access(.init())); for tool in defs { XCTAssertEqual(tool.spec.tier,.read); XCTAssertEqual(tool.audience,"copilot"); XCTAssertTrue(BackendDeckToolsSessionsGrants.ordinary.contains(tool.spec.id)); XCTAssertTrue(BackendDeckToolsSessionsGrants.ordinary.contains(tool.spec.wireName)); XCTAssertFalse(BackendDeckToolsSessionsGrants.elsewhere.contains(tool.spec.id)); XCTAssertFalse(BackendDeckToolsSessionsGrants.elsewhere.contains(tool.spec.wireName)) } }
}

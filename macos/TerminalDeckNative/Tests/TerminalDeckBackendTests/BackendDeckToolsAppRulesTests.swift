import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckToolsAppRulesTests: XCTestCase {
    private typealias K = BackendDeckToolsAppKit
    func testProtectedNamespacesSurviveReset() {
        for key in ["remote.enabled", "copilot.home", "deckControl.futureGrant", "security.future", "confine.future", "browser.persistSession", "advanced.debugMode"] {
            XCTAssertTrue(BackendDeckToolsAppApplication.isProtected(key), key)
        }
        XCTAssertFalse(BackendDeckToolsAppApplication.isProtected("appearance.density"))
        XCTAssertFalse(BackendDeckToolsAppApplication.isProtected("editor.font"))
    }
    func testTierEscalationCannotReadThroughWrites() throws {
        XCTAssertEqual(try BackendDeckToolsAppAdmin.effectiveTier("hoot.run", K.object([("action", .string("stop"))])), .alter)
        XCTAssertEqual(try BackendDeckToolsAppAdmin.effectiveTier("hoot.instructions", K.object([("action", .string("write"))])), .alter)
        XCTAssertEqual(try BackendDeckToolsAppAdmin.effectiveTier("hoot.memory", K.object([("action", .string("write"))])), .act)
        XCTAssertEqual(try BackendDeckToolsAppAdmin.effectiveTier("hoot.memory", K.object([("action", .string("delete"))])), .alter)
        XCTAssertEqual(try BackendDeckToolsAppAdmin.effectiveTier("notifications.status", K.object([("openSettings", .bool(true))])), .act)
        XCTAssertEqual(BackendDeckToolsAppUI.effectiveTier(K.object([("action", .string("run")), ("target", .string("features.install.split"))])), .alter)
    }
    func testGeneratedInstructionsCannotBeWritten() {
        XCTAssertThrowsError(try BackendDeckToolsAppAdmin.instructionsCall(K.object([("action", .string("write")), ("which", .string("contract")), ("text", .string("anything"))]))) { error in
            XCTAssertEqual((error as? NativeRPCError)?.message, "only \"yours\" and \"folder\" can be written; the contract is generated from what is wired")
        }
    }
    func testPrivateInputsAreReducedBeforeLogging() {
        XCTAssertEqual(K.redacted("voice.save_key", K.object([("key", .string("secret"))]))["key"], .string("[redacted]"))
        XCTAssertEqual(K.redacted("voice.transcribe", K.object([("audio", .string("QUJD"))]))["audio"], .string("[4 base64 characters]"))
        let input = K.object([("values", K.object([("API_KEY", .string("🦉x")), ("odd", .number(3))]))])
        XCTAssertEqual(K.redacted("store.community", input)["values"]["API_KEY"], .string("[3 characters]"))
        XCTAssertFalse(K.redacted("store.community", input).compact.contains("🦉"))
    }
    func testAudioRefusesBeforeUploadAndAcceptsBufferAlphabet() throws {
        XCTAssertEqual(try BackendDeckToolsAppVoice.decode("UklGRg=="), Data("RIFF".utf8))
        XCTAssertEqual(try BackendDeckToolsAppVoice.decode("  UklG Rg\n"), Data("RIFF".utf8))
        XCTAssertEqual(try BackendDeckToolsAppVoice.decode("_-4="), Data([255, 238]))
        XCTAssertThrowsError(try BackendDeckToolsAppVoice.decode("not base64!"))
        XCTAssertThrowsError(try BackendDeckToolsAppVoice.decode("A"))
        let big = String(repeating: "A", count: (BackendDeckToolsAppVoice.maxAudioBytes * 4 / 3) + 8)
        XCTAssertThrowsError(try BackendDeckToolsAppVoice.decode(big))
    }
    func testUIRefusesDialogsAndKeepsTargetsAsData() throws {
        XCTAssertThrowsError(try BackendDeckToolsAppUI.refuseDialogs(K.object([("action", .string("run")), ("target", .string("session.close"))]))) { error in XCTAssertTrue(error.localizedDescription.contains("Use sessions.stop instead.")) }
        let code = BackendDeckToolsAppUI.doCall(kind: "run", target: "x\"}); globalThis.pwned=true; ({\"a\":\"\u{2028}")
        XCTAssertTrue(code.contains("\\u2028"))
        XCTAssertTrue(code.contains("\\\""))
        XCTAssertTrue(code.hasPrefix("globalThis.__terminaldeckUi?.do({"))
    }
    func testWebLinksRejectNonWebSchemes() throws {
        XCTAssertThrowsError(try BackendDeckToolsAppAdmin.webAddress(K.object([("url", .string("file:///etc/passwd"))])))
        XCTAssertThrowsError(try BackendDeckToolsAppAdmin.webAddress(K.object([("url", .string("javascript:alert(1)"))])))
        XCTAssertEqual(try BackendDeckToolsAppAdmin.webAddress(K.object([("url", .string("HTTPS://EXAMPLE.COM:443/a"))])), "https://example.com/a")
    }
    func testReadDoesNotReturnPendingGitHubDeviceCode() {
        let state = K.object([("connected", .bool(false)), ("pending", K.object([("userCode", .string("WXYZ-1234")), ("verificationUri", .string("https://github.com/login/device"))]))])
        XCTAssertFalse(BackendDeckToolsAppGitHub.withoutCode(state).compact.contains("WXYZ-1234"))
        XCTAssertEqual(BackendDeckToolsAppGitHub.withoutCode(state)["pending"]["verificationUri"], .string("https://github.com/login/device"))
    }
    func testRoutinePatchPreservesPromptsAndRejectsPathIDs() throws {
        let prompt = "  Say hi.\n", patch = try BackendDeckToolsAppRoutines.patch(K.object([("when", .string("manual")), ("folder", .string(" /work/api ")), ("prompt", .string(prompt))]))
        XCTAssertEqual(patch["when"], .array([.string("manual")]))
        XCTAssertEqual(patch["in"], .string("/work/api"))
        XCTAssertEqual(patch["prompt"], .string(prompt))
        XCTAssertEqual(patch["quietFor"], .missing)
        for bad in ["../other", "con", "com1", "lpt9", "Bad", "trailing-", "", String(repeating: "x", count: 65)] { XCTAssertFalse(BackendDeckToolsAppRoutines.validID(bad), bad) }
        XCTAssertTrue(BackendDeckToolsAppRoutines.validID("nightly-sweep"))
    }
    func testRecipeCountShapeAndThreeValuedCompleteness() {
        let result = K.object([("rowsOnPage", .number(40)), ("rowsReturned", .number(20)), ("counts", K.object([("images", K.object([("matched", .number(240)), ("returned", .number(200))])), ("alts", K.object([("matched", .number(12)), ("returned", .number(12))]))]))])
        XCTAssertEqual(BackendDeckToolsAppExtraction.collected(hasRows: true, result: result).returned, 20)
        XCTAssertEqual(BackendDeckToolsAppExtraction.collected(hasRows: false, result: result).onPage, 240)
        XCTAssertEqual(BackendDeckToolsAppExtraction.collected(hasRows: false, result: result).returned, 200)
        XCTAssertNil(BackendDeckToolsAppExtraction.complete(1, returned: 20))
        XCTAssertNil(BackendDeckToolsAppExtraction.complete(nil, returned: 20))
        XCTAssertEqual(BackendDeckToolsAppExtraction.complete(1248, returned: 200), false)
        XCTAssertTrue(BackendDeckToolsAppExtraction.completenessNote(stated: 1, onPage: 20, returned: 20).contains("not believed"))
        XCTAssertTrue(BackendDeckToolsAppExtraction.completenessNote(stated: 1248, onPage: 500, returned: 200).contains("The limit on this call is part of it."))
    }
    func testRecipeHostsUseRealHostBoundary() {
        XCTAssertTrue(BackendDeckToolsAppExtraction.allows(["*.example.com"], url: "https://example.com/a"))
        XCTAssertTrue(BackendDeckToolsAppExtraction.allows(["*.example.com"], url: "https://sub.example.com/a"))
        XCTAssertFalse(BackendDeckToolsAppExtraction.allows(["*.example.com"], url: "https://example.com.evil/a"))
        XCTAssertFalse(BackendDeckToolsAppExtraction.allows(["example.com"], url: "file:///example.com"))
        XCTAssertTrue(BackendDeckToolsAppExtraction.allows(["*"], url: "about:blank"))
    }
    func testFixedModelResultCountsPicturesWithoutExposingBytes() {
        let result = K.object([("verdict", .string("differences")), ("differences", .array([K.object([("id", .string("f1")), ("needsPerson", .bool(true)), ("needsPersonWhy", .string("It touches money.")), ("changes", .array([])), ("more", .number(1))])])), ("pictures", K.object([("f1", .array([K.object([("before", .string("data:image/png;base64,AAAA"))])]))])), ("detail", .string("Full report"))])
        let shown = BackendDeckToolsAppFixed.resultsForModel(result)
        XCTAssertEqual(shown["differences"].elements?.first?["picturesKept"], .number(1))
        XCTAssertFalse(shown.compact.contains("base64"))
        XCTAssertEqual(shown["engineSummary"], .missing)
        XCTAssertEqual(BackendDeckToolsAppFixed.resultsForModel(result, full: true)["engineSummary"], .string("Full report"))
        XCTAssertEqual(BackendDeckToolsAppFixed.resultsForModel(nil)["ran"], .bool(false))
    }
    func testSessionCannotReachSettingsStoresOrOwnerOnlyGitHub() {
        let session = BackendDeckToolsAppCaller(kind: .session, sessionID: "s1")
        XCTAssertThrowsError(try K.noSession(session, "store.community"))
        XCTAssertThrowsError(try K.hereOnly(session, "Reading GitHub"))
        XCTAssertNoThrow(try K.hereOnly(.init(kind: .key, keyName: "ChatGPT"), "Reading GitHub"))
    }
    func testCatalogueKeepsSourceWireNamesSchemasAliasesAndTiers() throws {
        let entries = try BackendDeckToolsAppMetadata.entries()
        XCTAssertEqual(entries.count, 55)
        XCTAssertEqual(Set(entries.map { $0.spec.id }).count, 55)
        XCTAssertEqual(entries.first { $0.spec.id == "usage.cost" }?.spec.inputSchema["properties"]["limit"]["type"], .string("number"))
        XCTAssertEqual(entries.first { $0.spec.id == "browser.store" }?.spec.inputSchema["properties"]["tool"]["type"], .string("string"))
        XCTAssertEqual(entries.first { $0.spec.id == "hoot.state" }?.aliases, ["copilot.state", "copilot_state"])
        XCTAssertEqual(entries.first { $0.spec.id == "hooks.sync" }?.spec.tier, .alter)
        XCTAssertEqual(entries.first { $0.spec.id == "hooks.decline_offer" }?.spec.tier, .act)
        XCTAssertEqual(entries.first { $0.spec.id == "fixed.mark_good" }?.spec.tier, .alter)
        XCTAssertTrue(entries.allSatisfy { $0.spec.inputSchema["additionalProperties"] == .bool(false) })
    }
}

private actor BackendDeckToolsAppTestAudit {
    var consent: [(String, BackendMCPTier, Bool, NativeRPCValue)] = []
    var results: [NativeRPCValue] = []
    func authorize(_ id: String, tier: BackendMCPTier, owner: Bool, args: NativeRPCValue) { consent.append((id, tier, owner, args)) }
    func record(_ result: NativeRPCValue) { results.append(result) }
    func owners() -> [Bool] { consent.map(\.2) }
}
private actor BackendDeckToolsAppTestSetup: BackendDeckToolsAppSetupService {
    nonisolated let fixIDs: Set<String> = ["create-gitignore", "create-readme"]
    private var applied = 0
    private let offered: Bool
    init(offered: Bool) { self.offered = offered }
    func setup(_ caller: BackendMCPCallContext) async throws -> NativeRPCValue { throw BackendDeckToolsAppKit.unavailable("test setup") }
    func scan(_ path: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue {
        let fix: NativeRPCValue = offered ? .object([.init("id", .string("create-gitignore")), .init("description", .string("Writes .gitignore for this stack."))]) : .null
        return .object([.init("checks", .array([.object([.init("id", .string("gitignore")), .init("fix", fix)])]))])
    }
    func fix(_ path: String, id: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue {
        applied += 1
        return .object([.init("ok", .bool(true)), .init("message", .string("Wrote .gitignore.")), .init("changed", .array([.string(".gitignore")]))])
    }
    func applyCount() -> Int { applied }
}
private struct BackendDeckToolsAppTestFixed: BackendDeckToolsAppFixedService {
    private func absent() -> NativeRPCError { BackendDeckToolsAppKit.unavailable("unused test fixed operation") }
    func status(_ project: String) async throws -> NativeRPCValue { throw absent() }
    func readiness(_ project: String, refresh: Bool) async throws -> NativeRPCValue { throw absent() }
    func setup(_ project: String) async throws -> NativeRPCValue { throw absent() }
    func check(_ project: String, by: String) async throws -> NativeRPCValue { throw absent() }
    func progress(_ project: String) async throws -> NativeRPCValue? { throw absent() }
    func stop(_ project: String) async throws -> Bool { throw absent() }
    func waitFor(_ project: String, milliseconds: Int) async throws -> NativeRPCValue? { throw absent() }
    func results(_ project: String, full: Bool) async throws -> NativeRPCValue? { throw absent() }
    func markGood(_ project: String, anyway: Bool) async throws -> NativeRPCValue { .object([.init("marked", .bool(true)), .init("refusedFor", .null)]) }
    func setAgents(_ project: String, on: Bool) async throws -> NativeRPCValue { throw absent() }
}
extension BackendDeckToolsAppRulesTests {
    private func fixtureAccess(_ audit: BackendDeckToolsAppTestAudit) -> BackendDeckToolsAppAccess {
        .init(caller: { _ in .init(kind: .local) }, knownFolder: { _, path in
            guard path == "/work/api" else { throw BackendDeckToolsAppKit.refused("\(path) is not a folder this app has open. Use projects.list to see the folders you can ask about.") }; return path
        }, session: { _, _ in throw BackendDeckToolsAppKit.unavailable("unused test session") }, runnableProject: { _, path in path }, rpc: { _ in .init(caller: .internalEngine, ownerID: "test") }, authorize: { _, id, args, tier, _, owner in await audit.authorize(id, tier: tier, owner: owner, args: args) }, record: { _, _, _, result in await audit.record(result) }, now: { 1_000_000 })
    }
    private func fixtureCaller() -> BackendMCPCallContext { .init(sessionID: "test", machineID: "", projectRoot: nil, attended: true, allowedTools: [], allowedTiers: [.read, .act, .alter], cancellation: .init()) }
    func testReadinessRefusesAnUnofferedFixWithoutWriting() async throws {
        let audit = BackendDeckToolsAppTestAudit(), service = BackendDeckToolsAppTestSetup(offered: false)
        let definitions = try BackendDeckToolsAppSetup.definitions(service: service, access: fixtureAccess(audit))
        let tool = try XCTUnwrap(definitions.first { $0.spec.id == "readiness.fix" })
        let reply = try await tool.handler(fixtureCaller(), K.object([("projectPath", .string("/work/api")), ("fixId", .string("create-readme"))]))
        XCTAssertTrue(reply.isError)
        XCTAssertTrue(reply.content.first?["text"].string?.contains("is not offering create-readme right now") == true)
        let calls = await service.applyCount(); XCTAssertEqual(calls, 0)
    }
    func testReadinessReturnsTheFixItActuallyOffered() async throws {
        let audit = BackendDeckToolsAppTestAudit(), service = BackendDeckToolsAppTestSetup(offered: true)
        let definitions = try BackendDeckToolsAppSetup.definitions(service: service, access: fixtureAccess(audit))
        let tool = try XCTUnwrap(definitions.first { $0.spec.id == "readiness.fix" })
        let reply = try await tool.handler(fixtureCaller(), K.object([("projectPath", .string("/work/api")), ("fixId", .string("create-gitignore"))]))
        XCTAssertFalse(reply.isError)
        XCTAssertEqual(reply.structuredContent?["applied"]["description"], .string("Writes .gitignore for this stack."))
        let calls = await service.applyCount(); XCTAssertEqual(calls, 1)
    }
    func testMarkGoodAlwaysDemandsOwnerConsent() async throws {
        let audit = BackendDeckToolsAppTestAudit(), definitions = try BackendDeckToolsAppFixed.definitions(service: BackendDeckToolsAppTestFixed(), access: fixtureAccess(audit))
        let tool = try XCTUnwrap(definitions.first { $0.spec.id == "fixed.mark_good" })
        let reply = try await tool.handler(fixtureCaller(), K.object([("project", .string("/work/api")), ("anyway", .bool(true))]))
        XCTAssertFalse(reply.isError)
        let owners = await audit.owners(); XCTAssertEqual(owners, [true])
    }
}

private struct BackendDeckToolsAppTestMemory: BackendDeckToolsAppMemoryService {
    private func absent() -> NativeRPCError { BackendDeckToolsAppKit.unavailable("memory operation should not be reached by this caller") }
    func storeOf(_ session: NativeRPCValue) async throws -> String? { throw absent() }
    func codexSpaceFor(_ store: String) async throws -> NativeRPCValue? { throw absent() }
    func claudeSpaceFor(_ store: String, cwd: String) async throws -> NativeRPCValue? { throw absent() }
    func hootSpace() async throws -> NativeRPCValue? { throw absent() }
    func spacesForProject(_ folder: String) async throws -> [NativeRPCValue] { throw absent() }
    func searchIn(_ query: String, spaces: [String], limit: Int) async throws -> [NativeRPCValue] { throw absent() }
    func notes(_ space: String) async throws -> [NativeRPCValue] { throw absent() }
    func graph(_ space: String) async throws -> NativeRPCValue { throw absent() }
    func read(_ space: String, path: String) async throws -> NativeRPCValue { throw absent() }
}
extension BackendDeckToolsAppRulesTests {
    func testMemoryRefusesForeignCallersBeforeAnyMemoryIsRead() async throws {
        let base = fixtureAccess(BackendDeckToolsAppTestAudit())
        for caller in [BackendDeckToolsAppCaller(kind: .key), .init(kind: .remote), .init(kind: .session, sessionID: "s1", machineID: "machine-2")] {
            let access = BackendDeckToolsAppAccess(caller: { _ in caller }, knownFolder: base.knownFolder, session: base.session, runnableProject: base.runnableProject, rpc: base.rpc, authorize: base.authorize, record: base.record)
            do { _ = try await BackendDeckToolsAppMemory.scope(service: BackendDeckToolsAppTestMemory(), access: access, context: fixtureCaller(), project: nil); XCTFail("Foreign memory must be refused") }
            catch let error as NativeRPCError { XCTAssertEqual(error.code, "not-permitted"); XCTAssertFalse(error.message.contains("should not be reached")) }
        }
    }
    func testSessionCannotWidenMemoryByNamingAnotherProject() async throws {
        let base = fixtureAccess(BackendDeckToolsAppTestAudit()), access = BackendDeckToolsAppAccess(caller: { _ in .init(kind: .session, sessionID: "s1", machineID: "") }, knownFolder: base.knownFolder, session: base.session, runnableProject: base.runnableProject, rpc: base.rpc, authorize: base.authorize, record: base.record)
        do { _ = try await BackendDeckToolsAppMemory.scope(service: BackendDeckToolsAppTestMemory(), access: access, context: fixtureCaller(), project: "/work/next-door"); XCTFail("A session cannot choose another project's memory") }
        catch let error as NativeRPCError { XCTAssertEqual(error.message, "A session reads its own memory only; it cannot name another project.") }
    }
}

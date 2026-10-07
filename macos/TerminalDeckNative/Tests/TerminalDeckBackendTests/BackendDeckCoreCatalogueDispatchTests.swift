import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckCoreCatalogueDispatchTests: XCTestCase {
    private typealias Builtins = BackendDeckCoreCatalogueBuiltins
    private typealias Rules = BackendDeckCoreCatalogueRules
    private func context(caller: BackendDeckCoreSecurityCaller = .local, started: Set<String> = []) -> BackendDeckCoreSecurityCallContext {
        let native = BackendMCPCallContext(sessionID: "copilot", machineID: "", projectRoot: nil, attended: true,
            allowedTools: [], allowedTiers: [.read, .act, .alter], cancellation: BackendMCPCancellation())
        return .init(native: native, caller: caller, callID: "row-1", attended: true, granted: nil, sessionLimits: .missing,
            now: { 1_000_000 }, startedByCopilot: { started.contains($0) }, noteStarted: { _ in })
    }
    func testMissingDependenciesFailInsteadOfReturningEmptySuccess() async throws {
        let surface = BackendDeckCoreCatalogueDispatchTestSurface()
        do {
            _ = try await Builtins.run(id: "git.status", arguments: .object([.init("cwd", .string("/work"))]), context: context(), surface: surface)
            XCTFail("Missing Git adapter must fail")
        } catch { XCTAssertTrue(error.localizedDescription.lowercased().contains("git status")) }
    }
    func testViewReportsUnknownExitTimeAndDoesNotCallAppOwnedSessionCopilot() {
        let surface = BackendDeckCoreCatalogueDispatchTestSurface()
        let exited = Rules.object([("id", .string("s1")), ("cwd", .string("/work")), ("provider", .string("claude")),
            ("createdAt", .number(100)), ("exitCode", .number(2)), ("origin", .string("app")), ("originApp", .string("ChatGPT"))])
        let view = Builtins.viewOf(surface: surface, context: context(started: ["s1"]), metadata: exited)
        XCTAssertEqual(view["status"], .string("exited"))
        XCTAssertEqual(view["attentionForMs"], .null)
        XCTAssertEqual(view["attentionReason"], .string("process-failed"))
        XCTAssertEqual(view["startedByCopilot"], .bool(false))
        XCTAssertEqual(view["startedByApp"], .string("ChatGPT"))
    }
    func testRemoteFolderGrantAbsenceAndInvalidRemoteIdentityNeverFallBackToOwner() {
        let surface = BackendDeckCoreCatalogueDispatchTestSurface()
        let remote = BackendDeckCoreSecurityCaller(kind: .remote, tiers: [.read, .act], deviceID: "phone")
        XCTAssertThrowsError(try Builtins.requireStartableFolder(surface: surface, caller: remote, path: "/work")) { error in
            XCTAssertTrue(error.localizedDescription.contains("not available on this machine"))
        }
        surface.grant = ["/work/"]
        XCTAssertEqual(try Builtins.requireStartableFolder(surface: surface, caller: remote, path: "/work"), "/work/")
        XCTAssertThrowsError(try Builtins.requireStartableFolder(surface: surface, caller: .init(kind: .remote, tiers: [.act]), path: "/work")) { error in
            XCTAssertTrue(error.localizedDescription.contains("no folders chosen"))
        }
    }
    func testKeyFolderLimitContainsOnlyRealChildren() throws {
        let surface = BackendDeckCoreCatalogueDispatchTestSurface()
        surface.projects = ["/work", "/work/sub", "/work-other"]
        let caller = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.act], folders: ["/work"])
        XCTAssertEqual(try Builtins.requireStartableFolder(surface: surface, caller: caller, path: "/work/sub"), "/work/sub")
        XCTAssertThrowsError(try Builtins.requireStartableFolder(surface: surface, caller: caller, path: "/work-other"))
        XCTAssertThrowsError(try Builtins.requireKnownFolder(surface, path: "/private/secret"))
    }
    func testStartRefusesAppStorageSameFolderAndFiveSessionCeiling() throws {
        let surface = BackendDeckCoreCatalogueDispatchTestSurface()
        surface.projects = ["/state/work", "/work"]
        XCTAssertThrowsError(try Builtins.checkStart(surface: surface, context: context(), arguments: .object([.init("cwd", .string("/state/work"))])))
        surface.sessions = [surface.session(id: "mine", cwd: "/work")]
        XCTAssertThrowsError(try Builtins.checkStart(surface: surface, context: context(started: ["mine"]), arguments: .object([.init("cwd", .string("/work"))])))
        surface.sessions = (0..<5).map { surface.session(id: "s\($0)", cwd: "/other\($0)") }
        XCTAssertThrowsError(try Builtins.checkStart(surface: surface, context: context(started: Set((0..<5).map { "s\($0)" })), arguments: .object([.init("cwd", .string("/work"))])))
        surface.sessions = []
        surface.workspace = ["/state/work"]
        XCTAssertNoThrow(try Builtins.checkStart(surface: surface, context: context(), arguments: .object([.init("cwd", .string("/state/work"))])))
    }
    func testStartBriefMustHaveTitleAndWriteHappensBeforeSpawn() async throws {
        let surface = BackendDeckCoreCatalogueDispatchTestSurface()
        let brief = "Work in this repo. Make the change, verify the expected behavior, and leave other files alone."
        let args = Rules.object([("cwd", .string("/work")), ("brief", .string(brief)), ("title", .string("Fix parser")), ("account", .string("work")), ("conversation", .string("chat-1"))])
        XCTAssertThrowsError(try Builtins.checkBrief(args.removing("title")))
        surface.accountRows = [Rules.object([("id", .string("login-1")), ("name", .string("Work")), ("provider", .string("codex"))])]
        let output = try await Builtins.run(id: "sessions.start", arguments: args, context: context(caller: .init(kind: .key, tiers: [.act], keyID: "k1", keyName: "ChatGPT")), surface: surface)
        XCTAssertEqual(surface.events, ["spec", "start", "deliver"])
        XCTAssertEqual(surface.lastStart["provider"], .string("codex"))
        XCTAssertEqual(surface.lastStart["profileId"], .string("login-1"))
        XCTAssertEqual(surface.lastStart["resume"], .bool(true))
        XCTAssertEqual(surface.lastStart["resumeConversationId"], .string("chat-1"))
        XCTAssertEqual(surface.lastStart["origin"], .string("app"))
        XCTAssertEqual(surface.lastStart["originApp"], .string("ChatGPT"))
        XCTAssertEqual(surface.lastStart["originRunId"], .string("row-1"))
        XCTAssertEqual(surface.lastStart["cols"], .number(120))
        XCTAssertEqual(surface.lastStart["rows"], .number(30))
        XCTAssertEqual(output.value["spec"]["delivered"], .bool(true))
    }
    func testFailedBriefWriteNeverStartsAndFailedDeliveryNamesRecovery() async throws {
        let surface = BackendDeckCoreCatalogueDispatchTestSurface()
        let args = Rules.object([("cwd", .string("/work")), ("brief", .string(String(repeating: "scope ", count: 12))), ("title", .string("Task"))])
        surface.failSpec = true
        do { _ = try await Builtins.run(id: "sessions.start", arguments: args, context: context(), surface: surface); XCTFail("Writer must fail") } catch {}
        XCTAssertFalse(surface.events.contains("start"))
        surface.failSpec = false; surface.delivered = false
        let output = try await Builtins.run(id: "sessions.start", arguments: args, context: context(), surface: surface)
        XCTAssertTrue(output.value["spec"]["nextStep"].string?.contains("The session is running but has not been told anything") == true)
        XCTAssertTrue(output.value["spec"]["nextStep"].string?.contains("sessions.send") == true)
    }
    func testAccountUnknownAmbiguityProviderMismatchAndConversationFlagAreRefused() async throws {
        let surface = BackendDeckCoreCatalogueDispatchTestSurface()
        XCTAssertThrowsError(try Builtins.chooseAccount(surface: surface, arguments: .object([.init("account", .string("unknown"))])))
        surface.accountRows = [Rules.object([("id", .string("a")), ("name", .string("Work")), ("provider", .string("claude"))]),
            Rules.object([("id", .string("b")), ("name", .string("work")), ("provider", .string("codex"))])]
        XCTAssertThrowsError(try Builtins.chooseAccount(surface: surface, arguments: .object([.init("account", .string("work"))])))
        XCTAssertThrowsError(try Builtins.chooseAccount(surface: surface, arguments: Rules.object([("account", .string("a")), ("provider", .string("codex"))])))
        do {
            _ = try await Builtins.run(id: "sessions.start", arguments: Rules.object([("cwd", .string("/work")), ("conversation", .string("--danger"))]), context: context(), surface: surface)
            XCTFail("Conversation flags must never reach process args")
        } catch { XCTAssertEqual(error.localizedDescription, "conversation must be a conversation id") }
        XCTAssertTrue(surface.events.isEmpty)
    }
    func testSessionLimitsOnlyNarrowAndRejectPathsAndMalformedToolNames() throws {
        let limits = try Builtins.limitsFrom(Rules.object([("deniedTools", Rules.strings(["Bash", "Bash", "mcp__deck__send"])), ("noSkills", .bool(true)), ("agentInstructions", .string("writer-1"))]))
        XCTAssertEqual(limits["deniedTools"], Rules.strings(["Bash", "mcp__deck__send"]))
        XCTAssertEqual(limits["noSkills"], .bool(true))
        XCTAssertThrowsError(try Builtins.limitsFrom(.object([.init("agentInstructions", .string("../../outside"))])))
        XCTAssertThrowsError(try Builtins.limitsFrom(.object([.init("deniedTools", Rules.strings(["Bash,--flag"]))])))
        XCTAssertThrowsError(try Builtins.limitsFrom(.object([.init("deniedTools", .string("Bash"))])))
    }
    func testSendIsTwoWritesAndHumanSessionEscalates() async throws {
        let surface = BackendDeckCoreCatalogueDispatchTestSurface()
        surface.sessions = [surface.session(id: "s1", cwd: "/work")]
        let tools = try Builtins.tools(surface: surface), policy = try XCTUnwrap(tools.policies.first { $0.tool.id == "sessions.send" })
        let args = Rules.object([("sessionId", .string("s1")), ("text", .string("Read @file and finish the requested task"))])
        XCTAssertEqual(try policy.escalate?(args, context()), .alter)
        XCTAssertEqual(try policy.escalate?(args, context(started: ["s1"])), .act)
        let output = try await policy.run(args, context(started: ["s1"]))
        XCTAssertEqual(surface.writes, ["Read @file and finish the requested task ", "\r"])
        XCTAssertEqual(output.value["sentAt"], .number(1_000_000))
        XCTAssertEqual(output.summary?["text"], args["text"])
    }
    func testTranscriptUsesNewestMessagesCapsAndReportsWindowBounds() async throws {
        let surface = BackendDeckCoreCatalogueDispatchTestSurface()
        surface.sessions = [surface.session(id: "s1", cwd: "/work")]
        surface.match = Rules.object([("path", .string("/transcript")), ("basis", .string("exact")), ("ambiguous", .bool(false)), ("otherSessions", .array([])), ("note", .null)])
        surface.messages = (0..<30).map { Rules.object([("role", .string("assistant")), ("text", .string(String(repeating: String($0 % 10), count: 6_000)))]) }
        let output = try await Builtins.run(id: "sessions.transcript", arguments: Rules.object([("sessionId", .string("s1")), ("limit", .number(200)), ("windowBytes", .number(9_999_999))]), context: context(), surface: surface)
        XCTAssertEqual(surface.readFrom, 8_000_000 - 4_194_304)
        XCTAssertEqual(output.value["partial"], .bool(true))
        let messages = output.value["messages"].elements ?? []
        XCTAssertEqual(messages.last?["text"].string?.first, "9")
        XCTAssertTrue(messages.allSatisfy { $0["truncated"] == .bool(true) })
        XCTAssertLessThanOrEqual(messages.reduce(0) { $0 + ($1["text"].string?.utf16.count ?? 0) }, 65_536)
        surface.match = .object([.init("path", .null)]); surface.screen = String(repeating: "x", count: 9_000)
        let terminal = try await Builtins.run(id: "sessions.transcript", arguments: .object([.init("sessionId", .string("s1"))]), context: context(), surface: surface)
        XCTAssertEqual(terminal.value["source"], .string("terminal"))
        XCTAssertEqual(terminal.value["screen"].string?.count, 8_000)
        XCTAssertEqual(terminal.value["partial"], .bool(true))
    }
    func testSettingsValidationPrecedesSnapshotAndSnapshotPrecedesWriteAndPush() async throws {
        let surface = BackendDeckCoreCatalogueDispatchTestSurface()
        let args = Rules.object([("scope", .string("settings")), ("patch", Rules.object([("appearance.terminalFontSize", .number(4_000))]))])
        try Builtins.precheck(id: "settings.write", arguments: args, context: context(), surface: surface)
        XCTAssertEqual(surface.events, ["snapshot"])
        XCTAssertTrue(try Builtins.summary(id: "settings.write", arguments: args).contains("to 24 (asked for 4000)"))
        let output = try await Builtins.run(id: "settings.write", arguments: args, context: context(), surface: surface)
        XCTAssertEqual(surface.events, ["snapshot", "snapshot", "write", "push"])
        XCTAssertTrue(output.value["appliedToWindow"].string?.contains("not-yet-in-the-open-window") == true)
        surface.events = []
        let invalid = args.setting("patch", .object([.init("appearance.density", .string("none"))]))
        XCTAssertThrowsError(try Builtins.precheck(id: "settings.write", arguments: invalid, context: context(), surface: surface))
        XCTAssertTrue(surface.events.isEmpty)
    }
}

private final class BackendDeckCoreCatalogueDispatchTestSurface: BackendDeckCoreCatalogueSurface, @unchecked Sendable {
    // Each test owns one fixture; no production or persisted data is involved.
    var projects = ["/work"], sessions: [NativeRPCValue] = [], workspace: [String] = []
    var grant: [String]?, accountRows: [NativeRPCValue]?
    var events: [String] = [], writes: [String] = [], lastStart = NativeRPCValue.missing
    var failSpec = false, delivered = true
    var match = NativeRPCValue.object([.init("path", .null)]), messages: [NativeRPCValue] = [], screen = ""
    var readFrom: Double = 0
    func session(id: String, cwd: String) -> NativeRPCValue {
        .object([.init("id", .string(id)), .init("cwd", .string(cwd)), .init("title", .string("Task")), .init("provider", .string("claude")), .init("createdAt", .number(100)), .init("exitCode", .null)])
    }
    func listSessions() -> [NativeRPCValue] { sessions }
    func listProjects() -> [NativeRPCValue] { projects.map { .object([.init("path", .string($0))]) } }
    func taskWorkspaceFolders() -> [String] { workspace }
    func sessionStatus(_ sessionID: String) -> NativeRPCValue { .null }
    func appStateRoot() -> String { "/state" }
    func copilotRoot() -> String { "/state/copilot" }
    func accounts() -> [NativeRPCValue]? { accountRows }
    func deviceFolders(_ deviceID: String) -> [String]? { grant }
    func windows(sessionID: String) -> [NativeRPCValue] { [] }
    func readSettings() -> NativeRPCValue { .object([.init("settings", .object([])), .init("preferences", .object([]))]) }
    func snapshotSettings() throws -> NativeRPCValue { events.append("snapshot"); return .object([.init("path", .string("/state/settings.last-good.json"))]) }
    func writeSettings(_ patch: NativeRPCValue) throws -> NativeRPCValue { events.append("write"); return BackendDeckCoreCatalogueSettings.check(scope: "settings", patch: patch).effective }
    func applyToWindow(scope: String, values: NativeRPCValue) -> Bool { events.append("push"); return false }
    func transcriptFor(session: NativeRPCValue) async throws -> NativeRPCValue { match }
    func transcriptBytes(path: String) async throws -> Double { 8_000_000 }
    func readTranscriptFrom(path: String, fromByte: Double) async throws -> [NativeRPCValue] { readFrom = fromByte; return messages }
    func sessionScreen(_ sessionID: String) async throws -> String? { screen }
    func startSession(input: NativeRPCValue, forDevice: String?) async throws -> NativeRPCValue {
        events.append("start"); lastStart = input
        let meta = session(id: "new", cwd: input["cwd"].string ?? "").merging(input)
        sessions.append(meta); return meta
    }
    func writeToSession(_ sessionID: String, data: String) async throws { writes.append(data) }
    func writeSpec(directory: String, input: NativeRPCValue) throws -> NativeRPCValue {
        events.append("spec")
        if failSpec { throw NativeRPCError(code: "internal", message: "disk full") }
        return .object([.init("path", .string(directory + "/task.md"))])
    }
    func deliverBrief(_ sessionID: String, line: String) async throws -> NativeRPCValue {
        events.append("deliver")
        return .object([.init("delivered", .bool(delivered)), .init("waitedMs", .number(0)), .init("reason", delivered ? .null : .string("The prompt is busy."))])
    }
}

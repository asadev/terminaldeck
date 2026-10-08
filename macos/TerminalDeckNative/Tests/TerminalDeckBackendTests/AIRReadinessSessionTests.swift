import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class AIRReadinessSessionTests: XCTestCase {
    func testReadyPromptReachesSharedObservedBriefAdapterExactlyWithOriginalScope() async throws {
        let fixture = try await AIRSessionFixture.make()
        defer { fixture.remove() }
        let prompt = "Review the actual project.\n\n1. Fix only its test command.\n2. Re-check.\n" + String(repeating: "Useful detail. ", count: 320)
        let response = try await fixture.service.startAI(request: fixture.request(prompt: prompt), context: fixture.context)
        XCTAssertEqual(response["id"].string, "AIR-created-session")
        XCTAssertEqual(response["promptDelivered"].bool, true)
        XCTAssertEqual(response["title"].string, "AI readiness · Tests")
        let path = try XCTUnwrap(response["promptPath"].string)
        let saved = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(saved.hasSuffix(prompt + "\n"))
        XCTAssertTrue(saved.contains(NativeRPCValue.string(fixture.project.path).compact))
        let facts = await fixture.recorder.snapshot()
        XCTAssertEqual(facts.inputs.count, 1)
        XCTAssertEqual(facts.inputs.first?.cwd, fixture.project.path)
        XCTAssertEqual(facts.inputs.first?.provider, "claude")
        XCTAssertEqual(facts.inputs.first?.profileId, "AIR-login")
        XCTAssertEqual(facts.inputs.first?.resume, false)
        XCTAssertEqual(facts.promptPaths, [path])
        XCTAssertNil(facts.inputs.first?.permissionMode)
        XCTAssertNil(facts.inputs.first?.allowedTools)
        XCTAssertEqual(facts.contexts, [fixture.context.requestID, fixture.context.requestID, fixture.context.requestID])
        XCTAssertEqual(facts.gates, ["sessions.start", "sessions.send"])
        XCTAssertEqual(fixture.surface.typed(), [BackendDeckCoreBrief.deliveryLine(path), "\r"])
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testChoiceScreenKeepsCreatedSessionAndSavedPromptWithoutTyping() async throws {
        let fixture = try await AIRSessionFixture.make(mode: .choice)
        defer { fixture.remove() }
        let response = try await fixture.service.startAI(request: fixture.request(), context: fixture.context)
        XCTAssertEqual(response["id"].string, "AIR-created-session")
        XCTAssertEqual(response["promptDelivered"].bool, false)
        XCTAssertTrue(response["message"].string?.contains("AIR-created-session") == true)
        XCTAssertTrue(response["message"].string?.contains("saved prompt") == true)
        XCTAssertTrue(fixture.surface.typed().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(response["promptPath"].string)))
    }

    func testUnobservedEchoNeverSendsReturnOrClaimsPromptDelivery() async throws {
        let fixture = try await AIRSessionFixture.make(mode: .noEcho)
        defer { fixture.remove() }
        let response = try await fixture.service.startAI(request: fixture.request(), context: fixture.context)
        XCTAssertEqual(response["promptDelivered"].bool, false)
        XCTAssertEqual(fixture.surface.typed().last, "\u{15}")
        XCTAssertFalse(fixture.surface.typed().contains("\r"))
        XCTAssertTrue(response["message"].string?.contains("not delivered") == true)
    }

    func testDeniedLaunchDoesNotCreateSessionOrSavePrompt() async throws {
        let fixture = try await AIRSessionFixture.make(denyLaunch: true)
        defer { fixture.remove() }
        do {
            _ = try await fixture.service.startAI(request: fixture.request(), context: fixture.context)
            XCTFail("Launch without approval must fail")
        } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "access-denied") }
        let facts = await fixture.recorder.snapshot()
        XCTAssertTrue(facts.inputs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.specs.path))
    }

    func testCancelledLaunchCreatesNothing() async throws {
        let fixture = try await AIRSessionFixture.make()
        defer { fixture.remove() }
        let start = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.service.startAI(request: fixture.request(), context: fixture.context)
        }
        do { _ = try await start.value; XCTFail("Cancelled launch must stop") }
        catch { XCTAssertTrue(error is CancellationError) }
        let facts = await fixture.recorder.snapshot()
        XCTAssertTrue(facts.inputs.isEmpty)
    }

    func testCancellationAfterCreationRetainsSessionWithActionableFailure() async throws {
        let fixture = try await AIRSessionFixture.make(cancelDelivery: true)
        defer { fixture.remove() }
        let response = try await fixture.service.startAI(request: fixture.request(), context: fixture.context)
        XCTAssertEqual(response["id"].string, "AIR-created-session")
        XCTAssertEqual(response["promptDelivered"].bool, false)
        XCTAssertTrue(response["message"].string?.contains("cancelled") == true)
        let facts = await fixture.recorder.snapshot()
        XCTAssertEqual(facts.inputs.count, 1)
        XCTAssertTrue(fixture.surface.typed().isEmpty)
    }

    func testRequestCannotOverridePermissionsResumeOrUseShell() async throws {
        let fixture = try await AIRSessionFixture.make()
        defer { fixture.remove() }
        for request in [fixture.request().setting("permissionMode", .string("bypassPermissions")),
                        fixture.request().setting("resume", .bool(true)),
                        fixture.request().setting("provider", .string("shell")),
                        fixture.request().setting("firstPrompt", .string(" "))] {
            do { _ = try await fixture.service.startAI(request: request, context: fixture.context); XCTFail("Invalid readiness request must fail") }
            catch { XCTAssertEqual((error as? NativeRPCError)?.code, "invalid-arguments") }
        }
        let facts = await fixture.recorder.snapshot()
        XCTAssertTrue(facts.inputs.isEmpty)
    }

    func testRenameFailureDoesNotPretendReadyPromptWasDelivered() async throws {
        let fixture = try await AIRSessionFixture.make(renameSucceeds: false)
        defer { fixture.remove() }
        let response = try await fixture.service.startAI(request: fixture.request(), context: fixture.context)
        XCTAssertEqual(response["id"].string, "AIR-created-session")
        XCTAssertEqual(response["promptDelivered"].bool, false)
        XCTAssertTrue(response["message"].string?.contains("could not be named") == true)
        XCTAssertTrue(fixture.surface.typed().isEmpty)
    }

    func testMCPStartKeepsIssuedLimitsAndKeyOriginOutsideUserJSON() async throws {
        let fixture = try await AIRSessionFixture.make()
        defer { fixture.remove() }
        let starts = AIRSessionStartedRecorder()
        let core = fixture.coreContext(limits: .object([.init("deniedTools", .array([.string("Bash")])),
                                                       .init("noSkills", .bool(true)), .init("agentInstructions", .string("air-review"))]),
                                       noteStarted: { starts.add($0) })
        let rpc = NativeRPCContext(caller: .page, ownerID: "core-call:" + core.callID, capabilities: ["readiness"])
        let response = try await fixture.service.startAI(request: fixture.request(), context: rpc, coreContext: core)
        XCTAssertEqual(response["promptDelivered"].bool, true)
        let facts = await fixture.recorder.snapshot()
        XCTAssertEqual(facts.inputs.first?.deniedTools, ["Bash"])
        XCTAssertEqual(facts.inputs.first?.noSkills, true)
        XCTAssertEqual(facts.inputs.first?.agentInstructions, "air-review")
        XCTAssertEqual(facts.inputs.first?.origin, .app)
        XCTAssertEqual(facts.inputs.first?.originApp, "AIR key")
        XCTAssertEqual(facts.inputs.first?.originRunId, core.callID)
        XCTAssertEqual(facts.contexts, [rpc.requestID, rpc.requestID, rpc.requestID])
        XCTAssertEqual(starts.ids(), ["AIR-created-session"])
    }

    func testPageCannotLaunchWithoutMatchingLiveIssuedCoreContext() async throws {
        let fixture = try await AIRSessionFixture.make()
        defer { fixture.remove() }
        let core = fixture.coreContext()
        let rpc = NativeRPCContext(caller: .page, ownerID: "core-call:other", capabilities: ["readiness"])
        do { _ = try await fixture.service.startAI(request: fixture.request(), context: rpc); XCTFail("A Page needs the issuer context") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "access-denied") }
        do { _ = try await fixture.service.startAI(request: fixture.request(), context: rpc, coreContext: core); XCTFail("The issuer must match this core call") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "access-denied") }
        do { _ = try await fixture.service.invoke("readiness:startAI", args: [fixture.request()], context: rpc); XCTFail("The native bridge cannot issue an MCP launch") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "access-denied") }
        let facts = await fixture.recorder.snapshot()
        XCTAssertTrue(facts.inputs.isEmpty)
    }

    func testCancelledIssuedCoreCallCannotCreateAnAISession() async throws {
        let fixture = try await AIRSessionFixture.make()
        defer { fixture.remove() }
        let core = fixture.coreContext()
        core.native.cancellation.cancel()
        let rpc = NativeRPCContext(caller: .page, ownerID: "core-call:" + core.callID, capabilities: ["readiness"])
        do { _ = try await fixture.service.startAI(request: fixture.request(), context: rpc, coreContext: core); XCTFail("Cancelled core call must stop") }
        catch { XCTAssertTrue(error is CancellationError) }
        let facts = await fixture.recorder.snapshot()
        XCTAssertTrue(facts.inputs.isEmpty)
    }

    func testDeviceBriefGrantMustNameOnlyTheApprovedPromptFile() async throws {
        let fixture = try await AIRSessionFixture.make()
        defer { fixture.remove() }
        let path = fixture.specs.appendingPathComponent("approved.md").path
        let wholeDirectory = BackendLaunchContext(deviceBoundary: .init(deviceKey: "AIR-device", folder: fixture.project.path,
            readableFiles: [fixture.specs.path]))
        XCTAssertThrowsError(try BackendAIRReadinessSession.requirePromptAccess(wholeDirectory, promptPath: path))
        let exactFile = BackendLaunchContext(deviceBoundary: .init(deviceKey: "AIR-device", folder: fixture.project.path,
            readableFiles: [path]))
        XCTAssertNoThrow(try BackendAIRReadinessSession.requirePromptAccess(exactFile, promptPath: path))
    }
}

private actor AIRSessionRecorder {
    struct Facts: Sendable {
        var inputs: [BackendCreateSessionInput] = []
        var contexts: [UUID] = []
        var gates: [String] = []
        var promptPaths: [String] = []
    }
    private var facts = Facts()
    func created(_ input: BackendCreateSessionInput, _ context: NativeRPCContext, _ promptPath: String) -> BackendSessionMeta {
        facts.inputs.append(input); facts.contexts.append(context.requestID)
        facts.promptPaths.append(promptPath)
        return .init(id: "AIR-created-session", input: input,
            spawn: .init(provider: input.provider ?? "claude", command: "/fake/ai", args: [], path: "/fake",
                         profile: input.profileId.map { .init(id: $0, name: "AIR test login") }))
    }
    func renamed(_ context: NativeRPCContext) { facts.contexts.append(context.requestID) }
    func delivered(_ context: NativeRPCContext) { facts.contexts.append(context.requestID) }
    func gate(_ operation: String) { facts.gates.append(operation) }
    func snapshot() -> Facts { facts }
}

private final class AIRSessionBriefSurface: BackendDeckCoreBriefSurface, @unchecked Sendable {
    enum Mode: Sendable, Equatable { case ready, choice, noEcho }
    private let mode: Mode
    private let lock = NSLock()
    private var writes: [String] = []
    private var now = 0.0
    init(_ mode: Mode) { self.mode = mode }
    func listSessions() -> [NativeRPCValue] { [.object([.init("id", .string("AIR-created-session")), .init("exitCode", .null)])] }
    func sessionScreen(id: String) async throws -> String? {
        lock.withLock {
            if mode == .choice { return "❯ 1. Trust this folder" }
            if mode == .noEcho { return "❯ " }
            return writes.first.map { "❯ " + String($0.prefix(80)) } ?? "❯ "
        }
    }
    func writeToSession(id: String, data: String) async throws { lock.withLock { writes.append(data) } }
    func typed() -> [String] { lock.withLock { writes } }
    var clock: BackendDeckCoreBriefClock {
        .init(now: { self.lock.withLock { self.now } }, sleep: { amount in
            self.lock.withLock { self.now += amount }
        })
    }
}

private final class AIRSessionStartedRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [String] = []
    func add(_ id: String) { lock.withLock { started.append(id) } }
    func ids() -> [String] { lock.withLock { started } }
}

private struct AIRSessionFixture: Sendable {
    let root: URL
    let project: URL
    let specs: URL
    let context: NativeRPCContext
    let recorder: AIRSessionRecorder
    let surface: AIRSessionBriefSurface
    let service: BackendAIRReadinessSession
    func request(prompt: String = "Review this project and fix only its test command.\nThen run readiness.recheck.") -> NativeRPCValue {
        .object([.init("cwd", .string(project.path)), .init("provider", .string("claude")),
                 .init("profileId", .string("AIR-login")), .init("cols", .number(100)), .init("rows", .number(30)),
                 .init("resume", .bool(false)), .init("firstPrompt", .string(prompt)), .init("title", .string("AI readiness · Tests"))])
    }
    func coreContext(limits: NativeRPCValue = .missing,
                     noteStarted: @escaping @Sendable (String) -> Void = { _ in }) -> BackendDeckCoreSecurityCallContext {
        let native = BackendMCPCallContext(sessionID: "AIR-existing-caller", machineID: "", projectRoot: project.path,
            attended: true, allowedTools: ["readiness.ask_ai"], allowedTiers: [.read, .alter], cancellation: BackendMCPCancellation())
        let caller = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read, .alter],
            keyID: "AIR-test-key", keyName: "AIR key", folders: [project.path], projectRoot: project.path)
        return .init(native: native, caller: caller, callID: "AIR-issued-core-call", attended: true, granted: nil,
            sessionLimits: limits, now: { 0 }, startedByCopilot: { _ in false }, noteStarted: noteStarted)
    }
    static func make(mode: AIRSessionBriefSurface.Mode = .ready, denyLaunch: Bool = false,
                     cancelDelivery: Bool = false, renameSucceeds: Bool = true) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIR-session-" + UUID().uuidString)
        let project = root.appendingPathComponent("scratch-project"), specs = root.appendingPathComponent("owned-specs")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        do {
            let store = NativeStateStore()
            _ = try await store.addProject(project.path)
            let authority = BackendFilesystemAuthority { _ in .init(readRoots: [project], writeRoots: [project]) }
            let files = BackendFilesystemService(authority: authority)
            let projects = try BackendProjectService(store: store, files: files, home: root.path,
                appDataRoot: root.appendingPathComponent("isolated-store"), liveSessions: { [] })
            let context = NativeRPCContext(caller: .nativeApp, ownerID: "AIR-session-owner", capabilities: ["readiness"])
            let persistence = try BackendTaskPersistence(directory: specs, ownership: .exclusive)
            let recorder = AIRSessionRecorder(), surface = AIRSessionBriefSurface(mode)
            let service = BackendAIRReadinessSession(projects: projects, specs: persistence,
                create: { input, context, promptPath in await recorder.created(input, context, promptPath) },
                deliver: { id, line, context in
                    await recorder.delivered(context)
                    if cancelDelivery { throw CancellationError() }
                    let result = try await BackendDeckCoreBrief.deliver(surface: surface, sessionID: id, line: line,
                        timeoutMs: 1000, pollMs: 100, clock: surface.clock)
                    guard result["delivered"].bool == true else { throw NativeRPCError(code: "brief-not-delivered", message: result["reason"].string ?? "The brief was not delivered.") }
                }, rename: { _, _, context in await recorder.renamed(context); return renameSucceeds },
                authorize: { operation, _, _ in
                    await recorder.gate(operation)
                    if denyLaunch { throw NativeRPCError(code: "access-denied", message: "The launch was declined.") }
                })
            return .init(root: root, project: project, specs: specs, context: context,
                         recorder: recorder, surface: surface, service: service)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

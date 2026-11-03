import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor final class Fix20ChatFolderScopeTests: XCTestCase {
    private func roots(provider: String) async throws -> (NativeRPCValue, String) {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("td-fix20-scope-" + UUID().uuidString)
        let data = scratch.appendingPathComponent("data"), project = scratch.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = try NativeStateStore(file: data.appendingPathComponent("state.json"), ownership: .memory)
        _ = try await store.addProject(project.path)
        let root = try BackendCompositionRoot(dataRoot: data, state: store, environment: [:], home: scratch.path)
        let state = await BackendCompositionState.make(store: store, settings: root.settings, dataRoot: data,
            registry: root.registry, copilotRoot: { _ in data.appendingPathComponent("hoot").path })
        let configuration = try BackendAccountConfiguration(dataDirectory: data, homeDirectory: scratch,
            appName: "Fix20 Fixture", appID: "terminaldeck", helperExecutable: scratch.appendingPathComponent("never-run"),
            inheritedEnvironment: root.preparedSessions.environment)
        let contexts = BackendDeckCoreToolContextAuthority()
        let authority = try BackendCompositionAuthority(prepared: root.preparedSessions, state: state, configuration: configuration,
            coreContexts: contexts, gate: .init(authorize: { _, _, _, _, _, _ in }, record: { _, _, _, _ in }), hidden: .init())
        addTeardownBlock { authority.close(); await state.stop(); try await root.shutdown(); try? FileManager.default.removeItem(at: scratch) }
        var input = BackendCreateSessionInput(cwd: project.path, provider: provider); input.chat = true
        let meta = BackendSessionMeta(id: "caller", input: input, spawn: .init(provider: provider, command: "/never-run", args: [], path: "/usr/bin"))
        try root.preparedSessions.manager.registerChat(meta, controls: .init(send: { _ in }, stop: {}, text: { "" }, pid: { nil }))
        let caller = BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read], sessionID: "caller")
        let context = BackendDeckCoreSecurityCallContext(native: .init(sessionID: "caller", machineID: "", projectRoot: nil,
            attended: true, allowedTools: [], allowedTiers: [.read], cancellation: .init()),
            caller: caller, callID: "checked-call", attended: true, granted: nil, sessionLimits: .object([]), now: { 0 },
            startedByCopilot: { _ in false }, noteStarted: { _ in })
        let reply = try await contexts.invoke(handler: { native, _ in
            let rpc = try await authority.rpc(native)
            let scope = try await authority.filesystemScope(rpc)
            return .value(.object([.init("roots", .array(scope.readRoots.map { .string($0.path) }))]))
        }, arguments: .object([]), context: context)
        return (try XCTUnwrap(reply.structuredContent)["roots"], project.path)
    }
    func testCodexFolderAccessNeedsNoClaudeAccountAndGetsOnlyItsProject() async throws {
        let (value, project) = try await roots(provider: "codex")
        XCTAssertEqual(value.elements, [.string(project)])
    }
    func testGeminiFolderAccessAlsoCannotBorrowClaudeTranscripts() async throws {
        let (value, project) = try await roots(provider: "gemini")
        XCTAssertEqual(value.elements, [.string(project)])
    }
    func testClaudeStillRequiresItsOwnEstablishedTranscriptAccount() async {
        do { _ = try await roots(provider: "claude"); XCTFail("A Claude session without its established account must still refuse.") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Composition needs")) }
    }
}

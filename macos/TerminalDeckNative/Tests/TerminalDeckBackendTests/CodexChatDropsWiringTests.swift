import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor final class CodexChatDropsWiringTests: XCTestCase {
  func testProductionSessionProjectionKeepsChatOutcomeAndMode() async throws {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("drops-wire-" + UUID().uuidString)
    let data = scratch.appendingPathComponent("data")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    let store = try NativeStateStore(file: data.appendingPathComponent("state.json"), ownership: .memory)
    let root = try BackendCompositionRoot(dataRoot: data, state: store, environment: [:], home: scratch.path)
    let state = await BackendCompositionState.make(store: store, settings: root.settings, dataRoot: data,
      registry: root.registry, copilotRoot: { _ in data.appendingPathComponent("hoot").path })
    let configuration = try BackendAccountConfiguration(dataDirectory: data, homeDirectory: scratch,
      appName: "Chat drops fixture", appID: "terminaldeck", helperExecutable: scratch.appendingPathComponent("never-run"),
      inheritedEnvironment: root.preparedSessions.environment)
    let authority = try BackendCompositionAuthority(prepared: root.preparedSessions, state: state, configuration: configuration,
      coreContexts: .init(), gate: .init(authorize: { _, _, _, _, _, _ in }, record: { _, _, _, _ in }), hidden: .init())
    addTeardownBlock {
      authority.close(); await state.stop(); try await root.shutdown()
      try? FileManager.default.removeItem(at: scratch)
    }
    let gate = BackendCompositionDeckToolsGate(authority: authority, authorize: { _, _, _, _ in }, noteResult: { _, _ in })
    let scope = BackendCompositionDeckToolsScope(gate: gate, deviceFolders: nil, workspaces: nil, browserSlots: { _, _ in [] })
    let native = BackendMCPCallContext(sessionID: "fixture", machineID: "", projectRoot: nil, attended: true,
      allowedTools: [], allowedTiers: [.read], cancellation: .init())
    let core = BackendDeckCoreSecurityCallContext(native: native, caller: .local, callID: "fixture", attended: true,
      granted: nil, sessionLimits: .object([]), now: { 1_000 }, startedByCopilot: { _ in false }, noteStarted: { _ in })
    var input = BackendCreateSessionInput(cwd: scratch.path, provider: "codex")
    input.chat = true
    var meta = BackendSessionMeta(id: "finished", input: input, spawn: .init(provider: "codex", command: "/never-run", args: [], path: "/usr/bin"))
    meta.exitCode = 0
    let done = try await scope.view(meta, core: core)
    XCTAssertEqual(done["chat"], .bool(true))
    XCTAssertEqual(done["status"], .string("completed"))
    XCTAssertEqual(done["attentionReason"], .string("job-finished"))
    meta.exitCode = 1
    let failed = try await scope.view(meta, core: core)
    XCTAssertEqual(failed["status"], .string("failed"))
    XCTAssertEqual(failed["attentionReason"], .string("process-failed"))
  }
}

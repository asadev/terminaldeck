import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor final class ChatForkAuthorityTests: XCTestCase {
    func testNestedChatRequestsKeepOnlyTheSameLiveApproval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-fork-authority-" + UUID().uuidString)
        let data = directory.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let store = try NativeStateStore(file: data.appendingPathComponent("state.json"), ownership: .memory)
        let root = try BackendCompositionRoot(dataRoot: data, state: store, environment: [:], home: directory.path)
        let state = await BackendCompositionState.make(store: store, settings: root.settings, dataRoot: data,
            registry: root.registry, copilotRoot: { _ in data.appendingPathComponent("hoot").path })
        let configuration = try BackendAccountConfiguration(dataDirectory: data, homeDirectory: directory,
            appName: "Fork Authority Fixture", appID: "terminaldeck", helperExecutable: directory.appendingPathComponent("never-run"),
            inheritedEnvironment: root.preparedSessions.environment)
        let contexts = BackendDeckCoreToolContextAuthority()
        let authority = try BackendCompositionAuthority(prepared: root.preparedSessions, state: state, configuration: configuration,
            coreContexts: contexts, gate: .init(authorize: { _, _, _, _, _, _ in }, record: { _, _, _, _ in }), hidden: .init())
        addTeardownBlock { authority.close(); await state.stop(); try await root.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let registry = root.registry
        try await registry.register("fork:inner", ownerID: "fork-fixture", policy: { try authority.authorizeMutation($0) }) { context, _ in .string(context.ownerID) }
        try await registry.register("fork:outer", ownerID: "fork-fixture") { context, _ in
            try await registry.invoke("fork:inner", context: authority.childContext(context), arguments: [])
        }
        let cancellation = BackendMCPCancellation()
        let native = BackendMCPCallContext(sessionID: "", machineID: "", projectRoot: nil, attended: true,
            allowedTools: ["sessions.chat_fork"], allowedTiers: [.read, .act], cancellation: cancellation)
        let caller = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read, .act], keyID: "fork-key", keyName: "Fork fixture")
        let call = BackendDeckCoreSecurityCallContext(native: native, caller: caller, callID: "fork-call", attended: true,
            granted: nil, sessionLimits: .object([]), now: { 0 }, startedByCopilot: { _ in false }, noteStarted: { _ in })
        let escaped = BackendDeckCoreSecurityTestBox<NativeRPCContext?>(nil)
        _ = try await contexts.invoke(handler: { native, _ in
            let parent = try await authority.rpc(native)
            let unapproved = try authority.childContext(parent)
            XCTAssertThrowsError(try authority.authorizeMutation(unapproved))
            try await authority.authorize(native, tool: "sessions.chat_fork", arguments: .object([]), tier: .act, sentence: "Fork this fixture", ownerMustAnswer: true)
            let child = try authority.childContext(parent)
            XCTAssertNotEqual(child.requestID, parent.requestID)
            XCTAssertEqual(child.caller, parent.caller)
            XCTAssertEqual(child.ownerID, parent.ownerID)
            XCTAssertEqual(child.origin, parent.origin)
            XCTAssertEqual(child.capabilities, parent.capabilities)
            try authority.authorizeMutation(child)
            XCTAssertThrowsError(try authority.authorizeMutation(unapproved), "An earlier child cannot inherit a later approval")
            let canonical = try await authority.rpc(native)
            XCTAssertEqual(canonical.requestID, parent.requestID)
            let nested = try await registry.invoke("fork:outer", context: parent, arguments: [])
            XCTAssertEqual(nested.string, parent.ownerID)
            escaped.edit { $0 = child }
            return .value(.bool(true))
        }, arguments: .object([]), context: call)
        cancellation.cancel()
        let expired = try XCTUnwrap(escaped.get())
        XCTAssertThrowsError(try authority.authorizeMutation(expired))
        XCTAssertThrowsError(try authority.childContext(expired))
        let ui = try authority.localContext(), uiChild = try authority.childContext(ui)
        XCTAssertNotEqual(ui.requestID, uiChild.requestID)
        XCTAssertEqual(ui.caller, uiChild.caller)
        authority.revokeLocalUI()
        XCTAssertThrowsError(try authority.childContext(ui))
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TerminalDeckNative/NativeChatFork.swift")
        let code = try String(contentsOf: source, encoding: .utf8)
        XCTAssertEqual(code.components(separatedBy: "NativeChatForkRequest.child(context, authority: authority)").count, 3)
    }
}

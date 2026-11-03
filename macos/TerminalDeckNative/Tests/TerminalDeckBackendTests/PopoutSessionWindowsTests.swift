import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// U109 (#631): the older popout channels reach the app's own session windows, the ones the sidebar's
/// "Open in new window" and the windows tools use, instead of saying sessions cannot have windows.
@MainActor final class PopoutSessionWindowsTests: XCTestCase {
    private actor Windows {
        var out: [String] = []
        func open(_ id: String) -> NativeRPCValue {
            if !out.contains(id) { out.append(id) }
            return .object([.init("ok", .bool(true)), .init("sessionId", .string(id)), .init("message", .string("The same session is in its own window."))])
        }
        func dock(_ id: String) throws -> NativeRPCValue {
            guard out.contains(id) else { throw NativeRPCError.invalidArguments("That session is not in a window of its own.") }
            out.removeAll { $0 == id }
            return .object([.init("ok", .bool(true)), .init("sessionId", .string(id))])
        }
        func list() -> NativeRPCValue { .object([.init("windows", .array(out.map { .object([.init("sessionId", .string($0))]) }))]) }
    }

    func testPopoutChannelsOpenFocusListAndDockTheAppsSessionWindows() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("td-popout-" + UUID().uuidString)
        let data = scratch.appendingPathComponent("data"), project = scratch.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = try NativeStateStore(file: data.appendingPathComponent("state.json"), ownership: .memory)
        let root = try BackendCompositionRoot(dataRoot: data, state: store, environment: [:], home: scratch.path)
        let state = await BackendCompositionState.make(store: store, settings: root.settings, dataRoot: data,
            registry: root.registry, copilotRoot: { _ in data.appendingPathComponent("hoot").path })
        let configuration = try BackendAccountConfiguration(dataDirectory: data, homeDirectory: scratch,
            appName: "Popout Fixture", appID: "terminaldeck", helperExecutable: scratch.appendingPathComponent("never-run"),
            inheritedEnvironment: root.preparedSessions.environment)
        let authority = try BackendCompositionAuthority(prepared: root.preparedSessions, state: state, configuration: configuration,
            coreContexts: BackendDeckCoreToolContextAuthority(), gate: .init(authorize: { _, _, _, _, _, _ in }, record: { _, _, _, _ in }), hidden: .init())
        addTeardownBlock { authority.close(); await state.stop(); try await root.shutdown(); try? FileManager.default.removeItem(at: scratch) }
        var input = BackendCreateSessionInput(cwd: project.path, provider: "claude"); input.chat = true
        let meta = BackendSessionMeta(id: "s1", input: input, spawn: .init(provider: "claude", command: "/never-run", args: [], path: "/usr/bin"))
        try root.preparedSessions.manager.registerChat(meta, controls: .init(send: { _ in }, stop: {}, text: { "" }, pid: { nil }))

        let windows = Windows(), registry = NativeChannelRegistry()
        let ledger = BackendCompositionBrowserReachLedger(registry: registry, open: { _, _, _ in .null }, close: { _, _, _ in false })
        _ = try await BackendCompositionBrowserChannels.register(registry: registry, ownerID: "popout-test", authority: authority,
            bindings: { throw NativeRPCError(code: "unavailable", message: "No bindings in this test.") }, reachLedger: ledger, hiddenCommands: nil,
            sessionWindows: .init(open: { await windows.open($0) }, dock: { try await windows.dock($0) }, list: { await windows.list() }))
        let app = NativeRPCContext(caller: .nativeApp, ownerID: BackendCompositionRoot.appOwnerID)
        func call(_ channel: String, _ args: [NativeRPCValue]) async throws -> NativeRPCValue {
            try await registry.invoke(channel, context: app, arguments: args)
        }

        let notOut = try await call("popout:focus", [.string("s1")])
        XCTAssertEqual(notOut["ok"].bool, false, "focus never takes a session out of the main window")
        let opened = try await call("popout:open", [.string("s1")])
        XCTAssertEqual(opened["ok"].bool, true)
        XCTAssertNotEqual(opened["message"].string, BackendCompositionBrowserChannels.popoutRefusal)
        let listed = try await call("popout:list", [])
        XCTAssertEqual(listed["windows"].elements?.compactMap { $0["sessionId"].string }, ["s1"])
        let focused = try await call("popout:focus", [.string("s1")]), docked = try await call("popout:dock", [.string("s1")])
        XCTAssertEqual(focused["ok"].bool, true)
        XCTAssertEqual(docked["ok"].bool, true)
        let again = try await call("popout:dock", [.string("s1")])
        XCTAssertEqual(again["ok"].bool, false)
        XCTAssertEqual(again["message"].string, "That session is not in a window of its own.")
        let unknown = try await call("popout:open", [.string("gone")])
        XCTAssertEqual(unknown["message"].string, "No session with that id is running on this computer.")
    }
}

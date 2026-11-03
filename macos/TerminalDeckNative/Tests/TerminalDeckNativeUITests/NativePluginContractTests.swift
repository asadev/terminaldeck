import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend
@testable import TerminalDeckNative

private enum NativePulsePolicy { @TaskLocal static var tool: String? }
private struct NativePulseAuthority: BackendPluginsCallerAuthority {
    func isLocalHoot(_ context: BackendMCPCallContext) async -> Bool { context.sessionID.isEmpty }
    func authorize(_ context: BackendMCPCallContext, tool: String, arguments: NativeRPCValue, tier: BackendMCPTier) async throws {
        guard NativePulsePolicy.tool == tool, context.allowedTools.contains(tool), context.allowedTiers.contains(tier) else { throw NativeRPCError(code: "not-granted", message: "Missing real fixture dispatcher entry") }
    }
}
private struct NativePulseConsent: BackendPluginsConsent {
    func ask(_ question: BackendPluginsConsentRequest) async -> BackendPluginsConsentOutcome { .init(granted: true) }
    func shutdown() async {}
}
private actor NativePulsePeer: BackendPluginsRunningProcess {
    var active = false
    var project = ""
    let answer: BackendPluginsProcess.RequestHandler
    var starts = 0
    init(answer: @escaping BackendPluginsProcess.RequestHandler) { self.answer = answer }
    var alive: Bool { active }
    var pid: Int32? { active ? 12 : nil }
    func start() async throws { active = true }
    func stop(_ why: String) async { active = false }
    func kill(_ why: String) async { active = false }
    func request(_ method: String, params: NativeRPCValue, timeoutMilliseconds: Int?) async throws -> NativeRPCValue {
        if method == "initialize" { project = params["projects"].elements?.first?.string ?? ""; return .object([.init("protocol", .number(1)), .init("methods", .array([.string("ui/read"), .string("jobs/start")]))]) }
        if method == "ui/read" { return .object([.init("cards", .array([.object([.init("id", .string("pulse")), .init("project", .string(project)), .init("summary", .string("Fixture pulse")), .init("status", .string("Ready")), .init("fields", .object([]))])]))]) }
        guard method == "jobs/start" else { throw NativeRPCError(code: "fixture", message: "Unsupported") }
        starts += 1
        _ = try await answer("jobs/complete", .object([.init("id", params["id"]), .init("attempt", params["attempt"]), .init("receipt", .string("done")), .init("value", params["input"])]))
        return .object([.init("accepted", .bool(true)), .init("attempt", params["attempt"])])
    }
}
private final class NativePulseFactory: @unchecked Sendable {
    let lock = NSLock()
    var peer: NativePulsePeer?
    func make(_ answer: @escaping BackendPluginsProcess.RequestHandler) -> any BackendPluginsRunningProcess { lock.withLock { let p = NativePulsePeer(answer: answer); peer = p; return p } }
}
@MainActor final class NativePluginContractTests: XCTestCase {
    func testTypedInputAndNativeModelReachActualFactoryDispatcherHostAndPeer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-plugin-" + UUID().uuidString), folder = root.appendingPathComponent("plugins/pulse"), project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let raw = #"{"terminaldeck":1,"id":"pulse","name":"Pulse","summary":"Fixture","version":"1.0.0","plugin":{"main":"main.js","runtime":"node","capabilities":["ui.contribute","jobs.run"],"jobs":[{"id":"update","title":"Update","inputSchema":{"type":"object","properties":{"label":{"type":"string"}},"required":["label"],"additionalProperties":false}}],"ui":{"cards":[{"id":"pulse","title":"Pulse","fields":[],"actions":[{"id":"update","title":"Update now","kind":"job","target":"update"}]}]}}}"#
        try Data(raw.utf8).write(to: folder.appendingPathComponent("terminaldeck.json")); try Data("fixture only".utf8).write(to: folder.appendingPathComponent("main.js"))
        let factory = NativePulseFactory(), path = BackendPluginsFiles.real(project.path)
        let host = BackendPluginsHost(userData: root, runtime: "/fixture/runtime/bin/node", environment: [:], consent: NativePulseConsent(), services: .init(projects: { [path] }), processFactory: { _, answer, _ in factory.make(answer) })
        addTeardownBlock { await host.stopAll(); try? FileManager.default.removeItem(at: root) }
        await host.scan(); let allowed = await host.allow("pulse", input: .object([.init("capabilities", .array([.string("ui.contribute"), .string("jobs.run")])), .init("projects", .array([.string(path)]))])); XCTAssertEqual(allowed["ok"], .bool(true))
        let authority = NativePulseAuthority(), tools = try await BackendPluginsChannels.tools(host: host, authority: authority)
        let control = try BackendDeckCoreSecurityControl(log: .init(directory: root.appendingPathComponent("log")), consent: .init(ask: { _ in false }))
        try await control.register(tools.map { registration in .init(tool: registration.spec, audience: "copilot", summary: { _, _ in "Plugin fixture" }, run: { args, context in
            try await NativePulsePolicy.$tool.withValue(registration.spec.id) {
                let reply = try await registration.handler(context.native, args)
                guard !reply.isError, let value = reply.structuredContent else { throw NativeRPCError(code: "fixture", message: "Dispatcher refused") }; return .init(value: value)
            }
        }) })
        let registry = NativeChannelRegistry(), owner = NativeRPCContext(caller: .nativeApp, ownerID: BackendCompositionRoot.appOwnerID)
        try await BackendPluginExtensionTools.register(registry: registry, ownerID: "fixture", host: host, dispatch: { _, tool, input in
            let reply = await control.call(name: tool, arguments: input, options: .init(caller: .local, granted: Set(tools.map { $0.spec.id })))
            guard reply.ok else { throw NativeRPCError(code: "fixture", message: reply.error ?? "Refused") }; return reply.value
        })
        let model = NativePluginContractModel(pluginID: "pulse", invoke: { id, input in try await registry.invoke(BackendPluginExtensionTools.channel, context: owner, arguments: [.string(id), input]) })
        await model.perform(.object([.init("op", .string("start"))])); await model.perform(.object([.init("op", .string("read"))])); XCTAssertNil(model.problem)
        let card = try XCTUnwrap(model.state["cards"].elements?.first), manifest = try BackendPluginsManifestReader.parse(raw, folder: "pulse"), action = try XCTUnwrap(manifest.contract["cards"].elements?.first?["actions"].elements?.first)
        model.values["pulse/" + path + "/update/label"] = "Report ready"
        await model.runCard(card: card, action: action)
        XCTAssertNil(model.problem); XCTAssertFalse(model.pending)
        XCTAssertEqual(model.state["jobs"].elements?.last?["input"]["label"], .string("Report ready")); XCTAssertEqual(model.state["jobs"].elements?.last?["state"], .string("completed"))
        let state = await host.state(), item = try XCTUnwrap(PluginsState.from(CodingAIJSON(state.foundation))?.plugins.first)
        _ = NativePluginContractView(plugin: item, model: model) // initializer/compile only, no SwiftUI body or app window
    }
}

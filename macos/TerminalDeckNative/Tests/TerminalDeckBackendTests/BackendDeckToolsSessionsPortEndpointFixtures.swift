import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Reuse deck-core's existing finite fake scheduler and callback barriers.
typealias BackendDeckToolsSessionsPortScheduler = BackendDeckCoreTestPortSecurityClock

actor BackendDeckToolsSessionsPortEndpoint: BackendMCPToolEndpoint {
    nonisolated let readiness: BackendLaunchReadiness = .ready
    let revoked = BackendDeckCoreTestPortSecuritySignal()
    var available = true
    var registrations: [UUID: (token: String, grant: BackendMCPCallerGrant, session: String?, machine: String)] = [:]
    let specs: [BackendMCPTool]
    init(specs: [BackendMCPTool]) { self.specs = specs }
    func setAvailable(_ value: Bool) { available = value }
    func description() throws -> BackendMCPEndpointDescription? { guard available else { return nil }; return try .init(url: URL(string: "http://127.0.0.1:47821/mcp")!, implementation: .native) }
    func catalogue() -> [BackendMCPTool] { specs }
    func register(token: String, grant: BackendMCPCallerGrant) -> BackendMCPRegistration {
        let id = UUID(); registrations[id] = (token, grant, nil, ""); return .init(id: id)
    }
    func bind(_ registration: BackendMCPRegistration, sessionID: String, machineID: String) throws {
        guard var value = registrations[registration.id] else { throw BackendSessionFailure.missingSession }
        value.session = sessionID; value.machine = machineID; registrations[registration.id] = value
    }
    func revoke(_ registration: BackendMCPRegistration) { registrations[registration.id] = nil; revoked.signal() }
    func snapshot() -> [(token: String, grant: BackendMCPCallerGrant, session: String?, machine: String)] { registrations.values.map { $0 } }
}

/// Fake browser host; the real BackendBrowserService/Bindings/Driver do all
/// targeting, grant checks, argument validation and result shaping.
@MainActor final class BackendDeckToolsSessionsPortBrowserRuntime: BackendBrowserRuntime {
    var ownTabID: String?, tabs = ["browser:1": "http://localhost:3000/", "browser:9": "http://localhost:3000/"]
    var observed: [String] = [], instant = 1_000.0
    func bindings() async -> BrowserBindings { .init(windows: [:]) }
    func tabExists(_ id: String) -> Bool { tabs[id] != nil }
    func createTab(url: URL, isolated: Bool) -> String { let id = "created-\(tabs.count)"; tabs[id] = url.absoluteString; return id }
    func attach(_ id: String, to session: BrowserDriverSession) async -> String? { XCTFail("Session attach is supplied by actual BackendBrowserCallHost"); return nil }
    func load(_ id: String, url: URL) { tabs[id] = url.absoluteString }
    func isIsolated(_ id: String) -> Bool { false }
    func setIsolated(_ id: String, _ isolated: Bool) {}
    func settle(_ id: String, timeoutMs: Int) async -> Bool { true }
    func pageURL(_ id: String) -> String { tabs[id] ?? "" }
    func title(_ id: String) -> String { "Dev" }
    func displayTitle(_ id: String) -> String { "Dev" }
    func evaluate(_ id: String, _ script: String) async throws -> Any? {
        observed.append(id)
        switch BrowserDriverScripts.name(of: script) {
        case "outline": return ["url": pageURL(id), "title": "Dev", "text": "hello", "textTruncated": false, "elements": [], "matched": 0, "truncated": false] as [String: Any]
        case "probe": return ["found": true, "visible": true, "enabled": true, "hit": true, "viewport": ["width": 1200, "height": 900], "secret": false, "tag": "button", "label": "go", "count": 1, "rect": ["x": 1, "y": 1, "width": 50, "height": 20]] as [String: Any]
        case "text": return ["found": true, "secret": false, "text": "hello", "truncated": false] as [String: Any]
        default: return ["ok": true] as [String: Any]
        }
    }
    func reveal(_ id: String) async -> Bool { true }
    func click(_ id: String, cssRect: CGRect) -> Bool { true }
    func focusForTyping(_ id: String) -> Bool { true }
    func type(_ id: String, plan: BrowserTypingPlan) -> Bool { true }
    func press(_ id: String, key: BrowserKeySpec) -> Bool { true }
    func screenshot(_ id: String) async throws -> (path: String, width: Int, height: Int, masked: Int) { ("/fake/x.png", 1, 1, 0) }
    func handoverPrompt(_ id: String) -> String? { nil }
    func otherHandover(than id: String) -> String? { nil }
    func handOver(_ id: String, prompt: String, windowMs: Int) async -> String { "resumed" }
    func closeTab(_ id: String) { tabs[id] = nil }
    func unbind(_ id: String) {}
    func now() -> Double { instant }
    func pause(ms: Int) async { instant += Double(ms) }
    func pageState(_ tabID: String) -> NativeRPCValue { .object([.init("url", .string(pageURL(tabID))), .init("title", .string("Dev")), .init("profileId", .string("default"))]) }
    func pageCommand(_ tabID: String, operation: String, arguments: NativeRPCValue) throws -> NativeRPCValue { throw BackendDeckToolsSupport.unavailable("unused fake browser toolbar") }
    func frameCommand(_ tabID: String, operation: String, arguments: NativeRPCValue) throws -> NativeRPCValue { throw BackendDeckToolsSupport.unavailable("unused fake browser frame") }
    func dataCommand(_ operation: String, arguments: NativeRPCValue) throws -> NativeRPCValue { throw BackendDeckToolsSupport.unavailable("unused fake browser data") }
    func revealScreenshot(_ path: String) throws { throw BackendDeckToolsSupport.unavailable("unused fake reveal") }
    func createProfileTab(url: URL, isolated: Bool, profileID: String) -> String { createTab(url: url, isolated: isolated) }
}

@MainActor final class BackendDeckToolsSessionsPortTransport {
    typealias V = BackendDeckToolsSessionsPortValues
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendDeckToolsSessionsPort-" + UUID().uuidString)
    let clock = BackendDeckToolsSessionsPortScheduler(10_000)
    let browserRuntime = BackendDeckToolsSessionsPortBrowserRuntime(), bindings = BackendBrowserBindings()
    let browserSessions = BackendDeckToolsSessionsPortBrowserSessionTable()
    private(set) var browser: BackendBrowserService!
    private(set) var control: BackendDeckCoreSecurityControl!, server: BackendDeckCoreSecurityServer!, endpoint: BackendDeckCoreSessionEndpoint!
    var live: BackendDeckCoreSecurityEndpoint?
    private(set) var specs: [BackendMCPTool] = []
    init(includeNetwork: Bool = false) async throws {
        let bindings = self.bindings, browserSessions = self.browserSessions
        browser = BackendBrowserService(runtime: browserRuntime, bindings: bindings, resolve: { context in
            let parts = context.ownerID.components(separatedBy: "\u{0}")
            return .init(ownerID: context.ownerID, sessionID: parts.first, machineID: parts.count > 1 ? parts[1] : "")
        }, resolveSession: { try browserSessions.find($0) }, resolveProfile: { _, _ in .init(id: "default", name: "Default", partition: "default") },
            resolveCreationProfile: { _, _ in .init(id: "default", name: "Default", partition: "default") }, authorize: { _ in }, publish: { _, _, _ in }, reportEventFailure: { XCTFail($0.message) })
        let native = BackendNativeMCPServer()
        try await BackendBrowserFactories.registerTools(native, service: browser, context: { _ in throw BackendDeckToolsSupport.unavailable("Unused collecting endpoint") })
        var specs = try await native.catalogue().filter { BrowserDriverVerb.allCases.map(\.rawValue).contains($0.wireName) }
        if includeNetwork { specs += try BackendBrowserScrapingMCP.tools().filter { $0.id == "browser.network" } }
        self.specs = specs
        let browser: BackendBrowserService = self.browser
        let metadata = specs.map { BackendDeckCoreCatalogueMetadata(tool: $0, title: $0.id, index: $0.id == "browser.network" ? "Capture the page's network responses." : nil) }
        let describe = try BackendDeckCoreCatalogueDescribe.tools(catalogue: { metadata })
        let policies = try specs.map { spec -> BackendDeckCoreSecurityToolPolicy in
            if let verb = BrowserDriverVerb(rawValue: spec.wireName) {
                return .init(tool: spec, summary: { _, _ in spec.id }, run: { args, context in
                    let owner = (context.caller.sessionID ?? "") + "\u{0}" + (context.caller.machineID ?? "")
                    let value = try await browser.drive(.init(caller: .internalEngine, ownerID: owner), verb: verb, arguments: args)
                    return .init(value: value)
                })
            }
            return .init(tool: spec, summary: { _, _ in spec.id }, run: { _, _ in throw BackendDeckToolsSupport.unavailable("Capture is not exercised by this grant fixture") })
        }
        let log = BackendDeckCoreSecurityActionLog(directory: root, now: { 10_000 })
        let consent = BackendDeckCoreSecurityConsentBroker(clock: clock, ask: { _ in XCTFail("Only private-browser actions occur here"); return false })
        control = try .init(log: log, consent: consent, policies: policies + describe.policies, now: { 10_000 })
        let allMetadata = metadata + describe.metadata
        server = .init(control: control, ownPorts: .init(), listenerFactory: { BackendDeckCoreTestPortSecurityListener(handler: $0) }, listing: { _, caller, granted in
            try BackendDeckCoreCatalogueDescribe.wireListing(metadata: allMetadata, caller: caller, granted: granted)
        })
        endpoint = .init(server: server, control: control)
        live = try await server.start()
    }
    func attach(tab: String = "browser:1", session: String = "s1", machine: String = "") throws {
        browserSessions.note(session, machine: machine)
        bindings.observe(.init(tabID: tab, viewID: tab, url: "http://localhost:3000/", title: "Dev"))
        _ = try bindings.attach(tab, to: .init(sessionId: session, machineId: machine))
    }
    func registerOrdinary(session: String = "s1", machine: String = "") async throws -> (String, BackendMCPRegistration) {
        let token = String(repeating: "a", count: 64)
        let grant = BackendMCPCallerGrant(attended: true, allowedTools: BackendDeckToolsSessionsGrants.ordinary, allowedTiers: [.read, .act, .alter])
        let registration = try await endpoint.register(token: token, grant: grant); try await endpoint.bind(registration, sessionID: session, machineID: machine)
        return (token, registration)
    }
    func exchange(token: String, method: String, params: NativeRPCValue = .object([])) async throws -> (status: Int, value: NativeRPCValue) {
        let body = try V.object([("jsonrpc", .string("2.0")), ("id", .number(1)), ("method", .string(method)), ("params", params)]).encodedJSON()
        let response = await server.respond(.init(method: "POST", path: "/mcp", headers: ["host": "127.0.0.1:\(live?.port ?? 47821)", "authorization": "Bearer " + token,
            "content-type": "application/json", "accept": "application/json, text/event-stream"], body: body))
        return (response.status, try NativeRPCValue.parseJSON(response.body))
    }
    func call(token: String, name: String, args: NativeRPCValue = .object([])) async throws -> NativeRPCValue {
        try await exchange(token: token, method: "tools/call", params: V.object([("name", .string(name)), ("arguments", args)])).value["result"]
    }
    func close() async { await endpoint.revokeAll(); await server.stop(); await browser.shutdown(); try? FileManager.default.removeItem(at: root) }
}

final class BackendDeckToolsSessionsPortBrowserSessionTable: @unchecked Sendable {
    private let lock = NSLock(); private var machines: [String: String] = ["s1": ""]
    func note(_ id: String, machine: String) { lock.withLock { machines[id] = machine } }
    func find(_ id: String) throws -> BrowserDriverSession {
        guard let machine = lock.withLock({ machines[id] }) else { throw BackendSessionFailure.missingSession }
        return .init(sessionId: id, machineId: machine)
    }
}

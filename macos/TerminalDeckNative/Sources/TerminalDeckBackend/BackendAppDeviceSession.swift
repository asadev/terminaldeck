import Foundation
import TerminalDeckNativeCore

public protocol BackendAppDeviceSessionServing: AnyObject, Sendable {
    var events: AsyncStream<BackendAppDeviceSessionEvent> { get }
    func info() async -> NativeRPCValue?
    func screenConfiguration() async -> Data?
    func isOpen() async -> Bool
    func open() async throws -> NativeRPCValue
    func setPreview(_ on: Bool) async throws
    func tap(x: Double, y: Double, holdMilliseconds: Double?) async throws
    func touch(phase: String, x: Double, y: Double) async throws
    func swipe(from: NativeRPCValue, to: NativeRPCValue, durationMilliseconds: Double) async throws
    func type(_ text: String) async throws
    func key(_ key: String, modifiers: [String]) async throws
    func button(_ button: String) async throws
    func rotate(to: String?) async throws -> String
    func screenshot() async throws -> BackendAppDeviceScreenshot
    func foreground() async throws -> NativeRPCValue
    func elementAt(x: Double, y: Double) async throws -> NativeRPCValue?
    func tree(scope: String) async throws -> NativeRPCValue
    func close() async
}

public enum BackendAppDeviceSessionEvent: Sendable { case screen(Data), closed(String) }
public actor BackendAppDeviceSession: BackendAppDeviceSessionServing {
    public nonisolated let id: String
    public nonisolated let events: AsyncStream<BackendAppDeviceSessionEvent>
    private let emit: AsyncStream<BackendAppDeviceSessionEvent>.Continuation
    private let engine: BackendAppDeviceEngine
    private let environment: [String: String]
    private let home: String
    private let clock: any BackendAppSessionClock
    private let executor: any BackendAppSessionCommandExecuting
    private let factory: @Sendable (BackendAppDeviceEngine, String) async throws -> BackendAppDeviceCoreClient
    private var client: BackendAppDeviceCoreClient?
    private var opening: Task<NativeRPCValue, any Error>?
    private var details: NativeRPCValue?
    private var loop: Task<Void, Never>?
    private var previewing = false
    private var lastConfig: Data?
    private var orientation = "portrait"
    private var xctestTried = false
    private var frameCount: UInt64 = 0
    private var firstFrameTimer: Task<Void, Never>?
    public init(engine: BackendAppDeviceEngine, id: String, environment: [String: String], home: String,
                executor: any BackendAppSessionCommandExecuting = BackendAppSessionCommandExecutor(),
                clock: any BackendAppSessionClock = BackendAppSessionSystemClock(),
                factory: (@Sendable (BackendAppDeviceEngine, String) async throws -> BackendAppDeviceCoreClient)? = nil) {
        self.engine = engine; self.id = id; self.environment = environment; self.home = home; self.executor = executor; self.clock = clock
        self.factory = factory ?? { engine, id in try await BackendAppDeviceCoreClient.start(engine: engine, deviceID: id, environment: environment, codec: "h264", maxFrameRate: 60, clock: clock) }
        var sink: AsyncStream<BackendAppDeviceSessionEvent>.Continuation!
        events = AsyncStream { sink = $0 }; emit = sink
    }
    public func info() -> NativeRPCValue? { details }
    public func screenConfiguration() -> Data? { lastConfig }
    public func isOpen() async -> Bool { guard let client else { return false }; return !(await client.isClosed()) }
    public func open() async throws -> NativeRPCValue {
        if await isOpen(), let details { return details }
        if let opening { return try await opening.value }
        let work = Task { try await self.start() }; opening = work
        defer { opening = nil }; return try await work.value
    }
    private func start() async throws -> NativeRPCValue {
        var lastError: any Error = BackendAppSessionError("The device could not be opened.")
        for attempt in 0..<3 {
            try Task.checkCancellation()
            var proposed: BackendAppDeviceCoreClient?
            do {
                let current = try await factory(engine, id); proposed = current
                let started = try await current.request("capture.start")
                try Task.checkCancellation()
                adopt(current, device: started["device"])
                return details!
            } catch {
                lastError = error; await proposed?.close()
                if let error = error as? BackendAppDeviceEngineError, !error.recoverable { break }
                try await clock.sleep(milliseconds: 1_000 * (attempt + 1))
            }
        }
        throw BackendAppSessionError(lastError.localizedDescription)
    }
    private func adopt(_ client: BackendAppDeviceCoreClient, device: NativeRPCValue) {
        self.client = client
        let caps = device["capabilities"], input = caps["input"]
        details = BackendAppDeviceParsing.object([("id", .string(id)), ("name", .string(device["name"].string ?? id)),
            ("platform", .string(device["platform"].string == "android" ? "android" : "ios")), ("kind", .string(device["kind"].string ?? "")),
            ("pointWidth", .number(BackendAppDeviceParsing.number(device["pointWidth"]))), ("pointHeight", .number(BackendAppDeviceParsing.number(device["pointHeight"]))),
            ("buttons", .array(BackendAppDeviceParsing.strings(input["buttons"]).map(NativeRPCValue.string))), ("keys", .array(BackendAppDeviceParsing.strings(input["keys"]).map(NativeRPCValue.string))),
            ("text", .string(input["text"].string ?? "none")), ("canRotate", .bool(caps["orientation"].bool == true)), ("rawTouch", .bool(input["rawTouch"].bool == true))])
        loop?.cancel()
        let events = client.events
        loop = Task { [weak self] in for await event in events { guard let self else { return }; await self.received(event) } }
    }
    private func received(_ event: BackendAppDeviceClientEvent) {
        switch event {
        case .config(let payload): var packet = Data([0x10]); packet.append(payload); lastConfig = packet; emit.yield(.screen(packet))
        case .picture(let payload): var packet = Data([0x11]); packet.append(payload); frameCount &+= 1; emit.yield(.screen(packet))
        case .jpeg: break
        case .closed(let reason): client = nil; previewing = false; lastConfig = nil; emit.yield(.closed(reason))
        }
    }
    private func engineOrOpen() async throws -> BackendAppDeviceCoreClient {
        if let client, !(await client.isClosed()) { return client }
        _ = try await open()
        guard let client else { throw BackendAppSessionError("The device is not open.") }; return client
    }
    public func setPreview(_ on: Bool) async throws {
        let client = try await engineOrOpen()
        if on != previewing { _ = try await client.request("capture.preview", params: BackendAppDeviceParsing.object([("enabled", .bool(on))])); previewing = on }
        if on {
            _ = try? await client.request("capture.keyframe")
            firstFrameTimer?.cancel(); let before = frameCount
            firstFrameTimer = Task { [weak self, clock] in
                do { try await clock.sleep(milliseconds: 1_200) } catch { return }
                await self?.firstFrame(before: before)
            }
        }
    }
    private func firstFrame(before: UInt64) async {
        firstFrameTimer = nil
        guard previewing, frameCount == before, let shot = try? await screenshot(), previewing, frameCount == before else { return }
        var packet = Data([0x20]); packet.append(shot.png); frameCount &+= 1; emit.yield(.screen(packet))
    }
    public func input(_ method: String, params: NativeRPCValue) async throws { let current = try await engineOrOpen(); _ = try await current.request(method, params: params) }
    public func tap(x: Double, y: Double, holdMilliseconds: Double? = nil) async throws {
        var params = BackendAppDeviceParsing.object([("x", .number(x)), ("y", .number(y))])
        let long = (holdMilliseconds ?? 0) >= 400
        if long { params = params.setting("durationMs", .number(holdMilliseconds!)) }
        try await input(long ? "input.longPress" : "input.tap", params: params)
    }
    public func touch(phase: String, x: Double, y: Double) async throws {
        try await input("input.touch", params: BackendAppDeviceParsing.object([("contactId", .number(0)), ("phase", .string(phase)), ("x", .number(x)), ("y", .number(y))]))
    }
    public func swipe(from: NativeRPCValue, to: NativeRPCValue, durationMilliseconds: Double = 300) async throws {
        try await input("input.swipe", params: BackendAppDeviceParsing.object([("from", from), ("to", to), ("durationMs", .number(durationMilliseconds))]))
    }
    public func type(_ text: String) async throws { if !text.isEmpty { try await input("input.typeText", params: BackendAppDeviceParsing.object([("text", .string(text))])) } }
    public func key(_ key: String, modifiers: [String] = []) async throws {
        var params = BackendAppDeviceParsing.object([("key", .string(key))])
        if !modifiers.isEmpty { params = params.setting("modifiers", .array(modifiers.map(NativeRPCValue.string))) }
        try await input("input.key", params: params)
    }
    public func button(_ button: String) async throws { try await input("input.button", params: BackendAppDeviceParsing.object([("button", .string(button))])) }
    public func rotate(to: String? = nil) async throws -> String {
        let next = to ?? (orientation == "portrait" ? "landscape-left" : "portrait")
        let current = try await engineOrOpen(); _ = try await current.request("device.orientation.set", params: BackendAppDeviceParsing.object([("orientation", .string(next))]))
        orientation = next; return next
    }
    public func screenshot() async throws -> BackendAppDeviceScreenshot { try await engineOrOpen().screenshot() }
    public func foreground() async throws -> NativeRPCValue {
        let current = try await engineOrOpen()
        if details?["platform"].string == "android" {
            let context = (try? await current.request("device.context")) ?? .object([])
            func pick(_ names: [String]) -> String { names.compactMap { context[$0].string }.first { !$0.isEmpty } ?? "" }
            return BackendAppDeviceParsing.object([("app", .string(pick(["package", "packageName"]))), ("screen", .string(pick(["activity", "activityName"])))])
        }
        let target = (try? await current.request("probe.target")) ?? .object([])
        return BackendAppDeviceParsing.object([("app", .string(target["bundleId"].string ?? "")), ("screen", .string(""))])
    }
    public func elementAt(x: Double, y: Double) async throws -> NativeRPCValue? {
        let current = try await engineOrOpen()
        let raw = (try? await current.request("accessibility.elementAtPoint", params: BackendAppDeviceParsing.object([("x", .number(x)), ("y", .number(y))]))) ?? .null
        return BackendAppDeviceParsing.readNode(raw)
    }
    private func metroIsRunning() async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral; configuration.timeoutIntervalForRequest = 0.4; configuration.timeoutIntervalForResource = 0.4
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        guard let (data, _) = try? await session.data(from: URL(string: "http://localhost:8081/status")!) else { return false }
        return String(decoding: data, as: UTF8.self).contains("packager-status:running")
    }
    private func reactNativeTree(scope: String) async -> (tree: NativeRPCValue?, screen: String, reason: String) {
        guard FileManager.default.fileExists(atPath: engine.cli) else { return (nil, "", "") }
        let out = await executor.run(engine.cli, arguments: ["tree", "--json", "--scope", scope, "--device-id", id], environment: environment.merging(engine.environment) { _, new in new }, cwd: home, timeoutMilliseconds: 45_000, maximumBytes: 16 * 1024 * 1024)
        guard out.ok, let raw = try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8)), let parsed = try? NativeRPCValue.fromFoundation(raw) else { return (nil, "", "The React Native tree could not be read.") }
        guard let tree = BackendAppDeviceParsing.snapshot(parsed["snapshot"]), tree["source"].string == "react-native-fiber" else { return (nil, "", parsed["fallback"]["detail"].string ?? "") }
        let context = parsed["screenContext"]
        return (tree, context["route"].string ?? context["screenComponent"].string ?? "", "")
    }
    private func ask(_ client: BackendAppDeviceCoreClient, scope: String) async -> (tree: NativeRPCValue?, degraded: Bool, error: String) {
        do {
            let raw = try await client.request("accessibility.snapshot", params: BackendAppDeviceParsing.object([("scope", .string(scope)), ("maxNodes", .number(1500))]))
            let tree = BackendAppDeviceParsing.snapshot(raw)
            return (tree, raw["stats"]["quality"].string == "degraded" || BackendAppDeviceParsing.number(tree?["nodeCount"] ?? .null) <= 1, "")
        } catch { return (nil, true, error.localizedDescription) }
    }
    public func tree(scope: String = "visible") async throws -> NativeRPCValue {
        let current = try await engineOrOpen(), foreground = try await foreground()
        var fallback = ""
        if await metroIsRunning() {
            let rn = await reactNativeTree(scope: scope)
            if let tree = rn.tree { return BackendAppDeviceParsing.object([("tree", tree), ("foreground", rn.screen.isEmpty ? foreground : foreground.setting("screen", .string(rn.screen))), ("fallback", .string(""))]) }
            fallback = rn.reason
        }
        var answer = await ask(current, scope: scope)
        if answer.tree == nil { try await clock.sleep(milliseconds: 1_000); answer = await ask(current, scope: scope) }
        if answer.degraded, details?["platform"].string == "ios", !xctestTried {
            xctestTried = true
            if (try? await current.request("accessibility.enableXCTestProvider")) != nil {
                let second = await ask(current, scope: scope); if second.tree != nil { answer = second }
            }
        }
        guard let tree = answer.tree else { throw BackendAppSessionError(answer.error.isEmpty ? "This screen did not describe itself." : answer.error) }
        return BackendAppDeviceParsing.object([("tree", tree), ("foreground", foreground), ("fallback", .string(fallback))])
    }
    public func close() async {
        opening?.cancel(); opening = nil
        let current = client; client = nil; previewing = false; lastConfig = nil
        firstFrameTimer?.cancel(); firstFrameTimer = nil
        await current?.close(); loop?.cancel(); loop = nil
    }
}

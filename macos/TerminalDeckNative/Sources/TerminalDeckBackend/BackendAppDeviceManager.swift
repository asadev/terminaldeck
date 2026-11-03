import Foundation
import TerminalDeckNativeCore

public struct BackendAppDeviceViewer: Sendable {
    public let id: String
    public let send: @Sendable (String, [NativeRPCValue]) -> Void
    public let isDestroyed: @Sendable () -> Bool
    public init(id: String, send: @escaping @Sendable (String, [NativeRPCValue]) -> Void, isDestroyed: @escaping @Sendable () -> Bool) {
        self.id = id; self.send = send; self.isDestroyed = isDestroyed
    }
}
public enum BackendAppDeviceWatchMode: Sendable, Equatable { case on, off, paused }
public enum BackendAppDeviceManagerEvent: Sendable { case closed(id: String, reason: String), round(NativeRPCValue) }
public actor BackendAppDeviceManager {
    public nonisolated let events: AsyncStream<BackendAppDeviceManagerEvent>
    private let emit: AsyncStream<BackendAppDeviceManagerEvent>.Continuation
    private let locate: @Sendable () -> BackendAppDeviceEngineAnswer
    private let platform: BackendAppDevicePlatform
    private let clock: any BackendAppSessionClock
    private let writeImage: @Sendable (URL, Data) throws -> Void
    private let eventObserved: @Sendable (String, BackendAppDeviceSessionEvent) -> Void
    private let picturesDirectory: @Sendable () -> URL
    private let makeSession: @Sendable (BackendAppDeviceEngine, String) -> any BackendAppDeviceSessionServing
    private let sources: BackendAppDeviceInventorySources?
    private var engineAnswer: BackendAppDeviceEngineAnswer?
    private var inventory: BackendAppDeviceInventory?
    private var lastListed: [String: NativeRPCValue] = [:]
    private var sessions: [String: any BackendAppDeviceSessionServing] = [:]
    private var loops: [String: Task<Void, Never>] = [:]
    private struct Watch: Sendable { let viewer: BackendAppDeviceViewer; var paused: Bool }
    private var watches: [String: [String: Watch]] = [:]
    private var windows: [String: BackendAppDeviceViewer] = [:]
    private var idle: [String: Task<Void, Never>] = [:]
    private var busyWatches: Set<String> = []
    private var watchQueue: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var keptRounds: [NativeRPCValue] = []
    public init(locate: @escaping @Sendable () -> BackendAppDeviceEngineAnswer, platform: BackendAppDevicePlatform,
                picturesDirectory: @escaping @Sendable () -> URL, clock: any BackendAppSessionClock = BackendAppSessionSystemClock(),
                writeImage: (@Sendable (URL, Data) throws -> Void)? = nil,
                eventObserved: @escaping @Sendable (String, BackendAppDeviceSessionEvent) -> Void = { _, _ in }, sources: BackendAppDeviceInventorySources? = nil,
                makeSession: (@Sendable (BackendAppDeviceEngine, String) -> any BackendAppDeviceSessionServing)? = nil) {
        self.locate = locate; self.platform = platform; self.picturesDirectory = picturesDirectory; self.sources = sources; self.clock = clock; self.eventObserved = eventObserved
        self.writeImage = writeImage ?? { file, bytes in
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
        }
        self.makeSession = makeSession ?? { engine, id in BackendAppDeviceSession(engine: engine, id: id, platform: platform, clock: clock) }
        var sink: AsyncStream<BackendAppDeviceManagerEvent>.Continuation!
        events = AsyncStream { sink = $0 }; emit = sink
    }
    public func engine() -> BackendAppDeviceEngineAnswer {
        if let engineAnswer { return engineAnswer }; let answer = locate(); engineAnswer = answer; return answer
    }
    public func unavailable() -> String? { if case .unavailable(let reason) = engine() { return reason }; return nil }
    private func requireEngine() throws -> BackendAppDeviceEngine {
        switch engine() { case .available(let engine): return engine; case .unavailable(let reason): throw BackendAppSessionError(reason) }
    }
    private func inventoryFor(_ engine: BackendAppDeviceEngine) -> BackendAppDeviceInventory {
        if let inventory { return inventory }; let made = BackendAppDeviceInventory(sources: sources ?? platform.sources(engine: engine), clock: clock); inventory = made; return made
    }
    public func registerInterest(_ viewer: BackendAppDeviceViewer) { windows[viewer.id] = viewer }
    public func list() async -> NativeRPCValue {
        switch engine() {
        case .unavailable(let reason): return BackendAppDeviceParsing.object([("available", .bool(false)), ("reason", .string(reason)), ("devices", .array([]))])
        case .available(let engine):
            let rows = await inventoryFor(engine).list()
            let current = Dictionary(rows.compactMap { row in row["id"].string.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
            let gone = Set(lastListed.compactMap { id, row -> String? in
                if current[id] == nil {
                    if id.hasPrefix("avd:"), rows.contains(where: { $0["avd"].string == String(id.dropFirst(4)) }) { return nil }
                    return id
                }
                if ["ready", "booting"].contains(row["state"].string ?? ""), current[id]?["state"].string == "shutdown" { return id }
                return nil
            })
            lastListed = current
            if !gone.isEmpty { await BackendAppDeviceLifecycle.shared.exited(gone) }
            return BackendAppDeviceParsing.object([("available", .bool(true)), ("reason", .string("")), ("devices", .array(rows))])
        }
    }
    /// Why the list is empty, in plain words from what is on this Mac; nil while something is listed or there is no engine.
    public func emptyReason() async -> String? {
        guard case .available(let engine) = engine() else { return nil }
        let inventory = inventoryFor(engine)
        return await platform.diagnosis(engineAnswered: await inventory.engineAnswered).sentence(home: platform.home)
    }
    public func boot(_ id: String) async throws -> NativeRPCValue {
        let engine = try requireEngine(), result = await platform.boot(id); await inventoryFor(engine).forgetPending(); return result
    }
    public func shutDown(_ id: String) async throws -> NativeRPCValue {
        let engine = try requireEngine(); await closeSession(id); let result = await platform.shutDown(id); await inventoryFor(engine).forgetPending()
        if result["ok"].bool == true { await BackendAppDeviceLifecycle.shared.exited([id]) }
        return result
    }
    // #108 (L6-SIMMENU): the Simulators menu's management actions, through this one manager.
    public func deviceFolder(_ id: String) async throws -> URL {
        try await BackendFIXESDeviceManagement(platform: platform).folder(id, rows: await list()["devices"].elements ?? [])
    }
    public func manageDevice(_ action: BackendFIXESDeviceManagement.Action, id: String, name: String? = nil, confirmed: Bool = false) async throws -> NativeRPCValue {
        let engine = try requireEngine()
        let rows = await inventoryFor(engine).list()
        guard rows.contains(where: { $0["id"].string == id && ["simulator", "emulator"].contains($0["kind"].string ?? "") }) else {
            throw NativeRPCError(code: "device-refused", message: "That simulator is no longer listed. Refresh devices and try again.")
        }
        if action == .reset || action == .delete {
            guard confirmed else { throw NativeRPCError(code: "device-refused", message: "Confirm changing this device first.") }
        }
        if action != .rename { await closeSession(id) }
        let answer = try await BackendFIXESDeviceManagement(platform: platform).perform(action, id: id, name: name, confirmed: confirmed, rows: rows)
        await inventoryFor(engine).forgetPending()
        if action == .delete, answer["ok"].bool == true { await BackendAppDeviceLifecycle.shared.exited([id]) }
        return answer
    }
    public func presentDevice(_ id: String, destination: String, sessionID: String? = nil) async throws -> NativeRPCValue {
        guard ["tab", "window", "beside", "finder"].contains(destination) else {
            throw NativeRPCError(code: "device-refused", message: "Show a simulator in a new tab, a new window or beside a session.")
        }
        let rows = await list()["devices"].elements ?? []
        guard let row = rows.first(where: { $0["id"].string == id }) else {
            throw NativeRPCError(code: "device-refused", message: "That simulator is no longer listed. Refresh devices and try again.")
        }
        try await BackendFIXESDevicePresenter.shared.show(row, destination: destination, sessionID: sessionID)
        return .object([.init("ok", .bool(true)), .init("id", .string(id)), .init("shown", .string(destination))])
    }
    private func session(_ id: String) async throws -> any BackendAppDeviceSessionServing {
        let engine = try requireEngine(), session: any BackendAppDeviceSessionServing
        if let existing = sessions[id] { session = existing }
        else {
            session = makeSession(engine, id); sessions[id] = session
            let stream = session.events
            loops[id] = Task { [weak self, session] in
                for await event in stream { guard let self else { return }; await self.received(event, id: id, session: session) }
            }
        }
        _ = try await session.open(); touchIdle(id); return session
    }
    private func received(_ event: BackendAppDeviceSessionEvent, id: String, session: any BackendAppDeviceSessionServing) async {
        guard sessions[id] === session else { return }
        defer { eventObserved(id, event) }
        switch event {
        case .screen(let packet):
            for watch in (watches[id] ?? [:]).values where !watch.paused && !watch.viewer.isDestroyed() {
                watch.viewer.send("devices:frame", [.string(id), .bytes(packet)])
            }
        case .closed(let reason):
            watches[id] = nil; sessions[id] = nil; idle.removeValue(forKey: id)?.cancel()
            loops.removeValue(forKey: id)?.cancel()
            for viewer in windows.values where !viewer.isDestroyed() { viewer.send("devices:closed", [.string(id), .string(reason)]) }
            emit.yield(.closed(id: id, reason: reason))
            // A picture stream ending is not itself a device exit.
            if case .available(let engine) = engine() {
                let inventory = inventoryFor(engine); await inventory.forgetPending()
                let row = await inventory.list().first { $0["id"].string == id }
                if row == nil || row?["state"].string == "shutdown" { await BackendAppDeviceLifecycle.shared.exited([id]) }
            }
        }
    }
    public func open(_ id: String) async throws -> NativeRPCValue {
        let session = try await self.session(id)
        guard let info = await session.info() else { throw BackendAppSessionError("The device is not open.") }; return info
    }
    private func acquireWatch(_ id: String) async {
        if busyWatches.insert(id).inserted { return }
        await withCheckedContinuation { watchQueue[id, default: []].append($0) }
    }
    private func releaseWatch(_ id: String) {
        if var queue = watchQueue[id], !queue.isEmpty {
            let first = queue.removeFirst(); watchQueue[id] = queue.isEmpty ? nil : queue; first.resume()
        } else { busyWatches.remove(id) }
    }
    /// How long one watch change may hold its device's turn (an open fits inside it).
    public static let watchWithin: Double = BackendAppDeviceSession.openWithin + 30
    public func watch(_ viewer: BackendAppDeviceViewer, id: String, mode: BackendAppDeviceWatchMode) async throws {
        await acquireWatch(id); defer { releaseWatch(id) }
        // Turning a watch off is clean-up (a closed panel or window): it always runs, its own steps bounded.
        if mode == .off { try await changeWatch(viewer, id: id, mode: mode); return }
        // Devices freeze (26 Oct): the turn is always given back, by the deadline at the latest, and a caller that
        // gave up while it queued does not act late.
        try Task.checkCancellation()
        try await BackendAppDeviceDeadline.run(within: Self.watchWithin, "The device's picture stream") {
            try await self.changeWatch(viewer, id: id, mode: mode)
        }
    }
    private func changeWatch(_ viewer: BackendAppDeviceViewer, id: String, mode: BackendAppDeviceWatchMode) async throws {
        var viewers = watches[id] ?? [:]
        switch mode {
        case .off:
            viewers[viewer.id] = nil; watches[id] = viewers.isEmpty ? nil : viewers
            if viewers.isEmpty {
                if let current = sessions[id], await current.isOpen() { try? await current.setPreview(false) }; touchIdle(id)
            } else if viewers.values.allSatisfy(\.paused), let current = sessions[id], await current.isOpen() { try? await current.setPreview(false) }
        case .paused, .on:
            let current = try await session(id)
            // Past its deadline the next watch has the turn: a late one writes nothing. The viewers are read again
            // after the open, so a change made meanwhile is kept.
            try Task.checkCancellation()
            let paused = mode == .paused
            viewers = watches[id] ?? [:]
            viewers[viewer.id] = Watch(viewer: viewer, paused: paused); watches[id] = viewers
            if paused {
                if viewers.values.allSatisfy(\.paused) { try await current.setPreview(false) }
            } else {
                if let config = await current.screenConfiguration(), !viewer.isDestroyed() { viewer.send("devices:frame", [.string(id), .bytes(config)]) }
                try Task.checkCancellation() // a late watch does not turn the stream on
                try await current.setPreview(true)
            }
        }
    }
    public func forgetViewer(_ viewerID: String) async {
        windows[viewerID] = nil
        let viewer = BackendAppDeviceViewer(id: viewerID, send: { _, _ in }, isDestroyed: { true })
        let deviceIDs = watches.keys.filter { watches[$0]?[viewerID] != nil }
        for id in deviceIDs { try? await watch(viewer, id: id, mode: .off) }
    }
    private func touchIdle(_ id: String) {
        idle[id]?.cancel()
        idle[id] = Task { [weak self, clock] in
            do { try await clock.sleep(milliseconds: 60_000) } catch { return }
            await self?.idleElapsed(id)
        }
    }
    private func idleElapsed(_ id: String) async {
        idle[id] = nil
        if (watches[id]?.count ?? 0) == 0 { await closeSession(id) }
    }
    private func closeSession(_ id: String) async {
        let current = sessions.removeValue(forKey: id); loops.removeValue(forKey: id)?.cancel(); idle.removeValue(forKey: id)?.cancel()
        await current?.close()
    }
    private func inputSession(_ id: String) async throws -> any BackendAppDeviceSessionServing {
        if let current = sessions[id], await current.isOpen() { touchIdle(id); return current }
        return try await session(id)
    }
    public func tap(_ id: String, x: Double, y: Double, holdMS: Int? = nil) async throws { try await inputSession(id).tap(x: x, y: y, holdMilliseconds: holdMS.map(Double.init)) }
    public func tap(_ id: String, x: Double, y: Double, holdMilliseconds: Double?) async throws { try await inputSession(id).tap(x: x, y: y, holdMilliseconds: holdMilliseconds) }
    public func touch(_ id: String, phase: String, x: Double, y: Double) async throws { try await inputSession(id).touch(phase: phase, x: x, y: y) }
    public func swipe(_ id: String, from: NativeRPCValue, to: NativeRPCValue, durationMS: Int = 300) async throws { try await inputSession(id).swipe(from: from, to: to, durationMilliseconds: Double(durationMS)) }
    public func swipe(_ id: String, from: NativeRPCValue, to: NativeRPCValue, durationMilliseconds: Double) async throws { try await inputSession(id).swipe(from: from, to: to, durationMilliseconds: durationMilliseconds) }
    public func type(_ id: String, text: String) async throws { try await inputSession(id).type(text) }
    public func key(_ id: String, key: String, modifiers: [String] = []) async throws { try await inputSession(id).key(key, modifiers: modifiers) }
    public func button(_ id: String, button: String) async throws { try await inputSession(id).button(button) }
    public func rotate(_ id: String, to: String? = nil) async throws -> String { try await session(id).rotate(to: to) }
    public func tree(_ id: String, scope: String = "visible") async throws -> NativeRPCValue { try await session(id).tree(scope: scope) }
    public func foreground(_ id: String) async throws -> NativeRPCValue { try await session(id).foreground() }
    public func elementAt(_ id: String, x: Double, y: Double) async throws -> NativeRPCValue? { try await session(id).elementAt(x: x, y: y) }
    public func capture(_ id: String) async throws -> BackendAppDeviceScreenshot { try await session(id).screenshot() }
    public struct Shot: Sendable {
        public let path: String
        public let shot: BackendAppDeviceScreenshot
        public var wireValue: NativeRPCValue { BackendAppDeviceParsing.object([("path", .string(path)), ("width", .number(shot.width)), ("height", .number(shot.height))]) }
    }
    public func screenshot(_ id: String) async throws -> Shot {
        let shot = try await capture(id), info = await sessions[id]?.info()
        let path = try writePicture(shot.png, name: info?["name"].string ?? id, suffix: "")
        return .init(path: path, shot: shot)
    }
    private func writePicture(_ png: Data, name: String, suffix: String) throws -> String {
        let root = picturesDirectory()
        let file = root.appendingPathComponent(Self.pictureName(name, now: clock.now()) + suffix + ".png")
        try writeImage(file, png); return file.path
    }
    public func freeze(_ id: String) async throws -> NativeRPCValue {
        let shot = try await capture(id)
        var answer: NativeRPCValue = .null, error = ""
        do { answer = try await tree(id) } catch let failure { error = failure.localizedDescription }
        let info = try await open(id)
        var place = BackendAppDeviceParsing.object([("kind", .string("device")), ("place", .string(Self.place(platform: info["platform"].string ?? "ios", kind: info["kind"].string ?? "simulator"))), ("name", info["name"]), ("deviceId", .string(id))])
        for key in ["app", "screen"] { if let text = answer["foreground"][key].string, !text.isEmpty { place = place.setting(key, .string(text)) } }
        return BackendAppDeviceParsing.object([("image", .string("data:image/png;base64," + shot.png.base64EncodedString())), ("width", .number(shot.width)), ("height", .number(shot.height)),
            ("tree", answer["tree"].isNullish ? .null : answer["tree"]), ("treeError", .string(error)), ("where", place)])
    }
    public func saveRound(png: NativeRPCValue, round: NativeRPCValue) throws -> NativeRPCValue {
        guard let image = BackendSharedMarkedImage.decodePngDataUrl(png) else { throw BackendAppSessionError("That picture could not be read, so nothing was saved.") }
        let name = round["where"]["name"].string.flatMap { $0.isEmpty ? nil : $0 } ?? round["where"]["place"].string ?? ""
        let path = try writePicture(image.bytes, name: name, suffix: "-annotated")
        let picture = BackendAppDeviceParsing.object([("path", .string(path)), ("width", .number(Double(image.width))), ("height", .number(Double(image.height)))])
        remember(round.setting("picture", picture)); return picture
    }
    public func markSent(_ roundID: String, sessionID: String, label: String) {
        guard let round = keptRounds.first(where: { $0["id"].string == roundID }) else { return }
        remember(round.setting("sentTo", BackendAppDeviceParsing.object([("sessionId", .string(sessionID)), ("label", .string(label)), ("at", .number(clock.now().timeIntervalSince1970 * 1000))])))
    }
    private func remember(_ round: NativeRPCValue) {
        keptRounds.removeAll { $0["id"].string == round["id"].string }; keptRounds.insert(round, at: 0)
        if keptRounds.count > 20 { keptRounds.removeLast(keptRounds.count - 20) }; emit.yield(.round(round))
    }
    public func annotationRounds() -> [NativeRPCValue] { keptRounds }
    public func closeAll() async {
        let ids = Array(sessions.keys)
        for id in ids { await closeSession(id) }
        watches.removeAll(); windows.removeAll()
    }
    public nonisolated static func place(platform: String, kind: String) -> String {
        platform == "android" ? (kind == "physical" ? "Android phone" : "Android emulator") : "iOS Simulator"
    }
    public nonisolated static func pictureName(_ name: String, now: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let stamp = String(format: "%04d%02d%02d-%02d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        let safe = String(name.replacingOccurrences(of: #"[^a-zA-Z0-9.-]+"#, with: "-", options: .regularExpression).replacingOccurrences(of: #"^[.-]+|-+$"#, with: "", options: .regularExpression).prefix(48))
        return (safe.isEmpty ? "device" : safe) + "-" + stamp
    }
}
/// devices/tool-deps.ts: one manager for both page and MCP. Never expose PNG
/// buffers in a tool result; the page's facade retains those for its preview.
public struct BackendAppDeviceToolService: BackendDeckToolsMachinesDeviceService, BackendFIXESDeviceManaging {
    private let manager: BackendAppDeviceManager
    private let direct: BackendAppDeviceDirectInput
    public init(manager: BackendAppDeviceManager, direct: BackendAppDeviceDirectInput = .shared) { self.manager = manager; self.direct = direct }
    /// Input on an iOS Simulator goes the phone panel's way (BackendAppDeviceDirectInput): true when it was
    /// delivered there. The device session opens for every input anyway; its details say what the device is.
    private func directly(_ id: String, _ input: DeviceInput, modifiers: [String] = []) async throws -> Bool {
        guard id.hasPrefix("ios:"), direct.installed else { return false }
        let info = try await manager.open(id)
        guard case .iosSimulator? = DeviceDirectTarget(id: id, platform: info["platform"].string ?? "", kind: info["kind"].string ?? "") else { return false }
        return try await direct.send(id, input, modifiers: modifiers)
    }
    public func unavailable() async -> String? { await manager.unavailable() }
    public func list() async throws -> [NativeRPCValue] { await manager.list()["devices"].elements ?? [] }
    public func emptyReason() async -> String? { await manager.emptyReason() }
    public func boot(_ id: String) async throws -> NativeRPCValue { try await manager.boot(id) }
    public func shutDown(_ id: String) async throws -> NativeRPCValue { try await manager.shutDown(id) }
    public func open(_ id: String) async throws -> NativeRPCValue { try await manager.open(id) }
    public func screenshot(_ id: String) async throws -> NativeRPCValue { try await manager.screenshot(id).wireValue }
    public func tap(_ id: String, x: Double, y: Double, holdMS: Int?) async throws {
        if try await directly(id, .tap(x: x, y: y, holdMs: holdMS.map(Double.init))) { return }
        try await manager.tap(id, x: x, y: y, holdMS: holdMS)
    }
    public func swipe(_ id: String, from: NativeRPCValue, to: NativeRPCValue, durationMS: Int) async throws {
        if let fromX = from["x"].number, let fromY = from["y"].number, let toX = to["x"].number, let toY = to["y"].number,
           try await directly(id, .swipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY, ms: Double(durationMS))) { return }
        try await manager.swipe(id, from: from, to: to, durationMS: durationMS)
    }
    public func type(_ id: String, text: String) async throws {
        if !text.isEmpty, try await directly(id, .type(text)) { return }
        try await manager.type(id, text: text)
    }
    public func key(_ id: String, key: String, modifiers: [String]) async throws {
        if try await directly(id, .key(key), modifiers: modifiers) { return }
        try await manager.key(id, key: key, modifiers: modifiers)
    }
    public func button(_ id: String, button: String) async throws {
        if try await directly(id, .button(button)) { return }
        try await manager.button(id, button: button)
    }
    public func rotate(_ id: String, to: String) async throws -> String { try await manager.rotate(id, to: to) }
    public func tree(_ id: String, scope: String) async throws -> BackendDeckToolsMachinesDeviceTreeAnswer {
        let value = try await manager.tree(id, scope: scope)
        guard let tree = DeviceTree(json: value["tree"].foundation) else { throw BackendAppSessionError("This screen did not describe itself.") }
        return .init(tree: tree, foreground: value["foreground"], fallback: value["fallback"].string ?? "")
    }
    public func rounds() async throws -> [NativeRPCValue] { await manager.annotationRounds() }
    public func deviceFolder(_ id: String) async throws -> URL { try await manager.deviceFolder(id) }
    public func manageDevice(_ action: BackendFIXESDeviceManagement.Action, id: String, name: String?, confirmed: Bool) async throws -> NativeRPCValue {
        try await manager.manageDevice(action, id: id, name: name, confirmed: confirmed)
    }
    public func presentDevice(_ id: String, destination: String, sessionID: String?) async throws -> NativeRPCValue {
        try await manager.presentDevice(id, destination: destination, sessionID: sessionID)
    }
}

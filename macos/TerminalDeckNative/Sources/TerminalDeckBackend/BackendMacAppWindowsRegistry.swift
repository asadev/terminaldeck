import Foundation
import TerminalDeckNativeCore

/// Native view identity replaces Electron's webContents id. It is assigned by
/// app assembly and carried by NativeRPCContext, never accepted from tool args.
@MainActor public protocol BackendMacAppWindowsHandle: AnyObject {
    var windowID: Int { get }
    var ownerID: String { get }
    var bounds: BackendOSPopoutRules.Rect { get }
    var normalBounds: BackendOSPopoutRules.Rect { get }
    var fullScreen: Bool { get }
    var minimized: Bool { get }
    var focused: Bool { get }
    var destroyed: Bool { get }
    var contentDestroyed: Bool { get }
    func title(_ value: String)
    func fullscreen(_ on: Bool)
    func restore()
    func show()
    func focus()
    func close()
    func send(_ channel: String, arguments: [NativeRPCValue])
    func on(_ event: String, callback: @escaping @MainActor () -> Void)
}

@MainActor public protocol BackendMacAppWindowsDependencies: AnyObject {
    func makeWindow(sessionID: String, bounds: BackendOSPopoutRules.Rect, title: String) throws -> any BackendMacAppWindowsHandle
    func displays() throws -> (all: [BackendOSPopoutRules.Display], primary: BackendOSPopoutRules.Display)
    func mainBounds() -> BackendOSPopoutRules.Rect?
    func showMain(command: String?) throws
    func session(_ id: String) -> BackendSessionMeta?
    func refusal(_ id: String) -> String?
    func status(_ id: String) -> String?
    func readPlacements() throws -> NativeRPCValue
    func writePlacements(_ file: NativeRPCValue) throws
    func announce(view: NativeRPCValue, event: NativeRPCValue?)
    func announceReplaced(previousID: String, meta: BackendSessionMeta)
    func schedule(milliseconds: Int, run: @escaping @MainActor () -> Void) -> BackendMacAppWindowsScheduled
    func log(_ message: String, detail: NativeRPCValue)
}

@MainActor public final class BackendMacAppWindowsScheduled {
    private let cancelAction: @MainActor () -> Void
    public init(cancel: @escaping @MainActor () -> Void) { cancelAction = cancel }
    public func cancel() { cancelAction() }
}

/// popout-windows.ts registry. No dependency can create/stop a PTY. Close docks
/// the same session; suspend preserves tab-key placements for later restore.
@MainActor public final class BackendMacAppWindowsRegistry {
    public static let stateChannel = "popout:state"
    public static let invokeChannels = ["popout:open", "popout:dock", "popout:focus", "popout:list", "popout:rekey"]
    public static let sendChannels = ["popout:labels", "popout:show-main"]
    private final class Entry {
        var sessionID: String, key: String?, label: String
        let window: any BackendMacAppWindowsHandle
        var closing: String?, select = false
        init(session: BackendSessionMeta, window: any BackendMacAppWindowsHandle) {
            sessionID = session.id; key = session.tabKey; label = session.title; self.window = window
        }
    }
    private let deps: any BackendMacAppWindowsDependencies
    private var entries: [String: Entry] = [:], order: [String] = []
    private var placements: [BackendOSPopoutRules.Placement]
    private var pendingSave: BackendMacAppWindowsScheduled?, suspended = false
    private var sendSubscriptions: [NativeRPCSubscription] = []
    public init(dependencies: any BackendMacAppWindowsDependencies) {
        deps = dependencies
        placements = BackendOSPopoutRules.readPlacements((try? dependencies.readPlacements()) ?? .null)
    }
    private func o(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendDeckToolsSupport.object(pairs) }
    private func result(_ ok: Bool, _ message: String, _ id: String, window: Int? = nil, display: String? = nil) -> NativeRPCValue {
        var value = o([("ok", .bool(ok)), ("message", .string(message)), ("sessionId", .string(id))])
        if let window { value = value.setting("windowId", .number(Double(window))) }
        if let display { value = value.setting("display", .string(display)) }
        return value
    }
    private var orderedEntries: [Entry] { order.compactMap { entries[$0] } }
    private func remember(_ entry: Entry) {
        guard let key = entry.key, !entry.window.destroyed else { return }
        let bounds = entry.window.fullScreen ? entry.window.normalBounds : entry.window.bounds
        guard let displays = try? deps.displays() else { deps.log("popout: could not read displays", detail: .object([])); return }
        let display = BackendOSPopoutRules.mostlyHolding(bounds, displays: displays.all)
        placements.removeAll { $0.key == key }
        placements.append(.init(key: key, bounds: bounds, displayID: display?.id, fullScreen: entry.window.fullScreen))
        if placements.count > BackendOSPopoutRules.maximumRemembered { placements.removeFirst(placements.count - BackendOSPopoutRules.maximumRemembered) }
    }
    private func write() {
        do { try deps.writePlacements(BackendOSPopoutRules.file(placements)) }
        catch { deps.log("popout: could not write placements", detail: o([("error", .string(error.localizedDescription))])) }
    }
    private func saveSoon(_ entry: Entry) {
        if suspended { return }
        pendingSave?.cancel()
        pendingSave = deps.schedule(milliseconds: BackendOSPopoutRules.saveDelayMilliseconds) { [weak self, weak entry] in
            guard let self else { return }; self.pendingSave = nil
            if let entry, !entry.window.destroyed { self.remember(entry) }
            self.write()
        }
    }
    public func view() throws -> NativeRPCValue {
        let displays = try deps.displays()
        let windows = orderedEntries.filter { !$0.window.destroyed }.map { entry -> NativeRPCValue in
            let window = entry.window, bounds = window.fullScreen ? window.normalBounds : window.bounds
            let display = BackendOSPopoutRules.mostlyHolding(bounds, displays: displays.all)
            return o([("sessionId", .string(entry.sessionID)), ("windowId", .number(Double(window.windowID))), ("label", .string(entry.label)),
                ("status", deps.status(entry.sessionID).map(NativeRPCValue.string) ?? .null), ("displayId", (display?.id).map(NativeRPCValue.number) ?? .null),
                ("displayLabel", .string(display?.label ?? "")), ("bounds", bounds.wireValue), ("fullScreen", .bool(window.fullScreen)),
                ("minimized", .bool(window.minimized)), ("focused", .bool(window.focused))])
        }
        return o([("windows", .array(windows)), ("displays", .array(displays.all.map { display in
            o([("id", .number(display.id)), ("label", .string(display.label)), ("primary", .bool(display.id == displays.primary.id)),
                ("width", .number(display.bounds.width)), ("height", .number(display.bounds.height))])
        }))])
    }
    private func announce(_ event: NativeRPCValue?) {
        do { deps.announce(view: try view(), event: event) }
        catch { deps.log("popout: could not announce windows", detail: o([("error", .string(error.localizedDescription))])) }
    }
    private func attach(_ entry: Entry) {
        entry.window.on("close") { [weak self, weak entry] in
            guard let self, let entry, self.entries[entry.sessionID] === entry else { return }
            self.entries[entry.sessionID] = nil; self.order.removeAll { $0 == entry.sessionID }
            if entry.closing == "suspend" { self.announce(nil); return }
            if let key = entry.key {
                self.placements.removeAll { $0.key == key }; self.pendingSave?.cancel(); self.pendingSave = nil; self.write()
            }
            if entry.closing == "ended" { self.announce(nil); return }
            self.announce(self.o([("kind", .string("docked")), ("sessionId", .string(entry.sessionID)), ("select", .bool(entry.select))]))
            self.deps.log("popout: docked", detail: self.o([("sessionId", .string(entry.sessionID)), ("by", .string(entry.closing ?? "window"))]))
        }
        for event in ["move", "resize"] { entry.window.on(event) { [weak self, weak entry] in if let entry { self?.saveSoon(entry) } } }
        for event in ["enter-full-screen", "leave-full-screen"] {
            entry.window.on(event) { [weak self, weak entry] in if let entry { self?.saveSoon(entry) }; self?.announce(nil) }
        }
        for event in ["focus", "blur"] { entry.window.on(event) { [weak self] in self?.announce(nil) } }
    }
    private func make(_ session: BackendSessionMeta, bounds: BackendOSPopoutRules.Rect, fullScreen: Bool) throws -> Entry {
        let entry = Entry(session: session, window: try deps.makeWindow(sessionID: session.id, bounds: bounds, title: session.title))
        if entries[session.id] == nil { order.append(session.id) }; entries[session.id] = entry
        attach(entry); if fullScreen { entry.window.fullscreen(true) }; return entry
    }
    public func open(_ id: String, at: (x: Double, y: Double)? = nil, displayID: Double? = nil) throws -> NativeRPCValue {
        guard !id.isEmpty else { return result(false, "Which session? No id was given.", "") }
        if let entry = entries[id], !entry.window.destroyed {
            if entry.window.minimized { entry.window.restore() }; entry.window.show(); entry.window.focus()
            let display = BackendOSPopoutRules.mostlyHolding(entry.window.bounds, displays: try deps.displays().all)
            return result(true, "That session already has its own window; it is in front now.", id, window: entry.window.windowID, display: display?.label ?? "")
        }
        guard let session = deps.session(id) else { return result(false, "No session with that id is running on this computer.", id) }
        if let refusal = deps.refusal(id) { return result(false, refusal, id) }
        let displays = try deps.displays()
        let target = displayID.flatMap { wanted in displays.all.first { $0.id == wanted } }
        if displayID != nil && target == nil { return result(false, "There is no display with that id now; windows.list names the ones there are.", id) }
        let placed = BackendOSPopoutRules.new(at: at, target: target, main: deps.mainBounds(), displays: displays.all, primary: displays.primary, open: entries.count)
        suspended = false
        let entry = try make(session, bounds: placed.bounds, fullScreen: false)
        remember(entry); write(); announce(o([("kind", .string("opened")), ("sessionId", .string(id))]))
        deps.log("popout: opened", detail: o([("sessionId", .string(id)), ("display", .string(placed.display.label))]))
        return result(true, "It is in its own window now\(placed.display.label.isEmpty ? "" : ", on " + placed.display.label).", id, window: entry.window.windowID, display: placed.display.label)
    }
    public func dock(_ id: String, select: Bool = true) throws -> NativeRPCValue {
        guard let entry = entries[id], !entry.window.destroyed else { return result(false, "That session is not in a window of its own.", id) }
        entry.closing = "dock"; entry.select = select; entry.window.close()
        if select { try deps.showMain(command: nil) }
        return result(true, "It is back in the main window.", id)
    }
    public func focus(_ id: String) -> NativeRPCValue {
        guard let entry = entries[id], !entry.window.destroyed else { return result(false, "That session is not in a window of its own.", id) }
        if entry.window.minimized { entry.window.restore() }; entry.window.show(); entry.window.focus()
        return result(true, "Its window is in front.", id, window: entry.window.windowID)
    }
    public func isPopped(_ id: String) -> Bool { entries[id] != nil }
    public func forward(_ channel: String, arguments: [NativeRPCValue]) {
        if channel == "session:switched", let previous = arguments.first?.string, arguments.count > 1,
           let next = arguments[1]["id"].string, next != previous { sessionReplaced(previousID: previous, nextID: next) }
        if entries.isEmpty || BackendOSPopoutRules.notForwarded.contains(channel) { return }
        if channel == "session:data" {
            if let id = arguments.first?.string, let entry = entries[id], !entry.window.contentDestroyed { entry.window.send(channel, arguments: arguments) }
            return
        }
        for entry in orderedEntries where !entry.window.destroyed && !entry.window.contentDestroyed { entry.window.send(channel, arguments: arguments) }
    }
    public func setLabels(_ labels: NativeRPCValue) {
        var changed = false
        for field in labels.fields ?? [] {
            guard let label = field.value.string, !label.isEmpty, let entry = entries[field.key], entry.label != label else { continue }
            entry.label = label; if !entry.window.destroyed { entry.window.title(label) }; changed = true
        }
        if changed { announce(nil) }
    }
    public func sessionEnded(_ id: String) {
        if let entry = entries[id], !entry.window.destroyed { entry.closing = "ended"; entry.window.close(); return }
        if let key = deps.session(id)?.tabKey, placements.contains(where: { $0.key == key }) { placements.removeAll { $0.key == key }; write() }
    }
    public func sessionReplaced(previousID: String, nextID: String) {
        guard let entry = entries[previousID], previousID != nextID, entries[nextID] == nil else { return }
        entries[previousID] = nil; order.removeAll { $0 == previousID }; entry.sessionID = nextID
        let nextKey = deps.session(nextID)?.tabKey ?? entry.key
        if let key = entry.key, key != nextKey { placements.removeAll { $0.key == key } }
        entry.key = nextKey; entries[nextID] = entry; order.append(nextID)
        remember(entry); write(); announce(o([("kind", .string("replaced")), ("previousId", .string(previousID)), ("sessionId", .string(nextID))]))
    }
    public func rekey(ownerID: String, previousID: String, nextID: String) -> NativeRPCValue {
        guard let entry = entries[previousID], entry.window.ownerID == ownerID else { return result(false, "That window does not hold that session.", previousID) }
        guard let next = deps.session(nextID) else { return result(false, "The replacement session is not running.", nextID) }
        sessionReplaced(previousID: previousID, nextID: nextID); deps.announceReplaced(previousID: previousID, meta: next)
        return result(true, "The window follows the new session.", nextID, window: entry.window.windowID)
    }
    public func restore(_ sessions: [BackendSessionMeta]) throws -> [String] {
        suspended = false
        let displays = try deps.displays(); var reopened: [String] = [], keys = Set(orderedEntries.compactMap(\.key))
        for session in sessions {
            guard let key = session.tabKey, !key.isEmpty, entries[session.id] == nil, !keys.contains(key), let saved = placements.first(where: { $0.key == key }), deps.refusal(session.id) == nil else { continue }
            let placed = BackendOSPopoutRules.restored(saved, displays: displays.all, primary: displays.primary)
            let entry = try make(session, bounds: placed.bounds, fullScreen: saved.fullScreen); remember(entry); keys.insert(key); reopened.append(session.id)
            deps.log("popout: restored", detail: o([("sessionId", .string(session.id)), ("outcome", .string(placed.outcome)), ("display", .string(placed.display.label))]))
        }
        if !reopened.isEmpty { write(); announce(nil) }; return reopened
    }
    public func suspend() {
        pendingSave?.cancel(); pendingSave = nil
        for entry in orderedEntries { remember(entry) }; write(); suspended = true
        for entry in orderedEntries where !entry.window.destroyed { entry.closing = "suspend"; entry.window.close() }
    }
    public func sessionForOwner(_ ownerID: String) -> String? { orderedEntries.first { !$0.window.destroyed && $0.window.ownerID == ownerID }?.sessionID }
    public func windowIDForOwner(_ ownerID: String) -> Int? { orderedEntries.first { !$0.window.destroyed && $0.window.ownerID == ownerID }?.window.windowID }
    public func routeMenu(_ command: String) throws -> Bool {
        guard let focused = orderedEntries.last(where: { !$0.window.destroyed && $0.window.focused }) else { return false }
        if command == "session.close" { _ = try dock(focused.sessionID, select: false); return true }
        if command == "session.popOut" { return true }
        if command == "session.dock" { _ = try dock(focused.sessionID, select: true); return true }
        try deps.showMain(command: command); return true
    }
    public static func readPoint(_ value: NativeRPCValue) -> (x: Double, y: Double)? {
        guard let x = value["x"].number, let y = value["y"].number else { return nil }
        return (BackendOSPopoutRules.round(x), BackendOSPopoutRules.round(y))
    }
    public func invoke(_ channel: String, arguments: [NativeRPCValue], context: NativeRPCContext) throws -> NativeRPCValue {
        let first = arguments.first ?? .missing
        switch channel {
        case "popout:open":
            let options = arguments.count > 1 ? arguments[1] : .missing
            return try open(first.string ?? "", at: Self.readPoint(options["at"]), displayID: options["displayId"].number)
        case "popout:dock": return try dock(first.string ?? "", select: true)
        case "popout:focus": return focus(first.string ?? "")
        case "popout:list": return try view().setting("self", windowIDForOwner(context.ownerID).map { .number(Double($0)) } ?? .null)
        case "popout:rekey":
            guard let previous = first.string, arguments.count > 1, let next = arguments[1].string else { return result(false, "Which session? No id was given.", "") }
            return rekey(ownerID: context.ownerID, previousID: previous, nextID: next)
        default: throw NativeRPCError(code: "unavailable", message: "The native session-window channel \(channel) is unavailable.")
        }
    }
    public func sent(_ channel: String, arguments: [NativeRPCValue]) throws {
        let first = arguments.first ?? .missing
        if channel == "popout:labels" {
            guard let fields = first.fields else { return }
            setLabels(.object(fields.filter { $0.value.string.map { $0.utf16.count <= 200 } == true }))
        } else if channel == "popout:show-main" {
            try deps.showMain(command: first.string.flatMap { BackendOSPopoutRules.mainCommands.contains($0) ? $0 : nil })
        } else { throw NativeRPCError(code: "unavailable", message: "The native session-window send channel \(channel) is unavailable.") }
    }
    public func register(on registry: NativeChannelRegistry, ownerID: String = "native-popout-registry",
                         policy: @escaping NativeChannelRegistry.Policy = BackendOSNativeCaller.only) async throws -> [NativeRPCSubscription] {
        for subscription in sendSubscriptions { await subscription.cancelAndWait() }; sendSubscriptions = []
        for channel in Self.invokeChannels {
            await registry.removeHandler(channel, ownerID: ownerID)
            try await registry.register(channel, ownerID: ownerID, policy: policy) { [weak self] context, arguments in
                guard let self else { throw NativeRPCError(code: "unavailable", message: "The native session-window registry is unavailable.") }
                return try await self.invoke(channel, arguments: arguments, context: context)
            }
        }
        var subscriptions: [NativeRPCSubscription] = []
        for channel in Self.sendChannels {
            subscriptions.append(try await registry.onSend(channel, ownerID: ownerID, policy: policy) { [weak self] _, arguments in
                guard let self else { throw NativeRPCError(code: "unavailable", message: "The native session-window registry is unavailable.") }
                try await self.sent(channel, arguments: arguments)
            })
        }
        sendSubscriptions = subscriptions
        return subscriptions
    }
}

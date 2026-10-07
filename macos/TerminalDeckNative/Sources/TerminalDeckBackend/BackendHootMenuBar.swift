import Foundation
import TerminalDeckNativeCore

@MainActor public protocol BackendHootCancellation: AnyObject { func cancel() }
@MainActor public final class BackendHootTimer: BackendHootCancellation {
    private var task: Task<Void, Never>?
    public init(milliseconds: Int, run: @escaping @MainActor () -> Void) {
        task = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(milliseconds)); try Task.checkCancellation(); run() } catch { }
        }
    }
    public func cancel() { task?.cancel(); task = nil }
}

/// Supplied by the existing SwiftUI island/NSPanel. `ownerID` is authenticated
/// native bridge identity; a page cannot choose a sender id in its arguments.
@MainActor public protocol BackendHootIslandSurface: AnyObject {
    var ownerID: String { get }
    var destroyed: Bool { get }
    var focused: Bool { get }
    var bounds: CGRect { get }
    func setBounds(_ bounds: CGRect)
    func showInactive()
    func focus()
    func blur()
    func destroy()
    func ignoreMouseEvents(_ ignore: Bool)
    func send(_ channel: String, arguments: [NativeRPCValue])
    func menu(_ actions: [BackendHootMenuAction])
    func on(_ event: String, action: @escaping @MainActor () -> Void)
}
@MainActor public protocol BackendHootCatcherSurface: AnyObject {
    var ownerID: String { get }
    var destroyed: Bool { get }
    func setBounds(_ bounds: CGRect)
    func showInactive()
    func ignoreMouseEvents(_ ignore: Bool)
    func destroy()
}
@MainActor public struct BackendHootMenuAction {
    public let label: String?
    public let run: (@MainActor () -> Void)?
    public init(label: String?, run: (@MainActor () -> Void)? = nil) { self.label = label; self.run = run }
}
public struct BackendHootIslandPlace: Sendable {
    public var display: CGRect, barHeight: CGFloat, notch: IslandNotch?
    public init(display: CGRect, barHeight: CGFloat, notch: IslandNotch? = nil) { self.display = display; self.barHeight = barHeight; self.notch = notch }
}
public struct BackendHootMenuSessionState: Sendable {
    public var status: String, problem: String?, sessionID: String?, cwd: String, agentSessionID: String?
    public init(status: String, problem: String? = nil, sessionID: String? = nil, cwd: String, agentSessionID: String? = nil) {
        self.status = status; self.problem = problem; self.sessionID = sessionID; self.cwd = cwd; self.agentSessionID = agentSessionID
    }
}
@MainActor public struct BackendHootMenuBarDependencies {
    public let makeIsland: () throws -> any BackendHootIslandSurface
    public let makeCatcher: () throws -> any BackendHootCatcherSurface
    public let place: () -> BackendHootIslandPlace
    public let read: (String) -> NativeRPCValue
    public let write: (NativeRPCValue) throws -> Void
    public let hoot: () -> BackendHootMenuSessionState
    public let startHoot: () async throws -> String?
    public let say: (String, String) throws -> Void
    public let watchChat: (String, String?, @escaping @MainActor ([NativeRPCValue], Bool) -> Void) throws -> any BackendHootCancellation
    public let sessions: () -> [IslandSessionRow]
    public let isHoot: (String) -> Bool
    public let showSession: (String) -> Void
    public let openApp: (String?) -> Void
    public let quit: (@MainActor @Sendable () -> Void)?
    public let shownChanged: () -> Void
    public let appearance: () -> String
    public let supported: Bool
    public let schedule: (@escaping @MainActor () -> Void, Int) -> any BackendHootCancellation
    public let now: () -> Double
    public let log: (String, NativeRPCValue) -> Void
    public init(makeIsland: @escaping () throws -> any BackendHootIslandSurface,
                makeCatcher: @escaping () throws -> any BackendHootCatcherSurface,
                place: @escaping () -> BackendHootIslandPlace, read: @escaping (String) -> NativeRPCValue,
                write: @escaping (NativeRPCValue) throws -> Void, hoot: @escaping () -> BackendHootMenuSessionState,
                startHoot: @escaping () async throws -> String?, say: @escaping (String, String) throws -> Void,
                watchChat: @escaping (String, String?, @escaping @MainActor ([NativeRPCValue], Bool) -> Void) throws -> any BackendHootCancellation,
                sessions: @escaping () -> [IslandSessionRow], isHoot: @escaping (String) -> Bool,
                showSession: @escaping (String) -> Void, openApp: @escaping (String?) -> Void,
                quit: (@MainActor @Sendable () -> Void)? = nil, shownChanged: @escaping () -> Void = {}, appearance: @escaping () -> String,
                supported: Bool = true,
                schedule: @escaping (@escaping @MainActor () -> Void, Int) -> any BackendHootCancellation = { run, ms in BackendHootTimer(milliseconds: ms, run: run) },
                now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 },
                log: @escaping (String, NativeRPCValue) -> Void = { _, _ in }) {
        self.makeIsland = makeIsland; self.makeCatcher = makeCatcher; self.place = place; self.read = read; self.write = write
        self.hoot = hoot; self.startHoot = startHoot; self.say = say; self.watchChat = watchChat; self.sessions = sessions
        self.isHoot = isHoot; self.showSession = showSession; self.openApp = openApp; self.quit = quit; self.shownChanged = shownChanged
        self.appearance = appearance; self.supported = supported; self.schedule = schedule; self.now = now; self.log = log
    }
}

/// `createHootMenuBar`: one event-driven controller, the same Hoot as the desk,
/// stable maximum window bounds, and separate trusted island/catcher senders.
@MainActor public final class BackendHootMenuBar {
    public static let menuBarKey = "copilot.menuBar", widthKey = "copilot.islandWidth", heightKey = "copilot.islandHeight"
    public static let panelMessages = 12, focusGraceMS = 500, openDelayMS = 120, closeDelayMS = 100, momentMS = 4000, settleMS = 60
    private let deps: BackendHootMenuBarDependencies
    private var island: (any BackendHootIslandSurface)?, catcher: (any BackendHootCatcherSurface)?
    private var shown = false, placed: CGRect?, pill = CGSize(width: 96, height: 24)
    private var labels: [String: String] = [:], messages: [NativeRPCValue] = []
    private var hootCache: BackendHootMenuSessionState?
    private var watching: (id: String, stop: any BackendHootCancellation)?
    private var last: [String: String] = [:], fired: [String: Double] = [:]
    private var moment: (text: String, attention: Bool)?
    private var expanded = false, pinned = false, over = false, holding = false, keyed = false, quiet = false
    private var focusAskedAt = -Double.infinity
    private var timers: [String: any BackendHootCancellation] = [:]
    private var subscriptions: [NativeRPCSubscription] = []
    private var watcherGeneration = 0
    public init(_ dependencies: BackendHootMenuBarDependencies) { deps = dependencies }
    private var live: (any BackendHootIslandSurface)? { island.flatMap { $0.destroyed ? nil : $0 } }
    private var gate: (any BackendHootCatcherSurface)? { catcher.flatMap { $0.destroyed ? nil : $0 } }
    public func menuBarEnabled() -> Bool { deps.read(Self.menuBarKey).bool != false }
    public func rememberedSize() -> CGSize? {
        guard let w = deps.read(Self.widthKey).number, let h = deps.read(Self.heightKey).number, w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }
    private func hoot() -> BackendHootMenuSessionState {
        if let hootCache { return hootCache }; let state = deps.hoot(); hootCache = state; return state
    }
    private func theirs() -> [IslandSessionRow] {
        let own = hoot().sessionID
        return deps.sessions().filter { $0.id != own && !deps.isHoot($0.id) }
    }
    private func rows() -> [IslandSessionRow] {
        let statuses = ["idle", "working", "waiting", "input", "completed", "exited"]
        return theirs().map { .init(id: $0.id, label: labels[$0.id] ?? ($0.label.isEmpty ? "Session" : $0.label), status: statuses.contains($0.status) ? $0.status : "idle") }
    }
    private func label() -> (text: String, attention: Bool) {
        if let moment { return (Self.cut(moment.text, maximum: 34), moment.attention) }
        let sessions = rows(), open = sessions.filter { $0.status != "exited" }.count
        guard open > 0 else { return ("Hoot", false) }
        let working = sessions.filter { $0.status == "working" }.count, waiting = sessions.filter { $0.status == "input" }.count
        var parts = ["\(open) open"]
        if working > 0 { parts.append("\(working) working") }; if waiting > 0 { parts.append("\(waiting) waiting") }
        return (Self.cut(parts.joined(separator: " · "), maximum: 34), waiting > 0)
    }
    /// JavaScript's string limits are UTF-16 units, not Swift grapheme counts.
    public static func prefix(_ text: String, units: Int) -> String { BackendSharedText.prefix(text, units) }
    private static func cut(_ text: String, maximum: Int) -> String { text.utf16.count > maximum ? prefix(text, units: maximum - 1) + "…" : text }
    public static func mergeMessages(_ kept: [NativeRPCValue], update: [NativeRPCValue], reset: Bool) -> [NativeRPCValue] {
        var result = reset ? [] : kept
        for row in update {
            if let i = result.firstIndex(where: { $0["id"] == row["id"] }) { result[i] = row } else { result.append(row) }
        }
        return Array(result.suffix(panelMessages))
    }
    private static func box(_ size: CGSize) -> NativeRPCValue { .object([.init("width", .number(size.width)), .init("height", .number(size.height))]) }
    private static func rect(_ rect: CGRect) -> NativeRPCValue {
        .object([.init("x", .number(rect.minX)), .init("y", .number(rect.minY)), .init("width", .number(rect.width)), .init("height", .number(rect.height))])
    }
    public func snapshot() -> NativeRPCValue {
        let state = hoot(), place = deps.place(), label = label()
        let notch: NativeRPCValue = place.notch.map { .object([.init("left", .number($0.minX - place.display.minX)), .init("width", .number($0.width)), .init("height", .number($0.height))]) } ?? .null
        return .object([.init("assistant", .string("Hoot")), .init("appearance", .string(deps.appearance())),
            .init("hoot", .object([.init("status", .string(state.status)), .init("problem", state.problem.map(NativeRPCValue.string) ?? .null)])),
            .init("sessions", .array(theirs().map { .object([.init("id", .string($0.id)), .init("label", .string(labels[$0.id] ?? $0.label)), .init("status", .string($0.status))]) })),
            .init("messages", .array(messages)), .init("label", .object([.init("text", .string(label.text)), .init("attention", .bool(label.attention))])),
            .init("expanded", .bool(expanded)), .init("geometry", .object([.init("barHeight", .number(place.barHeight)), .init("displayWidth", .number(place.display.width)), .init("notch", notch)])),
            .init("size", rememberedSize().map { Self.box(BackendHootIslandBounds.clamp(displayWidth: place.display.width, barHeight: place.barHeight, size: $0)) } ?? .null)])
    }
    private func push() { live?.send("hoot-panel:snapshot", arguments: [snapshot()]) }
    private func cancel(_ name: String) { timers.removeValue(forKey: name)?.cancel() }
    private func after(_ name: String, milliseconds: Int, run: @escaping @MainActor () -> Void) {
        cancel(name); timers[name] = deps.schedule({ [weak self] in self?.timers[name] = nil; run() }, milliseconds)
    }
    private func placeWindow(reason: String) {
        guard let target = live else { return }; let place = deps.place()
        let bounds = BackendHootIslandBounds.place(display: place.display, notch: place.notch, size: BackendHootIslandBounds.window(displayWidth: place.display.width, barHeight: place.barHeight))
        if placed != bounds { target.setBounds(bounds); placed = bounds; deps.log("island: placed", .object([.init("reason", .string(reason)), .init("bounds", Self.rect(target.bounds)), .init("wanted", Self.rect(bounds)), .init("notch", snapshot()["geometry"]["notch"])])) }
        if !shown { shown = true; target.ignoreMouseEvents(true); target.showInactive() }; placeCatcher()
    }
    private func placeCatcher() {
        guard let target = gate else { return }; let place = deps.place()
        target.setBounds(BackendHootIslandBounds.place(display: place.display, notch: place.notch, size: pill)); target.showInactive()
    }
    private func listenAtRest() { live?.ignoreMouseEvents(true); gate?.ignoreMouseEvents(false) }
    private func listenOnShape() { live?.ignoreMouseEvents(false); gate?.ignoreMouseEvents(true) }
    private func follow() {
        let state = hoot(), wanted = expanded && state.status == "running" ? state.sessionID : nil
        if let watching, watching.id == wanted { return }
        watching?.stop.cancel(); watching = nil; watcherGeneration += 1
        guard let wanted else { return }; messages = []; let generation = watcherGeneration
        do {
            let stop = try deps.watchChat(state.cwd, state.agentSessionID) { [weak self] update, reset in
                guard let self, self.watcherGeneration == generation else { return }
                self.messages = Self.mergeMessages(self.messages, update: update, reset: reset); self.push()
            }; watching = (wanted, stop)
        } catch { deps.log("island: could not follow Hoot’s transcript", .object([.init("error", .string(error.localizedDescription))])) }
    }
    private func expand(keyboard: Bool, reason: String) {
        guard let target = live else { return }; cancel("open"); cancel("close"); quiet = false; listenOnShape()
        if !expanded {
            expanded = true; hootCache = nil; follow(); push()
            deps.log("island: opened", .object([.init("reason", .string(reason))]))
        }
        if keyboard { focusAskedAt = deps.now(); if !target.focused { target.focus() } }
    }
    private func collapse(onPurpose: Bool) {
        cancel("open"); cancel("close"); let was = expanded; expanded = false; pinned = false; holding = false
        if onPurpose && over { quiet = true }; over = false; listenAtRest(); if keyed { live?.blur() }; follow(); if was { push() }
    }
    private func closeSoon() {
        cancel("close"); guard expanded else { return }
        after("close", milliseconds: Self.closeDelayMS) { [weak self] in
            guard let self, !self.over, !self.holding, !self.pinned else { return }; self.collapse(onPurpose: false)
        }
    }
    private func arrive() {
        over = true; cancel("close"); listenOnShape(); guard !expanded, !quiet, timers["open"] == nil else { return }
        after("open", milliseconds: Self.openDelayMS) { [weak self] in guard let self, self.over, !self.quiet else { return }; self.expand(keyboard: false, reason: "hover") }
    }
    private func depart() {
        over = false; quiet = false; cancel("open")
        if expanded { if keyed { live?.ignoreMouseEvents(true) }; closeSoon() } else { listenAtRest() }
    }
    private func noticeSessions() {
        let sessions = rows(), now = deps.now(); var found: (text: String, attention: Bool)?
        for row in sessions {
            let previous = last.updateValue(row.status, forKey: row.id), key = row.id + ":" + row.status
            guard BackendSharedNotifyRule.decide(status: row.status, previous: previous, enabled: true, watching: false,
                lastFiredAt: fired[key], now: now, cooldownMs: BackendSharedNotifyRule.cooldownMilliseconds) == .fire else { continue }
            fired[key] = now; found = (row.label + (row.status == "input" ? " needs you" : " finished"), row.status == "input")
        }
        let seen = Set(sessions.map(\.id)); last = last.filter { seen.contains($0.key) }
        guard let found else { return }; moment = found
        after("moment", milliseconds: Self.momentMS) { [weak self] in self?.moment = nil; self?.push() }
    }
    public func apply() throws {
        guard deps.supported && menuBarEnabled() else { if island != nil { dispose() }; return }
        guard island == nil else { return }
        let made = try deps.makeIsland()
        let madeCatcher: any BackendHootCatcherSurface
        do { madeCatcher = try deps.makeCatcher() } catch { made.destroy(); throw error }
        island = made; catcher = madeCatcher; shown = false; placed = nil; pill = CGSize(width: 96, height: 24)
        expanded = false; keyed = false; over = false; quiet = false
        made.on("focus") { [weak self] in self?.keyed = true }
        made.on("blur") { [weak self] in
            guard let self else { return }; self.keyed = false
            guard self.expanded, !self.holding else { return }
            if self.deps.now() - self.focusAskedAt < Double(Self.focusGraceMS) { self.pinned = false; if !self.over { self.closeSoon() }; return }
            self.collapse(onPurpose: true)
        }
        made.on("closed") { [weak self, weak made] in
            guard let self, let made, self.island === made else { return }; self.island = nil; self.expanded = false; self.deps.shownChanged()
        }
        last = [:]; fired = [:]; noticeSessions(); placeWindow(reason: "shown"); listenAtRest(); deps.shownChanged()
    }
    public func openPanel() -> NativeRPCValue {
        guard live != nil else { return Self.result(false, "Hoot is not at the top of the screen; turn it on in Settings.") }
        pinned = true; expand(keyboard: true, reason: "asked to open (hoot-menubar:open)"); return Self.result(true)
    }
    public func config() -> NativeRPCValue { .object([.init("enabled", .bool(menuBarEnabled()))]) }
    public func configure(_ patch: NativeRPCValue) throws -> NativeRPCValue {
        if let value = patch["enabled"].bool { try deps.write(.object([.init(Self.menuBarKey, .bool(value))])) }; try apply(); return config()
    }
    public func setLabels(_ value: NativeRPCValue) {
        var clean: [String: String] = [:]
        for field in value.fields ?? [] { if let text = field.value.string, !text.isEmpty, text.utf16.count <= 200 { clean[field.key] = text } }
        if clean != labels { labels = clean; push() }
    }
    public func displaysChanged() { placeWindow(reason: "display changed"); push() }
    public func themeChanged() { push() }
    public func forward(_ channel: String, arguments: [NativeRPCValue]) {
        guard island != nil else { return }
        if ["prefs:changed", "settings:changed"].contains(channel) { live?.send(channel, arguments: arguments); push(); return }
        let hootChanges = ["session:created", "session:exit", "session:removed", "session:switched", "session:status"]
        let sessionChanges = ["session:status", "session:renamed", "session:exit", "session:removed", "session:created"]
        if hootChanges.contains(channel) { hootCache = nil; follow() }
        if sessionChanges.contains(channel) || hootChanges.contains(channel) {
            after("settle", milliseconds: Self.settleMS) { [weak self] in self?.noticeSessions(); self?.push() }
        }
    }
    public func say(_ raw: NativeRPCValue) -> NativeRPCValue {
        let text = raw.string.map(BackendSharedText.trim) ?? ""
        guard !text.isEmpty else { return Self.result(false, "Nothing to send.") }; hootCache = nil; let state = hoot()
        guard state.status == "running", let id = state.sessionID else { return Self.result(false, "Hoot isn’t running.") }
        do { try deps.say(id, Self.prefix(text, units: 4000)); return Self.result(true) } catch { return Self.result(false, "Hoot did not take that message.") }
    }
    public func startHoot() async -> NativeRPCValue {
        do { let problem = try await deps.startHoot(); hootCache = nil; follow(); push(); return Self.result(problem == nil, problem ?? "") }
        catch { return Self.result(false, error.localizedDescription) }
    }
    public func showSession(_ id: String) -> NativeRPCValue {
        guard theirs().contains(where: { $0.id == id }) else { return .object([.init("ok", .bool(false))]) }
        collapse(onPurpose: true); deps.showSession(id); return .object([.init("ok", .bool(true))])
    }
    public func isShowing() -> NativeRPCValue {
        .object([.init("island", .bool(live != nil)), .init("expanded", .bool(expanded)), .init("label", .string(label().text)), .init("bounds", live.map { Self.rect($0.bounds) } ?? .null)])
    }
    private func ours(_ owner: String) -> Bool { live?.ownerID == owner }
    public func event(_ channel: String, owner: String, argument: NativeRPCValue = .missing) {
        if channel == "hoot-panel:catch" {
            guard gate?.ownerID == owner, live != nil else { return }
            switch argument.string {
            case "enter": if !quiet { arrive() }
            case "leave": if !expanded { depart() }; quiet = false
            case "press": quiet = false; pinned = true; over = true; expand(keyboard: true, reason: "press on the pill")
            default: break
            }; return
        }
        if channel == "hoot-panel:menu" {
            guard ours(owner) || gate?.ownerID == owner else { return }
            var actions = [BackendHootMenuAction(label: "Open Terminal Deck", run: { [weak self] in self?.deps.openApp(nil) }),
                           BackendHootMenuAction(label: "Settings…", run: { [weak self] in self?.deps.openApp("hoot-settings") })]
            if let quit = deps.quit { actions += [.init(label: nil), .init(label: "Quit and Stop All Sessions", run: quit)] }; live?.menu(actions); return
        }
        guard ours(owner) else { return }
        switch channel {
        case "hoot-panel:pointer": argument.bool == true ? arrive() : depart()
        case "hoot-panel:held": holding = argument.bool == true; if !holding { closeSoon() }
        case "hoot-panel:focus": if !expanded { pinned = true }; over = true; expand(keyboard: true, reason: "press on the island")
        case "hoot-panel:close": collapse(onPurpose: true)
        case "hoot-panel:size":
            guard let w = argument["width"].number, let h = argument["height"].number, w >= 1, h >= 1 else { return }
            let next = CGSize(width: min(ceil(w), 800), height: min(ceil(h), 60)); if next != pill { pill = next; placeCatcher() }
        default: break
        }
    }
    public func resize(owner: String, argument: NativeRPCValue) throws {
        guard ours(owner), let w = argument["width"].number, let h = argument["height"].number else { return }; let place = deps.place()
        let size = BackendHootIslandBounds.clamp(displayWidth: place.display.width, barHeight: place.barHeight, size: CGSize(width: w, height: h))
        try deps.write(.object([.init(Self.widthKey, .number(size.width)), .init(Self.heightKey, .number(size.height))])); push()
    }
    public func dispose() {
        collapse(onPurpose: false); for name in Array(timers.keys) { cancel(name) }; watching?.stop.cancel(); watching = nil; watcherGeneration += 1
        let had = island != nil, target = live, gate = gate; island = nil; catcher = nil; target?.destroy(); gate?.destroy(); moment = nil
        if had { deps.shownChanged() }
    }
    private static func result(_ ok: Bool, _ message: String = "") -> NativeRPCValue { .object([.init("ok", .bool(ok)), .init("message", .string(message))]) }
    /// Keep subscriptions alive and unregister them with the owning composition.
    public func register(in registry: NativeChannelRegistry, ownerID: String = "hoot-menubar") async throws {
        for subscription in subscriptions { await subscription.cancelAndWait() }; subscriptions = []
        let handles = ["hoot-panel:snapshot", "hoot-panel:say", "hoot-panel:start-hoot", "hoot-panel:show-session", "hoot-menubar:config", "hoot-menubar:configure", "hoot-menubar:open"]
        for channel in handles {
            await registry.removeHandler(channel, ownerID: ownerID)
            try await registry.register(channel, ownerID: ownerID, policy: Self.localPolicy) { [weak self] _, args in
                guard let self else { throw NativeRPCError(code: "unavailable", message: "Hoot island is unavailable.") }
                return try await self.invoke(channel, argument: args.first ?? .missing)
            }
        }
        for channel in ["hoot-panel:pointer", "hoot-panel:held", "hoot-panel:focus", "hoot-panel:close", "hoot-panel:size", "hoot-panel:menu", "hoot-panel:catch", "hoot-panel:resize", "session:labels"] {
            let subscription = try await registry.onSend(channel, ownerID: ownerID, policy: Self.localPolicy) { [weak self] context, args in
                guard let self else { throw NativeRPCError(code: "unavailable", message: "Hoot island is unavailable.") }
                try await self.receive(channel, owner: context.ownerID, argument: args.first ?? .missing)
            }; subscriptions.append(subscription)
        }
        for channel in ["prefs:changed", "settings:changed", "session:status", "session:renamed", "session:exit", "session:removed", "session:created", "session:switched"] {
            let subscription = try await registry.subscribe(channel, ownerID: ownerID) { [weak self] event in
                await self?.forward(event.channel, arguments: event.arguments)
            }; subscriptions.append(subscription)
        }
    }
    public func unregister(in registry: NativeChannelRegistry, ownerID: String = "hoot-menubar") async {
        for subscription in subscriptions { await subscription.cancelAndWait() }; subscriptions = []; await registry.removeOwner(ownerID); dispose()
    }
    private nonisolated static func localPolicy(_ context: NativeRPCContext) throws {
        guard context.caller == .nativeApp || context.caller == .internalEngine else { throw NativeRPCError(code: "access-denied", message: "Hoot island controls are only available in the app.") }
    }
    private func invoke(_ channel: String, argument: NativeRPCValue) async throws -> NativeRPCValue {
        switch channel {
        case "hoot-panel:snapshot": return snapshot()
        case "hoot-panel:say": return say(argument)
        case "hoot-panel:start-hoot": return await startHoot()
        case "hoot-panel:show-session": return argument.string.map(showSession) ?? .object([.init("ok", .bool(false))])
        case "hoot-menubar:config": return config()
        case "hoot-menubar:configure": return try configure(argument)
        case "hoot-menubar:open": return openPanel()
        default: throw NativeRPCError(code: "missing-handler", message: "Unknown Hoot island channel.")
        }
    }
    private func receive(_ channel: String, owner: String, argument: NativeRPCValue) throws {
        if channel == "session:labels" { if argument.fields != nil { setLabels(argument) }; return }
        if channel == "hoot-panel:resize" { try resize(owner: owner, argument: argument); return }
        event(channel, owner: owner, argument: argument)
    }
}

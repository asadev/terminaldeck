import AppKit
import Darwin
import Foundation
import TerminalDeckNativeCore

/// The browser/window channels the page and the app still sent to Node (D14),
/// answered natively the way the TypeScript native-shell engine answers them:
/// browser-binding-ipc.ts, session-row-menu.ts, browser-reach.ts,
/// popout-windows.ts (with native-shell/mode.ts NATIVE_REFUSAL.popout), the
/// page's plumbing sends, and the retired Chrome-only surfaces as refusals.
///
/// The native-shell engine had no Electron window: `bindingDeps.window()` and
/// `showMainWindow` were null/no-ops there, popouts were refused for every
/// session, and the page's own browser (browser:create) was refused, so its
/// Chromium tab map stayed empty. Those answers are ported exactly.
public enum BackendCompositionBrowserChannels {
    /// native-shell/mode.ts NATIVE_REFUSAL, verbatim.
    public static let browserRefusal = "The built-in browser is not available in the native shell yet."
    public static let popoutRefusal = "Sessions cannot have windows of their own in the native shell yet — they stay in the main window."
    /// browser-reach.ts REACH_STATE_CHANNEL.
    public static let reachStateChannel = "browser:reach:state"
    /// Chrome-only surfaces retired by Asad's Chrome removal; kept as refusals.
    public static let retired: [String] = [
        "browser-extension:list", "browser-extension:install", "browser-extension:remove", "browser-extension:enable",
        "browser-extension:popup", "browser-extension:options", "browser-extension:add-folder", "browser-extension:add-crx",
        "browser-extension:reload", "browser-extension:rename",
        "chrome-import:browsers", "chrome-import:scan", "chrome-import:access", "chrome-import:open-privacy-settings",
        "cookie-import:sources", "cookie-import:status", "cookie-import:run", "cookie-import:clear",
        "browser-view:claim", "browser-view:release",
        "browser-isolation:key", "browser-isolation:dispose", "browser-isolation:count",
    ]
    public static let menus = ["browser:bind-menu", "browser:connect-menu", "browser:bind-menu-items", "session:row-menu"]
    public static let reach = ["browser:reach:list", "browser:reach:hold", "browser:reach:release"]
    public static let popouts = ["popout:open", "popout:dock", "popout:focus", "popout:list", "popout:rekey"]
    public static let invokes: [String] = menus + reach + popouts + retired
    public static let sends: [String] = ["popout:labels", "popout:show-main", "browser:bounds", "browser:visible",
        "browser:drive-opened", "browser:drive-closed", "browser:drive-shown", "browser:window-opened",
        "browser:window-closed", "window:dimmed", "menu:hidden-commands"]
    public static let events: [String] = [reachStateChannel]

    public typealias Bindings = @Sendable () async throws -> BackendBrowserBindings

    /// - `bindings`: the Safari graph's one binding map (late: the browser graph may start after this).
    /// - `reachLedger`: the one tunnel ledger; wire its `forget` to the machine and server owners' `tunnelsDropped`.
    /// - `hiddenCommands`: the native application menu's `updateHidden` (menu.ts L372-377);
    ///   nil when no native menu owner takes it, and then the list changes nothing.
    public static func register(registry: NativeChannelRegistry, ownerID: String, authority: BackendCompositionAuthority,
                                bindings: @escaping Bindings, reachLedger: BackendCompositionBrowserReachLedger,
                                hiddenCommands: (@Sendable (NativeRPCValue) async throws -> Void)?) async throws
        -> (invokes: [String], sends: [String], events: [String]) {
        for channel in invokes {
            if await registry.has(channel) { throw NativeRPCError(code: "duplicate-handler", message: "Browser channel is already registered: " + channel) }
        }
        let window: NativeChannelRegistry.Policy = { try authority.requireLocalUI($0) }
        let read: NativeChannelRegistry.Policy = { try authority.authorizeMetadata($0) }
        let change: NativeChannelRegistry.Policy = { try authority.authorizeMutation($0) }
        var handlers: [(String, NativeChannelRegistry.Policy, NativeChannelRegistry.Handler)] = []

        // browser-binding-ipc.ts L1099-1165 / session-row-menu.ts L224-242: the
        // native-shell engine had no window to pop a menu over, so the popped
        // menus answer false/null; the native window asks for the rows as data.
        handlers.append(("browser:bind-menu", window, { _, _ in .bool(false) }))
        handlers.append(("browser:connect-menu", window, { _, _ in .bool(false) }))
        handlers.append(("session:row-menu", window, { _, _ in .null }))
        handlers.append(("browser:bind-menu-items", window, { context, args in
            let input = context.argument(0, in: args)
            guard let sessionID = input["sessionId"].string, !sessionID.isEmpty else { return .null }
            let map = try await bindings()
            return await Self.bindMenuRows(map, sessionID: sessionID, machineID: input["machineId"].string ?? "", thisMachine: Self.thisMachineName())
        }))

        // browser-reach.ts registerBrowserReachIpc L383-411.
        handlers.append(("browser:reach:list", read, { _, _ in await reachLedger.list() }))
        handlers.append(("browser:reach:hold", change, { context, args in
            let named = BackendCompositionBrowserReachLedger.machine(context.argument(1, in: args))
            guard let holder = context.argument(0, in: args).string, let machine = named, let port = context.argument(2, in: args).number else {
                return .object([.init("answer", .object([.init("ok", .bool(false)), .init("message", .string("That is not a window, a machine and a port."))])),
                                .init("stranded", .null)])
            }
            return await reachLedger.hold(holder: holder, machine: machine, port: port)
        }))
        handlers.append(("browser:reach:release", change, { context, args in
            guard let holder = context.argument(0, in: args).string, let machineID = context.argument(1, in: args).string,
                  let port = context.argument(2, in: args).number else {
                return .object([.init("gone", .bool(false)), .init("holders", .number(0)), .init("message", .string("That is not a window, a machine and a port."))])
            }
            return await reachLedger.release(holder: holder, machineID: machineID, port: port)
        }))

        // popout-windows.ts registerPopoutIpc L719-752 over a registry whose
        // `refusal` is NATIVE_REFUSAL.popout for every session (index.ts
        // L4428-4430): nothing is ever out, so dock/focus/rekey find no window.
        handlers.append(("popout:open", change, { context, args in
            let sessionID = context.argument(0, in: args).string ?? ""
            guard !sessionID.isEmpty else { return Self.popoutResult(false, "Which session? No id was given.", "") }
            guard await Self.sessionRunning(sessionID, context: context, authority: authority) else {
                return Self.popoutResult(false, "No session with that id is running on this computer.", sessionID)
            }
            return Self.popoutResult(false, Self.popoutRefusal, sessionID)
        }))
        handlers.append(("popout:dock", change, { context, args in
            Self.popoutResult(false, "That session is not in a window of its own.", context.argument(0, in: args).string ?? "")
        }))
        handlers.append(("popout:focus", change, { context, args in
            Self.popoutResult(false, "That session is not in a window of its own.", context.argument(0, in: args).string ?? "")
        }))
        handlers.append(("popout:list", read, { _, _ in
            let screens = await Self.displays()
            return .object([.init("windows", .array([])), .init("displays", .array(screens)), .init("self", .null)])
        }))
        handlers.append(("popout:rekey", window, { context, args in
            guard let previous = context.argument(0, in: args).string, context.argument(1, in: args).string != nil else {
                return Self.popoutResult(false, "Which session? No id was given.", "")
            }
            return Self.popoutResult(false, "That window does not hold that session.", previous)
        }))

        // Retired Chrome-only surfaces: the native shell's browser sentence.
        for channel in retired {
            handlers.append((channel, read, { _, _ in throw NativeRPCError(code: "unavailable", message: Self.browserRefusal) }))
        }

        var sendHandlers: [(String, NativeChannelRegistry.Policy, NativeChannelRegistry.SendHandler)] = []
        // popout-windows.ts L753-763: labels for windows that are out (none); and
        // showMainWindow, which made no window in the native shell (index.ts L1503-1505).
        sendHandlers.append(("popout:labels", window, { _, _ in }))
        sendHandlers.append(("popout:show-main", change, { _, _ in }))
        // browser-tab.ts L1676-1697: bounds/visibility of a Chromium tab; the
        // native shell refused browser:create, so there is never such a tab.
        sendHandlers.append(("browser:bounds", window, { _, _ in }))
        sendHandlers.append(("browser:visible", window, { _, _ in }))
        // browser-drive-ipc.ts L552-568: answers to the drive's open/close/show
        // requests. No native owner asks the page for those, so none is pending.
        sendHandlers.append(("browser:drive-opened", window, { _, _ in }))
        sendHandlers.append(("browser:drive-closed", window, { _, _ in }))
        sendHandlers.append(("browser:drive-shown", window, { _, _ in }))
        // index.ts L2858-2862: the dim state only drives the Windows/Linux title-bar
        // overlay (title-bar.ts overlayFor is null on macOS).
        sendHandlers.append(("window:dimmed", window, { _, _ in }))
        // browser-binding-ipc.ts L1015-1067 (number and remember the window) and
        // browser-reach.ts L413-415 (a closed window lets go of its tunnels).
        sendHandlers.append(("browser:window-opened", window, { context, args in
            let input = context.argument(0, in: args)
            guard let tabID = input["tabId"].string, !tabID.isEmpty else { return }
            let map = try await bindings()
            await Self.windowOpened(map, tabID: tabID, input: input)
        }))
        sendHandlers.append(("browser:window-closed", window, { context, args in
            // Two independent listeners in the source: the ledger's runs even
            // when the binding map is not up.
            guard let tabID = context.argument(0, in: args).string else { return }
            await reachLedger.dropHolder(tabID)
            guard !tabID.isEmpty else { return }
            let map = try await bindings()
            await MainActor.run { map.closed(tabID) }
        }))
        sendHandlers.append(("menu:hidden-commands", window, { _, args in
            try await hiddenCommands?(args.first ?? .missing)
        }))

        var registered: [String] = [], subscriptions: [NativeRPCSubscription] = []
        do {
            for (channel, policy, handler) in handlers {
                try await registry.register(channel, ownerID: ownerID, policy: policy, handler: handler)
                registered.append(channel)
            }
            for (channel, policy, handler) in sendHandlers {
                subscriptions.append(try await registry.onSend(channel, ownerID: ownerID, policy: policy, handler: handler))
            }
        } catch {
            for channel in registered { await registry.removeHandler(channel, ownerID: ownerID) }
            for subscription in subscriptions { await subscription.cancelAndWait() }
            throw error
        }
        // Send listeners live as long as their subscriptions: kept for the area's lifetime.
        await BackendCompositionSendLeases.shared.keep(ownerID, subscriptions)
        return (invokes, sends, events)
    }

    static func popoutResult(_ ok: Bool, _ message: String, _ sessionID: String) -> NativeRPCValue {
        .object([.init("ok", .bool(ok)), .init("message", .string(message)), .init("sessionId", .string(sessionID))])
    }
    /// popoutSessions (index.ts L1398): a pty this app holds; scoped callers see only theirs.
    static func sessionRunning(_ id: String, context: NativeRPCContext, authority: BackendCompositionAuthority) async -> Bool {
        if context.caller == .nativeApp { return authority.prepared.manager.list().contains { $0.id == id } }
        do { try await authority.requireSessionRPC(id, context: context); return true } catch { return false }
    }
    /// popout-windows.ts electronDisplays + view(): id, label, primary, width, height.
    @MainActor static func displays() -> [NativeRPCValue] {
        let screens = NSScreen.screens
        let primary = (screens.first?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.doubleValue
        return screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.doubleValue else { return nil }
            return .object([.init("id", .number(id)), .init("label", .string(screen.localizedName)), .init("primary", .bool(id == primary)),
                            .init("width", .number(Double(screen.frame.width))), .init("height", .number(Double(screen.frame.height)))])
        }
    }
    /// platform/host.ts thisMachineName: the hostname without `.local`.
    public static func thisMachineName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "" }
        let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.replacingOccurrences(of: #"\.local$"#, with: "", options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// browser:window-opened's `known` entry, onto the Safari owner's one map.
    /// Only `viewId` falls back to what was known; the rest is what was reported.
    @MainActor static func windowOpened(_ map: BackendBrowserBindings, tabID: String, input: NativeRPCValue) {
        let before = map.window(tabID)
        map.observe(.init(tabID: tabID, viewID: input["viewId"].string ?? before?.viewID ?? tabID,
            url: input["url"].string ?? "", title: input["title"].string ?? "",
            hostMachineID: input["machineId"].string ?? "", hostMachineName: input["machineName"].string ?? "",
            visible: input["visible"].bool == true, width: before?.width ?? 0))
    }

    /// browser-binding-ipc.ts bindMenuModel (L668-731) rows, from the native map.
    @MainActor static func bindMenuRows(_ map: BackendBrowserBindings, sessionID: String, machineID: String, thisMachine: String) -> NativeRPCValue {
        func row(_ type: String, _ label: String, enabled: Bool, checked: Bool = false, act: NativeRPCValue = .null) -> NativeRPCValue {
            .object([.init("type", .string(type)), .init("label", .string(label)), .init("enabled", .bool(enabled)),
                     .init("checked", .bool(checked)), .init("act", act)])
        }
        func number(_ id: String) -> Int { map.displayName(id).flatMap { Int($0.dropFirst()) } ?? Int.max }
        let owner = BackendBrowserPrincipal(ownerID: BackendCompositionRoot.appOwnerID, managesWindows: true)
        let bound = map.bindings(for: owner).of(BrowserDriverSession(sessionId: sessionID, machineId: machineID))
        // Insertion order is first-seen order, which is the W number's order.
        let windows = map.windows().sorted { number($0.tabID) < number($1.tabID) }
        var rows: [NativeRPCValue] = []
        if windows.isEmpty { rows.append(row("item", "No browser windows are open.", enabled: false)) }
        var order: [String] = [], groups: [String: [BackendBrowserBindings.Window]] = [:]
        for window in windows {
            if groups[window.hostMachineID] == nil { order.append(window.hostMachineID) }
            groups[window.hostMachineID, default: []].append(window)
        }
        // machineOrder: the machine this menu is about leads.
        if let at = order.firstIndex(of: machineID), at > 0 { order.remove(at: at); order.insert(machineID, at: 0) }
        for machine in order {
            let members = groups[machine] ?? []
            if order.count > 1 {
                let name = members.first?.hostMachineName ?? ""
                let label = machine.isEmpty ? (thisMachine.isEmpty ? "This computer" : thisMachine) : (name.isEmpty ? machine : name)
                rows.append(row("item", label, enabled: false))
            }
            for window in members {
                let slot = bound.first { $0.tabID == window.tabID }
                let lead = slot.map(\.name) ?? (map.displayName(window.tabID) ?? "")
                let said = window.title.isEmpty ? window.url : window.title
                let label = said.isEmpty ? lead : lead + "   " + said
                let act: NativeRPCValue = .object([.init("kind", .string(slot == nil ? "bind" : "unbind")), .init("tabId", .string(window.tabID))])
                rows.append(row("checkbox", label, enabled: true, checked: slot != nil, act: act))
            }
        }
        rows.append(row("separator", "", enabled: false))
        rows.append(row("item", "New window, attached", enabled: true, act: .object([.init("kind", .string("new-window"))])))
        return .array(rows)
    }
}

/// browser-reach.ts createReachLedger: which browser windows hold which
/// tunnel, so the last one out closes it. One per app.
public actor BackendCompositionBrowserReachLedger {
    public typealias Open = @Sendable (_ kind: String, _ machineID: String, _ port: Int) async -> NativeRPCValue
    public typealias Close = @Sendable (_ kind: String, _ machineID: String, _ port: Int) async -> Bool
    public struct Machine: Sendable { public let id: String, name: String, kind: String }
    private struct Entry: Sendable {
        let machineID: String; var machineName: String; let kind: String; let port: Double
        var localPort: Double; var sameNumber: Bool; var holders: Set<String>; var stranded: Bool
    }
    private var entries: [String: Entry] = [:]
    private let registry: NativeChannelRegistry
    private let openTunnel: Open, closeTunnel: Close

    public init(registry: NativeChannelRegistry, open: @escaping Open, close: @escaping Close) {
        self.registry = registry; openTunnel = open; closeTunnel = close
    }
    /// index.ts L3982-3999 over the native owners, with its sentences when one is absent.
    public static func owners(machines: BackendMachineCoordinator?, servers: BackendServersReach?) -> (open: Open, close: Close) {
        let open: Open = { kind, id, port in
            if kind == "server" {
                guard let servers else { return Self.failed("This build cannot reach a server.") }
                return await servers.reach(id, port: port)
            }
            guard let machines else { return Self.failed("This build cannot reach another machine.") }
            do { return try await machines.reach(id, port: port).value }
            catch { return Self.failed(NativeRPCError.wrapping(error).message) }
        }
        let close: Close = { kind, id, port in
            if kind == "server" { return await servers?.closeReach(id, port: port) ?? false }
            guard let machines else { return false }
            await machines.closeReach(id, port: port); return true
        }
        return (open, close)
    }
    static func failed(_ message: String) -> NativeRPCValue { .object([.init("ok", .bool(false)), .init("message", .string(message))]) }
    /// asMachine: an object with a non-empty id; kind is server or device.
    public static func machine(_ value: NativeRPCValue) -> Machine? {
        guard value.fields != nil, let id = value["id"].string, !id.isEmpty else { return nil }
        return .init(id: id, name: value["name"].string ?? "", kind: value["kind"].string == "server" ? "server" : "device")
    }
    private static func key(_ machineID: String, _ port: Double) -> String { machineID + " " + NativeRPCValue.number(port).compact }
    private static func view(_ entry: Entry) -> NativeRPCValue {
        .object([.init("machineId", .string(entry.machineID)), .init("machineName", .string(entry.machineName)), .init("kind", .string(entry.kind)),
                 .init("port", .number(entry.port)), .init("localPort", .number(entry.localPort)), .init("sameNumber", .bool(entry.sameNumber)),
                 .init("holders", .number(Double(entry.holders.count))), .init("stranded", .bool(entry.stranded))])
    }
    public func list() -> NativeRPCValue {
        .array(entries.values.sorted { a, b in
            let names = a.machineName.localizedCompare(b.machineName)
            return names == .orderedSame ? a.port < b.port : names == .orderedAscending
        }.map(Self.view))
    }
    private func changed() async {
        try? await registry.publish(BackendCompositionBrowserChannels.reachStateChannel, arguments: [list()], ownerID: BackendCompositionRoot.appOwnerID)
    }
    /// shutDown: a listener that would not close stays, marked stranded.
    private func shutDown(_ key: String) async -> Bool {
        guard let entry = entries[key] else { return true }
        guard let port = Int(exactly: entry.port) else { entries[key]?.stranded = true; return false }
        if await closeTunnel(entry.kind, entry.machineID, port) { entries[key] = nil; return true }
        entries[key]?.stranded = true; return false
    }
    public func hold(holder: String, machine: Machine, port: Double) async -> NativeRPCValue {
        guard let wanted = Int(exactly: port) else {
            return .object([.init("answer", Self.failed("That is not a window, a machine and a port.")), .init("stranded", .null)])
        }
        let answer = await openTunnel(machine.kind, machine.id, wanted)
        guard answer["ok"].bool == true else { return .object([.init("answer", answer), .init("stranded", .null)]) }
        let key = Self.key(machine.id, port), localPort = answer["localPort"].number ?? 0
        var entry = entries[key] ?? Entry(machineID: machine.id, machineName: machine.name, kind: machine.kind, port: answer["port"].number ?? port,
                                          localPort: localPort, sameNumber: answer["sameNumber"].bool == true, holders: [], stranded: false)
        entry.machineName = machine.name; entry.localPort = localPort
        entry.sameNumber = answer["sameNumber"].bool == true; entry.stranded = false; entry.holders.insert(holder)
        entries[key] = entry
        // One local number, one tunnel: another machine's listener on it goes.
        var stranded: NativeRPCValue = .null
        for (otherKey, other) in entries where other.machineID != machine.id && other.localPort == localPort {
            let closed = await shutDown(otherKey)
            if !closed, let still = entries[otherKey] { stranded = Self.view(still) }
        }
        await changed()
        return .object([.init("answer", answer), .init("stranded", stranded)])
    }
    public func release(holder: String, machineID: String, port: Double) async -> NativeRPCValue {
        let key = Self.key(machineID, port)
        guard var entry = entries[key] else { return Self.released(gone: true, holders: 0, message: "") }
        entry.holders.remove(holder); entries[key] = entry
        if !entry.holders.isEmpty {
            await changed()
            return Self.released(gone: false, holders: entry.holders.count,
                                 message: "Another browser window is still reading \(entry.machineName):\(NativeRPCValue.number(entry.port).compact) here.")
        }
        let gone = await shutDown(key)
        await changed()
        return Self.released(gone: gone, holders: 0, message: gone ? "" : "\(entry.machineName) is still serving port \(NativeRPCValue.number(entry.localPort).compact) here.")
    }
    private static func released(gone: Bool, holders: Int, message: String) -> NativeRPCValue {
        .object([.init("gone", .bool(gone)), .init("holders", .number(Double(holders))), .init("message", .string(message))])
    }
    /// A browser window closed: everything it was the last reader of goes with it.
    public func dropHolder(_ holder: String) async {
        var touched = false
        for key in Array(entries.keys) {
            guard entries[key]?.holders.remove(holder) != nil else { continue }
            touched = true
            if entries[key]?.holders.isEmpty == true { _ = await shutDown(key) }
        }
        if touched { await changed() }
    }
    /// The machine's tunnels went down with its link: forget them without closing.
    public func forget(_ machineID: String) async {
        let keys = entries.filter { $0.value.machineID == machineID }.map { $0.key }
        for key in keys { entries[key] = nil }
        if !keys.isEmpty { await changed() }
    }
}

/// browser-signin.ts readCliVersion's `exec`: `<command> --version` on the
/// person's login PATH (the providers owner's own measurement, including its
/// override), five seconds, stdout only. Like the source's catch, a CLI that is
/// missing, fails, or overruns answers nil — never "stale"; only cancellation
/// propagates. Supply as `NativeCompositionBrowserDependencies.readVersionOutput`.
public enum BackendCompositionBrowserVersion {
    public static func reader(providers: BackendNativeProviders, executor: BackendDevProcessExecutor,
                              environment: [String: String], home: String) -> @Sendable (String) async throws -> String? {
        { command in
            try Task.checkCancellation()
            // A bare name from the sign-in table, looked up on the login PATH.
            guard !command.isEmpty, !command.contains("/"), !command.contains("\0") else { return nil }
            let path: String
            do { path = try await providers.loginPath() }
            catch is CancellationError { throw CancellationError() }
            catch { return nil }
            guard let executable = BackendNativeProviders.lookup(command, path: path) else { return nil }
            var launch = environment
            launch["PATH"] = path
            let outcome: BackendGitOutcome
            do {
                outcome = try await executor.run(command: executable, arguments: ["--version"], environment: launch, cwd: home,
                                                 timeoutMilliseconds: 5_000, maximumBytes: 256 * 1024)
            } catch is CancellationError { throw CancellationError() }
            catch { return nil }
            try Task.checkCancellation()
            return outcome.ok ? outcome.stdout : nil
        }
    }
}

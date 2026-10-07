import Foundation
import TerminalDeckNativeCore

/// Request 8: one inert registration over retained owners. No Hoot process,
/// monitor, transcript watch, plugin or listener starts during registration.
public enum BackendHootRegistration {
    public static let domain = "hoot"
    public static let menuInvokes: Set<String> = ["hoot-panel:snapshot", "hoot-panel:say", "hoot-panel:start-hoot", "hoot-panel:show-session", "hoot-menubar:config", "hoot-menubar:configure", "hoot-menubar:open"]
    public static let folderInvokes: Set<String> = ["copilot:folder", "copilot:folder:pick", "copilot:folder:clear"]
    public static let invokeChannels = Set(BackendCopilotSessionRuntime.channels + BackendCopilotInspect.channels).union(folderInvokes).union(menuInvokes)
    public static let sendChannels: Set<String> = ["hoot-panel:pointer", "hoot-panel:held", "hoot-panel:focus", "hoot-panel:close", "hoot-panel:size", "hoot-panel:resize", "hoot-panel:menu", "hoot-panel:catch", "session:labels"]
    public static let eventChannels: Set<String> = ["hoot-panel:snapshot"]
    public static let consumedEvents: Set<String> = ["prefs:changed", "settings:changed", "session:status", "session:renamed", "session:exit", "session:removed", "session:created", "session:switched"]
    /// These remain supplied to deck-tools, not installed a second time here.
    public static let delegatedHootToolIDs: Set<String> = ["hoot.state", "hoot.run", "hoot.instructions", "hoot.memory"]

    public struct Dependencies: Sendable {
        public let dataRoot: URL
        public let storageRoot: URL
        public let runtime: BackendCopilotSessionRuntime
        public let manager: BackendPTYManager
        public let lifecycle: BackendSessionLifecycleCoordinator
        public let folder: BackendCopilotFolderService
        public let mcpDoor: BackendCopilotSessionMCPDoor
        public let actionLog: BackendDeckCoreSecurityActionLog
        public let rawSink: any BackendHootJoinRawActionSink
        public let boundary: BackendHootJoinSpawnBoundary
        public let menu: BackendHootMenuBar
        public let menuSnapshot: BackendHootJoinMenuSnapshot
        public let screenMonitor: BackendHootScreenMonitor
        public let authority: any BackendHootRegistrationAuthority
        public let joins: any BackendHootRegistrationGraphJoins
        public let reveal: (any BackendCopilotInspectRevealing)?
        /// The backend half of the menu dependencies; started/stopped with the area.
        public let menuSupply: BackendHootJoinMenuSupply?
        public init(dataRoot: URL, storageRoot: URL, runtime: BackendCopilotSessionRuntime,
                    manager: BackendPTYManager, lifecycle: BackendSessionLifecycleCoordinator,
                    folder: BackendCopilotFolderService, mcpDoor: BackendCopilotSessionMCPDoor,
                    actionLog: BackendDeckCoreSecurityActionLog, rawSink: any BackendHootJoinRawActionSink,
                    boundary: BackendHootJoinSpawnBoundary, menu: BackendHootMenuBar,
                    menuSnapshot: BackendHootJoinMenuSnapshot, screenMonitor: BackendHootScreenMonitor,
                    authority: any BackendHootRegistrationAuthority, joins: any BackendHootRegistrationGraphJoins,
                    reveal: (any BackendCopilotInspectRevealing)? = nil, menuSupply: BackendHootJoinMenuSupply? = nil) {
            self.dataRoot = dataRoot; self.storageRoot = storageRoot; self.runtime = runtime; self.manager = manager
            self.lifecycle = lifecycle; self.folder = folder; self.mcpDoor = mcpDoor; self.actionLog = actionLog
            self.rawSink = rawSink; self.boundary = boundary; self.menu = menu; self.menuSnapshot = menuSnapshot
            self.screenMonitor = screenMonitor; self.authority = authority; self.joins = joins; self.reveal = reveal
            self.menuSupply = menuSupply
        }
    }
    public struct Installed: Sendable {
        public let ownerID: String
        public let invokes = invokeChannels
        public let sends = sendChannels
        public let events = eventChannels
        public let toolIDs: Set<String> = [] // Admin tools belong to deck-tools.
        public let sendSubscriptions: [NativeRPCSubscription]
        public let administrativeService: any BackendDeckToolsAppCopilotService
        private let state: State
        fileprivate init(ownerID: String, sendSubscriptions: [NativeRPCSubscription], state: State) {
            self.ownerID = ownerID; self.sendSubscriptions = sendSubscriptions; self.state = state
            administrativeService = Admin(owner: state)
        }
        public func start() async throws { try await state.start() }
        public func stop() async throws { try await state.stop() }
        public func disconnect(_ context: NativeRPCContext) async throws { try await state.disconnect(context) }
        public var area: BackendCompositionRoot.Area {
            .init(name: domain, domains: [domain], ownerID: ownerID, invokes: invokes, sends: sends, events: events, stop: { try await state.stop() })
        }
    }
    public static func verify(_ receipt: BackendHootJoinReceipt, dependencies d: Dependencies) throws {
        let scope = BackendCopilotSessionRuntime.homeScope(userData: d.dataRoot.path, storageDir: d.storageRoot.path)
        guard receipt.runtime === d.runtime, receipt.manager === d.manager, d.lifecycle.manager === d.manager,
              receipt.mcpDoor === d.mcpDoor, receipt.actionLog === d.actionLog,
              ObjectIdentifier(receipt.homeSink) == ObjectIdentifier(d.rawSink), ObjectIdentifier(receipt.toolSink) == ObjectIdentifier(d.rawSink),
              receipt.hidden === d.boundary.hidden,
              receipt.homeScope.home == scope.home, receipt.homeScope.folder == scope.folder else {
            throw NativeRPCError(code: "unavailable", message: "Hoot's installed joins do not belong to the same retained runtime, PTY, writer, hidden register and transcript scope.")
        }
        let missing = Set(BackendHootJoinCapability.allCases).subtracting(receipt.capabilities)
        guard missing.isEmpty else {
            throw NativeRPCError(code: "unavailable", message: "Hoot's required joins are unavailable: " + missing.map(\.rawValue).sorted().joined(separator: ", "))
        }
        let expectedLog = d.dataRoot.standardizedFileURL.appendingPathComponent("copilot-log/actions.jsonl").path
        guard d.rawSink.file.standardizedFileURL.path == expectedLog else {
            throw NativeRPCError(code: "unavailable", message: "Hoot's shared raw action writer belongs to another data folder.")
        }
    }
    public static func register(registry: NativeChannelRegistry, mcpServer: BackendNativeMCPServer,
                                dependencies d: Dependencies, oldHootOwnerDisabled: Bool,
                                ownerID: String? = nil) async throws -> Installed {
        guard oldHootOwnerDisabled else { throw NativeRPCError(code: "ownership-required", message: "The original Hoot owner must relinquish its sessions, island and action records before native registration.") }
        try verify(try await d.joins.installed(), dependencies: d)
        let owner = ownerID ?? "native-composition:hoot:" + UUID().uuidString.lowercased()
        guard !owner.isEmpty, !owner.contains("\0") else { throw NativeRPCError.invalidArguments("Hoot registration needs its actual area owner ID.") }
        let invokes = Set(await registry.channels()), sends = Set(await registry.sends())
        guard invokeChannels.isDisjoint(with: invokes), sendChannels.isDisjoint(with: sends) else {
            throw NativeRPCError(code: "duplicate-handler", message: "Hoot channels already have a native owner.")
        }
        let state = State(registry: registry, mcp: mcpServer, ownerID: owner, dependencies: d)
        var subscriptions: [NativeRPCSubscription] = []
        do {
            for channel in invokeChannels.sorted() {
                try await registry.register(channel, ownerID: owner) { context, args in
                    try await state.invoke(channel, context: context, args: args)
                }
            }
            for channel in sendChannels.sorted() {
                subscriptions.append(try await registry.onSend(channel, ownerID: owner) { context, args in
                    try await state.send(channel, context: context, args: args)
                })
            }
            await state.retainSends(subscriptions)
            return .init(ownerID: owner, sendSubscriptions: subscriptions, state: state)
        } catch {
            for subscription in subscriptions.reversed() { await subscription.cancelAndWait() }
            await registry.removeOwner(owner); throw error
        }
    }
    fileprivate actor State {
        let registry: NativeChannelRegistry
        let mcp: BackendNativeMCPServer // Shared collector; this area owns no tools.
        let owner: String
        let d: Dependencies
        var active = false, closed = false, didStart = false
        var startup: Task<Void, Error>?
        var sends: [NativeRPCSubscription] = []
        var watches: [NativeRPCSubscription] = []
        var pendingEvents: [NativeRPCEvent] = []
        var hiddenPredicate: UUID?
        init(registry: NativeChannelRegistry, mcp: BackendNativeMCPServer, ownerID: String, dependencies: Dependencies) {
            self.registry = registry; self.mcp = mcp; owner = ownerID; d = dependencies
        }
        func retainSends(_ values: [NativeRPCSubscription]) { sends = values }
        func requireStarted() throws {
            guard active, !closed else { throw NativeRPCError(code: "unavailable", message: "The native Hoot area is not started.") }
        }
        func source(_ context: NativeRPCContext) throws -> BackendHootRegistrationSource {
            guard context.caller != .pairedDevice else { return .unrelated }
            return try d.authority.source(context)
        }
        func requireWindow(_ context: NativeRPCContext) throws {
            guard try source(context) == .window else { throw NativeRPCError(code: "access-denied", message: "Hoot's desk session is available on this computer only.") }
        }
        func start() async throws {
            if active { return }
            guard !closed else { throw NativeRPCError(code: "unavailable", message: "The native Hoot registration is stopped.") }
            if let startup { return try await startup.value }
            let task = Task { try await self.startNow() }; startup = task
            defer { startup = nil }; try await task.value
        }
        func startNow() async throws {
            try BackendHootRegistration.verify(try await d.joins.installed(), dependencies: d)
            try Task.checkCancellation()
            guard !closed else { throw NativeRPCError(code: "unavailable", message: "The native Hoot registration stopped during startup.") }
            do {
                // Subscribe only on explicit area start. Registry events are
                // the single UI road; the lifecycle observer only releases leases.
                for channel in consumedEvents.sorted() {
                    watches.append(try await registry.subscribe(channel, ownerID: owner) { [weak self] event in
                        await self?.forward(event)
                    })
                }
                let lifecycleID = await d.lifecycle.observe { [weak self, boundary = d.boundary] event in
                    // Real reaped exit: release only an ID the boundary hid itself.
                    if case .exit(let id, _) = event { boundary.processReaped(id); await self?.releaseTools(id) }
                }
                watches.append(NativeRPCSubscription { [lifecycle = d.lifecycle] in await lifecycle.removeObserver(lifecycleID) })
                // host-core.ts: hidden = isCopilotSession(id) || isHiddenSession(id).
                hiddenPredicate = d.boundary.hidden.addPredicate { [runtime = d.runtime] id in runtime.isCopilotSession(id) }
                await d.menuSupply?.start()
                try await refreshMenu()
                try Task.checkCancellation()
                guard !closed else { throw NativeRPCError(code: "unavailable", message: "The native Hoot registration stopped during startup.") }
                try await MainActor.run { try d.menu.apply(); d.screenMonitor.start(bar: d.menu) }
                didStart = true
                try Task.checkCancellation()
                guard !closed else { throw NativeRPCError(code: "unavailable", message: "The native Hoot registration stopped during startup.") }
                active = true
                let queued = pendingEvents; pendingEvents = []
                for event in queued { await forward(event) }
            } catch {
                for subscription in watches.reversed() { await subscription.cancelAndWait() }; watches = []
                if let token = hiddenPredicate { d.boundary.hidden.removePredicate(token); hiddenPredicate = nil }
                await d.menuSupply?.stop()
                await MainActor.run { d.screenMonitor.stop(); d.menu.dispose() }; didStart = false; pendingEvents = []; throw error
            }
        }
        func refreshMenu() async throws {
            let state = try await d.runtime.state(), metadata = await d.lifecycle.metadata()
            await d.menuSnapshot.update(state, metadata: metadata)
        }
        func forward(_ event: NativeRPCEvent) async {
            guard !closed else { return }
            if !active {
                if startup != nil {
                    // Retain the bounded latest event road during the initial
                    // snapshot read; replay after activation, never start a watcher.
                    if pendingEvents.count == 256 { pendingEvents.removeFirst() }
                    pendingEvents.append(event)
                }
                return
            }
            do { try await refreshMenu(); await d.menu.forward(event.channel, arguments: event.arguments) }
            catch { NSLog("[native Hoot] could not refresh the island: %@", error.localizedDescription) }
        }
        func releaseTools(_ id: String) async { if active && !closed { await d.mcpDoor.release(sessionID: id) } }
        func inspection() -> BackendCopilotInspectDependencies {
            .init(userData: d.dataRoot.path, paths: { [runtime = d.runtime] in try await runtime.layerPaths() }, reveal: d.reveal)
        }
        func invoke(_ channel: String, context: NativeRPCContext, args: [NativeRPCValue]) async throws -> NativeRPCValue {
            try requireStarted()
            if menuInvokes.contains(channel) {
                let role = try source(context)
                guard role == .window || role == .island else { throw NativeRPCError(code: "access-denied", message: "Hoot island controls are only available in the app.") }
                return try await menuInvoke(channel, value: args.first ?? .missing)
            }
            try requireWindow(context)
            return try await backendInvoke(channel, args: args)
        }
        func backendInvoke(_ channel: String, args: [NativeRPCValue]) async throws -> NativeRPCValue {
            try requireStarted()
            let value: (Int) -> NativeRPCValue = { args.indices.contains($0) ? args[$0] : .missing }
            if BackendCopilotSessionRuntime.channels.contains(channel) { return try await d.runtime.invoke(channel, arguments: args) }
            if folderInvokes.contains(channel) {
                guard args.isEmpty else { throw NativeRPCError.invalidArguments("Expected 0...0 arguments, got \(args.count)") }
                if channel == "copilot:folder" { return try await d.folder.report().wireValue }
                if channel == "copilot:folder:pick" { return try await d.folder.pick().wireValue }
                return try await d.folder.clear().wireValue
            }
            let paths = try await d.runtime.layerPaths()
            switch channel {
            case "copilot:scaffold":
                let result = BackendCopilotHome.scaffold(paths)
                if result.error == nil && !result.created.isEmpty {
                    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let row = NativeRPCValue.object([.init("at", .string(formatter.string(from: Date()))), .init("action", .string("home.created")),
                        .init("detail", .string("created \(result.created.count) of Hoot's files, from Settings"))])
                    try? d.rawSink.append(try row.encodedJSON() + Data([10]), policy: .home(limit: BackendCopilotHome.logLimitBytes))
                }
                return result.wireValue
            case "copilot:memory": return BackendCopilotInspect.readMemory(paths).wireValue
            case "copilot:memory-read": return BackendCopilotInspect.readMemoryFact(paths, name: value(0))
            case "copilot:memory-write": return BackendCopilotInspect.writeMemoryFact(paths, name: value(0), text: value(1))
            case "copilot:memory-delete": return BackendCopilotInspect.deleteMemoryFact(paths, name: value(0))
            case "copilot:actions": return BackendCopilotInspect.readActionLog(paths, want: value(0).number ?? 200).wireValue
            case "copilot:reveal": return try await BackendCopilotInspect.reveal(inspection(), place: value(0))
            default: throw NativeRPCError(code: "unavailable", message: "Unknown Hoot session channel.")
            }
        }
        func menuInvoke(_ channel: String, value: NativeRPCValue) async throws -> NativeRPCValue {
            switch channel {
            case "hoot-panel:snapshot": return await d.menu.snapshot()
            case "hoot-panel:say": return await d.menu.say(value)
            case "hoot-panel:start-hoot": return await d.menu.startHoot()
            case "hoot-panel:show-session":
                guard let id = value.string else { return .object([.init("ok", .bool(false))]) }
                return await d.menu.showSession(id)
            case "hoot-menubar:config": return await d.menu.config()
            case "hoot-menubar:configure": return try await d.menu.configure(value)
            case "hoot-menubar:open": return await d.menu.openPanel()
            default: throw NativeRPCError(code: "missing-handler", message: "Unknown Hoot island channel.")
            }
        }
        func send(_ channel: String, context: NativeRPCContext, args: [NativeRPCValue]) async throws {
            try requireStarted()
            let role = try source(context), value = args.first ?? .missing
            if context.caller == .pairedDevice { throw NativeRPCError(code: "access-denied", message: "Hoot island controls are only available in the app.") }
            if channel == "session:labels" { if role == .window && value.fields != nil { await d.menu.setLabels(value) }; return }
            let permitted = channel == "hoot-panel:catch" ? role == .catcher : channel == "hoot-panel:menu" ? role == .island || role == .catcher : role == .island
            guard permitted else { return } // Original sender mismatch is ignored.
            if channel == "hoot-panel:resize" { try await d.menu.resize(owner: context.ownerID, argument: value) }
            else { await d.menu.event(channel, owner: context.ownerID, argument: value) }
        }
        func disconnect(_ context: NativeRPCContext) async throws {
            let role = try source(context)
            guard role != .unrelated else { return }
            if role == .window { try await d.joins.windowGone(context) }
            else if active { await MainActor.run { d.screenMonitor.stop(); d.menu.dispose() } }
        }
        func stop() async throws {
            if closed && !didStart { await cleanupRoutes(); return }
            closed = true; active = false
            startup?.cancel()
            if let startup { _ = try? await startup.value }
            if didStart {
                // Required joined supplier drains pending launches first. The
                // old stop() alone cannot drain its private startup Task latch.
                try await d.joins.quiesceAndStopHoot()
                await d.mcpDoor.stop()
                await MainActor.run { d.screenMonitor.stop(); d.menu.dispose() }
                await d.menuSupply?.stop()
                didStart = false
            }
            for subscription in watches.reversed() { await subscription.cancelAndWait() }; watches = []
            // Only after the desk Hoot is stopped: its ID stops being hidden.
            if let token = hiddenPredicate { d.boundary.hidden.removePredicate(token); hiddenPredicate = nil }
            await cleanupRoutes()
        }
        func cleanupRoutes() async {
            for subscription in sends.reversed() { await subscription.cancelAndWait() }; sends = []
            await registry.removeOwner(owner)
        }
    }
    private struct Admin: BackendDeckToolsAppCopilotService {
        let owner: State
        func state() async throws -> NativeRPCValue {
            try await owner.backendInvoke("copilot:state", args: [])
        }
        func signIn() async throws -> NativeRPCValue { try await owner.backendInvoke("copilot:signin", args: []) }
        func start() async throws -> NativeRPCValue { try await owner.backendInvoke("copilot:ensure", args: []) }
        func stop() async throws -> NativeRPCValue { try await owner.backendInvoke("copilot:stop", args: []) }
        func scaffold() async throws -> NativeRPCValue { try await owner.backendInvoke("copilot:scaffold", args: []) }
        func reveal(_ place: String) async throws -> NativeRPCValue { try await owner.backendInvoke("copilot:reveal", args: [.string(place)]) }
        func readInstructions(_ which: String) async throws -> NativeRPCValue {
            let channels = ["yours": "copilot:read-instructions", "folder": "copilot:read-folder-instructions", "contract": "copilot:read-contract", "composed": "copilot:read-composed"]
            guard let channel = channels[which] else { throw NativeRPCError.invalidArguments("Choose yours, folder, contract or composed instructions.") }
            return try await owner.backendInvoke(channel, args: [])
        }
        func writeInstructions(_ which: String, text: String) async throws -> NativeRPCValue {
            guard which == "yours" || which == "folder" else { throw NativeRPCError.invalidArguments("Only yours and folder instructions can be written.") }
            return try await owner.backendInvoke(which == "yours" ? "copilot:write-instructions" : "copilot:write-folder-instructions", args: [.string(text)])
        }
        func resetInstructions() async throws -> NativeRPCValue { try await owner.backendInvoke("copilot:reset-instructions", args: []) }
        func listMemory() async throws -> NativeRPCValue { try await owner.backendInvoke("copilot:memory", args: []) }
        func readMemory(_ name: String) async throws -> NativeRPCValue { try await owner.backendInvoke("copilot:memory-read", args: [.string(name)]) }
        func writeMemory(_ name: String, text: String) async throws -> NativeRPCValue { try await owner.backendInvoke("copilot:memory-write", args: [.string(name), .string(text)]) }
        func deleteMemory(_ name: String) async throws -> NativeRPCValue { try await owner.backendInvoke("copilot:memory-delete", args: [.string(name)]) }
    }
}

public extension BackendCompositionRoot {
    @discardableResult
    func installHoot(dependencies: BackendHootRegistration.Dependencies, oldHootOwnerDisabled: Bool) async throws -> BackendHootRegistration.Installed {
        try requireAssemblyOpen()
        let installed = try await BackendHootRegistration.register(registry: registry, mcpServer: mcp,
            dependencies: dependencies, oldHootOwnerDisabled: oldHootOwnerDisabled)
        do { try await retain(installed.area); return installed }
        catch { try await installed.stop(); throw error }
    }
}

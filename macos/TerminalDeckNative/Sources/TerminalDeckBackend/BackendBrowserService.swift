import Foundation
import TerminalDeckNativeCore

@MainActor
public final class BackendBrowserService {
    public typealias Resolve = @Sendable (NativeRPCContext) async throws -> BackendBrowserPrincipal
    public typealias Authorize = @Sendable (BackendBrowserAccess) async throws -> Void
    public typealias Forward = @Sendable (BackendBrowserPrincipal, String, NativeRPCValue) async throws -> NativeRPCValue
    public typealias ResolveSession = @Sendable (String) async throws -> BrowserDriverSession
    public typealias ResolveProfile = @Sendable (NativeRPCContext, String?) async throws -> BackendBrowserWebsiteProfile
    public typealias Publish = @Sendable (NativeRPCContext, String, NativeRPCValue) async throws -> Void
    public let runtime: any BackendBrowserRuntime
    public let bindings: BackendBrowserBindings
    private let resolve: Resolve
    private let authorize: Authorize
    private let forward: Forward?
    private let resolveSession: ResolveSession
    private let resolveProfile: ResolveProfile
    private let resolveCreationProfile: ResolveProfile
    private let publish: Publish
    private let reportEventFailure: @Sendable (NativeRPCError) -> Void
    private var listeners: [String: NativeRPCContext] = [:]
    private var updateTask: Task<Void, Never>?
    private var updateRequested = false
    private var active: Set<String> = []
    private var stepCounts: [String: Int] = [:]
    private var currentTabs: [String: String] = [:]
    /// When an agent last touched each page (browser-driver.ts slot.touchedAt), for the window's drive band.
    private var touchedAt: [String: Double] = [:]
    private var ownerEpochs: [String: UInt64] = [:]
    private var closed = false
    public init(runtime: any BackendBrowserRuntime, bindings: BackendBrowserBindings,
                resolve: @escaping Resolve, resolveSession: @escaping ResolveSession, resolveProfile: @escaping ResolveProfile,
                resolveCreationProfile: @escaping ResolveProfile,
                authorize: @escaping Authorize, publish: @escaping Publish,
                reportEventFailure: @escaping @Sendable (NativeRPCError) -> Void, forward: Forward? = nil) {
        self.runtime = runtime; self.bindings = bindings; self.resolve = resolve
        self.authorize = authorize; self.forward = forward
        self.resolveSession = resolveSession
        self.resolveProfile = resolveProfile
        self.resolveCreationProfile = resolveCreationProfile
        self.publish = publish; self.reportEventFailure = reportEventFailure
        bindings.changed = { [weak self] in self?.scheduleUpdates() }
    }
    public func principal(_ context: NativeRPCContext) async throws -> BackendBrowserPrincipal {
        guard !closed else { throw NativeRPCError(code: "closed", message: "The native browser service is shut down.") }
        let epoch = ownerEpochs[context.ownerID, default: 0]
        let principal = try await resolve(context)
        guard !closed, epoch == ownerEpochs[context.ownerID, default: 0] else { throw NativeRPCError(code: "not-permitted", message: "This browser caller disconnected while its grant was being resolved.") }
        guard principal.ownerID == context.ownerID, !principal.ownerID.isEmpty,
              principal.sessionID != nil || principal.managesWindows else {
            throw NativeRPCError(code: "not-permitted", message: "This caller has no browser grant.")
        }
        // Only a window (the app's own, or a paired device's) receives browser events;
        // an MCP caller's context lives for one call, and keeping it made every later
        // update fail its permission check and log a removal (lane BR, walk 4).
        if context.caller == .nativeApp || context.caller == .pairedDevice { listeners[context.ownerID] = context }
        return principal
    }
    /// browser-driver.ts keeps one own slot (`this.own`): the tab Hoot and anyone acting
    /// as the person drive when no window is named. A core call's owner id is new on
    /// every call, so keying it by caller lost the tab between `open` and `read`
    /// (lane BR, walk 4). A session's calls share one slot per session.
    nonisolated static let ownSlot = "own"
    nonisolated static func slot(_ who: BackendBrowserPrincipal) -> String {
        who.session.map { "session:" + BrowserBindings.key($0) } ?? ownSlot
    }
    public func bindingsView(_ context: NativeRPCContext) async throws -> NativeRPCValue {
        let who = try await principal(context)
        try await authorize(.init(tool: "browser:bindings", principal: who, tier: .read))
        return bindings.view(for: who)
    }
    public func driveStatus(_ context: NativeRPCContext) async throws -> NativeRPCValue {
        let who = try await principal(context)
        try await authorize(.init(tool: "browser:drive-status", principal: who, tier: .read))
        return status(for: who)
    }
    public func windows(_ context: NativeRPCContext, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        let who = try await principal(context)
        guard who.managesWindows, context.caller != .pairedDevice else { throw NativeRPCError(code: "not-permitted", message: "This caller cannot enumerate or manage other browser windows.") }
        let action = arguments["action"].string ?? "list"
        guard ["list", "open", "close", "attach", "detach", "reach", "unreach"].contains(action) else { throw NativeRPCError.invalidArguments("Unknown window action.") }
        try await authorize(.init(tool: "browser.windows", principal: who,
            tier: ["attach", "detach"].contains(action) ? .alter : action == "list" ? .read : .act))
        if action == "list" {
            return .object([.init("windows", .array(bindings.windows().map { window in
                var row = window.value.setting("window", .string(bindings.displayName(window.tabID) ?? ""))
                if let owner = bindings.owner(of: window.tabID), let bound = bindings.bindings(for: who).of(owner).first(where: { $0.tabID == window.tabID }) {
                    row = row.setting("attachedTo", .object([.init("sessionId", .string(owner.sessionId)), .init("as", .string(bound.name))]))
                } else { row = row.setting("attachedTo", .null) }
                return row.removing("tabId").removing("browserTabId").removing("viewId")
            }))])
        }
        if action == "reach" || action == "unreach" {
            guard let forward else { throw NativeRPCError(code: "unavailable", message: "The authorized remote reach transport has not been supplied.") }
            return try await forward(who, "browser.windows", arguments)
        }
        if action == "open" {
            let state = try await nativeCreate(context, arguments: arguments)
            let id = try state["id"].requireString("tabId")
            _ = await runtime.reveal(id)
            return state.removing("id").setting("window", .string(bindings.displayName(id) ?? ""))
        }
        let name = try arguments["window"].requireString("window", nonempty: true)
        let session: BrowserDriverSession?
        if let named = arguments["sessionId"].string { session = try await resolveSession(named) } else { session = nil }
        guard let window = bindings.named(name, session: name.uppercased().hasPrefix("B") ? session : nil) else { throw NativeRPCError(code: "not-permitted", message: "No browser window by that name is available.") }
        switch action {
        case "close": runtime.closeTab(window.tabID); bindings.closed(window.tabID)
        case "detach": bindings.detach(window.tabID); runtime.unbind(window.tabID)
        case "attach":
            guard let session else { throw NativeRPCError.invalidArguments("Attach needs a sessionId.") }
            try await authorize(.init(tool: "browser.windows", principal: who, tabID: window.tabID, tier: .alter, targetSession: session))
            return .object([.init("window", .string(try bindings.attach(window.tabID, to: session).name))])
        default: break
        }
        return .object([.init("window", .string(name)), .init("action", .string(action))])
    }
    public func bind(_ context: NativeRPCContext, arguments: NativeRPCValue, detach: Bool = false) async throws -> NativeRPCValue {
        let who = try await principal(context)
        guard who.managesWindows else { throw NativeRPCError(code: "not-permitted", message: "Only the person's browser picker may attach or detach a window.") }
        let id = try arguments["tabId"].requireString("tabId", nonempty: true)
        if detach {
            try await authorize(.init(tool: "browser:unbind", principal: who, tabID: id, tier: .alter))
            bindings.detach(id); runtime.unbind(id); return .null
        }
        let session = try await resolveSession(arguments["sessionId"].requireString("sessionId", nonempty: true))
        if let machine = arguments["machineId"].string, machine != session.machineId { throw NativeRPCError(code: "not-permitted", message: "That session's machine does not match this binding request.") }
        try await authorize(.init(tool: "browser:bind", principal: who, tabID: id, tier: .alter, targetSession: session))
        let bound = try bindings.attach(id, to: session)
        return .object([.init("window", .string(bound.name))])
    }
    /// browser-tools.ts `mayDrive` (key-reach.test.ts L65), same refusals and words:
    /// nobody but a calling session or someone acting as the owner (the person here,
    /// an AI app on their access key) drives this browser, and never an unwatched run.
    public static func mayDrive(tool: String, callingSession: String?, actsAsOwner: Bool, attended: Bool?) throws {
        if callingSession == nil && !actsAsOwner {
            throw NativeRPCError(code: "not-granted", message: "\(tool) only works for the person at this machine. Driving a browser from a paired device is "
                + "not something this app does, and it will not be. Say what you would have opened and let them do it.")
        }
        if attended == false {
            throw NativeRPCError(code: "not-permitted-unattended", message: "\(tool) drives a browser that holds the person's logins, and there is nobody at the machine to "
                + "watch it. Do not retry and do not look for another way. Say in your report what you would have driven and why.")
        }
    }
    /// `attended` is the MCP caller's (false for a routine with nobody watching);
    /// nil for callers that have no such notion, as in the source.
    public func drive(_ context: NativeRPCContext, verb: BrowserDriverVerb, arguments: NativeRPCValue, attended: Bool? = nil) async throws -> NativeRPCValue {
        let who = try await principal(context)
        let epoch = ownerEpochs[who.ownerID, default: 0]
        let tool = verb.rawValue.replacingOccurrences(of: "_", with: ".")
        // A paired device never drives this Mac's browser, not even by naming a session.
        try Self.mayDrive(tool: tool, callingSession: context.caller == .pairedDevice ? nil : who.sessionID,
                          actsAsOwner: context.caller != .pairedDevice, attended: attended)
        _ = try arguments.requireObject("browser arguments")
        if who.routesToOriginatingDevice {
            guard let forward else { throw NativeRPCError(code: "unavailable", message: "The originating device's browser transport is unavailable.") }
            try await authorize(.init(tool: tool, principal: who, tier: verb == .read || verb == .screenshot ? .read : .act))
            return try await forward(who, tool, arguments)
        }
        // browser-tools.ts refuseAPathOnTheWrongComputer (L707-716), run in the
        // screenshot precheck (L1142) before the window is resolved: a session
        // on another computer would be handed a path to a file on this Mac.
        if verb == .screenshot, !who.machineID.isEmpty {
            throw NativeRPCError(code: "not-permitted", message: "browser.screenshot writes the picture on the computer the browser window is on, so the path it answers with is not a file you can open. Use browser.read: the outline is what tells you what to click, and a picture is not.")
        }
        let selectedSession = try await commandSession(who, verb: verb, arguments: arguments)
        guard let command = BrowserDriverCommand.decode([["id": context.requestID.uuidString, "verb": verb.rawValue,
            "args": arguments.foundation ?? [:], "session": selectedSession.map { ["sessionId": $0.sessionId, "machineId": $0.machineId] } as Any? ?? NSNull()]]) else {
            throw NativeRPCError.invalidArguments("Invalid browser command.")
        }
        let target = try Self.resolveTarget(command, bindings: bindings.bindings(for: who))
        let tabID: String?
        switch target {
        case .own: tabID = bindings.ownTab(Self.slot(who))
        case .window(let bound, _): tabID = bound.tabID
        case .newWindow: tabID = nil
        }
        if let tabID, let window = bindings.window(tabID), !window.hostMachineID.isEmpty {
            guard let forward else { throw NativeRPCError(code: "unavailable", message: "This window needs the authorized remote browser transport.") }
            try await authorize(.init(tool: tool, principal: who, tabID: tabID, tier: verb == .read || verb == .screenshot ? .read : .act))
            return try await forward(who, tool, arguments)
        }
        let lockKey = tabID ?? "owner:\(who.ownerID):\(who.sessionID ?? "")"
        guard !active.contains(lockKey) else { throw NativeRPCError(code: "busy", message: "Another browser operation is still using this page.") }
        active.insert(lockKey); defer { active.remove(lockKey) }
        defer { scheduleUpdates() }
        let state = tabID.flatMap { try? runtime.pageState($0) }
        if verb != .handover, let tabID, runtime.handoverPrompt(tabID) != nil {
            throw NativeRPCError(code: "not-permitted", message: "The person has this page right now. Wait for Done or Stop.")
        }
        let origin = tabID.flatMap { BackendBrowserOrigin.exact(runtime.pageURL($0)) }
        let tier: BackendMCPTier = verb == .read || verb == .screenshot ? .read
            : verb == .step && origin.map({ !BackendBrowserOrigin.isPrivate($0) }) == true ? .alter : .act
        // Refuse known secret targets before asking for public-site consent.
        if verb == .step, arguments["verb"].string == "type", let tabID,
           let selector = arguments["selector"].string {
            let raw = try await runtime.evaluate(tabID, BrowserDriverScripts.with(BrowserDriverScripts.probe, args: ["selector": BrowserElementRef.selector(for: selector)]))
            if (raw as? [String: Any])?["secret"] as? Bool == true {
                throw NativeRPCError(code: "not-permitted", message: "This is a secret field. Use browser.handover so the person can fill it.")
            }
        }
        let targetSession: BrowserDriverSession?
        switch target { case .newWindow(let session), .window(_, let session): targetSession = session; case .own: targetSession = nil }
        try await authorize(.init(tool: tool, principal: who, tabID: tabID, profileID: state?["profileId"].string, origin: origin, tier: tier, targetSession: targetSession, arguments: arguments))
        try Task.checkCancellation()
        guard !closed, epoch == ownerEpochs[who.ownerID, default: 0] else { throw NativeRPCError(code: "not-permitted", message: "This browser call's grant was revoked.") }
        if let tabID { currentTabs[Self.slot(who)] = tabID; touchedAt[tabID] = Date().timeIntervalSince1970 * 1000 }
        scheduleUpdates()
        let host = BackendBrowserCallHost(runtime: runtime, bindings: bindings, principal: who, origin: origin, authority: { [weak self] in
            guard let self else { return false }; return !self.closed && self.ownerEpochs[who.ownerID, default: 0] == epoch
        }) { [weak self] id in
            self?.currentTabs[Self.slot(who)] = id; self?.touchedAt[id] = Date().timeIntervalSince1970 * 1000; self?.scheduleUpdates()
        }
        let result = try NativeRPCValue.fromFoundation(await BrowserDriverEngine(host: host).answer(command))
        try Task.checkCancellation()
        guard !closed, epoch == ownerEpochs[who.ownerID, default: 0] else { throw NativeRPCError(code: "not-permitted", message: "This browser call disconnected before its result could be returned.") }
        if let error = result["error"].string { throw NativeRPCError(code: "browser-refused", message: error) }
        if verb == .step, let tabID { stepCounts[tabID, default: 0] += 1 }
        if let id = host.ownTabID, let state = try? runtime.pageState(id) {
            bindings.observe(.init(tabID: id, viewID: id, url: state["url"].string ?? "", title: state["title"].string ?? ""))
        }
        return result["value"]
    }
    /// Page/frame operations use the same target ownership as the six tools.
    /// INT (deck-tools browser.extract): the page a recipe would run on, by the same target rules as
    /// page(operation: "extract", sessionReader: true); no consent, no page command. Nil = not knowable here.
    public func extractionOrigin(_ context: NativeRPCContext, arguments: NativeRPCValue) async throws -> String? {
        let who = try await principal(context)
        guard context.caller != .pairedDevice else { throw NativeRPCError(code: "not-permitted", message: "A paired device may not drive this Mac's browser.") }
        if who.routesToOriginatingDevice { return nil }
        let id: String
        if who.managesWindows, let named = arguments["window"].string, named.uppercased().hasPrefix("W") {
            guard let window = bindings.named(named) else { throw NativeRPCError(code: "not-permitted", message: "No browser window by that name is available.") }
            id = window.tabID
        } else {
            let selectedSession = try await commandSession(who, verb: .read, arguments: arguments)
            let envelope: [String: Any] = ["id": context.requestID.uuidString, "verb": BrowserDriverVerb.read.rawValue,
                "args": arguments.foundation ?? [:], "session": selectedSession.map { ["sessionId": $0.sessionId, "machineId": $0.machineId] } as Any? ?? NSNull()]
            guard let command = BrowserDriverCommand.decode([envelope]) else { throw NativeRPCError.invalidArguments("Invalid target.") }
            switch try Self.resolveTarget(command, bindings: bindings.bindings(for: who)) {
            case .own: guard let own = bindings.ownTab(Self.slot(who)) else { return nil }; id = own
            case .window(let window, _): id = window.tabID
            case .newWindow: return nil
            }
        }
        guard runtime.handoverPrompt(id) == nil else { throw NativeRPCError(code: "not-permitted", message: "The person has this page right now.") }
        guard bindings.window(id)?.hostMachineID.isEmpty != false else { return nil }
        let url = runtime.pageURL(id); return url.isEmpty ? nil : url
    }
    public func page(_ context: NativeRPCContext, operation: String, arguments: NativeRPCValue, frame: Bool = false, sessionReader: Bool = false) async throws -> NativeRPCValue {
        let who = try await principal(context)
        guard context.caller != .pairedDevice else { throw NativeRPCError(code: "not-permitted", message: "A paired device may not drive this Mac's browser.") }
        guard who.managesWindows || sessionReader && operation == "extract" || frame && context.capabilities.contains("browser.frames") else {
            throw NativeRPCError(code: "not-permitted", message: "An ordinary session uses the six browser tools or an installed page reader. Browser toolbar management requires the person's grant.")
        }
        if operation == "reveal", !frame { return try await revealScreenshot(context, path: arguments["path"].requireString("path", nonempty: true)) }
        if who.routesToOriginatingDevice {
            guard let forward else { throw NativeRPCError(code: "unavailable", message: "The originating device's browser transport is unavailable.") }
            try await authorize(.init(tool: frame ? "browser.frames" : "browser.page", principal: who, tier: .act))
            return try await forward(who, frame ? "browser.frames" : "browser.page", arguments.setting("action", .string(operation)))
        }
        let id: String
        if who.managesWindows, let named = arguments["window"].string, named.uppercased().hasPrefix("W") {
            guard let window = bindings.named(named) else { throw NativeRPCError(code: "not-permitted", message: "No browser window by that name is available.") }
            id = window.tabID
        } else {
            let selectedSession = try await commandSession(who, verb: .read, arguments: arguments)
            let envelope: [String: Any] = ["id": context.requestID.uuidString, "verb": BrowserDriverVerb.read.rawValue,
                "args": arguments.foundation ?? [:], "session": selectedSession.map { ["sessionId": $0.sessionId, "machineId": $0.machineId] } as Any? ?? NSNull()]
            guard let command = BrowserDriverCommand.decode([envelope]) else { throw NativeRPCError.invalidArguments("Invalid target.") }
            let target = try Self.resolveTarget(command, bindings: bindings.bindings(for: who))
            switch target {
            case .own: guard let own = bindings.ownTab(Self.slot(who)) else { throw NativeRPCError(code: "not-permitted", message: "Open a page first.") }; id = own
            case .window(let window, _): id = window.tabID
            case .newWindow: throw NativeRPCError.invalidArguments("Open the window first.")
            }
        }
        guard runtime.handoverPrompt(id) == nil else { throw NativeRPCError(code: "not-permitted", message: "The person has this page right now.") }
        guard bindings.window(id)?.hostMachineID.isEmpty != false else {
            guard let forward else { throw NativeRPCError(code: "unavailable", message: "Remote browser transport is unavailable.") }
            try await authorize(.init(tool: frame ? "browser.frames" : "browser.page", principal: who, tabID: id, tier: .act))
            return try await forward(who, frame ? "browser.frames" : "browser.page", arguments.setting("action", .string(operation)))
        }
        guard operation != "evaluate" || who.evaluatesScripts else { throw NativeRPCError(code: "not-permitted", message: "Arbitrary page evaluation is reserved for an explicitly granted app tool; it is not an agent browser tool.") }
        guard !active.contains(id) else { throw NativeRPCError(code: "busy", message: "Another operation is using this page.") }
        active.insert(id); defer { active.remove(id) }
        let origin = BackendBrowserOrigin.exact(runtime.pageURL(id))
        let readOnly = ["state", "frames", "read", "wait", "snapshot", "screenshot", "recording", "extract"].contains(operation)
        let effectiveTier: BackendMCPTier = readOnly ? .read :
            ["recordclear", "evaluate"].contains(operation) ? .alter :
            frame && operation == "step" && origin.map({ !BackendBrowserOrigin.isPrivate($0) }) == true ? .alter : .act
        try await authorize(.init(tool: frame ? "browser.frames" : "browser.page", principal: who, tabID: id,
            profileID: try runtime.pageState(id)["profileId"].string, origin: origin,
            tier: effectiveTier, arguments: arguments))
        if frame, operation != "frames" {
            let state = try await runtime.frameCommand(id, operation: "state", arguments: arguments)
            guard let frameOrigin = state["url"].string.flatMap(BackendBrowserOrigin.exact) else { throw NativeRPCError(code: "not-permitted", message: "This frame has no allowed web origin.") }
            try await authorize(.init(tool: "browser.frames", principal: who, tabID: id,
                profileID: try runtime.pageState(id)["profileId"].string, origin: frameOrigin,
                tier: readOnly ? .read : operation == "evaluate" || operation == "step" && !BackendBrowserOrigin.isPrivate(frameOrigin) ? .alter : .act, arguments: arguments))
            // Pass the granted frame origin to the runtime, which verifies it
            // again after the consent callback before evaluating anything.
            let guarded = arguments.setting("authorizedOrigin", .string(frameOrigin))
            return try await runtime.frameCommand(id, operation: operation, arguments: guarded)
        }
        guard readOnly || BackendBrowserOrigin.exact(runtime.pageURL(id)) == origin else { throw NativeRPCError(code: "origin-changed", message: "The site changed while approval was pending. Try the action again.") }
        try Task.checkCancellation()
        let answer: NativeRPCValue
        if frame { answer = try await runtime.frameCommand(id, operation: operation, arguments: arguments) }
        else { answer = try await runtime.pageCommand(id, operation: operation, arguments: arguments) }
        guard (who.session == nil || bindings.owner(of: id) == who.session), runtime.handoverPrompt(id) == nil else {
            throw NativeRPCError(code: "not-permitted", message: "This page's grant changed while the operation was running.")
        }
        return answer
    }
    public func nativePage(_ context: NativeRPCContext, id: String, operation: String, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        let who = try await principal(context)
        guard who.managesWindows else { throw NativeRPCError(code: "not-permitted", message: "Use your session's named browser window.") }
        guard context.caller == .nativeApp || runtime.handoverPrompt(id) == nil else { throw NativeRPCError(code: "not-permitted", message: "The person has this page or its sign-in popup right now.") }
        try await authorize(.init(tool: "browser:\(operation)", principal: who, tabID: id,
            profileID: try runtime.pageState(id)["profileId"].string, origin: BackendBrowserOrigin.exact(runtime.pageURL(id)),
            tier: operation == "recordclear" ? .alter : ["state", "recording", "frame", "user-screenshot", "pick"].contains(operation) ? .read : .act, arguments: arguments))
        return try await runtime.pageCommand(id, operation: operation, arguments: arguments)
    }
    public func revealScreenshot(_ context: NativeRPCContext, path: String) async throws -> NativeRPCValue {
        let who = try await principal(context)
        guard who.managesWindows, context.caller != .pairedDevice else { throw NativeRPCError(code: "not-permitted", message: "Only the person's browser tools may reveal saved images.") }
        try await authorize(.init(tool: "browser-view:reveal", principal: who, tier: .act, resourcePath: path))
        try runtime.revealScreenshot(path); return .null
    }
    public func resume(_ context: NativeRPCContext, carryOn: Bool, tabID: String? = nil) async throws -> NativeRPCValue {
        let who = try await principal(context)
        guard who.managesWindows, context.caller == .nativeApp else { throw NativeRPCError(code: "not-permitted", message: "Only the person may return the browser baton.") }
        let ids = tabID.map { [$0] } ?? bindings.windows().map(\.tabID).filter { runtime.handoverPrompt($0) != nil }
        guard ids.count == 1, let id = ids.first else { throw NativeRPCError.invalidArguments("Name the browser tab to resume.") }
        try await authorize(.init(tool: "browser:drive-resume", principal: who, tabID: id, tier: .act))
        return try await runtime.pageCommand(id, operation: "resume", arguments: .object([.init("carryOn", .bool(carryOn))]))
    }
    public func nativeCreate(_ context: NativeRPCContext, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        let who = try await principal(context)
        guard who.managesWindows else { throw NativeRPCError(code: "not-permitted", message: "Use browser.open for your session.") }
        let profile = try await resolveCreationProfile(context, arguments["profileId"].string)
        try await authorize(.init(tool: "browser:create", principal: who, profileID: profile.id, tier: .act, arguments: arguments))
        let rawURL = (arguments["url"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // browser-tab.ts: an empty address opens the blank page (BLANK_URL); anything else must be an openable http(s) page.
        let url = rawURL.isEmpty || rawURL == "about:blank" ? URL(string: "about:blank")! : try BrowserStepRules.openableURL(rawURL)
        let isolationKey = arguments["isolationKey"].string
        if !arguments["isolationKey"].isNullish {
            guard let isolationKey, isolationKey.hasPrefix("terminaldeck-tab-"),
                  UUID(uuidString: String(isolationKey.dropFirst("terminaldeck-tab-".count))) != nil else {
                throw NativeRPCError.invalidArguments("The isolated tab key must be this app's temporary UUID partition.")
            }
        }
        let id = runtime.createProfileTab(url: url, isolated: isolationKey != nil || arguments["isolated"].bool == true, profileID: profile.id)
        if let isolationKey {
            do { _ = try await runtime.dataCommand("browser-data:bind-isolated", arguments: .object([.init("partition", .string(isolationKey)), .init("tabId", .string(id))])) }
            catch { runtime.closeTab(id); bindings.closed(id); throw error }
        }
        let state = try runtime.pageState(id)
        bindings.observe(.init(tabID: id, viewID: id, url: state["url"].string ?? "", title: state["title"].string ?? ""))
        return state
    }
    /// `browser:bind-new-window` ({ sessionId, machineId }): "New window, attached" from the bind menu
    /// (browser-binding-ipc.ts L1120 -> openNewBoundWindow -> openForSession with url '' and newWindow).
    /// A silent no-op without a sessionId, as in the source; refused like `browser:bind` otherwise.
    public func bindNewWindow(_ context: NativeRPCContext, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        guard let named = arguments["sessionId"].string, !named.isEmpty else { return .null }
        let who = try await principal(context)
        guard who.managesWindows else { throw NativeRPCError(code: "not-permitted", message: "Only the person's browser picker may attach or detach a window.") }
        let session = try await resolveSession(named)
        if let machine = arguments["machineId"].string, machine != session.machineId { throw NativeRPCError(code: "not-permitted", message: "That session's machine does not match this binding request.") }
        let created = try await nativeCreate(context, arguments: .object([]))
        let id = try created["id"].requireString("tabId", nonempty: true)
        do { try await authorize(.init(tool: "browser:bind", principal: who, tabID: id, tier: .alter, targetSession: session)) }
        catch { runtime.closeTab(id); bindings.closed(id); throw error }
        let bound = try bindings.attach(id, to: session)
        _ = await runtime.reveal(id)
        return .object([.init("window", .string(bound.name))])
    }
    public func openLink(_ context: NativeRPCContext, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        let who = try await principal(context)
        let url = try arguments["url"].requireString("url", nonempty: true)
        _ = try BrowserStepRules.openableURL(url)
        if who.routesToOriginatingDevice {
            guard let forward else { throw NativeRPCError(code: "unavailable", message: "The originating device's browser link transport is unavailable.") }
            try await authorize(.init(tool: "link:open", principal: who, tier: .act, arguments: arguments))
            return try await forward(who, "link:open", arguments)
        }
        let session: BrowserDriverSession?
        if let own = who.session {
            if let named = arguments["sessionId"].string, named != own.sessionId { throw NativeRPCError(code: "not-permitted", message: "This link does not belong to the calling session.") }
            session = own
        } else if let named = arguments["sessionId"].string { session = try await resolveSession(named) }
        else { session = nil }
        if let session {
            let existing = bindings.bindings(for: who).of(session).first
            var args = NativeRPCValue.object([.init("url", .string(url)), .init("sessionId", .string(session.sessionId))])
            if let existing, arguments["newWindow"].bool != true { args = args.setting("window", .string(existing.name)) }
            else { args = args.setting("newWindow", .bool(true)) }
            let value = try await drive(context, verb: .open, arguments: args)
            return .object([.init("route", .string("tab")), .init("line", value["line"].isNullish ? .string("Opened in \(value["window"].string ?? "the browser").") : value["line"]), .init("window", value["window"]), .init("url", value["url"])])
        }
        let value = try await nativeCreate(context, arguments: .object([.init("url", .string(url))]))
        let id = try value["id"].requireString("tabId", nonempty: true)
        _ = await runtime.reveal(id)
        return .object([.init("route", .string("tab")), .init("line", .string("Opened in the app's browser.")),
            .init("window", .string(bindings.displayName(id) ?? "")), .init("url", .string(url))])
    }
    public func data(_ context: NativeRPCContext, operation: String, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        let who = try await principal(context)
        guard who.managesWindows else { throw NativeRPCError(code: "not-permitted", message: "Browser profile data needs the person's explicit profile grant.") }
        let partition = arguments["partition"].string
        var profileID = partition
        if let partition, partition.hasPrefix("persist:terminaldeck-browser") {
            let requested: String
            if partition == "persist:terminaldeck-browser" { requested = "default" }
            else if partition.hasPrefix("persist:terminaldeck-browser-") { requested = String(partition.dropFirst("persist:terminaldeck-browser-".count)) }
            else { throw NativeRPCError.invalidArguments("Invalid browser partition.") }
            let known = try await resolveProfile(context, requested)
            guard known.partition == partition else { throw NativeRPCError(code: "not-permitted", message: "This partition does not match the granted live profile.") }
            profileID = known.id
        }
        let tabID = arguments["tabId"].string
        let requestURL = arguments["url"].string ?? arguments["details"]["url"].string ?? arguments["filter"]["url"].string
        try await authorize(.init(tool: operation, principal: who, tabID: tabID, profileID: profileID,
            origin: requestURL.flatMap(BackendBrowserOrigin.exact), tier: .alter, arguments: arguments))
        return try await runtime.dataCommand(operation, arguments: arguments)
    }
    /// browser-tools.ts noSuchWindow (L229-234): a bad target is a
    /// not-permitted refusal in the targeting rule's own words. The raw
    /// BrowserDriverRefusal is not a LocalizedError, so letting it escape would
    /// hand the caller Foundation's generic "operation couldn't be completed".
    private static func resolveTarget(_ command: BrowserDriverCommand, bindings: BrowserBindings) throws -> BrowserDriverTarget {
        do { return try BrowserDriverTargeting.resolve(command, bindings: bindings) }
        catch { throw NativeRPCError(code: "not-permitted", message: error.message) }
    }
    private func commandSession(_ who: BackendBrowserPrincipal, verb: BrowserDriverVerb, arguments: NativeRPCValue) async throws -> BrowserDriverSession? {
        if let own = who.session {
            // Both identifiers come from the live session table; a stale token
            // cannot keep a departed session's windows alive.
            let current = try await resolveSession(own.sessionId)
            guard current == own else { throw NativeRPCError(code: "not-permitted", message: "This session's browser grant is no longer current.") }
            return current
        }
        guard let named = arguments["sessionId"].string, !named.isEmpty else { return nil }
        guard arguments["window"].string != nil || verb == .open && arguments["newWindow"].bool == true else {
            throw NativeRPCError.invalidArguments("Name sessionId and window together, or use sessionId with newWindow.")
        }
        return try await resolveSession(named)
    }
    /// Called from the real browser/session/device teardown; no background
    /// event stream retains a departed caller or manufactures a new grant.
    public func disconnect(_ ownerID: String) { ownerEpochs[ownerID, default: 0] &+= 1; listeners[ownerID] = nil; currentTabs[ownerID] = nil; bindings.setOwnTab(ownerID, nil) }
    public func shutdown() { closed = true; updateTask?.cancel(); updateTask = nil; listeners.removeAll(); currentTabs.removeAll(); bindings.changed = nil }
    public func refreshEvents() { scheduleUpdates() }
    /// browser-driver.ts `showing()` + `status()`: of every page an agent holds (its
    /// own tab, or a window attached to a session), the one asking the person first,
    /// else the one touched last; idle when none. `driveChipText` reads it.
    func showingStatusValue() -> NativeRPCValue {
        let held = Set(currentTabs.compactMap { owner, tab -> String? in
            guard runtime.tabExists(tab), bindings.ownTab(owner) == tab || bindings.owner(of: tab) != nil else { return nil }
            return tab
        })
        let asking = held.filter { runtime.handoverPrompt($0) != nil }.sorted().first
        let id: String? = asking ?? held.max { (touchedAt[$0] ?? 0, $0) < (touchedAt[$1] ?? 0, $1) }
        let prompt: String = id.flatMap { runtime.handoverPrompt($0) } ?? ""
        let state: String = id == nil ? "idle" : (asking != nil ? "human" : "agent")
        let tabID: NativeRPCValue = id.map(NativeRPCValue.string) ?? .null
        let url: String = id.map { runtime.pageURL($0) } ?? ""
        let step: String = id.map { active.contains($0) && asking == nil ? "working on the page" : "" } ?? ""
        let steps: Int = id.flatMap { stepCounts[$0] } ?? 0
        return .object([.init("state", .string(state)), .init("tabId", tabID), .init("url", .string(url)),
            .init("prompt", .string(prompt)), .init("step", .string(step)), .init("stepCount", .number(Double(steps)))])
    }
    public func agentHolds(_ tabID: String) -> Bool {
        currentTabs.contains { owner, tab in tab == tabID && runtime.tabExists(tabID) &&
            (bindings.owner(of: tabID) != nil || bindings.ownTab(owner) == tabID) }
    }
    private func scheduleUpdates() {
        updateRequested = true
        guard !closed, updateTask == nil, !listeners.isEmpty else { return }
        updateTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            // Coalesced native events, not a timer or a polling service. An
            // update arriving during an awaited delivery gets one more pass.
            repeat {
              self.updateRequested = false
              for context in Array(self.listeners.values) {
                guard !Task.isCancelled else { break }
                do {
                    let who = try await self.resolve(context)
                    guard who.ownerID == context.ownerID else { throw NativeRPCError(code: "not-permitted", message: "The browser event owner changed.") }
                    try await self.authorize(.init(tool: "browser:bindings", principal: who, tier: .read))
                    try await self.publish(context, "browser:bindings", self.bindings.view(for: who))
                    try await self.publish(context, "browser:drive-state", self.status(for: who))
                } catch {
                    self.listeners[context.ownerID] = nil
                    self.reportEventFailure(NativeRPCError(code: "browser-events", message: "A browser event subscriber was removed after permission or delivery failed.", details: .object([.init("ownerID", .string(context.ownerID))])))
                }
              }
              if self.updateRequested { await Task.yield() }
            } while self.updateRequested && !Task.isCancelled
            self.updateTask = nil
        }
    }
    private func status(for who: BackendBrowserPrincipal) -> NativeRPCValue {
        // The person's window (and anyone acting as the owner) sees the one drive
        // the web browser's band shows (lane BR, browser-driver.ts showing()).
        if who.managesWindows && who.sessionID == nil { return showingStatusValue() }
        let id = currentTabs[Self.slot(who)].flatMap { tab -> String? in
            guard runtime.tabExists(tab), bindings.ownTab(Self.slot(who)) == tab ||
                  (who.session != nil && bindings.owner(of: tab) == who.session) ||
                  (who.managesWindows && bindings.owner(of: tab) != nil) else { return nil }
            return tab
        }
        // Typed one value at a time: Swift 6.3 (CI) gave up type-checking this as one expression.
        let prompt: String? = id.flatMap { runtime.handoverPrompt($0) }
        let state: String = id == nil ? "idle" : (prompt != nil ? "human" : "agent")
        let tabID: NativeRPCValue = id.map(NativeRPCValue.string) ?? .null
        let url: String = id.flatMap { prompt == nil ? runtime.pageURL($0) : nil } ?? ""
        let step: String = id.map { active.contains($0) ? "working on the page" : "" } ?? ""
        let steps: Int = id.flatMap { stepCounts[$0] } ?? 0
        return .object([.init("state", .string(state)), .init("tabId", tabID), .init("url", .string(url)),
            .init("prompt", .string(prompt ?? "")), .init("step", .string(step)), .init("stepCount", .number(Double(steps)))])
    }
}

/// A caller gets its own Hoot tab; concurrent caller tabs never share a baton.
@MainActor
private final class BackendBrowserCallHost: BrowserDriverHost {
    let runtime: any BackendBrowserRuntime
    let map: BackendBrowserBindings
    let who: BackendBrowserPrincipal
    let grantedOrigin: String?
    let created: @MainActor (String) -> Void
    let authority: @MainActor () -> Bool
    init(runtime: any BackendBrowserRuntime, bindings: BackendBrowserBindings, principal: BackendBrowserPrincipal, origin: String?,
         authority: @escaping @MainActor () -> Bool, created: @escaping @MainActor (String) -> Void) {
        self.runtime = runtime; map = bindings; who = principal; grantedOrigin = origin
        self.created = created
        self.authority = authority
    }
    var ownTabID: String? { get { map.ownTab(BackendBrowserService.slot(who)) } set { map.setOwnTab(BackendBrowserService.slot(who), newValue) } }
    func bindings() async -> BrowserBindings { map.bindings(for: who) }
    func permittedTab(_ id: String) -> Bool {
        guard authority() else { return false }
        if let session = who.session { return map.owner(of: id) == session }
        return map.ownTab(BackendBrowserService.slot(who)) == id || who.managesWindows && map.owner(of: id) != nil
    }
    func tabExists(_ id: String) -> Bool { !Task.isCancelled && permittedTab(id) && runtime.tabExists(id) }
    func createTab(url: URL, isolated: Bool) -> String {
        guard authority(), !Task.isCancelled else { return "" }
        let id = runtime.createTab(url: url, isolated: isolated)
        map.observe(.init(tabID: id, viewID: id, url: url.absoluteString)); created(id); return id
    }
    func attach(_ id: String, to session: BrowserDriverSession) async -> String? { try? map.attach(id, to: session).name }
    func load(_ id: String, url: URL) { if !Task.isCancelled, permittedTab(id) { runtime.load(id, url: url) } }
    func isIsolated(_ id: String) -> Bool { runtime.isIsolated(id) }
    func setIsolated(_ id: String, _ isolated: Bool) { if !Task.isCancelled { runtime.setIsolated(id, isolated) } }
    func settle(_ id: String, timeoutMs: Int) async -> Bool { guard !Task.isCancelled else { return false }; return await runtime.settle(id, timeoutMs: timeoutMs) }
    func pageURL(_ id: String) -> String { permittedTab(id) && runtime.handoverPrompt(id) == nil ? runtime.pageURL(id) : "" }
    func title(_ id: String) -> String { permittedTab(id) && runtime.handoverPrompt(id) == nil ? runtime.title(id) : "" }
    func displayTitle(_ id: String) -> String { runtime.displayTitle(id) }
    func mayInput(_ id: String) -> Bool { !Task.isCancelled && permittedTab(id) && runtime.handoverPrompt(id) == nil && BackendBrowserOrigin.exact(runtime.pageURL(id)) == grantedOrigin }
    func evaluate(_ id: String, _ script: String) async throws -> Any? {
        try Task.checkCancellation()
        guard permittedTab(id) else { throw NativeRPCError(code: "not-permitted", message: "This window is no longer attached to this caller.") }
        guard runtime.handoverPrompt(id) == nil else { throw NativeRPCError(code: "not-permitted", message: "The person has this page.") }
        if ["select", "focusAndSelect", "scriptedInput"].contains(BrowserDriverScripts.name(of: script) ?? ""), !mayInput(id) {
            throw NativeRPCError(code: "origin-changed", message: "The site changed. The previous permission no longer applies.")
        }
        let value = try await runtime.evaluate(id, script)
        guard permittedTab(id), runtime.handoverPrompt(id) == nil else { throw NativeRPCError(code: "not-permitted", message: "This page's grant changed during the read.") }
        return value
    }
    func reveal(_ id: String) async -> Bool { guard !Task.isCancelled else { return false }; return await runtime.reveal(id) }
    func click(_ id: String, cssRect: CGRect) -> Bool { mayInput(id) && runtime.click(id, cssRect: cssRect) }
    func focusForTyping(_ id: String) -> Bool { mayInput(id) && runtime.focusForTyping(id) }
    func type(_ id: String, plan: BrowserTypingPlan) -> Bool { mayInput(id) && runtime.type(id, plan: plan) }
    func press(_ id: String, key: BrowserKeySpec) -> Bool { mayInput(id) && runtime.press(id, key: key) }
    func screenshot(_ id: String) async throws -> (path: String, width: Int, height: Int, masked: Int) {
        try Task.checkCancellation(); guard permittedTab(id) else { throw NativeRPCError(code: "not-permitted", message: "This window's grant was revoked.") }
        let shot = try await runtime.screenshot(id)
        guard permittedTab(id), runtime.handoverPrompt(id) == nil else { throw NativeRPCError(code: "not-permitted", message: "This page's grant changed during capture.") }
        return shot
    }
    func handoverPrompt(_ id: String) -> String? { runtime.handoverPrompt(id) }
    func otherHandover(than id: String) -> String? { runtime.otherHandover(than: id) }
    func handOver(_ id: String, prompt: String, windowMs: Int) async -> String { await runtime.handOver(id, prompt: prompt, windowMs: windowMs) }
    func closeTab(_ id: String) { if !Task.isCancelled { runtime.closeTab(id); map.closed(id) } }
    func unbind(_ id: String) { map.detach(id) }
    func now() -> Double { runtime.now() }
    func pause(ms: Int) async { await runtime.pause(ms: ms) }
}

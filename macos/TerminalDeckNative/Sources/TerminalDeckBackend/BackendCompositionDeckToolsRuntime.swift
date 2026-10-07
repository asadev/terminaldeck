import Foundation
import TerminalDeckNativeCore

/// The caller-scoped facts every deck-tools runtime adapter shares (INT-R, 7 Oct).
///
/// Who is asking comes ONLY from deck-core's credential-resolved call context
/// (`gate.authority.resolve`); folders and sessions go through the
/// authority's grant checks; every effect enters the one running call through
/// `gate.authorize`. Nothing here is read from tool arguments or `attended`.
public struct BackendCompositionDeckToolsScope: Sendable {
    public typealias DeviceFolders = @Sendable (_ deviceID: String) async throws -> [String]
    public typealias BrowserSlots = @Sendable (_ sessionID: String, _ machineID: String) async throws -> [String]
    public let gate: BackendCompositionDeckToolsGate
    /// surface.ts `deviceFolders`: the folders one paired device may start a
    /// session in — the same list its own `create` is checked against. Nil when
    /// this host cannot answer, which refuses (remote-start.ts L112-119).
    public let deviceFolders: DeviceFolders?
    /// surface.ts `taskWorkspaceFolders` (task-workspaces.ts liveFolders). Nil: no workspaces here.
    public let workspaces: BackendWorkspaceService?
    /// browser-binding.ts `windowsOf(sessionId, machineId).map(slotName)`: the
    /// Safari window slots bound to a session ("B1"…); [] when none.
    public let browserSlots: BrowserSlots
    public init(gate: BackendCompositionDeckToolsGate, deviceFolders: DeviceFolders?,
                workspaces: BackendWorkspaceService?, browserSlots: @escaping BrowserSlots) {
        self.gate = gate; self.deviceFolders = deviceFolders; self.workspaces = workspaces; self.browserSlots = browserSlots
    }

    var authority: BackendCompositionAuthority { gate.authority }
    public func resolve(_ native: BackendMCPCallContext) async throws -> BackendDeckCoreSecurityCallContext {
        try await gate.authority.resolve(native)
    }

    /// catalogue.ts requireSession / requireKnownFolder sentences, verbatim.
    static func missingSession(_ id: String) -> NativeRPCError {
        BackendDeckToolsArgs.bad("this app is not holding a session with id \(id). Either that is not one of its ids — check sessions.list — or the session was stopped, which drops it and everything this app knew about it. A session that exited on its own is still here, with its exit code; a stopped one is not. Ask before stopping something you will want to report on.")
    }
    static func notKnown(_ path: String) -> NativeRPCError {
        NativeRPCError(code: "not-permitted", message: "\(path) is not a folder this app has open. Use projects.list to see the folders you can ask about.")
    }
    static func refused(_ message: String) -> NativeRPCError { NativeRPCError(code: "not-permitted", message: message) }

    /// callers.ts / surface.ts Caller, as the sessions factories read it.
    public static func sessionsCaller(_ core: BackendDeckCoreSecurityCallContext) -> BackendDeckToolsSessionsCaller {
        let kind: BackendDeckToolsSessionsCaller.Kind
        switch core.caller.kind {
        case .local: kind = .local
        case .key: kind = .key
        case .session: kind = .session
        case .remote: kind = .remote
        }
        return .init(kind: kind, sessionID: core.caller.sessionID, machineID: core.caller.machineID,
                     deviceID: core.caller.deviceID, keyName: core.caller.keyName, callID: core.callID)
    }
    public static func appCaller(_ core: BackendDeckCoreSecurityCallContext) -> BackendDeckToolsAppCaller {
        let kind: BackendDeckToolsAppCaller.Kind
        switch core.caller.kind {
        case .local: kind = .local
        case .key: kind = .key
        case .session: kind = .session
        case .remote: kind = .remote
        }
        return .init(kind: kind, sessionID: core.caller.sessionID, machineID: core.caller.machineID, keyName: core.caller.keyName)
    }

    /// A grant check that refuses is "not this caller's"; cancellation is not.
    private func passes(_ check: () async throws -> Void) async throws -> Bool {
        do { try await check(); return true }
        catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            return false
        }
    }

    /// The sessions this caller may see, each as catalogue.ts `viewOf` draws it.
    /// Hidden sessions (the desk Hoot, per-device runs: hidden-sessions.ts) are
    /// never shown; any other caller than the local owner sees exactly the
    /// sessions `authority.requireSession` admits (key folders, own session or
    /// project root, a device's shared sessions).
    public func sessions(_ native: BackendMCPCallContext) async throws -> [NativeRPCValue] {
        let core = try await resolve(native)
        var rows: [NativeRPCValue] = []
        for meta in authority.prepared.manager.list() {
            if native.cancellation.isCancelled { throw CancellationError() }
            if authority.hidden.contains(meta.id) { continue }
            if core.caller.kind != .local {
                let id = meta.id
                guard try await passes({ _ = try await authority.requireSession(id, native: native) }) else { continue }
            }
            rows.append(try await view(meta, core: core))
        }
        return rows
    }
    /// catalogue.ts viewOf (L757-797) over the authoritative status receipts.
    func view(_ meta: BackendSessionMeta, core: BackendDeckCoreSecurityCallContext) async throws -> NativeRPCValue {
        let live = authority.statusRecord(meta.id)
        let status = BackendDeckCoreAttention.status(exitCode: meta.exitCode, live: live?["status"].string)
        let statusSince = live?["at"].number ?? meta.createdAt
        let attentionSince: Double? = meta.exitCode != nil && live == nil ? nil : statusSince
        let windows = try await browserSlots(meta.id, "")
        return BackendDeckToolsSupport.object([("id", .string(meta.id)), ("cwd", .string(meta.cwd)), ("title", .string(meta.title)),
            ("provider", .string(meta.provider)), ("status", .string(status)), ("statusSince", .number(statusSince))])
            .merging(BackendDeckCoreAttention.view(status: status, statusSince: attentionSince, exitCode: meta.exitCode, now: core.now()))
            .merging(BackendDeckToolsSupport.object([
                ("createdAt", .number(meta.createdAt)), ("exitCode", meta.exitCode.map { .number(Double($0)) } ?? .null),
                ("resumed", .bool(meta.resumed)), ("profileName", meta.profileName.map(NativeRPCValue.string) ?? .null),
                // Only the copilot's: an app's session is never reported as the copilot's.
                ("startedByCopilot", .bool(meta.origin != .app && core.startedByCopilot(meta.id))),
                ("startedByApp", meta.origin == .app ? .string(meta.originApp ?? "An AI app") : .null),
                ("windows", .array(windows.map(NativeRPCValue.string))),
            ]))
    }
    /// catalogue.ts requireSession: the caller-visible view, or the source sentence.
    public func session(_ id: String, native: BackendMCPCallContext) async throws -> NativeRPCValue {
        guard let row = try await sessions(native).first(where: { $0["id"].string == id }) else { throw Self.missingSession(id) }
        return row
    }

    /// catalogue.ts knownFolders (L823-830): open projects (within this caller's
    /// grant), the folders of the sessions it may see, and task workspaces.
    public func knownFolders(_ native: BackendMCPCallContext) async throws -> Set<String> {
        let core = try await resolve(native)
        var folders = Set<String>()
        for project in authority.state.listProjects().compactMap({ $0["path"].string }) {
            if try await passes({ _ = try await authority.knownFolder(project, native: native) }) { folders.insert(project) }
        }
        for row in try await sessions(native) { if let cwd = row["cwd"].string { folders.insert(cwd) } }
        folders.formUnion(try await workspaceFolders(core))
        return folders
    }
    /// catalogue.ts requireKnownFolder: membership of exactly that set.
    public func knownFolder(_ path: String, native: BackendMCPCallContext) async throws -> String {
        let core = try await resolve(native)
        if try await passes({ _ = try await authority.knownFolder(path, native: native) }) { return path }
        if try await sessions(native).contains(where: { $0["cwd"].string == path }) { return path }
        if try await workspaceFolders(core).contains(path) { return path }
        throw Self.notKnown(path)
    }
    /// Task workspaces narrowed to the caller's own reach: a key's folders, a
    /// session's root. A paired device reaches them only through its grants.
    func workspaceFolders(_ core: BackendDeckCoreSecurityCallContext) async throws -> [String] {
        guard let workspaces else { return [] }
        switch core.caller.kind {
        case .remote: return []
        case .local: return try await workspaces.liveFolders()
        case .key:
            let all = try await workspaces.liveFolders()
            guard let granted = core.caller.folders else { return all }
            return all.filter { folder in granted.contains { BackendCompositionAuthority.within(folder, $0) } }
        case .session:
            let own = authority.prepared.manager.list().first(where: { $0.id == core.caller.sessionID && $0.exitCode == nil })?.cwd
            guard let root = core.caller.projectRoot ?? own else { return [] }
            return try await workspaces.liveFolders().filter { BackendCompositionAuthority.within($0, root) }
        }
    }

    /// fixed-tools.ts projectFor (L94-99): a known folder this caller may run
    /// things in — a device's granted folder (its own spelling), a limited
    /// key's folders, otherwise the folder itself.
    public func runnableProject(_ folder: String, native: BackendMCPCallContext) async throws -> String {
        let core = try await resolve(native)
        switch core.caller.kind {
        case .remote: return try await deviceFolder(core.caller.deviceID ?? "", folder: folder)
        case .key:
            // remote-start.ts requireKeyFolder (L156-169).
            guard let folders = core.caller.folders, !folders.isEmpty else { return folder }
            let inside = folders.contains { allowed in
                if BackendRemoteServeSessionPolicy.sameFolder(allowed, folder) { return true }
                return folder.hasPrefix(allowed.hasSuffix("/") ? allowed : allowed + "/")
            }
            guard inside else {
                throw Self.refused("the access key this app is using may only start sessions in: \(folders.joined(separator: ", ")). Nothing was started. Use one of those, or say what you would have needed — the owner chooses the folders in Settings.")
            }
            return folder
        case .local, .session: return folder
        }
    }
    /// remote-start.ts requireDeviceFolder (L107-135). The folder is never echoed.
    func deviceFolder(_ deviceID: String, folder: String) async throws -> String {
        guard let deviceFolders else {
            throw Self.refused("starting a session on behalf of a device is not available on this machine, so this was refused. Tell the person what you would have started and let them start it.")
        }
        let offered: [String] = try await (deviceID.isEmpty ? [] : deviceFolders(deviceID))
        guard let granted = offered.first(where: { BackendRemoteServeSessionPolicy.sameFolder($0, folder) }) else {
            throw Self.refused(offered.isEmpty
                ? "this device has no folders chosen for it, so it cannot start a session anywhere. Nothing was started. Say so, and do not retry — the folders are chosen on the desktop, in Settings."
                : "this device may only start a session in: \(offered.joined(separator: ", ")). Nothing was started. Use one of those, or say what you would have needed.")
        }
        return granted
    }
}

/// `BackendDeckToolsSessionsRuntime` for the sessions/agents/accounts/windows/lift factories.
public struct BackendCompositionDeckToolsSessionsRuntime: BackendDeckToolsSessionsRuntime {
    private let scope: BackendCompositionDeckToolsScope
    public init(scope: BackendCompositionDeckToolsScope) { self.scope = scope }

    public func caller(_ context: BackendMCPCallContext) async throws -> BackendDeckToolsSessionsCaller {
        BackendCompositionDeckToolsScope.sessionsCaller(try await scope.resolve(context))
    }
    public func sessions(_ context: BackendMCPCallContext) async throws -> [NativeRPCValue] { try await scope.sessions(context) }
    public func knownFolders(_ context: BackendMCPCallContext) async throws -> Set<String> { try await scope.knownFolders(context) }
    /// The device's folder list, for that device's own call only. Nil: this host cannot answer.
    public func deviceFolders(deviceID: String, context: BackendMCPCallContext) async throws -> [String]? {
        let core = try await scope.resolve(context)
        guard core.caller.kind == .remote, (core.caller.deviceID ?? "") == deviceID else {
            throw NativeRPCError(code: "access-denied", message: "A device's folder grant is read only for that device's own call.")
        }
        guard let list = scope.deviceFolders else { return nil }
        return try await (deviceID.isEmpty ? [] : list(deviceID))
    }
    /// Core's per-starter bucket (a key's own, or the copilot's), never a global bit.
    public func startedByCaller(sessionID: String, context: BackendMCPCallContext) async throws -> Bool {
        try await scope.resolve(context).startedByCopilot(sessionID)
    }
    public func noteStarted(sessionID: String, context: BackendMCPCallContext) async throws {
        try await scope.resolve(context).noteStarted(sessionID)
    }
    /// The running call's one consent/budget/log entry, at the effective tier.
    public func authorize(tool: BackendMCPTool, tier: BackendMCPTier, summary: String, arguments: NativeRPCValue, context: BackendMCPCallContext) async throws {
        try await scope.gate.authorize(context, tier, summary, false)
    }
    public func recordResult(toolID: String, summary: NativeRPCValue, context: BackendMCPCallContext) async throws {
        await scope.gate.noteResult(context, summary)
    }
    public func browserSlots(sessionID: String, machineID: String, context: BackendMCPCallContext) async throws -> [String] {
        _ = try await scope.resolve(context)
        return try await scope.browserSlots(sessionID, machineID)
    }
}

/// One `browser.lift_request` ask, as lift-ask-tool.ts hands it to the desk.
/// `askedBy` is the tool's human-readable asker, never a session or owner id.
public struct BackendCompositionDeckToolsLiftAsk: Sendable {
    public let askedBy: String
    public let from: String
    public let into: [String]
    public let reason: NativeRPCValue
    public init(askedBy: String, from: String, into: [String], reason: NativeRPCValue) {
        self.askedBy = askedBy; self.from = from; self.into = into; self.reason = reason
    }
}

/// lift-ask-tool.ts → browser-lift-requests.ts fileLiftRequest, into the ONE
/// Safari inbox the app target owns. Files an ask only; it moves no login.
public struct BackendCompositionDeckToolsLiftRequests: BackendDeckToolsSessionsLiftRequests {
    /// The app target's ingress into its `BackendBrowserWorkersLiftRequests`
    /// (same actor the Scraping panel reads): it builds the scraping caller for
    /// `native` through its browser authority and answers `FileLiftAnswer`.
    public typealias Inbox = @Sendable (_ ask: BackendCompositionDeckToolsLiftAsk, _ native: BackendMCPCallContext) async throws -> NativeRPCValue
    private let gate: BackendCompositionDeckToolsGate
    private let inbox: Inbox?
    public init(gate: BackendCompositionDeckToolsGate, inbox: Inbox?) { self.gate = gate; self.inbox = inbox }

    public func file(askedBy: String, from: String, into: [String], reason: NativeRPCValue, context: BackendMCPCallContext) async throws -> NativeRPCValue {
        let core = try await gate.authority.resolve(context)
        // Same gates as the tool, from the credential rather than the call.
        try BackendDeckToolsSessionsArea.mayAskLift(caller: BackendCompositionDeckToolsScope.sessionsCaller(core), attended: core.attended)
        // fileLiftRequest L157-159: no desk wired is a named refusal, not a throw.
        guard let inbox else { return Self.notFiled("nothing in this build can carry a lift request.") }
        return try Self.sourceAnswer(try await inbox(.init(askedBy: askedBy, from: from, into: into, reason: reason), context))
    }
    static func notFiled(_ reason: String) -> NativeRPCValue {
        BackendDeckToolsSupport.object([("ok", .bool(false)), ("reason", .string(reason))])
    }
    /// browser-lift-requests.ts FileLiftAnswer, exactly; anything else is refused, never reported filed.
    static func sourceAnswer(_ answer: NativeRPCValue) throws -> NativeRPCValue {
        if answer["ok"].bool == false, let reason = answer["reason"].string { return notFiled(reason) }
        let request = answer["request"]
        guard answer["ok"].bool == true, request.fields != nil, request["id"].string != nil,
              let fromName = answer["fromName"].string, let names = answer["intoNames"].elements,
              names.allSatisfy({ $0.string != nil }), let repeated = answer["repeated"].bool else {
            throw NativeRPCError(code: "unavailable", message: "The browser's lift inbox did not answer in the desk's own shape, so nothing is reported as asked.")
        }
        let row = BackendDeckToolsSupport.object(["id", "askedBy", "fromProfileId", "intoProfileIds", "reason", "at"].map { ($0, request[$0]) })
        return BackendDeckToolsSupport.object([("ok", .bool(true)), ("request", row), ("fromName", .string(fromName)),
            ("intoNames", .array(names)), ("repeated", .bool(repeated))])
    }
}

/// Builder for the app-tool family's access (app-tools / fixed / github /
/// memory / stores / usage …) over the same scope and gate.
public enum BackendCompositionDeckToolsAccess {
    public static func appAccess(gate: BackendCompositionDeckToolsGate,
                                 deviceFolders: BackendCompositionDeckToolsScope.DeviceFolders?,
                                 workspaces: BackendWorkspaceService?,
                                 browserSlots: @escaping BackendCompositionDeckToolsScope.BrowserSlots) -> BackendDeckToolsAppAccess {
        appAccess(scope: .init(gate: gate, deviceFolders: deviceFolders, workspaces: workspaces, browserSlots: browserSlots))
    }
    public static func appAccess(scope: BackendCompositionDeckToolsScope) -> BackendDeckToolsAppAccess {
        BackendDeckToolsAppAccess(
            caller: { native in BackendCompositionDeckToolsScope.appCaller(try await scope.resolve(native)) },
            knownFolder: { native, path in try await scope.knownFolder(path, native: native) },
            session: { native, id in try await scope.session(id, native: native) },
            runnableProject: { native, path in try await scope.runnableProject(path, native: native) },
            rpc: { native in try await scope.gate.authority.rpc(native) },
            // The kit hands redacted arguments and the source sentence; the gate
            // binds the running call's own tool/arguments, so neither can be swapped.
            authorize: { native, _, _, tier, sentence, ownerMustAnswer in
                try await scope.gate.authorize(native, tier, sentence, ownerMustAnswer)
            },
            record: { native, _, _, summary in await scope.gate.noteResult(native, summary) })
    }
}

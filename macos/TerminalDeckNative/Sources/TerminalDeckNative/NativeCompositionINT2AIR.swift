import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// AIR projects the existing scanner, core consent and session owner. Saved
/// previews bind the credential identity; temporary RPC call owners grant nothing.
struct NativeCompositionINT2AIR: Sendable {
    static let ownerID = "native.air-readiness"
    let service: BackendAIRReadinessService
    let session: BackendAIRReadinessSession
    private let projects: BackendProjectService
    private let specs: BackendTaskPersistence
    private let lifecycle: BackendSessionLifecycleCoordinator
    private let manager: BackendPTYManager
    private let authority: BackendCompositionAuthority
    private let joins: BackendCompositionProductionBindings
    private let surface: BackendDeckCoreLiveSurface

    init(readiness: BackendReadinessService, projects: BackendProjectService,
         specs: BackendTaskPersistence, sessions: BackendCompositionSessions,
         authority: BackendCompositionAuthority, joins: BackendCompositionProductionBindings,
         core: BackendDeckCoreRuntime, surface: BackendDeckCoreLiveSurface) throws {
        let gate = try joins.deckToolsGate()
        self.projects = projects; self.specs = specs
        lifecycle = sessions.lifecycle; manager = sessions.manager
        self.authority = authority; self.joins = joins; self.surface = surface
        service = BackendAIRReadinessService(readiness: readiness, projects: projects,
            callerIdentity: { rpc in
                if rpc.caller == .nativeApp {
                    try authority.requireLocalUI(rpc)
                    return NativeRPCValue.object([.init("kind", .string("nativeApp")), .init("owner", .string(rpc.ownerID))]).compact
                }
                let caller = try await authority.rpcCaller(rpc)
                let identifier: String
                switch caller.kind {
                case .local: identifier = BackendCompositionRoot.appOwnerID
                case .key: identifier = try Self.identifier(caller.keyID, kind: "key")
                case .remote: identifier = try Self.identifier(caller.deviceID, kind: "device")
                case .session: identifier = try Self.identifier(caller.sessionID, kind: "session")
                }
                return NativeRPCValue.object([.init("kind", .string(caller.kind.rawValue)), .init("id", .string(identifier)),
                    .init("machine", caller.machineID.map(NativeRPCValue.string) ?? .null),
                    .init("project", caller.projectRoot.map(NativeRPCValue.string) ?? .null)]).compact
            }, approve: { rpc, preview in
                if rpc.caller == .nativeApp {
                    try await Self.nativeApproval(authority: authority, consent: core.consent, rpc: rpc,
                        tool: "readiness.fix", summary: Self.previewSentence(preview), arguments: AIRReadinessWire.wire(preview))
                    return
                }
                let native = try await authority.nativeCaller(rpc)
                let (tool, args) = try await joins.nativeTool(native)
                let expected: NativeRPCValue = .object([.init("previewId", .string(preview.id))])
                guard tool == "readiness.fix", args == expected, native.allowedTiers.contains(.alter) else {
                    throw Self.denied("This approval does not match the running readiness fix.")
                }
                try await gate.authorize(native, .alter, Self.previewSentence(preview), true)
                try authority.authorizeMutation(rpc)
            }, authorizeMutation: { try authority.authorizeMutation($0) })
        session = BackendAIRReadinessSession(projects: projects, specs: specs,
            create: { input, rpc, promptPath in
                try authority.requireLocalUI(rpc)
                let prior = try await authority.createContext(input, context: rpc)
                return try await sessions.lifecycle.create(input, context: Self.promptContext(prior, path: promptPath), holdOnFailure: false)
            }, deliver: { id, line, rpc in
                try authority.requireLocalUI(rpc)
                try await BackendTaskBriefDelivery.deliver(id, line: line, manager: sessions.manager,
                    write: { text in try authority.requireLocalUI(rpc); try await sessions.lifecycle.write(sessionID: id, data: text) })
            }, rename: { id, title, rpc in
                try authority.requireLocalUI(rpc)
                return try await sessions.lifecycle.rename(sessionID: id, title: title)
            }, authorize: { operation, args, rpc in
                try authority.requireLocalUI(rpc)
                if operation == "sessions.start" {
                    try await Self.nativeApproval(authority: authority, consent: core.consent, rpc: rpc,
                        tool: "readiness.ask_ai", summary: Self.launchSentence(args), arguments: args)
                } else if operation != "sessions.send" { throw Self.denied("This readiness session step is unavailable.") }
            })
    }

    func definitions() throws -> [BackendDeckToolsDefinition] {
        let gate = try joins.deckToolsGate()
        return try BackendAIRReadinessTools.definitions(service: service, access: .init(
            rpcContext: { try await authority.rpc($0) },
            knownFolder: { try await authority.knownFolder($1, native: $0) },
            authorizeRead: { native, id, args in
                let (tool, original) = try await joins.nativeTool(native)
                guard tool == id, original == args else { throw Self.denied("This readiness read does not match the running tool.") }
                try await gate.authorize(native, .read, "Read AI readiness in " + (args["projectPath"].string ?? "the approved project"), false)
            }, noteResult: { await gate.noteResult($0, $1) },
            authorizeLaunch: { native, args, request in
                let (tool, original) = try await joins.nativeTool(native)
                guard tool == "readiness.ask_ai", original == args, native.allowedTiers.contains(.alter) else {
                    throw Self.denied("This approval does not match the running readiness AI request.")
                }
                try BackendDeckCoreCatalogueBuiltins.checkStart(surface: surface,
                    context: try await authority.resolve(native), arguments: Self.sourceArguments(request))
                try await gate.authorize(native, .alter, Self.launchSentence(request), true)
                try BackendDeckCoreCatalogueBuiltins.checkStart(surface: surface,
                    context: try await authority.resolve(native), arguments: Self.sourceArguments(request))
            }, launchAI: { native, rpc, request in
                let (tool, original) = try await joins.nativeTool(native)
                guard tool == "readiness.ask_ai" else { throw Self.denied("No readiness AI request is running.") }
                let receipt = NativeCompositionINT2AIRLaunch(native: native, rpc: rpc, arguments: original, request: request,
                    authority: authority, joins: joins, surface: surface)
                let adapter = BackendAIRReadinessSession(projects: projects, specs: specs,
                    create: { input, context, promptPath in
                        try await receipt.checkStart(request, context: context)
                        let prior = try await authority.createContext(input, context: context)
                        // Recheck after resolving the launch boundary, immediately before create.
                        try await receipt.checkStart(request, context: context)
                        let meta = try await lifecycle.create(input, context: Self.promptContext(prior, path: promptPath), holdOnFailure: false)
                        receipt.created(meta.id, path: promptPath)
                        return meta
                    }, deliver: { id, line, context in
                        try await receipt.checkSend(id: id, line: line, context: context)
                        try await BackendTaskBriefDelivery.deliver(id, line: line, manager: manager, write: { text in
                            try await receipt.checkSend(id: id, line: line, context: context)
                            try await lifecycle.write(sessionID: id, data: text)
                        })
                    }, rename: { id, title, context in
                        try await receipt.checkSession(id, context: context)
                        return try await lifecycle.rename(sessionID: id, title: title)
                    }, authorize: { operation, args, context in
                        if operation == "sessions.start" { try await receipt.checkStart(args, context: context) }
                        else if operation == "sessions.send" {
                            try await receipt.checkSend(id: args["sessionId"].requireString("session id", nonempty: true),
                                line: args["text"].requireString("delivery line", nonempty: true), context: context, path: args["promptPath"].string)
                        } else { throw Self.denied("This readiness session step is unavailable.") }
                    })
                let current = try await authority.resolve(native)
                return try await adapter.startAI(request: request, context: rpc, coreContext: current)
            }))
    }

    private static func identifier(_ id: String?, kind: String) throws -> String {
        guard let id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw denied("The readiness preview needs the current " + kind + " identity.")
        }
        return id
    }
    static func denied(_ message: String) -> NativeRPCError { .init(code: "access-denied", message: message) }
    static func previewSentence(_ preview: AIRReadinessFixPreview) -> String {
        preview.summary + "\nProject: " + preview.projectPath + "\n" + preview.changes.map {
            $0.path + " — " + ($0.action ?? "Change") + "\n" + ($0.after ?? "")
        }.joined(separator: "\n")
    }
    static func sourceArguments(_ request: NativeRPCValue) -> NativeRPCValue {
        .object([.init("cwd", request["cwd"]), .init("brief", request["firstPrompt"]), .init("title", request["title"]),
            .init("provider", request["provider"]), .init("account", request["profileId"])])
    }
    static func launchSentence(_ request: NativeRPCValue) -> String {
        "Start an AI session in " + (request["cwd"].string ?? "") + "\nAI: " + (request["provider"].string ?? "project default") +
            "\nLogin: " + (request["profileId"].string ?? "project default") + "\nReady prompt:\n" + (request["firstPrompt"].string ?? "")
    }
    static func nativeApproval(authority: BackendCompositionAuthority, consent: BackendDeckCoreSecurityConsentBroker,
                               rpc: NativeRPCContext, tool: String, summary: String, arguments: NativeRPCValue) async throws {
        try authority.requireLocalUI(rpc); try Task.checkCancellation()
        let cancellation = BackendMCPCancellation()
        let outcome = await withTaskCancellationHandler {
            await consent.request(tool: tool, tier: .alter, summary: summary, arguments: arguments, cancellation: cancellation, origin: "window")
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation(); try authority.requireLocalUI(rpc)
        guard outcome.granted else { throw NativeRPCError(code: "approval-required", message: "The readiness action was not approved.") }
    }
    static func promptContext(_ prior: BackendLaunchContext, path: String) -> BackendLaunchContext {
        guard let old = prior.deviceBoundary else { return prior }
        let boundary = BackendDeviceBoundary(deviceKey: old.deviceKey, folder: old.folder,
            writableDirectories: old.writableDirectories, readableFiles: Array(Set(old.readableFiles + [path])).sorted(),
            readOnlyProjects: old.readOnlyProjects)
        return BackendLaunchContext(deviceBoundary: boundary, appFenceID: prior.appFenceID, extraArguments: prior.extraArguments,
            rememberTab: prior.rememberTab, environmentOverrides: prior.environmentOverrides,
            removeEnvironment: prior.removeEnvironment, isAppComposed: prior.isAppComposed, beforeExposure: prior.beforeExposure)
    }
}

/// Per-call internal steps reuse the accepted readiness effect. They never
/// prepare a second sessions.start/send effect or broaden its exact request.
private final class NativeCompositionINT2AIRLaunch: @unchecked Sendable {
    let native: BackendMCPCallContext
    let rpc: NativeRPCContext
    let arguments: NativeRPCValue
    let request: NativeRPCValue
    let authority: BackendCompositionAuthority
    let joins: BackendCompositionProductionBindings
    let surface: BackendDeckCoreLiveSurface
    private let lock = NSLock()
    private var createdSession: (id: String, path: String)?
    init(native: BackendMCPCallContext, rpc: NativeRPCContext, arguments: NativeRPCValue, request: NativeRPCValue,
         authority: BackendCompositionAuthority, joins: BackendCompositionProductionBindings, surface: BackendDeckCoreLiveSurface) {
        self.native = native; self.rpc = rpc; self.arguments = arguments; self.request = request
        self.authority = authority; self.joins = joins; self.surface = surface
    }
    func created(_ id: String, path: String) { lock.withLock { createdSession = (id, path) } }
    private func checkReceipt(_ context: NativeRPCContext) async throws -> BackendDeckCoreSecurityCallContext {
        try Task.checkCancellation()
        guard context.requestID == rpc.requestID, context.ownerID == rpc.ownerID, context.caller == rpc.caller else {
            throw NativeCompositionINT2AIR.denied("The readiness session lost its original caller.")
        }
        let current = try await authority.resolve(native)
        let (tool, original) = try await joins.nativeTool(native)
        guard tool == "readiness.ask_ai", original == arguments, current.native.allowedTiers.contains(.alter),
              current.caller.tiers.contains(.alter), !current.cancellation.isCancelled else {
            throw NativeCompositionINT2AIR.denied("The approved readiness AI request is no longer current.")
        }
        try authority.authorizeMutation(context)
        return current
    }
    func checkStart(_ accepted: NativeRPCValue, context: NativeRPCContext) async throws {
        guard accepted == request, lock.withLock({ createdSession == nil }) else {
            throw NativeCompositionINT2AIR.denied("The readiness launch does not match its approved request.")
        }
        try BackendDeckCoreCatalogueBuiltins.checkStart(surface: surface, context: try await checkReceipt(context),
            arguments: NativeCompositionINT2AIR.sourceArguments(request))
    }
    func checkSession(_ id: String, context: NativeRPCContext) async throws {
        _ = try await checkReceipt(context)
        guard lock.withLock({ createdSession?.id == id }) else {
            throw NativeCompositionINT2AIR.denied("Only the new readiness session is covered by this approval.")
        }
        _ = try await authority.requireSession(id, native: native)
    }
    func checkSend(id: String, line: String, context: NativeRPCContext, path: String? = nil) async throws {
        try await checkSession(id, context: context)
        guard let saved = lock.withLock({ createdSession }), line == BackendDeckCoreBrief.deliveryLine(saved.path),
              path == nil || path == saved.path else {
            throw NativeCompositionINT2AIR.denied("Only the exact saved readiness prompt is covered by this approval.")
        }
    }
}

extension NativeCompositionProduction {
    func installAIRReadiness() async throws {
        guard airReadiness == nil, let surface = coreSurface else {
            throw NativeRPCError(code: "composition-incomplete", message: "AIR needs the existing core surface and one readiness owner.")
        }
        let installed = try NativeCompositionINT2AIR(readiness: usage.readiness, projects: files.projects,
            specs: BackendTaskPersistence(directory: root.dataRoot.appendingPathComponent("remote/task-briefs", isDirectory: true),
                ownership: root.state.ownership), sessions: sessions, authority: authority, joins: joins, core: core, surface: surface)
        do {
            for channel in BackendAIRReadinessService.channels.sorted() {
                try await root.registry.register(channel, ownerID: NativeCompositionINT2AIR.ownerID,
                    policy: { [authority] in try authority!.authorizeMetadata($0) }) { context, args in
                    try await installed.service.invoke(channel, args: args, context: context)
                }
            }
            try await root.registry.register("readiness:startAI", ownerID: NativeCompositionINT2AIR.ownerID,
                policy: { [authority] in try authority!.requireLocalUI($0) }) { context, args in
                try await installed.session.invoke("readiness:startAI", args: args, context: context)
            }
            try await root.retain(.init(name: "air-readiness", domains: ["air-readiness"], ownerID: NativeCompositionINT2AIR.ownerID,
                invokes: BackendAIRReadinessService.channels.union(BackendAIRReadinessSession.channels),
                stop: { [root] in await root.registry.removeOwner(NativeCompositionINT2AIR.ownerID) }))
            airReadiness = installed
        } catch {
            await root.registry.removeOwner(NativeCompositionINT2AIR.ownerID)
            throw error
        }
    }
}

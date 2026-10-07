import Foundation
import TerminalDeckNativeCore

/// Channels the page and the app still asked Node for (INT-A, D14), natively:
///  - `agent:controls:read/apply/models` — agent-controls.ts:2744 registerAgentControlsIpc,
///    over the ONE `BackendCompositionAgentControlsOwning` the deck tools and the task driver use;
///  - `chat:load` / `chat:tail` (invoke) and `chat:close` (send) — chat-transcript.ts:723
///    registerChatIpc (native-transcripts.ts in native-shell mode), over Core's
///    `NativeChatTranscriptReader` and the authority's caller-scoped transcript stores;
///  - `providers:detect` (index.ts:2847 detectAllProviders) and `brand:get` (index.ts brand).
///
/// Policy (actions/agents.ts, actions/sessions.ts): every channel here is also a
/// tool's, so the app window OR a credential-resolved page ticket may call it —
/// reads `authorizeMetadata`, the two that type into a session
/// `authorizeMutation`. A ticket's session and transcript reach come from its
/// grant (`requireSessionRPC`, `transcriptScope`), never from the request.
/// `chat:close` only releases this window's own cached reader: app window only.
public enum BackendCompositionAppChannels {
    public static let reads: [String] = ["agent:controls:read", "chat:load", "chat:tail", "providers:detect", "brand:get"]
    public static let writes: [String] = ["agent:controls:apply", "agent:controls:models"]
    public static let sendChannels: [String] = ["chat:close"]

    public static func register(registry: NativeChannelRegistry, ownerID: String, authority: BackendCompositionAuthority,
                                controls: any BackendCompositionAgentControlsOwning, providers: BackendNativeProviders,
                                customAgents: BackendCustomAgentsStore) async throws -> (invokes: [String], sends: [String], events: [String]) {
        for channel in reads + writes {
            if await registry.has(channel) { throw NativeRPCError(code: "duplicate-handler", message: "App channel is already registered: " + channel) }
        }
        let readers = BackendCompositionChatReaders()
        let deviceHomes = authority.configuration.dataDirectory.appendingPathComponent("remote/device-home").path

        /// ReadRequest/ApplyRequest's session: the window's own request as sent; a
        /// ticket's only after its grant admits the session, read from the session itself.
        let session: @Sendable (NativeRPCContext, NativeRPCValue) async throws -> (id: String?, cwd: String?, provider: String?, local: Bool) = { context, request in
            let id = request["sessionId"].string
            if context.caller == .nativeApp {
                return (id, request["cwd"].string, request["provider"].string, request["scope"]["onThisMachine"].bool != false)
            }
            guard let id, !id.isEmpty else { return (nil, nil, nil, true) }
            try await authority.requireSessionRPC(id, context: context)
            let meta = authority.prepared.manager.list().first { $0.id == id }
            return (id, meta?.cwd, meta?.provider, true)
        }
        /// chat-transcript.ts chat:load / chat:tail: an exact transcript wins over the
        /// folder's newest; nothing found is `found: false`, not an error.
        let chat: @Sendable (NativeRPCContext, [NativeRPCValue], Bool) async throws -> NativeRPCValue = { context, args, whole in
            let request = context.argument(0, in: args)
            let path = request["transcriptPath"].string.flatMap { $0.isEmpty ? nil : $0 }
            let cwd = request["cwd"].string.flatMap { $0.isEmpty ? nil : $0 }
            var granted = try await authority.transcriptScope(project: nil, context: context)
            // transcript.ts configDirs: the window also reads paired devices' homes.
            if context.caller == .nativeApp { granted.deviceHomesRoot = deviceHomes }
            let scope = granted
            let located = try await Task.detached(priority: .utility) { () async throws -> (path: String?, roots: [String]) in
                let roots = try NativeTranscriptPaths.approvedRoots(scope)
                if let path { return (try NativeTranscriptPaths.assertTranscript(path, scope: scope), roots) }
                if let cwd { return (try NativeTranscriptPaths.newest(cwd, scope: scope)?.path, roots) }
                return (nil, roots)
            }.value
            guard let found = located.path else { return BackendCompositionAppChannels.wire(.absent()) }
            // Colliding encoded folder names: a scoped caller proves membership by the transcript's cwd.
            if scope.projectFolders != nil {
                let belongs = try await BackendCompositionAuthorityTranscripts.belongs(found, scope: scope)
                guard belongs else { throw NativeRPCError(code: "access-denied", message: "This transcript belongs to a different project") }
            }
            return try await readers.read(owner: context.ownerID, path: found, roots: located.roots, whole: whole)
        }

        var handlers: [(String, NativeChannelRegistry.Handler)] = []
        handlers.append(("agent:controls:read", { context, args in
            let s = try await session(context, context.argument(0, in: args))
            return await controls.read(sessionID: s.id, cwd: s.cwd, provider: s.provider, onThisMachine: s.local)
        }))
        handlers.append(("agent:controls:apply", { context, args in
            let request = context.argument(0, in: args)
            let s = try await session(context, request)
            return try await controls.apply(sessionID: s.id ?? "", cwd: s.cwd, control: request["control"].string ?? "undefined",
                                            value: request["value"].string ?? "", provider: s.provider, onThisMachine: s.local)
        }))
        handlers.append(("agent:controls:models", { context, args in
            let s = try await session(context, context.argument(0, in: args))
            guard let id = s.id, !id.isEmpty else {
                return NativeRPCValue.object([.init("models", .array([])), .init("message", .string("No session to ask."))])
            }
            return try await controls.models(sessionID: id, provider: s.provider)
        }))
        handlers.append(("chat:load", { context, args in try await chat(context, args, true) }))
        handlers.append(("chat:tail", { context, args in try await chat(context, args, false) }))
        handlers.append(("providers:detect", { _, _ in try await BackendCompositionAppChannels.detectProviders(providers: providers, customAgents: customAgents) }))
        handlers.append(("brand:get", { _, _ in
            NativeRPCValue.object([.init("name", .string(BackendSharedBrand.name)), .init("tagline", .string(BackendSharedBrand.tagline))])
        }))

        var registered: [String] = []
        do {
            for (channel, handler) in handlers {
                let write = writes.contains(channel)
                try await registry.register(channel, ownerID: ownerID, policy: { context in
                    if write { try authority.authorizeMutation(context) } else { try authority.authorizeMetadata(context) }
                }, handler: handler)
                registered.append(channel)
            }
            // chat-transcript.ts chat:close: drop the window's resident reader for that path.
            let close = try await registry.onSend("chat:close", ownerID: ownerID, policy: { try authority.requireLocalUI($0) }) { context, args in
                await readers.close(owner: context.ownerID, path: context.argument(0, in: args).string ?? "")
            }
            // Retained with the readers, which the chat handlers above retain.
            await readers.keep(close)
        } catch {
            for channel in registered { await registry.removeHandler(channel, ownerID: ownerID) }
            await readers.release()
            throw error
        }
        return (registered, sendChannels, [])
    }

    /// index.ts:2736 detectAllProviders: the catalogue's agents by a runnable
    /// binary (providers.ts canStart), the shell always, then every added
    /// agent by command lookup on the login PATH.
    public static func detectProviders(providers: BackendNativeProviders, customAgents: BackendCustomAgentsStore) async throws -> NativeRPCValue {
        let path = try await providers.loginPath()
        var answer = NativeRPCValue.object([])
        for id in ["claude", "codex", "gemini"] {
            let binary = await providers.resolveBinary(id, path: path)
            answer = answer.setting(id, .bool(binary.runnable != nil))
        }
        answer = answer.setting("shell", .bool(true))
        let lookup = BackendCustomAgentsStore.nativeLookup(loginPath: { path })
        for agent in await customAgents.list().elements ?? [] {
            guard let id = agent["id"].string, let command = agent["command"].string else { continue }
            let found = try? await lookup(command)
            answer = answer.setting(id, .bool(found != nil))
        }
        return answer
    }

    /// chat-transcript.ts ChatUpdate, with the native reader's two extra facts.
    static func wire(_ read: NativeChatTranscriptRead) -> NativeRPCValue {
        let messages = read.messages.map { message -> NativeRPCValue in
            .object([.init("id", .string(message.id)), .init("role", .string(message.role.rawValue)),
                     .init("text", .string(message.text)), .init("at", .number(message.at))])
        }
        return .object([.init("transcriptPath", .string(read.path)), .init("sessionId", .string(read.sessionID)),
                        .init("cwd", .string(read.cwd)), .init("messages", .array(messages)), .init("reset", .bool(read.reset)),
                        .init("cursor", .number(Double(read.cursor))), .init("found", .bool(read.found)),
                        .init("complete", .bool(read.complete)), .init("startedMidFile", .bool(read.startedMidFile)),
                        .init("skippedOversizedLines", .number(Double(read.skippedOversizedLines))),
                        .init("updatedAt", .number(read.updatedAt))])
    }
}

/// chat-transcript.ts `readers`: resident readers so a live session appends
/// instead of re-reading, capped at 12, oldest first out. Keyed per caller as
/// well as per path, so one caller's tail can never consume another's delta.
actor BackendCompositionChatReaders {
    static let maximum = 12
    private var readers: [String: NativeChatTranscriptReader] = [:]
    private var order: [String] = []
    private var kept: [NativeRPCSubscription] = []

    func keep(_ subscription: NativeRPCSubscription) { kept.append(subscription) }
    func release() async {
        let held = kept; kept = []
        for subscription in held { await subscription.cancelAndWait() }
    }

    /// load: a fresh reader and the whole conversation. tail: what changed since
    /// this caller's last read — or, for a path it never read, the whole
    /// conversation flagged as a reset.
    func read(owner: String, path: String, roots: [String], whole: Bool) async throws -> NativeRPCValue {
        let key = owner + "\u{0}" + path
        if whole { readers[key] = nil; order.removeAll { $0 == key } }
        let known = readers[key] != nil
        let reader: NativeChatTranscriptReader
        if let cached = readers[key] { reader = cached }
        else {
            while readers.count >= Self.maximum, !order.isEmpty { let oldest = order.removeFirst(); readers[oldest] = nil }
            reader = NativeChatTranscriptReader(path: path, allowedRoots: roots)
            readers[key] = reader; order.append(key)
        }
        let read = try await reader.readAll(wholeConversation: whole || !known, forceReset: !whole && !known)
        return BackendCompositionAppChannels.wire(read)
    }

    func close(owner: String, path: String) {
        guard !path.isEmpty else { return }
        let key = owner + "\u{0}" + NativeTranscriptPaths.canonical(path)
        readers[key] = nil
        order.removeAll { $0 == key }
    }
}

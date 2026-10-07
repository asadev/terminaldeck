import Foundation
import TerminalDeckNativeCore

/// Scoped read-only adapters for deck-control/memory-tools.ts, using the same service as IPC.
public enum BackendMemoryMCP {
    public static let index = [
        "memory.search": "Search the memory notes your agent keeps for this project (or, for Hoot, a project it names).",
        "memory.read": "Read one of your memory notes, with what it links to and what links to it — or list them all."
    ]
    public static func grantToolNames(for kind: BackendKnowledgeToolCaller.Kind, machineID: String = "") -> Set<String> {
        guard kind == .local || (kind == .session && machineID.isEmpty) else { return [] }
        return ["memory.search", "memory_search", "memory.read", "memory_read"]
    }
    public static func specifications() throws -> [BackendMCPTool] {
        let p = BackendKnowledgeToolArguments.property
        return [
            try .init(id: "memory.search", wireName: "memory_search", description: "Search the memory notes you keep — the ones your agent reads at the start of a conversation — by words. A session searches its own memory for the folder it runs in; Hoot searches its own, and may add `project` to read one open project’s memory and knowledge for planning. Answers each note’s place, title and the line that matched; memory.read opens one. What comes back goes to you as tool output.",
                inputSchema: BackendKnowledgeToolArguments.schema([("query", p("string", "Words to look for.", nil)), ("project", p("string", "Hoot only: an open project folder whose memory to read too.", nil)), ("limit", p("number", "Most results, 1–40. Default 10.", nil))], required: ["query"]), tier: .read, advertised: false),
            try .init(id: "memory.read", wireName: "memory_read", description: "Read one memory note by its `path` (as memory.search or a listing gives it): its text, the notes it links to, the links that reach nothing, and the notes that link to it. Without `path`, lists the notes in your memory. Same scope as memory.search: your own memory, and for Hoot a named `project`’s, read-only. Pass `space` when more than one memory is in scope. What comes back goes to you as tool output.",
                inputSchema: BackendKnowledgeToolArguments.schema([("path", p("string", "The note, relative to its memory folder. Omit to list.", nil)), ("space", p("string", "Which memory, when more than one is in scope.", nil)), ("project", p("string", "Hoot only: an open project folder whose memory to read.", nil))], required: []), tier: .read, advertised: false)
        ]
    }
    public static func register(server: BackendNativeMCPServer, service: BackendMemoryService, authority: any BackendKnowledgeToolAuthority) async throws -> [String] {
        for tool in try specifications() {
            try await server.registerTool(tool) { context, args in
                do { return try await BackendKnowledgeMCP.cancellable(context.cancellation) { .value(try await call(tool: tool.id, args: args, context: context, service: service, authority: authority)) } }
                catch { return .failure(error.localizedDescription) }
            }
        }
        return ["memory.search", "memory.read"]
    }
    static func view(_ space: BackendMemoryFoundSpace) -> NativeRPCValue {
        BackendMemoryParsing.object([("space", .string(space.id)), ("kind", .string(space.space.kind.rawValue)), ("label", .string(space.space.label)),
            ("project", BackendMemoryParsing.optional(space.space.project)), ("sharedWith", space.space.sharedWith.isEmpty ? .missing : BackendMemoryParsing.strings(space.space.sharedWith))])
    }
    public static func scope(service: BackendMemoryService, authority: any BackendKnowledgeToolAuthority, context: BackendMCPCallContext, project: String?) async throws -> (spaces: [BackendMemoryFoundSpace], about: String) {
        let caller = try await authority.caller(context)
        if caller.kind == .session {
            if project != nil { throw NativeRPCError(code: "not-permitted", message: "A session reads its own memory only; it cannot name another project.") }
            if !context.machineID.isEmpty { throw NativeRPCError(code: "not-permitted", message: "This session runs on another computer, and its memory is there, not on this one.") }
            guard let session = caller.session, session.id == context.sessionID else { throw NativeRPCError(code: "not-permitted", message: "This session is not one this app is running.") }
            guard let store = caller.store else { return ([], "This app does not read \(session.provider)'s memory.") }
            if session.provider == "codex" {
                guard let space = try await service.codexSpaceFor(configDir: store) else { return ([], "Codex has kept no memory under this account yet.") }
                return ([space], "Your own Codex memory.")
            }
            guard let space = try await service.claudeSpaceFor(configDir: store, cwd: session.cwd) else { return ([], "No memory has been kept for \(session.cwd) under this account yet.") }
            let shared = space.space.sharedWith
            let about = shared.isEmpty ? "Your own memory for \(session.cwd)." : "This memory is shared: \(shared.joined(separator: ", ")) read\(shared.count == 1 ? "s" : "") and write\(shared.count == 1 ? "s" : "") the same notes, through a link that already exists on disk."
            return ([space], about)
        }
        if caller.kind == .local {
            let own = try await service.hootSpace().map { [$0] } ?? []
            guard let project else { return (own, "Your own memory.") }
            let folder = try await authority.requireKnownFolder(project), theirs = try await service.spacesForProject(folder)
            return (own + theirs, theirs.isEmpty ? "Your own memory; \(folder) has no memory or knowledge kept yet." : "Your own memory, and \(folder)'s memory and knowledge, read-only, for planning.")
        }
        throw NativeRPCError(code: "not-permitted", message: "The memory of the agents on this computer is read on this computer only.")
    }
    public static func call(tool: String, args: NativeRPCValue, context: BackendMCPCallContext, service: BackendMemoryService, authority: any BackendKnowledgeToolAuthority) async throws -> NativeRPCValue {
        _ = try args.requireObject("memory arguments")
        guard !context.cancellation.isCancelled else { throw CancellationError() }
        let A = BackendKnowledgeToolArguments.self
        if tool == "memory.search" { _ = try A.string(args, "query"); _ = try A.integer(args, "limit", fallback: 10, min: 1, max: 40) }
        guard ["memory.search", "memory.read"].contains(tool) else { throw NativeRPCError.invalidArguments("Unknown memory tool.") }
        let scoped = try await scope(service: service, authority: authority, context: context, project: A.optional(args, "project"))
        try await authority.authorize(context, tool: tool, arguments: args, tier: .read)
        guard !context.cancellation.isCancelled else { throw CancellationError() }
        if tool == "memory.search" {
            let hits = try await service.searchIn(A.string(args, "query"), spaceIDs: scoped.spaces.map(\.id), limit: A.integer(args, "limit", fallback: 10, min: 1, max: 40))
            let results = hits.map { hit in BackendMemoryParsing.object([("space", hit["spaceId"]), ("memory", BackendMemoryParsing.optional(scoped.spaces.first { $0.id == hit["spaceId"].string }?.space.label)), ("path", hit["path"]), ("title", hit["title"]), ("snippet", hit["snippet"])]) }
            return BackendMemoryParsing.object([("scope", .string(scoped.about)), ("spaces", .array(scoped.spaces.map(view))), ("results", .array(results))])
        }
        let wanted = try A.optional(args, "space"), path = try A.optional(args, "path")
        let spaces = wanted == nil ? scoped.spaces : scoped.spaces.filter { $0.id == wanted }
        if let wanted, spaces.isEmpty { throw NativeRPCError.invalidArguments("\(wanted) is not a memory you can read") }
        if path == nil {
            var listed: [NativeRPCValue] = []
            for space in spaces {
                let notes = try await service.notes(space.id).map { note in BackendMemoryParsing.object([("path", note["path"]), ("title", note["title"]), ("description", note["description"]), ("type", note["type"])]) }
                listed.append(view(space).setting("notes", .array(notes)).setting("linksToNothing", BackendMemoryParsing.graphWire(try await service.graph(space.id))["dangling"]))
            }
            return BackendMemoryParsing.object([("scope", .string(scoped.about)), ("memories", .array(listed))])
        }
        if spaces.count > 1, wanted == nil { throw NativeRPCError.invalidArguments("more than one memory is in scope; pass space as one of " + spaces.map(\.id).joined(separator: ", ")) }
        guard let space = spaces.first else { throw NativeRPCError(code: "not-permitted", message: scoped.about) }
        let read = await service.read(space.id, path: .string(path!))
        guard read["ok"].bool == true else { throw NativeRPCError.invalidArguments(read["error"].string ?? "This note could not be read.") }
        let text = read["text"].string ?? "", long = text.utf16.count > 64 * 1024, links = read["links"].elements ?? []
        return view(space).merging(BackendMemoryParsing.object([("path", read["path"]), ("title", read["note"]["title"]),
            ("text", .string(long ? BackendMemoryParsing.cut(text, 64 * 1024) : text)), ("cut", long || read["truncated"].bool == true ? .string("This note is longer than what is shown.") : .missing),
            ("linksTo", .array(links.filter { !$0["to"].isNullish }.map { $0["to"] })), ("linksToNothing", .array(links.filter { $0["to"].isNullish }.map { $0["target"] })), ("linkedFrom", read["backlinks"])]))
    }
}

import Foundation
import TerminalDeckNativeCore

/// The native memory worker supplies discovery, note confinement and graph
/// reads. A FoundSpace wire record carries id/kind/label/project/sharedWith.
public protocol BackendDeckToolsAppMemoryService: Sendable {
    func storeOf(_ session: NativeRPCValue) async throws -> String?
    func codexSpaceFor(_ store: String) async throws -> NativeRPCValue?
    func claudeSpaceFor(_ store: String, cwd: String) async throws -> NativeRPCValue?
    func hootSpace() async throws -> NativeRPCValue?
    func spacesForProject(_ folder: String) async throws -> [NativeRPCValue]
    func searchIn(_ query: String, spaces: [String], limit: Int) async throws -> [NativeRPCValue]
    func notes(_ space: String) async throws -> [NativeRPCValue]
    func graph(_ space: String) async throws -> NativeRPCValue
    /// Returns ok/path/text/note/links/backlinks/truncated or ok:false/error.
    func read(_ space: String, path: String) async throws -> NativeRPCValue
}
public enum BackendDeckToolsAppMemory {
    private typealias K = BackendDeckToolsAppKit
    public static let maxReadChars = 64 * 1024
    public struct Scope: Sendable { public let spaces: [NativeRPCValue], about: String }
    private static func service(_ value: (any BackendDeckToolsAppMemoryService)?) throws -> any BackendDeckToolsAppMemoryService {
        guard let value else { throw K.refused("Memory is not available in this build.") }; return value
    }
    public static func scope(service: (any BackendDeckToolsAppMemoryService)?, access: BackendDeckToolsAppAccess,
                             context: BackendMCPCallContext, project: String?) async throws -> Scope {
        let memory = try self.service(service), caller = try await access.caller(context)
        if caller.kind == .session {
            guard project == nil else { throw K.refused("A session reads its own memory only; it cannot name another project.") }
            guard caller.machineID == nil || caller.machineID == "" else { throw K.refused("This session runs on another computer, and its memory is there, not on this one.") }
            guard let sessionID = caller.sessionID else { throw K.refused("This session is not one this app is running.") }
            let session: NativeRPCValue
            do { session = try await access.session(context, sessionID) }
            catch { throw K.refused("This session is not one this app is running.") }
            guard let store = try await memory.storeOf(session) else { return .init(spaces: [], about: "This app does not read \(session["provider"].string ?? "undefined")'s memory.") }
            if session["provider"].string == "codex" {
                guard let own = try await memory.codexSpaceFor(store) else { return .init(spaces: [], about: "Codex has kept no memory under this account yet.") }
                return .init(spaces: [own], about: "Your own Codex memory.")
            }
            let cwd = session["cwd"].string ?? ""
            guard let own = try await memory.claudeSpaceFor(store, cwd: cwd) else { return .init(spaces: [], about: "No memory has been kept for \(cwd) under this account yet.") }
            let shared = own["sharedWith"].elements?.compactMap(\.string) ?? []
            let about = shared.isEmpty ? "Your own memory for \(cwd)." : "This memory is shared: \(shared.joined(separator: ", ")) read\(shared.count == 1 ? "s" : "") and write\(shared.count == 1 ? "s" : "") the same notes, through a link that already exists on disk."
            return .init(spaces: [own], about: about)
        }
        if caller.kind == .local {
            let own = try await memory.hootSpace(), spaces = own.map { [$0] } ?? []
            guard let project else { return .init(spaces: spaces, about: "Your own memory.") }
            let folder = try await access.knownFolder(context, project), theirs = try await memory.spacesForProject(folder)
            return .init(spaces: spaces + theirs, about: theirs.isEmpty ? "Your own memory; \(folder) has no memory or knowledge kept yet." : "Your own memory, and \(folder)'s memory and knowledge, read-only, for planning.")
        }
        throw K.refused("The memory of the agents on this computer is read on this computer only.")
    }
    public static func spaceView(_ space: NativeRPCValue) -> NativeRPCValue {
        var value = K.object([("space", space["id"]), ("kind", space["kind"]), ("label", space["label"]), ("project", space["project"])])
        if !(space["sharedWith"].elements ?? []).isEmpty { value = value.setting("sharedWith", space["sharedWith"]) }
        return value
    }
    public static func definitions(service: (any BackendDeckToolsAppMemoryService)?, access: BackendDeckToolsAppAccess) throws -> [BackendDeckToolsDefinition] {
        try K.definitions(module: "memory-tools", access: access, consent: { id, _, args in
            let path = try K.optStr(args, "path")
            return (.read, id == "memory.search" ? "Search memory for “\(try K.optStr(args, "query") ?? "")”" : path.map { "Read memory note \($0)" } ?? "List memory notes", false)
        }, run: { id, context, args in
            if id == "memory.search" {
                let query = try K.str(args, "query"), limit = try BackendDeckToolsArgs.optInt(args, "limit", 10, 1, 40)
                let scope = try await scope(service: service, access: access, context: context, project: K.optStr(args, "project")), memory = try self.service(service)
                let hits = try await memory.searchIn(query, spaces: scope.spaces.compactMap { $0["id"].string }, limit: limit)
                let results = hits.map { hit in K.object([("space", hit["spaceId"]), ("memory", scope.spaces.first { $0["id"] == hit["spaceId"] }?["label"] ?? hit["spaceId"]), ("path", hit["path"]), ("title", hit["title"]), ("snippet", hit["snippet"])]) }
                return .init(K.object([("scope", .string(scope.about)), ("spaces", .array(scope.spaces.map(spaceView))), ("results", .array(results))]), K.object([("spaces", K.n(scope.spaces.count)), ("results", K.n(hits.count))]))
            }
            let scope = try await scope(service: service, access: access, context: context, project: K.optStr(args, "project")), memory = try self.service(service)
            let wanted = try K.optStr(args, "space"), path = try K.optStr(args, "path"), spaces = wanted.map { wanted in scope.spaces.filter { $0["id"].string == wanted } } ?? scope.spaces
            if let wanted, spaces.isEmpty { throw BackendDeckToolsArgs.bad("\(wanted) is not a memory you can read") }
            guard let path else {
                var listed: [NativeRPCValue] = []
                for space in spaces {
                    let id = space["id"].string ?? ""
                    async let notes = memory.notes(id)
                    async let graph = memory.graph(id)
                    let listedNotes = try await notes, listedGraph = try await graph
                    let notesValue = listedNotes.map { note in K.object([("path", note["path"]), ("title", note["title"]), ("description", note["description"]), ("type", note["type"])]) }
                    listed.append(spaceView(space).setting("notes", .array(notesValue)).setting("linksToNothing", listedGraph["dangling"]))
                }
                return .init(K.object([("scope", .string(scope.about)), ("memories", .array(listed))]), K.object([("spaces", K.n(listed.count)), ("notes", K.n(listed.reduce(0) { $0 + ($1["notes"].elements?.count ?? 0) }))]))
            }
            if spaces.count > 1 && wanted == nil { throw BackendDeckToolsArgs.bad("more than one memory is in scope; pass space as one of \(spaces.compactMap { $0["id"].string }.joined(separator: ", "))") }
            guard let space = spaces.first else { throw K.refused(scope.about) }
            let read = try await memory.read(space["id"].string ?? "", path: path)
            guard read["ok"].bool == true else { throw BackendDeckToolsArgs.bad(read["error"].string ?? "This note could not be read.") }
            let text = read["text"].string ?? "", long = text.utf16.count > maxReadChars, links = read["links"].elements ?? []
            var value = spaceView(space).merging(K.object([("path", read["path"]), ("title", read["note"]["title"]), ("text", .string(long ? BackendDeckToolsSupport.slice(text, 0, maxReadChars) : text)), ("linksTo", .array(links.filter { $0["to"] != .null }.map { $0["to"] })), ("linksToNothing", .array(links.filter { $0["to"] == .null }.map { $0["target"] })), ("linkedFrom", read["backlinks"])]))
            if long || read["truncated"].bool == true { value = value.setting("cut", .string("This note is longer than what is shown.")) }
            return .init(value, K.object([("path", read["path"]), ("chars", K.n(min(text.utf16.count, maxReadChars)))]))
        })
    }
}

public protocol BackendDeckToolsAppRoutineService: Sendable {
    func list() async throws -> [NativeRPCValue]
    func get(_ id: String) async throws -> NativeRPCValue?
    func text(_ id: String) async throws -> NativeRPCValue
    /// Loader's parser and serializers, including quietFor and expectEvery;
    /// nil only for genuinely invalid source text, never absent implementation.
    func draftFromFile(id: String, text: String) async throws -> NativeRPCValue?
    func create(_ draft: NativeRPCValue) async throws -> NativeRPCValue
    func update(_ id: String, draft: NativeRPCValue) async throws -> NativeRPCValue
    func remove(_ id: String) async throws -> NativeRPCValue
    func run(_ id: String, by: String) async throws -> NativeRPCValue
    func pause(_ id: String, reason: String) async throws -> Bool
    func resume(_ id: String) async throws -> Bool
}
public enum BackendDeckToolsAppRoutines {
    private typealias K = BackendDeckToolsAppKit
    public static func validID(_ id: String) -> Bool {
        let reserved = ["con", "prn", "aux", "nul"] + (1...9).map { "com\($0)" } + (1...9).map { "lpt\($0)" }
        return !reserved.contains(id) && !id.hasSuffix("-") && id.range(of: #"^[a-z0-9][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil
    }
    /// Source patchOf (routine-tools.ts:110-131): the draft's fields in the source's
    /// own order (name, when, in, prompt, enabled, overlap, maxRunsPerHour,
    /// maxRunsPerDay, quietFor, expectEvery), so the draft handed to create/update
    /// and the first bad argument reported both match the source.
    public static func patch(_ args: NativeRPCValue) throws -> NativeRPCValue {
        var result = NativeRPCValue.object([])
        if let text = try K.optStr(args, "name", trimmed: true) { result = result.setting("name", .string(text)) }
        if !args["when"].isNullish {
            if let text = args["when"].string { result = result.setting("when", text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .array([]) : .array([.string(text)])) }
            else if let list = args["when"].elements, list.allSatisfy({ $0.string != nil }) { result = result.setting("when", .array(list)) }
            else { throw BackendDeckToolsArgs.bad("when must be a list of strings") }
        }
        if let text = try K.optStr(args, "folder", trimmed: true) { result = result.setting("in", .string(text)) }
        if args["prompt"].string != nil { result = result.setting("prompt", args["prompt"]) }
        if args["enabled"] != .missing { result = result.setting("enabled", .bool(try BackendDeckToolsArgs.optBool(args, "enabled", true))) }
        if let text = try K.optStr(args, "overlap", trimmed: true) { result = result.setting("overlap", .string(text)) }
        for key in ["maxRunsPerHour", "maxRunsPerDay"] where !args[key].isNullish {
            guard let number = args[key].number else { throw BackendDeckToolsArgs.bad("\(key) must be a number") }
            result = result.setting(key, .number(number))
        }
        for key in ["quietFor", "expectEvery"] { if let text = try K.optStr(args, key, trimmed: true) { result = result.setting(key, .string(text)) } }
        return result
    }
    public static func currentDraft(_ service: any BackendDeckToolsAppRoutineService, _ id: String) async throws -> NativeRPCValue? {
        let text = try await service.text(id)
        guard text["ok"].bool == true, let contents = text["text"].string else { return nil }
        return try await service.draftFromFile(id: id, text: contents)
    }
    private static func exists(_ service: any BackendDeckToolsAppRoutineService, _ id: String) async throws -> NativeRPCValue {
        guard let view = try await service.get(id) else { throw K.refused("there is no routine called \(id). routines.list shows them.") }; return view
    }
    private static func failed(_ result: NativeRPCValue, _ what: String) throws {
        guard result["ok"].bool == true else { let problems = result["problems"].elements?.compactMap(\.string).joined(separator: " ") ?? ""; throw K.refused("\(what): \(problems.isEmpty ? "it was refused." : problems)") }
    }
    public static func definitions(service: any BackendDeckToolsAppRoutineService, access: BackendDeckToolsAppAccess) throws -> [BackendDeckToolsDefinition] {
        try K.definitions(module: "routine-tools", access: access, precheck: { id, context, args in
            if id == "routines.save" {
                if let folder = try K.optStr(args, "folder", trimmed: true) { _ = try await access.knownFolder(context, folder) }
                if let id = try K.optStr(args, "routineId", trimmed: true), !validID(id) { throw K.refused("\(id) is not a usable routine id. Use lowercase letters, digits and hyphens.") }
            }
        }, consent: { id, _, args in
            let routineID = try K.optStr(args, "routineId", trimmed: true), shownID = routineID ?? "?", sentence: String
            switch id {
            case "routines.list": sentence = "List the routines"
            case "routines.get": sentence = "Read the routine \(shownID)"
            case "routines.save":
                if let routineID, try await service.get(routineID) != nil {
                    let fields = args.fields?.map(\.key).filter { $0 != "routineId" } ?? []
                    sentence = "Change the routine \(routineID): \(fields.isEmpty ? "nothing" : fields.joined(separator: ", "))"
                } else {
                    let when = try patch(args)["when"].elements?.compactMap(\.string).joined(separator: " or ") ?? ""
                    sentence = "Create a routine called \(try K.optStr(args, "name", trimmed: true) ?? routineID ?? "?") in \(try K.optStr(args, "folder", trimmed: true) ?? "?"), run \(when.isEmpty ? "?" : when)"
                }
            case "routines.delete": sentence = "Delete the routine \(shownID)"
            case "routines.run": sentence = "Run the routine \(shownID) now"
            case "routines.pause": sentence = "Pause the routine \(shownID)"
            default: sentence = "Resume the routine \(shownID)"
            }
            return (["routines.save", "routines.delete"].contains(id) ? .alter : ["routines.run", "routines.pause", "routines.resume"].contains(id) ? .act : .read, sentence, false)
        }, run: { id, context, args in
            if id == "routines.list" { let rows = try await service.list(); return .init(K.object([("routines", .array(rows))]), K.object([("routines", K.n(rows.count))])) }
            if id == "routines.save" {
                if let folder = try K.optStr(args, "folder", trimmed: true) { _ = try await access.knownFolder(context, folder) }
                let id = try K.optStr(args, "routineId", trimmed: true), patch = try patch(args)
                if let id, try await service.get(id) != nil {
                    let base = try await currentDraft(service, id) ?? .object([]), result = try await service.update(id, draft: base.merging(patch))
                    try failed(result, "\(id) was not changed")
                    return .init(K.object([("saved", .string("changed")), ("routine", result["view"])]), K.object([("routineId", .string(id)), ("created", .bool(false))]))
                }
                let result = try await service.create(id.map { patch.setting("id", .string($0)) } ?? patch)
                try failed(result, "the routine was not created")
                return .init(K.object([("saved", .string("created")), ("routine", result["view"])]), K.object([("routineId", result["id"]), ("created", .bool(true))]))
            }
            let routineID = try K.str(args, "routineId", trimmed: true)
            if id == "routines.delete" { let result = try await service.remove(routineID); try failed(result, "\(routineID) was not deleted"); return .init(K.object([("deleted", .string(routineID))]), K.object([("routineId", .string(routineID))])) }
            let view = try await exists(service, routineID), actualID = view["id"].string ?? routineID
            if id == "routines.get" {
                let text = try await service.text(actualID), file = text["ok"].bool == true ? K.object([("path", text["file"]), ("text", text["text"])]) : K.object([("problems", text["problems"])])
                return .init(K.object([("routine", view), ("file", file)]), K.object([("routineId", .string(actualID))]))
            }
            if id == "routines.run" {
                let result = try await service.run(actualID, by: "copilot")
                guard result["started"].bool == true else { throw K.refused("\(actualID) did not start: \(result["reason"].string ?? "undefined")") }
                let value = K.object([("routineId", .string(actualID)), ("runId", result["runId"])]); return .init(value, value)
            }
            let paused: Bool
            if id == "routines.pause" { paused = try await service.pause(actualID, reason: K.optStr(args, "reason", trimmed: true) ?? "Paused by Hoot.") }
            else { paused = try await service.resume(actualID) }
            let flag = id == "routines.pause" ? "paused" : "resumed"
            return .init(K.object([("routineId", .string(actualID)), (flag, .bool(paused)), ("routine", try await service.get(actualID) ?? .null)]), K.object([("routineId", .string(actualID)), (flag, .bool(paused))]))
        })
    }
}

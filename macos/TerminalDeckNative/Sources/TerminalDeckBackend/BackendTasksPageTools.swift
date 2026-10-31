import Foundation
import TerminalDeckNativeCore

/// Main Tasks page controls. No creation, assignment or session launch path.
public enum BackendTasksPageTools {
    public static let ids = ["tasks.views", "tasks.bulk"]
    public static func install(server: BackendNativeMCPServer, ownerID: String, authority: BackendTaskToolAuthority,
                               store: BackendTaskStore, local: BackendTaskLocalService,
                               views: @escaping @Sendable (NativeRPCValue) async throws -> NativeRPCValue) async throws {
        let string = NativeRPCValue.object([.init("type", .string("string"))])
        let strings = NativeRPCValue.object([.init("type", .string("array")), .init("items", string)])
        func schema(_ fields: [(String, NativeRPCValue)], required: [String]) -> NativeRPCValue {
            .object([.init("type", .string("object")), .init("properties", .object(fields.map { .init($0.0, $0.1) })),
                     .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
        }
        let specs = [
            try BackendMCPTool(id: "tasks.views", wireName: "tasks_views",
                description: "Main Tasks page saved tabs. do: list, save (name; captures current view), select, rename or delete (id). Changes to an open saved tab stay unsaved until resave (id of the open tab: it keeps the current view) or revert (id: back to how it was saved). update replaces the current view settings using state: tab, groupBy, sort, showClosed, subtasks, columns (booleans), columnOrder (names), columnWidths (72–360 points), filters (pile/search/statuses/priorities/boards/due/archived). List returns current state, whether the open saved tab has unsaved changes (changed) and saved tabs. No tasks are created.",
                inputSchema: schema([("do", string.setting("enum", .array(["list", "save", "select", "rename", "delete", "resave", "revert", "update"].map(NativeRPCValue.string)))), ("id", string), ("name", string), ("state", .object([.init("type", .string("object"))]))], required: ["do"]), tier: .read),
            try BackendMCPTool(id: "tasks.bulk", wireName: "tasks_bulk",
                description: "Change many visible local tasks together. tasks: ids; do: due (due_date YYYY-MM-DD, or null to clear) or tags (labels; mode add/remove/replace/clear). All ids are checked before changes. Returns updated ids and any failure. Never assigns agents or starts sessions.",
                inputSchema: schema([("do", string.setting("enum", .array([.string("due"), .string("tags")]))), ("tasks", strings),
                    ("due_date", string.setting("type", .array([.string("string"), .string("null")]))), ("labels", strings),
                    ("mode", string.setting("enum", .array(["add", "remove", "replace", "clear"].map(NativeRPCValue.string))))], required: ["do", "tasks"]), tier: .alter)
        ]
        for spec in specs {
            try await server.registerTool(spec, ownerID: ownerID) { caller, args in
                let tier: BackendMCPTier = spec.id == "tasks.views" && args["do"].string == "list" ? .read : .alter
                guard caller.allowedTiers.contains(tier), !caller.cancellation.isCancelled else {
                    throw NativeRPCError(code: "not-granted", message: "This caller cannot change the Tasks page.")
                }
                try await authority.requireTasks(caller)
                if spec.id == "tasks.views" {
                    try await authority.authorize(caller, spec.id, args, tier)
                    return .value(try await views(args))
                }
                let verb = try args["do"].requireString("do")
                guard ["due", "tags"].contains(verb) else { throw NativeRPCError.invalidArguments("do must be due or tags") }
                let ids = try args["tasks"].requireArray("tasks").map { try $0.requireString("task id", nonempty: true) }
                guard !ids.isEmpty, ids.count <= 500, Set(ids).count == ids.count else { throw NativeRPCError.invalidArguments("Give 1–500 distinct task ids.") }
                var rows: [BackendTaskRecord] = []
                for id in ids {
                    guard let row = try await store.byID(id), row.isLocal, try await authority.visible(caller, row) else {
                        throw NativeRPCError.invalidArguments("A task is missing or outside your access.")
                    }
                    if !row.project.isEmpty { try await authority.project(caller, row.project) }
                    rows.append(row)
                }
                var due: NativeRPCValue = .null
                let mode = args["mode"].string ?? "add"
                var tags: [String] = []
                if verb == "due" {
                    guard args.has("due_date"), args["due_date"] == .null || args["due_date"].string.map { TaskList.isYmd($0) } == true else {
                        throw NativeRPCError.invalidArguments("due_date must be YYYY-MM-DD or null.")
                    }
                    due = args["due_date"]
                } else {
                    guard ["add", "remove", "replace", "clear"].contains(mode) else { throw NativeRPCError.invalidArguments("Unknown tag action.") }
                    if mode != "clear" { tags = try args["labels"].requireArray("labels").map { try $0.requireString("tag", nonempty: true) } }
                }
                try await authority.authorize(caller, spec.id, args, .alter)
                let by = try await authority.actorName(caller)
                var updated: [NativeRPCValue] = []
                for row in rows {
                    try Task.checkCancellation()
                    guard !caller.cancellation.isCancelled else { throw CancellationError() }
                    let patch: NativeRPCValue
                    if verb == "due" { patch = .object([.init("dueDate", due)]) }
                    else {
                        let current = try await store.byID(row.id)
                        let labels = TasksBulkTags.apply(tags, to: current?.value["labels"].elements?.compactMap(\.string) ?? [], mode: mode)
                        patch = .object([.init("labels", .array(labels.map(NativeRPCValue.string)))])
                    }
                    do { _ = try await local.update(row.id, input: patch, by: by); updated.append(.string(row.id)) }
                    catch { return .value(.object([.init("updated", .array(updated)), .init("failed", .string(row.id)), .init("error", .string(error.localizedDescription))])) }
                }
                return .value(.object([.init("updated", .array(updated))]))
            }
        }
    }
}

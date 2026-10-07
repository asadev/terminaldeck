import Foundation
import TerminalDeckNativeCore

/// The source's actual split: a local child is created here; a CRM child is
/// requested through the signed outbox and exists only when the CRM sends it.
public struct BackendTaskDelegation: Sendable {
    private let store: BackendTaskStore, configuration: BackendTaskConfiguration, local: BackendTaskLocalService, engine: BackendTaskEngine
    private let outgoing: @Sendable (BackendTaskRecord, NativeRPCValue) async throws -> Void
    public init(store: BackendTaskStore, configuration: BackendTaskConfiguration, local: BackendTaskLocalService,
                engine: BackendTaskEngine, outgoing: @escaping @Sendable (BackendTaskRecord, NativeRPCValue) async throws -> Void) {
        self.store = store; self.configuration = configuration; self.local = local; self.engine = engine; self.outgoing = outgoing
    }
    public func delegate(taskID: String, agent: String, title: String, instructions: String, project: String?) async throws -> NativeRPCValue {
        guard let task = try await store.byID(taskID), let agent = try await configuration.agent(agent) else { throw NativeRPCError.invalidArguments("There is no such task or task agent") }
        let project = project ?? task.project
        if task.isLocal {
            let child = try await local.create(BackendTaskValues.object([("title", .string(title)), ("instructions", .string(instructions)), ("project", .string(project)), ("assignee", agent["id"])]), by: "hoot", parentID: task.id)
            try await engine.comment(task.id, kind: "progress", text: "Asked \(agent["name"].string ?? "an agent") to: \(title)", by: "hoot")
            return BackendTaskValues.object([("asked", agent["name"]), ("task", .string(child.id))])
        }
        guard let connection = try await configuration.connection(task.value["keyId"].string ?? ""), connection["enabled"].bool == true else { throw NativeRPCError(code: "not-permitted", message: "The CRM connection is off.") }
        guard let hoot = connection["hootIdentity"].string else { throw NativeRPCError(code: "not-permitted", message: "Hoot has no CRM identity on this connection.") }
        guard let identity = connection["identities"].fields?.first(where: { $0.value == agent["id"] })?.key else { throw NativeRPCError(code: "not-permitted", message: "This agent has no CRM identity on this connection.") }
        guard (task.value["hops"].number ?? 0) + 1 <= (connection["maxHops"].number ?? 3) else { throw NativeRPCError(code: "too-many-hops", message: "The hand-off limit for this task tree is reached.") }
        guard BackendTaskAPI.folderAllowed(connection, path: project) else { throw NativeRPCError(code: "folder-not-allowed", message: "That is not a folder this connection allows.") }
        try await outgoing(task, BackendTaskValues.object([("type", .string("task.delegate_requested")), ("actor", .string(hoot)), ("delegate", BackendTaskValues.object([("assignee", .string(identity)), ("title", .string(title)), ("instructions", .string(instructions)), ("project", .string(project))]))]))
        try await engine.comment(task.id, kind: "progress", text: "Asked \(agent["name"].string ?? "an agent") to: \(String(title.prefix(200)))", by: hoot)
        return BackendTaskValues.object([("asked", agent["name"]), ("note", .string("The CRM creates the child task; it runs here when it arrives."))])
    }
}

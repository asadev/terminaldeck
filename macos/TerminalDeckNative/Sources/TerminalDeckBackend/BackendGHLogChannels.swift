import Foundation
import TerminalDeckNativeCore

/// One job snapshot stream per visible native viewer. Opening another stream
/// with the same viewer token cancels the old download; close/shutdown cancels
/// all remaining work. There is no timer or background log watcher.
public actor BackendGHLogChannels {
    public static let channels = ["github:logs:open", "github:logs:close"]
    public static let event = "github:logs:data"
    private let service: any BackendGHJobLogStreaming
    private let registry: NativeChannelRegistry
    private var tasks: [String: (ownerID: String, revision: UUID, task: Task<Void, Never>)] = [:]
    private var stopped = false
    public init(service: any BackendGHJobLogStreaming, registry: NativeChannelRegistry) {
        self.service = service; self.registry = registry
    }

    public func register(ownerID: String) async throws {
        for channel in Self.channels {
            try await registry.register(channel, ownerID: ownerID) { [self] context, values in
                guard context.caller == .nativeApp else {
                    throw NativeRPCError(code: "access-denied", message: "Job log streams belong to the GitHub viewer in this app. Use the GitHub log tool for other callers.")
                }
                try context.requireCount(values, 1...1)
                if channel == "github:logs:close" {
                    let id = try Self.identifier(values[0])
                    try await close(id, ownerID: context.ownerID)
                    return .object([.init("ok", .bool(true))])
                }
                let args = values[0]
                let id = try Self.identifier(args["streamId"])
                try BackendGHMCPTools.validate(operation: .actionsLogs, arguments: args.removing("streamId"))
                return try await open(id: id, ownerID: context.ownerID, arguments: args.removing("streamId"))
            }
        }
    }

    private static func identifier(_ value: NativeRPCValue) throws -> String {
        guard let id = value.string, UUID(uuidString: id) != nil else {
            throw NativeRPCError.invalidArguments("The job log viewer needs a valid stream identifier.")
        }
        return id
    }

    private func open(id: String, ownerID: String, arguments: NativeRPCValue) throws -> NativeRPCValue {
        guard !stopped else { throw NativeRPCError(code: "unavailable", message: "The GitHub log viewer has closed. Open it again.") }
        guard tasks[id] != nil || tasks.count < 4 else {
            throw NativeRPCError(code: "too-many-streams", message: "Close another GitHub job log viewer before opening this one.")
        }
        try close(id, ownerID: ownerID)
        let revision = UUID()
        let task = Task { [self, service] in
            do {
                let stream = await service.streamJobLogs(arguments: arguments)
                for try await chunk in stream {
                    try Task.checkCancellation()
                    guard current(id, revision: revision) else { return }
                    try await registry.publish(Self.event, arguments: [chunk.setting("streamId", .string(id))], ownerID: ownerID)
                }
            } catch is CancellationError { /* Closing a viewer is a normal end. */ }
            catch {
                if current(id, revision: revision), !Task.isCancelled {
                    let failure = NativeRPCError.wrapping(error)
                    try? await registry.publish(Self.event, arguments: [.object([
                        .init("streamId", .string(id)), .init("error", .string(failure.message)), .init("complete", .bool(true))
                    ])], ownerID: ownerID)
                }
            }
            finished(id, revision: revision)
        }
        tasks[id] = (ownerID, revision, task)
        return .object([.init("streamId", .string(id))])
    }
    private func current(_ id: String, revision: UUID) -> Bool { !stopped && tasks[id]?.revision == revision }
    private func finished(_ id: String, revision: UUID) { if tasks[id]?.revision == revision { tasks[id] = nil } }
    private func close(_ id: String, ownerID: String) throws {
        guard tasks[id] == nil || tasks[id]?.ownerID == ownerID else {
            throw NativeRPCError(code: "access-denied", message: "That GitHub log viewer belongs to another window.")
        }
        tasks.removeValue(forKey: id)?.task.cancel()
    }
    public func shutdown() {
        stopped = true
        let active = tasks.values; tasks.removeAll()
        for item in active { item.task.cancel() }
    }
}

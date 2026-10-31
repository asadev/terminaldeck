import Foundation
import TerminalDeckNativeCore

/// Exact workspaces-ipc.ts channels. Task identity is the only input; opening
/// or removing an arbitrary renderer-provided folder is never possible.
public enum BackendWorkspaceChannels {
    public static func register(registry: NativeChannelRegistry, ownerID: String, workspaces: BackendWorkspaceService,
                                liveFolders: @escaping @Sendable () async -> [String],
                                openFolder: @escaping @Sendable (String) async throws -> String) async throws -> [String] {
        let channels = ["tasks:workspace", "tasks:workspace-open", "tasks:workspace-remove"]
        for channel in channels {
            try await registry.register(channel, ownerID: ownerID) { context, args in
                guard context.caller == .nativeApp else { throw NativeRPCError(code: "access-denied", message: "Only the app's own window may use a task workspace") }
                let taskID = context.argument(0, in: args).string
                if channel == "tasks:workspace" {
                    guard let taskID else { return .object([.init("workspace", .null), .init("refusal", .null)]) }
                    return try await workspaces.view(taskID: taskID, context: context)
                }
                if channel == "tasks:workspace-open" {
                    guard let taskID, let folder = try await workspaces.folderToOpen(taskID: taskID, context: context) else {
                        return .object([.init("ok", .bool(false)), .init("error", .string("This task has no workspace folder to open."))])
                    }
                    let error = try await openFolder(folder)
                    return error.isEmpty ? .object([.init("ok", .bool(true))]) : .object([.init("ok", .bool(false)), .init("error", .string(error))])
                }
                guard let taskID else {
                    return .object([.init("ok", .bool(false)), .init("message", .string("That request was not understood.")), .init("view", .object([.init("workspace", .null), .init("refusal", .null)]))])
                }
                return try await workspaces.remove(taskID: taskID, liveFolders: liveFolders(), context: context)
            }
        }
        // Integration invokes pruneVanished only after exclusive domain handoff,
        // rather than write to live Node-owned records during registration.
        return channels
    }
}

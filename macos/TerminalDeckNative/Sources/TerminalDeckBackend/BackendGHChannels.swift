import Foundation
import TerminalDeckNativeCore

/// This channel is only for the app's own native window. Page, device and
/// session requests use MCP, where the existing caller/consent gate applies.
public enum BackendGHChannels {
    public static let channel = "github:workspace"
    public static func register(registry: NativeChannelRegistry, ownerID: String,
                                service: any BackendGHWorkspaceServing) async throws {
        try await registry.register(channel, ownerID: ownerID) { context, values in
            guard context.caller == .nativeApp else {
                throw NativeRPCError(code: "access-denied", message: "Open GitHub in the app, or use its GitHub tools with your granted access.")
            }
            try context.requireCount(values, 1...1)
            let request = values[0]
            guard request.fields != nil,
                  let name = request["operation"].string,
                  let operation = BackendGHOperation(rawValue: name),
                  request["arguments"].fields != nil else {
                throw NativeRPCError.invalidArguments("Choose a supported GitHub action and provide its arguments.")
            }
            guard !operation.isWrite || request["approved"].bool == true else {
                throw NativeRPCError(code: "approval-required", message: "Review the proposed GitHub change and confirm it first.")
            }
            try Task.checkCancellation()
            return try await service.perform(operation: name, arguments: request["arguments"])
        }
    }
}

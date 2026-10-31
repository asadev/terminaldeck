import Foundation
import TerminalDeckNativeCore

public enum BackendAGOPTProfileChannels {
    public static let channels = ["agopt:profile", "agopt:settings-get", "agopt:settings-set", "agopt:profile-action", "agopt:instructions-read", "agopt:instructions-save", "agopt:budget-get", "agopt:budget-set"]
    public static func register(registry: NativeChannelRegistry, ownerID: String, service: BackendAGOPTProfileService,
                                requireOwner: @escaping @Sendable (NativeRPCContext) async throws -> Void) async throws {
        for channel in channels {
            try await registry.register(channel, ownerID: ownerID) { context, args in
                guard context.caller == .nativeApp else { throw NativeRPCError(code: "not-permitted", message: "This profile editor belongs to the owner's native app.") }
                try await requireOwner(context); try context.requireCount(args, 1...1)
                let call = BackendAGOPTProfileCall.app(context)
                if ["agopt:profile", "agopt:settings-get", "agopt:instructions-read", "agopt:budget-get"].contains(channel) {
                    let id = try args[0].requireString("agent id", nonempty: true)
                    do {
                        switch channel {
                        case "agopt:profile": return try await service.profile(id, call: call)
                        case "agopt:settings-get": return try await service.settings(id, call: call)
                        case "agopt:instructions-read": return try await service.instructions(id, call: call)
                        default: return try await service.budget(id, call: call)
                        }
                    } catch let error as NativeRPCError where error.code == "missing-agent" {
                        // L4-AGENTS: a view still open on an agent deleted a moment ago. An answer, not a failure:
                        // the view closes itself (it was logged as an ERROR three times after every delete).
                        return .object([.init("gone", .bool(true)), .init("id", .string(id))])
                    }
                }
                let input = try args[0].requireObject("agent change"), id = try input["id"].requireString("agent id", nonempty: true)
                switch channel {
                case "agopt:settings-set", "agopt:budget-set":
                    let field = try input["field"].requireString("setting field", nonempty: true)
                    guard input.has("value") else { throw NativeRPCError.invalidArguments("Supply the reviewed field value.") }
                    if channel == "agopt:settings-set" { return try await service.setSetting(id, field: field, value: input["value"], call: call) }
                    return try await service.setBudget(id, field: field, value: input["value"], call: call)
                case "agopt:instructions-save":
                    return try await service.saveInstructions(id, text: input["body"].requireString("instructions"), hash: input["revision"].requireString("file revision", nonempty: true), keepMine: input["overwrite"].bool == true, call: call)
                default:
                    return try await service.action(id, action: input["action"].requireString("agent action", nonempty: true), target: input["target"].string, call: call)
                }
            }
        }
    }
}

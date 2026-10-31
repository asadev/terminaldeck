import Foundation
import TerminalDeckNativeCore

public enum BackendStaysFixedChannels {
    public static let channels = ["staysfixed:status", "staysfixed:readiness", "staysfixed:setup", "staysfixed:check", "staysfixed:stop", "staysfixed:results", "staysfixed:mark-good", "staysfixed:agents"]
    public static func register(registry: NativeChannelRegistry, ownerID: String, service: BackendStaysFixedService) async throws {
        for channel in channels {
            try await registry.register(channel, ownerID: ownerID) { context, args in
                // The shared action dispatcher must apply fixed.* permissions
                // for non-app callers before reaching the domain channel.
                try context.require(["staysfixed:status", "staysfixed:readiness", "staysfixed:results"].contains(channel) ? "fixed.read" : "fixed.write")
                if channel == "staysfixed:readiness" || channel == "staysfixed:check" {
                    do {
                        let root = try BackendStaysFixedWhere.folder(context.argument(0, in: args))
                        let value = try await (channel == "staysfixed:readiness" ? service.readiness(root, refresh: context.argument(1, in: args).bool == true) : service.check(root, by: "you"))
                        return BackendStaysFixedRead.object([("ok", .bool(true)), (channel == "staysfixed:readiness" ? "readiness" : "results", value)])
                    } catch { return BackendStaysFixedRead.object([("ok", .bool(false)), ("message", .string(error.localizedDescription))]) }
                }
                let root = try BackendStaysFixedWhere.folder(context.argument(0, in: args))
                switch channel {
                case "staysfixed:status": return await service.status(root)
                case "staysfixed:setup": return try await service.setup(root)
                case "staysfixed:stop": return .bool(await service.stop(root))
                case "staysfixed:results": return await service.results(root, full: context.argument(1, in: args).bool == true)
                case "staysfixed:mark-good": return try await service.markGood(root, anyway: context.argument(1, in: args).bool == true)
                default:
                    guard let on = context.argument(1, in: args).bool else { throw NativeRPCError.invalidArguments("Say on or off.") }
                    return try await service.setAgents(root, on: on)
                }
            }
        }
    }
}

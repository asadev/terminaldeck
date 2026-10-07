import Foundation
import TerminalDeckNativeCore

public enum BackendMemoryChannels {
    public static let names = ["memory:spaces", "memory:notes", "memory:read", "memory:search", "memory:save", "memory:delete", "memory:provenance"]
    /// The app supplies `onChanged` at service creation: registry.publish("memory:changed", arguments: [.string(id)]).
    public static func register(registry: NativeChannelRegistry, ownerID: String, service: BackendMemoryService) async throws {
        for name in names {
            try await registry.register(name, ownerID: ownerID) { context, arguments in
                // IPC is the person's memory page. Remote readers must use the scoped MCP tools.
                guard context.caller == .nativeApp || context.caller == .internalEngine else { throw NativeRPCError(code: "access-denied", message: "The memory of the agents on this computer is read on this computer only.") }
                let argument: (Int) -> NativeRPCValue = { context.argument($0, in: arguments) }
                if name == "memory:spaces" { return BackendMemoryParsing.object([("spaces", .array(try await service.spaces(refresh: argument(0).bool == true).map(\.wire)))]) }
                if name == "memory:search" {
                    guard let query = argument(0).string, let ids = argument(1).elements else { return BackendMemoryParsing.object([("ok", .bool(true)), ("hits", .array([]))]) }
                    return BackendMemoryParsing.object([("ok", .bool(true)), ("hits", .array(await service.searchIn(query, spaceIDs: ids.compactMap(\.string), limit: 40)))])
                }
                guard let id = argument(0).string else { return BackendMemoryService.failure(BackendMemoryService.refusal("That is not a memory on this machine.")) }
                switch name {
                case "memory:notes":
                    do { return BackendMemoryParsing.object([("ok", .bool(true)), ("notes", .array(try await service.notes(id))), ("graph", BackendMemoryParsing.graphWire(try await service.graph(id)))]) }
                    catch { return BackendMemoryService.failure(error) }
                case "memory:read": return await service.read(id, path: argument(1))
                case "memory:save": return await service.save(id, path: argument(1), text: argument(2), version: argument(3))
                case "memory:delete": return await service.remove(id, path: argument(1), indexLine: argument(2).bool == true)
                case "memory:provenance": return await service.provenance(id, path: argument(1))
                default: throw NativeRPCError(code: "unavailable", message: "Unknown memory channel.")
                }
            }
        }
    }
}

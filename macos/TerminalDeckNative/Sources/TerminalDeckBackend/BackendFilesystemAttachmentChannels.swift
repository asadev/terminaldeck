import Foundation
import TerminalDeckNativeCore

public enum BackendFilesystemAttachmentChannels {
    public static func register(registry: NativeChannelRegistry, ownerID: String, transfers: BackendFilesystemTransfers,
                                boundaryOf: @escaping @Sendable (String, NativeRPCContext) async throws -> BackendDeviceBoundary?) async throws -> [String] {
        try await registry.register("attach:boundary", ownerID: ownerID) { context, args in
            try context.require("files.read")
            guard let id = context.argument(0, in: args).string, let boundary = try await boundaryOf(id, context) else { return .null }
            return .object([.init("folder", .string(boundary.folder)), .init("readableProjects", .array(boundary.readOnlyProjects.map(NativeRPCValue.string)))])
        }
        try await registry.register("attach:bring-in", ownerID: ownerID) { context, args in
            try context.require("files.write")
            guard let id = context.argument(0, in: args).string, !id.isEmpty,
                  let raw = context.argument(1, in: args).elements else { return .object([.init("brought", .array([])), .init("refused", .number(0))]) }
            let paths = raw.compactMap(\.string).filter { !$0.isEmpty }
            guard let boundary = try await boundaryOf(id, context), !boundary.folder.isEmpty else {
                return .object([.init("brought", .array([])), .init("refused", .number(Double(paths.count)))])
            }
            var brought: [NativeRPCValue] = [], refused = 0
            for path in paths {
                try Task.checkCancellation()
                do {
                    let landed = try await transfers.bringIn(source: path, folder: boundary.folder, context: context)
                    brought.append(.object([.init("from", .string(path)), .init("path", .string(landed))]))
                } catch is CancellationError { throw CancellationError() }
                catch { refused += 1 }
            }
            return .object([.init("brought", .array(brought)), .init("refused", .number(Double(refused)))])
        }
        return ["attach:boundary", "attach:bring-in"]
    }
}

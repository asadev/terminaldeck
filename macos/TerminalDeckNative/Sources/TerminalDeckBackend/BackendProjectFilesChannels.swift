import Foundation
import TerminalDeckNativeCore

/// Explicit integration factory. It does not start watches, run Git, touch
/// project data, or take Store ownership merely by registering these handlers.
public enum BackendProjectFilesChannels {
    public struct Handle: Sendable {
        public let channels: [String]
        public let subscriptions: [NativeRPCSubscription]
    }
    public static func register(registry: NativeChannelRegistry, ownerID: String, files: BackendFilesystemService,
                                git: BackendGitService, projects: BackendProjectService,
                                watches: BackendFileWatchService, transfers: BackendFilesystemTransfers? = nil,
                                pickFolder: (@Sendable () async throws -> String?)? = nil) async throws -> Handle {
        var channels: [String] = []
        var subscriptions: [NativeRPCSubscription] = []
        func add(_ name: String, _ handler: @escaping NativeChannelRegistry.Handler) async throws {
            try await registry.register(name, ownerID: ownerID, handler: handler); channels.append(name)
        }
        try await add("fs:list") { context, args in
            try context.require("files.read")
            let options = context.argument(2, in: args)
            return try await files.list(root: try context.argument(0, in: args).requireString("root"),
                relative: context.argument(1, in: args).string ?? "", options: .init(showIgnored: options["showIgnored"].bool == true, withStats: options["withStats"].bool == true), context: context)
        }
        try await add("fs:read") { context, args in
            try context.require("files.read")
            return try await files.read(root: try context.argument(0, in: args).requireString("root"), relative: try context.argument(1, in: args).requireString("path"), context: context)
        }
        try await add("search:files") { context, args in
            try context.require("files.read")
            let request = context.argument(0, in: args)
            guard let root = request["root"].string, (try? await projects.requireKnown(root)) != nil else { return .object([.init("ok", .bool(false)), .init("error", .string("invalid-root"))]) }
            do {
                let result = try await files.projectFiles(root: root, refresh: request["refresh"].bool == true,
                    limit: Int(min(max(request["limit"].number ?? 10_000, 1), 50_000)), context: context, home: projects.home)
                return result.setting("ok", .bool(true))
            } catch { return .object([.init("ok", .bool(false)), .init("error", .string(error is CancellationError ? "cancelled" : "failed"))]) }
        }
        try await add("search:cancel") { context, _ in await files.cancel(ownerID: context.ownerID); return .missing }
        try await add("search:invalidate") { context, args in try context.require("files.read"); await files.invalidate(root: context.argument(0, in: args).string); return .missing }
        for action in ["overview", "explain", "filter", "invalidate"] {
            try await add("deckignore:" + action) { context, args in
                try context.require("files.read")
                let root = try context.argument(0, in: args).requireString("root")
                _ = try await projects.requireKnown(root)
                if action == "invalidate" { await files.invalidate(root: root); return .missing }
                let result = try await files.ignore(root: root, action: action, path: context.argument(1, in: args).string,
                    directory: context.argument(2, in: args).bool == true,
                    paths: context.argument(1, in: args).elements?.compactMap(\.string) ?? [], context: context)
                return action == "filter" ? result["kept"] : result
            }
        }
        try await add("git:status") { context, args in try context.require("git.read"); return try await git.status(cwd: context.argument(0, in: args).requireString("cwd"), context: context) }
        try await add("git:init") { context, args in try context.require("git.write"); return try await git.initialize(cwd: context.argument(0, in: args).requireString("cwd"), context: context) }
        try await add("git:diff") { context, args in
            try context.require("git.read")
            let options = context.argument(2, in: args)
            return .string(try await git.diff(cwd: context.argument(0, in: args).requireString("cwd"), path: context.argument(1, in: args).requireString("path"),
                options: .init(staged: options["staged"].bool == true, untracked: options["untracked"].bool == true), context: context))
        }
        try await add("git:watch") { context, args in try context.require("git.read"); return try await watches.watchGit(cwd: context.argument(0, in: args).requireString("cwd"), context: context) }
        let unwatch = try await registry.onSend("git:unwatch", ownerID: ownerID) { context, args in
            if let cwd = context.argument(0, in: args).string { await watches.unwatch(cwd: cwd, ownerID: context.ownerID) }
        }
        subscriptions.append(unwatch)
        channels.append("git:unwatch")
        try await add("project:home") { context, _ in try context.require("projects.read"); return .string(projects.home) }
        if let pickFolder {
            try await add("project:pick") { context, _ in
                guard context.caller == .nativeApp else { throw NativeRPCError(code: "access-denied", message: "Only the native window may show the project chooser") }
                return try await pickFolder().map(NativeRPCValue.string) ?? .null
            }
        }
        if let transfers {
            try await add("transfer:stage") { context, args in
                try context.require("files.write")
                let data: Data
                if case .bytes(let value) = context.argument(1, in: args) { data = value }
                else { throw NativeRPCError.invalidArguments("File staging needs actual bytes") }
                return await transfers.stage(name: context.argument(0, in: args).string ?? "file", bytes: data)
            }
        }
        return Handle(channels: channels, subscriptions: subscriptions)
    }
}

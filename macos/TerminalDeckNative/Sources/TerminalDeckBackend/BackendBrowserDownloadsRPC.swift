import Foundation
import TerminalDeckNativeCore

/// The caller-kind bit is supplied by the real authenticated MCP caller table.
/// A session shell is forbidden from browser settings even if a tool is
/// accidentally added to its allowlist. Never derive it from tool arguments.
public struct BackendBrowserDownloadsToolCaller: Sendable {
    public let context: NativeRPCContext
    public let attended: Bool
    public let isSession: Bool
    public init(context: NativeRPCContext, attended: Bool, isSession: Bool) {
        self.context = context; self.attended = attended; self.isSession = isSession
    }
}

public struct BackendBrowserDownloadsRPC: Sendable {
    public static let channels = [
        "browser-download:list", "browser-download:destination", "browser-download:cancel",
        "browser-download:clear", "browser-download:open", "browser-download:reveal", "browser-download:folder"
    ]
    private let downloads: BackendBrowserDownloads
    private let attended: @Sendable (NativeRPCContext) async -> Bool
    public init(downloads: BackendBrowserDownloads, attended: @escaping @Sendable (NativeRPCContext) async -> Bool) {
        self.downloads = downloads; self.attended = attended
    }

    public func registerChannels(in registry: NativeChannelRegistry, ownerID: String) async throws {
        var installed: [String] = []
        do {
            for channel in Self.channels {
                try await registry.register(channel, ownerID: ownerID) { context, arguments in
                    try await self.invoke(channel, context: context, arguments: arguments)
                }
                installed.append(channel)
            }
        } catch {
            for channel in installed { await registry.removeHandler(channel, ownerID: ownerID) }
            throw error
        }
    }

    public func invoke(_ channel: String, context: NativeRPCContext, arguments: [NativeRPCValue]) async throws -> NativeRPCValue {
        switch channel {
        case "browser-download:list":
            try context.requireCount(arguments, 0...0)
            return try await downloads.view(context: context).wireValue
        case "browser-download:destination":
            try context.requireCount(arguments, 1...1)
            return try await downloads.setDestination(.read(arguments[0]), context: context).wireValue
        case "browser-download:cancel":
            try context.requireCount(arguments, 1...1)
            return try await downloads.cancel(arguments[0].requireString("download id", nonempty: true), context: context).wireValue
        case "browser-download:clear":
            try context.requireCount(arguments, 0...0)
            return try await downloads.clear(context: context).wireValue
        case "browser-download:open", "browser-download:reveal":
            try context.requireCount(arguments, 1...1)
            let id = try arguments[0].requireString("download id", nonempty: true)
            do {
                return try await (channel == "browser-download:open" ? downloads.open(id, context: context) : downloads.reveal(id, context: context)).wireValue
            } catch {
                return BackendBrowserDownloadOperationReply(ok: false, message: error.localizedDescription).wireValue
            }
        case "browser-download:folder":
            try context.requireCount(arguments, 0...0)
            return .string(try await downloads.chooseFolder(context: context, attended: await attended(context)))
        default: throw NativeRPCError(code: "missing-handler", message: "No native download handler for \(channel).")
        }
    }

    /// One forwarder for each authenticated consumer. Publishing globally would
    /// disclose another profile's rows; every event here carries ownerID and is
    /// recomputed through the current per-row permission callback.
    public func forwardEvents(to registry: NativeChannelRegistry, context: NativeRPCContext) async throws -> Task<Void, any Error> {
        let stream = try await downloads.updates(context: context)
        return Task {
            for try await view in stream {
                try Task.checkCancellation()
                try await registry.publish(BackendBrowserDownloads.eventChannel, arguments: [view.wireValue], ownerID: context.ownerID)
            }
        }
    }

    public func registerMCP(in server: BackendNativeMCPServer,
                            resolveCaller: @escaping @Sendable (BackendMCPCallContext) async throws -> BackendBrowserDownloadsToolCaller) async throws {
        let schema = NativeRPCValue.object([
            .init("type", .string("object")),
            .init("properties", .object([
                .init("action", .object([.init("type", .string("string")), .init("enum", .array(Self.actions.map(NativeRPCValue.string))), .init("description", .string("Default list."))])),
                .init("download", Self.stringSchema("For cancel, open and reveal: the id from the list.")),
                .init("folder", Self.stringSchema("For destination: an absolute folder, or omit to open the chooser for the person.")),
                .init("machineId", Self.stringSchema("For destination: a currently permitted machine to deliver to, or omit for this computer.")),
                .init("machineName", Self.stringSchema("The display name of that destination machine."))
            ])), .init("additionalProperties", .bool(false))
        ])
        let spec = try BackendMCPTool(id: "browser.downloads", wireName: "browser_downloads",
            description: "The browser's Downloads list. List files and their progress and destination; cancel a download; clear finished rows without deleting files; open or reveal a completed local file; choose the destination folder or a permitted remote machine. Opening an installer, app, script, executable or unknown format requires the person's explicit consent.",
            inputSchema: schema, tier: .read)
        try await server.registerTool(spec) { mcp, arguments in
            do {
                guard !mcp.cancellation.isCancelled else { throw CancellationError() }
                let caller = try await resolveCaller(mcp)
                guard !caller.isSession else {
                    throw NativeRPCError(code: "not-permitted", message: "browser.downloads is the browser's own settings. A session can use only its attached browser windows.")
                }
                return .value(try await self.runTool(arguments, caller: caller))
            } catch {
                return .failure(NativeRPCError.wrapping(error).message)
            }
        }
    }

    private static let actions = ["list", "cancel", "clear", "open", "reveal", "destination"]
    private static func stringSchema(_ description: String) -> NativeRPCValue {
        .object([.init("type", .string("string")), .init("description", .string(description))])
    }

    private func listing(_ view: BackendBrowserDownloadsView, context: NativeRPCContext) async throws -> NativeRPCValue {
        var output: [NativeRPCValue] = []
        for row in view.items {
            let safelyOpenable = try await downloads.opensAsData(row, context: context)
            output.append(.object([
                .init("download", .string(row.id)), .init("name", .string(row.name)), .init("url", .string(row.url)),
                .init("state", .string(row.state.rawValue)), .init("bytes", .number(Double(row.bytes))), .init("received", .number(Double(row.received))),
                .init("path", .string(row.path)), .init("onMachine", .string(row.onMachine.isEmpty ? "this computer" : row.onMachineName.isEmpty ? row.onMachine : row.onMachineName)),
                .init("message", .string(row.message)), .init("startedAt", .number(row.startedAt)), .init("digest", .string(row.digest)),
                .init("opensWithoutAsking", .bool(safelyOpenable))
            ]))
        }
        return .object([
            .init("destination", .object([
                .init("machine", .string(view.destination.machineId.isEmpty ? "this computer" : view.destination.machineName.isEmpty ? view.destination.machineId : view.destination.machineName)),
                .init("folder", .string(view.destination.folder.isEmpty ? view.defaultFolder : view.destination.folder))
            ])), .init("downloads", .array(output)), .init("persistenceMessage", .string(view.persistenceMessage))
        ])
    }

    private func runTool(_ raw: NativeRPCValue, caller: BackendBrowserDownloadsToolCaller) async throws -> NativeRPCValue {
        _ = try raw.requireObject("download arguments")
        guard raw.fields?.allSatisfy({ ["action", "download", "folder", "machineId", "machineName"].contains($0.key) }) == true else {
            throw NativeRPCError.invalidArguments("Unknown download tool argument.")
        }
        func optional(_ key: String) throws -> String? {
            if raw[key].isNullish || raw[key].string == "" { return nil }
            return try raw[key].requireString(key)
        }
        let action = try optional("action") ?? "list"
        guard Self.actions.contains(action) else { throw NativeRPCError.invalidArguments("action must be one of: \(Self.actions.joined(separator: ", ")).") }
        let context = caller.context
        switch action {
        case "list": return try await listing(downloads.view(context: context), context: context)
        case "cancel":
            let id = try raw["download"].requireString("download", nonempty: true)
            let view = try await downloads.cancel(id, context: context)
            return .object([.init("download", .string(id)), .init("state", .string(view.items.first(where: { $0.id == id })?.state.rawValue ?? "gone"))])
        case "clear":
            let before = try await downloads.view(context: context).items.count
            let after = try await downloads.clear(context: context).items.count
            return .object([.init("cleared", .number(Double(max(0, before - after)))), .init("note", .string("Only the rows went. Every file is where it was."))])
        case "open", "reveal":
            let id = try raw["download"].requireString("download", nonempty: true)
            let result = try await (action == "open" ? downloads.open(id, context: context) : downloads.reveal(id, context: context))
            guard result.ok else { throw NativeRPCError(code: "download-open", message: result.message) }
            return .object([.init("download", .string(id)), .init(action == "open" ? "opened" : "shown", .bool(true))])
        case "destination":
            let machine = try optional("machineId")
            var folder = try optional("folder")
            if machine == nil, folder == nil {
                folder = try await downloads.chooseFolder(context: context, attended: caller.attended)
                if folder == "" { return .object([.init("changed", .bool(false)), .init("note", .string("The person closed the chooser without picking a folder."))]) }
            }
            let next = BackendBrowserDownloadDestination(machineId: machine ?? "", machineName: machine == nil ? "" : try optional("machineName") ?? machine!, folder: folder ?? "")
            let view = try await downloads.setDestination(next, context: context)
            return try await listing(view, context: context).setting("changed", .bool(true))
        default: throw NativeRPCError.invalidArguments("Unknown download action.")
        }
    }
}

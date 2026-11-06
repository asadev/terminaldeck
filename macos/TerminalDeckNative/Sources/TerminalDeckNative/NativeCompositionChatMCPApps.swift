import AppKit
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    func installChatMCPApps() async throws {
        guard chatMCPApps == nil, let service = clients?.mcpClients, let core else { return }
        let apps = BackendChatMCPApps(read: { [weak self] id in
            guard let self else { throw BackendSessionFailure.closed }
            return try await self.chatMCPAppConversation(id)
        }, servers: { project in try await service.list(project.map(NativeRPCValue.string) ?? .missing).requireArray("MCP servers") },
        inventory: { id, project, _, _ in try await service.inventory(.string(id), project: project.map(NativeRPCValue.string) ?? .missing) },
        resource: { id, project, uri, _ in try await service.resource(.string(id), uri: .string(uri), project: project.map(NativeRPCValue.string) ?? .missing) },
        call: { id, project, tool, args in try await service.call(.string(id), name: .string(tool), arguments: args, project: project.map(NativeRPCValue.string) ?? .missing) },
        consent: { [weak self] session, operation, args in
            guard let self else { return false }
            _ = try await self.chatMCPAppConversation(session)
            // The normal consent broker presents and records this request in the Mac and phone approval desks.
            let decision = await core.consent.request(tool: operation, tier: operation == "mcp.call" ? .alter : .act,
                summary: operation == "mcp.call" ? "Let this chat app run \(args["tool"].string ?? "a tool") on \(args["serverId"].string ?? "its server")?" : "Open \(args["url"].string ?? "this link")?",
                arguments: args.setting("sourceSession", .string(session)), origin: "plugin-consent", label: "Chat app", askedBy: "A tool in this chat")
            guard decision.granted else { return false }
            _ = try await self.chatMCPAppConversation(session)
            return true
        }, openLink: { url in await MainActor.run { NSWorkspace.shared.open(url) } }, restoreResult: { [weak self] session, row in
            guard let self else { throw BackendSessionFailure.closed }
            if session == "hoot" {
                guard let store = await MainActor.run(body: { self.hoot?.runtime.structuredChat }) else { throw BackendSessionFailure.closed }
                return try await BackendChatStoredMedia.result(store: store, rowID: row)
            }
            guard let chats = await MainActor.run(body: { self.sessionChats }) else { throw BackendSessionFailure.closed }
            return try await chats.media(session, rowID: row)
        })
        let owner = "native.chat-mcp-apps", channels = ["chat:mcp-app:read", "chat:mcp-app:bridge"]
        for channel in channels {
            try await root.registry.register(channel, ownerID: owner, policy: { context in
                guard context.caller == .nativeApp || context.caller == .internalEngine else {
                    throw NativeRPCError(code: "access-denied", message: "Use this device's authenticated chat connection.")
                }
            }) { context, args in
                try context.requireCount(args, channel.hasSuffix(":read") ? 2...2 : 3...4)
                let session = try args[0].requireString("chat", nonempty: true), row = try args[1].requireString("tool row", nonempty: true)
                if channel.hasSuffix(":read") { return try await apps.sourceDocument(session: session, rowID: row) }
                return await apps.bridge(session: session, rowID: row, message: args[2], viewID: args.count > 3 ? try args[3].requireString("view", nonempty: true) : "default")
            }
        }
        do {
            try await root.retain(.init(name: "chat-mcp-apps", domains: ["chat-mcp-apps"], ownerID: owner, invokes: Set(channels),
                stop: { [root] in for channel in channels { await root.registry.removeHandler(channel, ownerID: owner) } }))
            chatMCPApps = apps
        } catch {
            for channel in channels { await root.registry.removeHandler(channel, ownerID: owner) }
            throw error
        }
    }

    func chatMCPAppConversation(_ id: String) async throws -> BackendChatMCPApps.Conversation {
        var events: [HootChatEvent] = [], cursor: Int? = 0
        let history = await sessionChats?.conversation(id)
        let meta = sessions?.manager.list().first { $0.id == id } ?? history?.session
        let project = id == "hoot" ? (try await hoot?.runtime.state(details: false))?.paths.root : meta?.cwd
        let agentID: String? = id == "hoot" ? "hoot" : history?.job.agentID
        if id != "hoot", meta == nil { throw NativeRPCError(code: "unknown-session", message: "That chat is no longer on this Mac.") }
        for _ in 0..<2000 {
            let page: NativeRPCValue
            if id == "hoot" {
                guard let store = hoot?.runtime.structuredChat else { throw BackendSessionFailure.closed }
                page = await store.snapshot(after: cursor, limit: 500)
            } else {
                guard let sessionChats, await sessionChats.isChat(id) else { throw BackendSessionFailure.closed }
                page = try await sessionChats.read(id, cursor: cursor, limit: 500)
            }
            events += try (page["events"].elements ?? []).map { try HootChatEvent(wire: $0) }
            if page["hasMore"].bool != true {
                return .init(rows: HootChatProjection.rows(events), project: project,
                    provider: meta?.provider ?? events.last?.provider.rawValue ?? "claude", agentID: agentID)
            }
            guard let next = page["cursor"].number, next > Double(cursor ?? 0), next < Double(Int.max / 2) else { break }
            cursor = Int(next)
        }
        throw NativeRPCError(code: "unavailable", message: "The complete source chat could not be read.")
    }

    func chatMCPAppsPhoneFeature() -> BackendRemoteHostFeature? {
        guard let apps = chatMCPApps, let endpoint = remoteEndpoint, let trust = remoteTrust else { return nil }
        return BackendChatMCPApps.phoneFeature(apps: apps, endpoint: endpoint, trust: trust)
    }
}

import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Agent chats on a paired phone (iOS batch 1, step 3): the remote `chats` capability, served by the same chat
/// engine as this Mac's own Chat sessions. A new chat is created the way a phone's `create` creates a session —
/// the device's folder boundary, the person's remembered tab — only as a Chat.
extension NativeCompositionProduction {
    func installINT2PhoneChats() async throws {
        guard phoneChats == nil, let trust = remoteTrust, let endpoint = remoteEndpoint, let chats = sessionChats, let sessions, let authority else {
            throw NativeRPCError(code: "composition-incomplete", message: "Phone chats need the remote endpoint and the chat sessions first.")
        }
        // This Mac's own channels, as its New session dialog reads them (its owner context, never the phone's).
        let invoke: NativePhoneStart.Invoke = { [root] channel, arguments in
            try await root.registry.invoke(channel, context: authority.localContext(), arguments: arguments)
        }
        let specs = try? BackendTaskPersistence(directory: root.dataRoot.appendingPathComponent("remote/task-briefs"), ownership: root.state.ownership)
        var engine = BackendPhoneChats.Engine(
            read: { id in try await chats.read(id, cursor: nil, limit: 500) },
            isChat: { id in await chats.isChat(id) },
            say: { id, text in _ = try await chats.say(id, text: text) },
            interrupt: { id in _ = try await chats.stopAnswer(id) },
            answer: { id, request, allowed in _ = try await chats.answer(id, request: request, allowed: allowed, answers: .object([])) },
            start: { [sessions, joins] request in
                // The phone's New session choices (agent, model, effort, permission, account), as this Mac's dialog.
                let input = try await NativePhoneStart.input(request, chat: true, invoke: invoke, specs: specs)
                // At Full control no folder sandbox (Decker D2): the AI reaches its login, the network and its settings.
                let boundary = try await joins.phoneStartBoundary(deviceID: request.deviceID, folder: request.cwd)
                let meta = try await sessions.lifecycle.create(input, context: .init(deviceBoundary: boundary, rememberTab: true))
                if boundary == nil { NativePhoneStart.rememberFolder(request.cwd) }
                return meta
            },
            choices: { folder in await NativePhoneStart.choices(folder: folder, invoke: invoke) },
            options: { id in try await chats.options(id) },
            setOptions: { id, patch in try await chats.setOptions(id, patch) },
            steer: { id, text in _ = try await chats.steer(id, text: text) })
        engine.sendIdentified = { id, text, messageID, steer in
            if steer { _ = try await chats.steer(id, text: text, clientMessageID: messageID) }
            else { _ = try await chats.say(id, text: text, clientMessageID: messageID) }
        }
        // 31 Oct (`chats.files`): the phone's uploaded files, as this Mac's composer sends them.
        let uploads = BackendUploadDestination.uploadsFolder(home: configuration.homeDirectory, appName: configuration.appName)
        engine.sendFiles = { [sessions] id, text, files, messageID, steer, device in
            let provider = sessions.manager.list().first { $0.id == id }?.provider ?? "claude"
            let resolved = try await NativePhoneAttachments.resolve(files, text: text, provider: provider, deviceID: device, uploads: uploads, trust: trust)
            if steer { _ = try await chats.steer(id, text: resolved.text, attachments: resolved.attachments, clientMessageID: messageID) }
            else { _ = try await chats.say(id, text: resolved.text, attachments: resolved.attachments, clientMessageID: messageID) }
        }
        let bridge = BackendPhoneChats(endpoint: endpoint, trust: trust, engine: engine)
        let owner = "native.phone-chats"
        // With it, "Other folder…" on the phone (folders.pick), which no native Mac served before (26 Oct 2026).
        let folders = BackendPhoneFolders(home: configuration.homeDirectory.path)
        // 31 Oct: what an agent changed (git.status/git.diff, which no native Mac served) and Commit/Push (git.write).
        let changes = files.map { files in BackendPhoneChanges(git: files.git, context: { try authority.localContext() }) }
        let lease = try await endpoint.installFeatures(ownerID: owner, features: [await bridge.feature(), folders.feature()] + (changes?.features() ?? []),
            connectionClosed: { await bridge.disconnected($0) })
        do {
            try await root.retain(.init(name: "phone-chats", domains: ["phone-chats"], ownerID: owner,
                invokes: [], stop: { await lease.cancelAndWait(); await bridge.stop() }))
            phoneChats = bridge
        } catch { await lease.cancelAndWait(); await bridge.stop(); throw error }
    }
}

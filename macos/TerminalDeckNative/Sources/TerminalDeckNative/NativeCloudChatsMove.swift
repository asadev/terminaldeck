import AppKit
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The app's own doors the move uses (bound once by the composition; NO session host change): the side panel's
/// close, the normal create with resume, and this Mac's AI logins.
struct NativeCloudMoveHooks: Sendable {
    var close: @Sendable (_ sessionID: String) async throws -> Void
    var create: @Sendable (_ input: BackendCreateSessionInput) async throws -> BackendSessionMeta
    var profiles: @Sendable (_ provider: String) async -> [BackendAccountProfile]
}

/// "Switch to this Mac" (step 2): the Mac's half of `BackendCloudSessionMove`, wired to this app.
extension NativeCloudChats {
    /// With the uploader, per identity: the move machines, the socket's hint and the uploader's `not_yours`.
    func attachMove(send: @escaping BackendCloudChatsUploader.Send, uploader: BackendCloudChatsUploader, file: URL) {
        let ports = BackendCloudSessionMove.Ports(
            send: send,
            row: { ref in
                guard let read = await BackendCloudSessionsRead.list(send, earlier: false) else { return nil }
                return read.rows.first { $0.ref == ref }
            },
            local: { sessionId in await NativeCloudChats.shared.local(sessionId) },
            close: { id in
                guard let hooks = await MainActor.run(body: { NativeCloudChats.shared.moveHooks }) else { throw BackendSessionFailure.closed }
                try await hooks.close(id)
            },
            flush: { local in
                guard let item = await NativeCloudChats.shared.listed(local) else { return nil }
                return await uploader.flush(item)
            },
            keepLeft: { local in
                guard let item = await NativeCloudChats.shared.listed(local) else { return }
                await uploader.keepLeft(item, machine: Host.current().localizedName ?? "this Mac")
            },
            handOver: { projectID, folder in
                await BackendCodeBackupHolder.shared.actions?.handOver(projectID: projectID, folder: folder)
            },
            ownBackup: { projectID, _ in
                guard let projectID, let actions = await BackendCodeBackupHolder.shared.actions else { return true }
                return await actions.backUp(projectID: projectID).ok
            },
            folder: { row in await NativeCloudChats.folder(for: row) },
            takeCode: { request, record in
                guard let actions = await BackendCodeBackupHolder.shared.actions else { return .init(kind: .notConnected) }
                return await actions.takeCode(projectID: request.folder.projectID, folder: request.folder.path, named: request.named,
                                              pending: request.pending, record: record)
            },
            account: { provider, login in await NativeCloudChats.account(provider: provider, login: login) },
            place: { request in try BackendCloudSessionMovePlace.place(request) },
            launch: { request in
                guard let hooks = await MainActor.run(body: { NativeCloudChats.shared.moveHooks }) else { throw BackendSessionFailure.closed }
                var input = BackendCreateSessionInput(cwd: request.cwd, provider: request.provider)
                if !request.terminal, let conversation = request.conversationId {
                    input.resume = true; input.resumeConversationId = conversation; input.forkSession = false; input.pickConversation = false
                    input.profileId = request.profileID
                    if request.chat { input.chat = true }
                }
                input.projectId = request.projectID
                // The same Cloud id: the chat goes on growing in the same session of his Cloud.
                input.tabKey = request.sessionId
                await uploader.owned(request.sessionId)
                let meta = try await hooks.create(input)
                await MainActor.run {
                    NativeSessionNames.shared.rename(tabId: meta.id, typed: request.name)
                }
                return meta.id
            },
            changed: { entry in
                await MainActor.run { NativeCloudChats.shared.noteMove(entry) }
                // The take succeeded here: the session's WhatsApp agent follows it (receiver and reader here).
                if entry.role == .taker, entry.step == .done, let id = entry.launchedID,
                   let engine = NativeWhatsAppEngineBox.shared.engine {
                    await engine.sessionArrived(cloudSessionID: entry.sessionId, sessionID: id)
                }
            })
        let mover = BackendCloudSessionMove(ports: ports, file: file)
        self.mover = mover
        Task {
            await uploader.onMoved { sessionId, machine in await mover.movedAway(sessionId: sessionId, to: machine) }
            await mover.resume()
            let entries = await mover.entries
            await MainActor.run { for entry in entries.values { NativeCloudChats.shared.noteMove(entry) } }
        }
    }

    /// The socket said "look": each named session is looked at (giver side), and a waiting taker looks at once.
    nonisolated static func movesHinted(_ refs: [String]) {
        Task { @MainActor in
            guard let mover = NativeCloudChats.shared.mover else { return }
            for ref in refs.prefix(50) { await mover.hint(ref: ref) }
        }
    }

    // MARK: The page's button and the tool

    func switchHere(ref: String) {
        guard NativeCloudOffers.shows(.sessionMove) else { return }
        guard let mover else { return }
        moveNotes[ref] = BackendCloudSessionMoveWords.preparing
        Task {
            let line = await mover.switchHere(ref: ref)
            let started = await mover.entry(ref: ref).map { !$0.finished } ?? false
            moveNotes[ref] = started ? nil : line
        }
    }
    func cancelMove(ref: String) {
        guard let mover else { return }
        Task { _ = await mover.cancel(ref: ref) }
    }
    /// The page's one line for this session (nil: the plain "Runs on <machine>").
    func moveLine(ref: String, sessionId: String?) -> (line: String, moving: Bool, canCancel: Bool)? {
        let entry = moves[ref] ?? sessionId.flatMap { id in moves.values.filter { $0.sessionId == id || $0.sessionId + "~left" == id }.max { $0.startedAt < $1.startedAt } }
        if let note = moveNotes[ref], entry.map({ $0.finished }) ?? true { return (note, note == BackendCloudSessionMoveWords.preparing, false) }
        guard let entry, let line = entry.line, !line.isEmpty else { return nil }
        // A finished line is shown once, for a while (then the page is back to its plain line).
        if entry.finished, Self.now() - (entry.lineAt ?? 0) > 6 * 3_600_000 { return nil }
        return (line, entry.role == .taker && !entry.finished, entry.role == .taker && entry.step == .asked && !entry.cancelAsked)
    }

    /// The tool's lookup: a session of another machine by its name (or its ref); nil when none or several match.
    func findOther(_ wanted: String) -> String? {
        guard NativeCloudOffers.shows(.sessionMove) else { return nil }
        if others.contains(where: { $0.ref == wanted }) { return wanted }
        let named = others.filter { ($0.name ?? "").localizedCaseInsensitiveCompare(wanted) == .orderedSame }
        return named.count == 1 ? named[0].ref : nil
    }
    static func toolEntries() throws -> [(BackendMCPTool, BackendNativeMCPServer.Handler)] {
        guard NativeCloudOffers.shows(.sessionMove) else { return [] }
        return try BackendCloudSessionMoveTools.registrations(find: { wanted in await MainActor.run { NativeCloudChats.shared.findOther(wanted) } },
                                                       move: { await MainActor.run { NativeCloudChats.shared.mover } })
    }

    // MARK: Ports

    /// One of this Mac's sessions by its Cloud id, as the side panel lists it now.
    func local(_ sessionId: String) async -> BackendCloudSessionMove.Local? {
        guard let list = listReader else { return nil }
        let sessions = await list()
        guard let item = sessions.first(where: { BackendCloudChats.cloudID($0.meta) == sessionId }) else { return nil }
        let meta = item.meta
        seenMeta[sessionId] = meta
        let projects = SIDEBARProjectStore.shared.projects.isEmpty ? PROJProjects.defaults : SIDEBARProjectStore.shared.projects
        let project = PROJProjects.resolve(projectID: meta.projectId, folder: meta.cwd, projects: projects)
        let row = BackendCloudChats.row(item, name: nil, projects: projects)
        return .init(id: meta.id, sessionId: sessionId, status: row.status ?? "idle", kind: row.kind ?? "terminal", cwd: meta.cwd,
                     provider: meta.provider, conversationId: meta.agentSessionId,
                     projectID: project == PROJProjects.independentID ? nil : project, name: row.name)
    }
    /// The uploader's view of a session (its history files), from the meta last seen (it may be closed by now).
    func listed(_ local: BackendCloudSessionMove.Local) -> BackendCloudChats.Listed? {
        guard let meta = seenMeta[local.sessionId], let locator = chatsLocator else { return nil }
        let projects = SIDEBARProjectStore.shared.projects.isEmpty ? PROJProjects.defaults : SIDEBARProjectStore.shared.projects
        var row = BackendCloudChats.row(.init(meta: meta, status: local.status, lastUsedAt: Double(Self.now())), name: local.name, projects: projects)
        row.name = local.name
        return .init(row: row, source: locator.source(meta))
    }

    /// The AI login this Mac continues with: the same login by name, else another of that AI, else none.
    nonisolated static func account(provider: String, login: String?) async -> BackendCloudSessionMove.Account {
        guard let hooks = await MainActor.run(body: { NativeCloudChats.shared.moveHooks }) else { return .none }
        let profiles = await hooks.profiles(provider).filter { $0.provider == provider }
        if let login, let same = profiles.first(where: { $0.name.localizedCaseInsensitiveCompare(login) == .orderedSame }) {
            return .same(profileID: same.system ? nil : same.id, home: same.configDir)
        }
        let chosen = profiles.sorted { ($0.lastUsedAt ?? 0) > ($1.lastUsedAt ?? 0) }.first
        guard let chosen else { return .none }
        if login == nil { return .same(profileID: chosen.system ? nil : chosen.id, home: chosen.configDir) }
        return .other(profileID: chosen.system ? nil : chosen.id, name: chosen.name, home: chosen.configDir)
    }

    /// The project's folder on this Mac: its own when it is here; else the one this Mac gives Cloud projects (made
    /// now, nothing asked); a session with no project keeps its folder when it exists, else this Mac's Independent.
    nonisolated static func folder(for row: BackendCloudSessionsRead.Row) async -> BackendCloudSessionMove.Folder? {
        let manager = FileManager.default
        func isFolder(_ path: String) -> Bool { var directory: ObjCBool = false; return manager.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue }
        guard let projectID = row.project?.cloudRef, projectID != PROJProjects.independentID else {
            if let cwd = row.cwd, isFolder(cwd) { return .init(path: cwd, projectID: nil, made: false) }
            guard let made = try? NativeLandingPlaces.ensureIndependent() else { return nil }
            return .init(path: made, projectID: nil, made: false)
        }
        guard let folders = BackendProjectFolders.installed else { return nil }
        var found = (try? await folders.rows())?.first { $0.projectID == projectID }
        if found?.folder == nil { _ = await folders.placeMissing(); found = (try? await folders.rows())?.first { $0.projectID == projectID } }
        if let path = found?.folder, isFolder(path) {
            let empty = ((try? manager.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }.isEmpty && !manager.fileExists(atPath: path + "/.git")
            return .init(path: path, projectID: projectID, made: empty)
        }
        // Moved or deleted here: a fresh folder in this Mac's Projects folder, his old path left alone.
        let name = BackendCodeBackupNames.repository(row.project?.name ?? "project")
        let projects = await folders.projectsFolder()
        var path = projects.appendingPathComponent(name, isDirectory: true).path
        var index = 2
        while manager.fileExists(atPath: path) { path = projects.appendingPathComponent(name + "-\(index)").path; index += 1 }
        guard (try? manager.createDirectory(atPath: path, withIntermediateDirectories: true)) != nil else { return nil }
        _ = try? await folders.use(projectID: projectID, folder: path)
        return .init(path: path, projectID: projectID, made: true)
    }
}

import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The delete rule's door for the AI tools (`cloud.delete`, `cloud.not_here`, `cloud.bring_back`, and the task/agent
/// delete verbs): every live item an AI may name, every owner by its route, this Mac's id and name, and the gate.
/// It never reaches a Bin: owners are asked only for `deleteItems`, `notHere` and `bringBack` (BackendCloudDeleteDoor).
enum NativeCloudDeleteToolDoor {
    static func live() -> BackendCloudDeleteDoor {
        BackendCloudDeleteDoor(
            targets: { try await targets() },
            owners: { await NativeCloudDeleteOwners.all() },
            route: { BackendCloudDeletePage.route($0) },
            folderOf: { item in await folder(of: item) },
            thisMac: { await thisMac() },
            gateOpen: { await NativeCloudFileOps.store()?.cloudDeleteRuleIsOpen() ?? false })
    }

    /// This Mac: its id from the Devices list (the row standing for this Mac), its own name, never the id as a name.
    static func thisMac() async -> BackendCloudDeleteDoor.Mac? {
        await MainActor.run {
            let snapshot = NativeCloudAccount.shared.snapshot
            guard let id = snapshot.trust.first(where: { $0.standing == .thisMac })?.deviceId, !id.isEmpty else { return nil }
            let device = snapshot.devices.first { $0.deviceId.lowercased() == id.lowercased() }
            return .init(id: id, name: BackendCloudContentsWords.plain(device?.shownName) ?? Host.current().localizedName ?? "This Mac")
        }
    }

    /// Every live item an AI may name: memory rows, Cloud folder files, artifacts, instruction files, tasks, agents,
    /// projects and the saved-password kinds. Never a Bin row, never a sidecar.
    static func targets() async throws -> [BackendCloudDeleteDoor.Target] {
        let projectRoot: @Sendable (String) async -> String? = { id in await MainActor.run { NativeCloudBoot.shared.projectRoot(id)?.path } }
        var all: [BackendCloudDeleteDoor.Target] = []
        if let snapshot = await NativeCloudContentsModel.toolContents() {
            all += await BackendCloudDeleteDoor.memoryTargets(snapshot, folder: projectRoot)
        }
        if let artifacts = await MainActor.run(body: { NativeCloudArtifacts.shared.owner }) {
            for item in (try? await artifacts.items()) ?? [] {
                if let target = BackendCloudDeleteDoor.artifactTarget(item, folder: await projectRoot(item.projectId)) { all.append(target) }
            }
        }
        all += await recordTargets()
        all += await fileTargets()
        all += await secretTargets()
        // Sessions in the Cloud: every chat of the account the Cloud holds, by its name (Everywhere, into the Bin).
        all += await MainActor.run { NativeCloudChats.shared.deleteTargets() }
        return all
    }

    /// Cloud folder files (by their path in the folder) and instruction files (by their place), never a sidecar.
    static func fileTargets() async -> [BackendCloudDeleteDoor.Target] {
        var all: [BackendCloudDeleteDoor.Target] = []
        if let folder = await MainActor.run(body: { NativeCloudFolder.current }) {
            all += ((try? await folder.trackedPaths()) ?? []).compactMap(BackendCloudDeleteDoor.cloudFolderTarget(relative:))
        }
        if let boot = await MainActor.run(body: { NativeCloudBoot.shared.boot }) {
            let projects = (try? await BackendPROJRegistry.installed?.projects()) ?? []
            for file in (try? await boot.trackedFiles()) ?? [] where !BackendCloudManagerTools.isSidecar(file.relative) {
                let name = (file.relative as NSString).lastPathComponent
                if file.place == .project {
                    guard let id = file.identity else { continue }
                    let root = await MainActor.run { NativeCloudBoot.shared.projectRoot(id)?.path }
                    all.append(BackendCloudDeleteDoor.bootTarget(sourceId: file.sourceId, relative: file.relative, name: name,
                        placeName: projects.first { $0.id == id }?.name, folder: root ?? projects.first { $0.id == id }?.folders.first))
                } else {
                    all.append(BackendCloudDeleteDoor.bootTarget(sourceId: file.sourceId, relative: file.relative, name: name,
                        placeName: file.place.rawValue.capitalized, folder: nil))
                }
            }
        }
        return all
    }

    /// Project secret files, saved passwords and MCP servers: names only, never a value, never a Bin entry.
    static func secretTargets() async -> [BackendCloudDeleteDoor.Target] {
        var all: [BackendCloudDeleteDoor.Target] = []
        if let store = await MainActor.run(body: { BackendProjectSecretFilesHolder.shared.store }) {
            let projects = (try? await BackendPROJRegistry.installed?.projects()) ?? []
            for file in (try? await store.deleteListing()) ?? [] {
                let project = projects.first { $0.id == file.item.place }
                all.append(.init(item: file.item, placeName: project?.name, folder: project?.folders.first))
            }
        }
        if let graph = await MainActor.run(body: { NativeCloudSecrets.shared.graph }) {
            for source in await MainActor.run(body: { NativeCloudDeleteOwners.secretSources }) {
                guard let owner = await graph.deleteOwner(sourceId: source) as? BackendProjectSecretFilesSavedDeleteOwner else { continue }
                for item in (try? await owner.items()) ?? [] { all.append(.init(item: item)) }
            }
        }
        return all
    }

    /// Tasks (this Mac's own, not in Trash), agents and projects, named by title / name, with their project's folder.
    static func recordTargets() async -> [BackendCloudDeleteDoor.Target] {
        let projects = (try? await BackendPROJRegistry.installed?.projects()) ?? []
        func project(_ id: String?) -> PROJProject? { id.flatMap { id in projects.first { $0.id == id } } }
        var all: [BackendCloudDeleteDoor.Target] = []
        if let store = await MainActor.run(body: { NativeCloudRecordsOwners.taskStore }) {
            for task in (try? await store.all()) ?? [] where task.isLocal {
                let folder = task.project.isEmpty ? nil : task.project
                let owner = folder.flatMap { folder in project(PROJProjects.resolve(projectID: nil, folder: folder, projects: projects)) }
                all.append(BackendCloudDeleteDoor.recordTarget(kind: "task", id: task.id, name: task.value["title"].string ?? "Task",
                                                               placeName: owner?.name, folder: folder))
            }
        }
        if let roster = await MainActor.run(body: { NativeCloudRecordsOwners.roster }) {
            for agent in (try? await roster.allAgents()) ?? [] {
                guard let id = agent["id"].string, let name = agent["name"].string else { continue }
                let owner = project(agent["projectId"].string)
                all.append(BackendCloudDeleteDoor.recordTarget(kind: "agent", id: id, name: name, placeName: owner?.name, folder: owner?.folders.first))
            }
        }
        for entry in projects where entry.id != PROJProjects.independentID {
            all.append(BackendCloudDeleteDoor.recordTarget(kind: "project", id: entry.id, name: entry.name, placeName: nil, folder: entry.folders.first))
        }
        return all
    }

    /// The project folder of a marked item, for the caller's scope: projects and agents by their project; the rest
    /// (account memory, Cloud folder, instruction files of an AI account) belong to no project.
    static func folder(of item: CloudDeleteItem) async -> String? {
        let projects = (try? await BackendPROJRegistry.installed?.projects()) ?? []
        let id = item.id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? item.id
        switch item.kind {
        case "project":
            return projects.first { $0.id == id || $0.id == item.id }?.folders.first
        default:
            return nil
        }
    }
}

/// One source for the delete rule's gate and Mac names, shared by every owner the composition wires (lead, 15 Nov:
/// one name per Mac everywhere = the device list's shown name).
enum NativeCloudDeleteNames {
    /// Open only when every computer of the account announced the delete rule (`DeckMemoryStore.cloudDeleteRuleIsOpen`).
    static let gate: @Sendable () async -> Bool = { await NativeCloudFileOps.store()?.cloudDeleteRuleIsOpen() ?? false }
    /// A Mac's shown name from the device list, or nil when it is not listed (never its id).
    static func macName(_ deviceId: String) async -> String? {
        await MainActor.run {
            NativeCloudAccount.shared.snapshot.devices.first { $0.deviceId.lowercased() == deviceId.lowercased() }
                .flatMap { BackendCloudContentsWords.plain($0.shownName) }
        }
    }
    /// The person's own press on this Mac: one actor, one new group (the Your Cloud page's `personDeleteActor`).
    @MainActor static func personActor() -> CloudDeleteActor {
        let snapshot = NativeCloudAccount.shared.snapshot
        let id = snapshot.trust.first { $0.standing == .thisMac }?.deviceId ?? ""
        let this = snapshot.devices.first { $0.deviceId.lowercased() == id.lowercased() }
        return .init(by: .person, mac: id, macName: BackendCloudContentsWords.plain(this?.shownName) ?? "This Mac",
                     at: Int64(Date().timeIntervalSince1970 * 1000), group: UUID().uuidString.lowercased())
    }
    /// The records owners take a plain name: "another device" when the device list does not name it.
    static let recordMacName: @Sendable (String) async -> String = { id in await macName(id) ?? "another device" }
}

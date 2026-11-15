import Foundation
import TerminalDeckNativeCore

/// I08 — memory flow history and Hoot knowledge. Inert until the account assembly constructs it after the Cloud gate.
///
/// Owners and how an incoming version reaches them:
/// - `D/deck-memory/{flow-state.json,job-flow.jsonl,helper/**}` (DeckMemoryFlowStateFile, BackendJobFlowLog, the flow's
///   helper work folder). The flow engine loads its state once and owns it while running; its contents are this Mac's
///   reading positions (paths, inodes, offsets). Raw bytes are uploaded and kept readable in the Cloud archive area on
///   every Mac; they are never made live on another device (archive-only), so no running owner is overwritten.
/// - `<hoot>/{memory,specs,runs}/**` (Hoot's memory folder, briefs/specs, routine run reports). Their owners read files
///   on demand; an absent file is created once (create-only, read back). A different existing file stays and the
///   incoming version is kept beside it.
/// - `D/knowledge/<projectKey>/{project.json,*.md,log.jsonl}` (BackendKnowledgeStore, which reads from disk on demand).
///   The folder key is a hash of the project's local path, so it is recomputed from this Mac's path map: the project
///   identity travels on each operation, and project.json's `project` field is set to the local folder. Unmapped
///   projects wait, retained, until their folder is known.
public enum BackendCloudBrainFlow {
    public static let flowArchiveReason = "This Mac's own reading positions and helper work; kept readable, never made live on another device."

    public static func adapter(dataRoot: URL, hootRoot: URL, deviceId: String, stateRoot: URL, projects: [BackendCloudBrainProjectRoot],
                               resolveProject: @escaping @Sendable (String, String) async -> URL?) throws -> BackendCloudBrainFiles {
        let knowledgeRoot = dataRoot.appendingPathComponent("knowledge", isDirectory: true)
        var byKey: [String: (projectId: String, rootId: String)] = [:]
        for project in projects {
            let real = (try? BackendKnowledgeFormat.realProject(project.path.path)) ?? project.path.resolvingSymlinksInPath().path
            byKey[BackendKnowledgeFormat.projectKey(real)] = (projectId: project.projectId, rootId: project.rootId)
        }
        let keys = byKey
        let flow = BackendCloudBrainFilesSource(
            sourceId: "flow", root: dataRoot.appendingPathComponent("deck-memory", isDirectory: true),
            include: ["flow-state.json", "job-flow.jsonl", "helper/**"], exclude: BackendCloudBrainFilesNames.locks, excludeExecutables: true,
            projection: .archiveOnly(flowArchiveReason))
        let hoot = BackendCloudBrainFilesSource(
            sourceId: "hoot", root: hootRoot, include: ["memory/**", "specs/**", "runs/**"], exclude: BackendCloudBrainFilesNames.locks,
            excludeExecutables: true, projection: .createOnly(transform: nil))
        let knowledge = BackendCloudBrainFilesSource(
            sourceId: "knowledge", root: knowledgeRoot, include: ["*/project.json", "*/*.md", "*/log.jsonl"], exclude: BackendCloudBrainFilesNames.locks,
            projection: .custom({ incoming in try await placeKnowledge(incoming, knowledgeRoot: knowledgeRoot, resolveProject: resolveProject) }),
            project: { relative in
                guard let folder = relative.split(separator: "/").first else { return nil }
                return keys[String(folder)]
            })
        return try BackendCloudBrainFiles(inventoryRow: "I08", deviceId: deviceId, stateRoot: stateRoot, sources: [flow, hoot, knowledge])
    }

    static func placeKnowledge(_ incoming: BackendCloudBrainFilesIncoming, knowledgeRoot: URL,
                               resolveProject: @Sendable (String, String) async -> URL?) async throws -> BackendCloudBrainFilesPlacement {
        guard let projectId = incoming.projectId, let rootId = incoming.rootId else {
            return .waiting("This knowledge belongs to a project folder that is not registered.")
        }
        guard let local = await resolveProject(projectId, rootId) else { return .waiting("The project's folder is not on this Mac yet.") }
        let real = (try? BackendKnowledgeFormat.realProject(local.path)) ?? local.resolvingSymlinksInPath().path
        let parts = incoming.relative.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw CloudFailure.invalidRequest }
        var bytes = incoming.bytes
        if parts[1] == "project.json" {
            // Only the known path field is projected; message text is never rewritten.
            let value = try NativeRPCValue.parseJSON(incoming.bytes)
            guard let fields = value.fields else { throw CloudFailure.unsupportedFormat }
            var replaced = false
            let mapped = fields.map { field -> NativeRPCValue.Field in
                guard field.key == "project" else { return field }
                replaced = true
                return .init("project", .string(real))
            }
            guard replaced else { throw CloudFailure.unsupportedFormat }
            bytes = try NativeRPCValue.object(mapped).encodedJSON()
        }
        return .write(knowledgeRoot.appendingPathComponent(BackendKnowledgeFormat.projectKey(real)).appendingPathComponent(parts[1]), bytes)
    }
}

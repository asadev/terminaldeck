import Foundation
import TerminalDeckNativeCore

/// One resolved provider configuration home, supplied by its existing owner (profiles, account logins, agent homes).
/// `home` is the folder that directly holds the provider's files: `~/.claude`, `~/.codex`, `~/.gemini`, `~/.agents` or a profile's own copy.
public struct BackendCloudBrainProviderHome: Sendable, Equatable {
    public let provider: String
    public let profileId: String
    public let home: URL
    public init(provider: String, profileId: String, home: URL) { self.provider = provider; self.profileId = profileId; self.home = home }
}

/// I09 — provider-owned memory, instructions and skills (text only).
///
/// Exact allow-lists per home and project folder; nothing else under a home is read, so sign-in and auth files are never
/// included. Binary skill assets are counted as blocked: they belong to work backup, which is not available yet.
/// Restore: home files go to the same relative path in this Mac's home for that provider/profile (create-only); Claude
/// project memory (`projects/<encoded>/memory/**`) is re-encoded from this Mac's project folder, never by reversing the
/// lossy folder name; project instruction files go into the mapped project folder. Anything without a destination waits,
/// retained, and is counted as waiting.
public enum BackendCloudBrainInstructions {
    public static let binaryReason = "kept by work backup, which is not available yet."
    public static let homeIncludes: [String: [String]] = [
        "claude": ["CLAUDE.md", "agents/**", "skills/**", "projects/*/memory/**"],
        "codex": ["AGENTS.md", "memories/**", "skills/**"],
        "gemini": ["GEMINI.md", "skills/**"],
        "agents": ["skills/**"]
    ]
    public static let projectIncludes = ["CLAUDE.md", "AGENTS.md", "GEMINI.md", ".claude/agents/**", ".claude/skills/**", ".agents/skills/**",
                                         ".codex/skills/**", ".gemini/GEMINI.md", ".gemini/skills/**"]

    public static func adapter(homes: [BackendCloudBrainProviderHome], projects: [BackendCloudBrainProjectRoot], deviceId: String, stateRoot: URL,
                               resolveHome: @escaping @Sendable (String, String) async -> URL?,
                               resolveProject: @escaping @Sendable (String, String) async -> URL?) throws -> BackendCloudBrainFiles {
        guard homes.allSatisfy({ homeIncludes[$0.provider] != nil }), projects.allSatisfy({ UUID(uuidString: $0.rootId) != nil }) else { throw CloudFailure.invalidRequest }
        // Claude names a project's folder by an encoding of its path; map each encoding back to the registered identity.
        var encoded: [String: (projectId: String, rootId: String)] = [:]
        for project in projects {
            for spelling in NativeTranscriptPaths.projectSpellings(project.path.path) + [project.path.path] {
                encoded[NativeTranscriptPaths.encodeProjectPath(spelling)] = (projectId: project.projectId, rootId: project.rootId)
            }
        }
        let byEncoding = encoded
        var sources: [BackendCloudBrainFilesSource] = []
        for home in homes {
            sources.append(homeSource(provider: home.provider, profileId: home.profileId, root: home.home, byEncoding: byEncoding,
                                      resolveHome: resolveHome, resolveProject: resolveProject))
        }
        for project in projects {
            sources.append(projectSource(projectId: project.projectId, rootId: project.rootId, root: project.path, resolveProject: resolveProject))
        }
        guard !sources.isEmpty else { throw CloudFailure.invalidRequest }
        let dynamic: @Sendable (String) -> BackendCloudBrainFilesSource? = { id in
            let parts = id.split(separator: "/").map(String.init)
            let placeholder = stateRoot.appendingPathComponent("not-on-this-mac", isDirectory: true)
            if parts.count == 3, parts[0] == "home", homeIncludes[parts[1]] != nil, let profileId = BackendCloudBrainFilesNames.untoken(parts[2]) {
                // Another AI account: retained and waiting until that account exists on this Mac. Never walked here.
                return homeSource(provider: parts[1], profileId: profileId, root: placeholder, byEncoding: [:], resolveHome: resolveHome, resolveProject: resolveProject, id: id)
            }
            if parts.count == 2, parts[0] == "project", UUID(uuidString: parts[1]) != nil {
                return projectSource(projectId: nil, rootId: parts[1], root: placeholder, resolveProject: resolveProject)
            }
            return nil
        }
        return try BackendCloudBrainFiles(inventoryRow: "I09", deviceId: deviceId, stateRoot: stateRoot, sources: sources, dynamicSource: dynamic)
    }

    static func homeSource(provider: String, profileId: String, root: URL, byEncoding: [String: (projectId: String, rootId: String)],
                           resolveHome: @escaping @Sendable (String, String) async -> URL?,
                           resolveProject: @escaping @Sendable (String, String) async -> URL?, id: String? = nil) -> BackendCloudBrainFilesSource {
        BackendCloudBrainFilesSource(
            sourceId: id ?? "home/" + provider + "/" + BackendCloudBrainFilesNames.token(profileId), root: root, include: homeIncludes[provider] ?? [],
            exclude: BackendCloudBrainFilesNames.locks, excludeExecutables: true, binaryBlockedReason: binaryReason, optional: true,
            projection: .custom({ incoming in
                guard let home = await resolveHome(provider, profileId) else { return .waiting("This AI account is not on this Mac yet.") }
                let parts = incoming.relative.split(separator: "/", maxSplits: 2).map(String.init)
                if parts.first == "projects" {
                    guard parts.count == 3, let projectId = incoming.projectId, let rootId = incoming.rootId else {
                        return .waiting("This memory belongs to a folder that is not a registered project.")
                    }
                    guard let local = await resolveProject(projectId, rootId) else { return .waiting("The project's folder is not on this Mac yet.") }
                    return .write(home.appendingPathComponent("projects").appendingPathComponent(NativeTranscriptPaths.encodeProjectPath(local.path))
                        .appendingPathComponent(parts[2]), incoming.bytes)
                }
                return .write(home.appendingPathComponent(incoming.relative), incoming.bytes)
            }),
            project: { relative in
                let parts = relative.split(separator: "/", maxSplits: 2)
                guard parts.count == 3, parts[0] == "projects" else { return nil }
                return byEncoding[String(parts[1])]
            })
    }

    static func projectSource(projectId: String?, rootId: String, root: URL,
                              resolveProject: @escaping @Sendable (String, String) async -> URL?) -> BackendCloudBrainFilesSource {
        BackendCloudBrainFilesSource(
            sourceId: "project/" + rootId.lowercased(), root: root, include: projectIncludes, exclude: BackendCloudBrainFilesNames.locks,
            excludeExecutables: true, binaryBlockedReason: binaryReason, optional: false,
            projection: .custom({ incoming in
                guard let projectId = incoming.projectId ?? projectId, let local = await resolveProject(projectId, incoming.rootId ?? rootId) else {
                    return .waiting("The project's folder is not on this Mac yet.")
                }
                return .write(local.appendingPathComponent(incoming.relative), incoming.bytes)
            }),
            project: { _ in
                guard let projectId else { return nil }
                return (projectId: projectId, rootId: rootId.lowercased())
            })
    }
}

import Foundation
import TerminalDeckNativeCore

/// Explicit finite roots for every credential caller. Only the current local
/// owner may receive nil roots; [] means no access, never an implicit fallback.
public struct BackendROUTINESSkillsScope: Equatable, Sendable {
    public let roots: [String]?
    public let projectRoot: String?
    public init(roots: [String]?, projectRoot: String? = nil) {
        self.roots = roots.map { Array(Set($0.map(Self.canonical))).sorted() }
        self.projectRoot = projectRoot.map(Self.canonical)
    }
    public static let owner = Self(roots: nil)
    public static func canonical(_ path: String) -> String {
        // Foundation leaves parent aliases unresolved when the final file does not exist.
        // Resolve the nearest existing ancestor before appending a new destination.
        var ancestor = URL(fileURLWithPath: path).standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        ancestor = ancestor.resolvingSymlinksInPath()
        for component in missing.reversed() { ancestor.appendPathComponent(component) }
        return ancestor.standardizedFileURL.path
    }
    private static func within(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root == "/" ? "/" : root + "/") }
    public func allows(_ path: String) -> Bool {
        let current = Self.canonical(path)
        if let projectRoot, !Self.within(current, projectRoot) { return false }
        return roots.map { $0.contains { Self.within(current, $0) } } ?? true
    }
    public func require(_ path: String) throws {
        guard allows(path) else { throw NativeRPCError(code: "not-granted", message: "That skill or agent is outside the caller's current folder grant.") }
    }
    /// The atomic task owner and installer receive one selected boundary. This
    /// keeps an agent that moves while awaiting their actor outside the old grant.
    public func boundary(for path: String) throws -> String? {
        try require(path)
        let canonical = Self.canonical(path)
        if let projectRoot { return projectRoot }
        return roots?.filter { Self.within(canonical, $0) }.max { $0.count < $1.count }
    }
}

public struct BackendROUTINESSkillsGrant: Equatable, Sendable {
    public let reads: BackendROUTINESSkillsScope
    public let writes: BackendROUTINESSkillsScope
    public let identity: String
    public let localOwner: Bool
    public let agentChangesAllowed: Bool
    public let mutationsAllowed: Bool
    public init(readRoots: [String]?, writeRoots: [String]?, identity: String, localOwner: Bool = false, projectRoot: String? = nil, agentChangesAllowed: Bool = true, mutationsAllowed: Bool = true) {
        reads = .init(roots: readRoots, projectRoot: projectRoot); writes = .init(roots: writeRoots, projectRoot: projectRoot)
        self.identity = identity; self.localOwner = localOwner
        self.agentChangesAllowed = agentChangesAllowed
        self.mutationsAllowed = mutationsAllowed
    }
    public func validate() throws {
        guard localOwner || reads.roots != nil && writes.roots != nil else {
            throw NativeRPCError(code: "not-granted", message: "A credential caller needs explicit current folder grants.")
        }
    }
    public func samePlanningGrant(as other: Self) -> Bool { identity == other.identity && reads == other.reads && localOwner == other.localOwner && agentChangesAllowed == other.agentChangesAllowed && mutationsAllowed == other.mutationsAllowed }
}

public struct BackendROUTINESSkillsEffectGuard: Sendable {
    public let verify: @Sendable () async throws -> Void
    public init(verify: @escaping @Sendable () async throws -> Void) { self.verify = verify }
}

/// Portable approval boundary, used by the shipped native MCP definitions and
/// its stub tests. It never fabricates a local UI or guesses a credential scope.
public enum BackendROUTINESSkillsBoundary {
    public typealias CurrentGrant = @Sendable (_ approved: Bool) async throws -> BackendROUTINESSkillsGrant
    public static func run(channel: String, arguments: NativeRPCValue, changing: Bool, service: BackendROUTINESSkills,
                           currentGrant: @escaping CurrentGrant,
                           approve: @escaping @Sendable (NativeRPCValue) async throws -> Void) async throws -> NativeRPCValue {
        let plannedGrant = try await currentGrant(false); try plannedGrant.validate()
        if changing, !plannedGrant.mutationsAllowed { throw NativeRPCError(code: "not-granted", message: "This caller's current permission allows reading skills only.") }
        if channel == "skills:assign" || channel == "skills:unassign" || channel == "skills:rename" {
            guard plannedGrant.agentChangesAllowed else { throw NativeRPCError(code: "not-granted", message: "This access key has no Tasks grant for changing agent profiles.") }
        }
        let plan = try await service.scoped(arguments, channel: channel, scope: plannedGrant.reads)
        try await approve(plan)
        let accepted = try await currentGrant(true); try accepted.validate()
        guard accepted.samePlanningGrant(as: plannedGrant) else {
            throw NativeRPCError(code: "approval-stale", message: "The caller's grant changed while approval was open. Ask again.")
        }
        let scope = changing ? accepted.writes : accepted.reads
        let currentPlan = try await service.scoped(arguments, channel: channel, scope: scope, readScope: accepted.reads)
        guard currentPlan == plan else { throw NativeRPCError(code: "approval-stale", message: "The selected target changed while approval was open. Ask again.") }
        let recheck: @Sendable () async throws -> BackendROUTINESSkillsScope = {
            let current = try await currentGrant(true); try current.validate()
            guard current == accepted else { throw NativeRPCError(code: "approval-stale", message: "The caller's grant changed before this skill change could finish. Ask again.") }
            return changing ? current.writes : current.reads
        }
        let output = try await service.call(channel, currentPlan, scope: scope, readScope: accepted.reads, currentScope: recheck)
        _ = try await recheck()
        return output
    }
}

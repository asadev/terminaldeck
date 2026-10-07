import Foundation
import TerminalDeckNativeCore

/// The synchronous registry in hidden-sessions.ts. Owners register before
/// exposing a spawned PTY and release only after its process is gone. No TTL.
public final class BackendRemoteServeSessionHidden: @unchecked Sendable {
    public static let shared = BackendRemoteServeSessionHidden()
    private let lock = NSLock()
    private var ids = Set<String>()
    private var predicates: [UUID: @Sendable (String) -> Bool] = [:]
    public init() {}
    public func hide(_ id: String) { lock.lock(); defer { lock.unlock() }; if !id.isEmpty { ids.insert(id) } }
    public func release(_ id: String) { lock.lock(); defer { lock.unlock() }; ids.remove(id) }
    /// host-core.ts `hidden: (id) => isCopilotSession(id) || isHiddenSession(id)`:
    /// the per-device run IDs above, OR any installed owner answer (the desk
    /// Hoot runtime's `isCopilotSession`). Predicates are evaluated outside the lock.
    public func contains(_ id: String) -> Bool {
        lock.lock(); let listed = ids.contains(id); let answers = Array(predicates.values); lock.unlock()
        return listed || answers.contains { $0(id) }
    }
    /// Only the explicitly hidden IDs (TS `isHiddenSession`: per-device runs),
    /// without owner predicates such as the desk Hoot's identity.
    public func listed(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
    /// Install an ID-only owner answer; returns the token for `removePredicate`.
    @discardableResult public func addPredicate(_ predicate: @escaping @Sendable (String) -> Bool) -> UUID {
        let token = UUID(); lock.lock(); predicates[token] = predicate; lock.unlock(); return token
    }
    public func removePredicate(_ token: UUID) { lock.lock(); predicates[token] = nil; lock.unlock() }
    /// For tests only, as in resetHiddenSessions.
    public func resetForTests() { lock.lock(); defer { lock.unlock() }; ids.removeAll(); predicates.removeAll() }
}

/// Reusable rules for the existing BackendRemoteHost fanout. POSIX lexical
/// normalization deliberately does not consult symlinks or case-fold the Mac.
public enum BackendRemoteServeSessionPolicy {
    public static func normalizeFolder(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var segments: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if let last = segments.last, last != ".." { segments.removeLast() }
                else if !absolute { segments.append(part) }
            } else { segments.append(part) }
        }
        let joined = segments.joined(separator: "/")
        return absolute ? "/" + joined : (joined.isEmpty ? "." : joined)
    }
    public static func sameFolder(_ left: String, _ right: String) -> Bool { normalizeFolder(left) == normalizeFolder(right) }
    public static func withinFolder(_ root: String, _ path: String) -> Bool {
        if sameFolder(root, path) { return true }
        guard root.hasPrefix("/"), path.hasPrefix("/") else { return false }
        let parent = normalizeFolder(root), child = normalizeFolder(path)
        return child.hasPrefix(parent == "/" ? "/" : parent + "/")
    }
    public static func cleanFolders(_ values: [NativeRPCValue]) -> [String] {
        var kept: [String] = []
        for value in values {
            guard let path = value.string.map(BackendRemoteServeAccountGrantStorage.trim), path.hasPrefix("/"), path.utf16.count <= 4096,
                  !kept.contains(where: { sameFolder($0, path) }) else { continue }
            kept.append(path)
            if kept.count == 64 { break }
        }
        return kept
    }
    public static func isHidden(_ id: String, ask: (@Sendable (String) throws -> Bool)?) -> Bool {
        guard let ask else { return false }
        do { return try ask(id) } catch { return true }
    }
    public static func visible(deviceID: String, session: BackendSessionMeta?,
                               hidden: (@Sendable (String) throws -> Bool)?,
                               reach: (@Sendable (String) throws -> (unrestricted: Bool, folders: [String]))?,
                               shared: (@Sendable (String, String) throws -> Bool)?) -> Bool {
        guard let session, !isHidden(session.id, ask: hidden) else { return false }
        do {
            if let reach { let value = try reach(deviceID); if !value.unrestricted && !value.folders.contains(where: { withinFolder($0, session.cwd) }) { return false } }
            if let shared, try !shared(deviceID, session.id) { return false }
            return true
        } catch { return false }
    }
    /// Filter exactly the hidden sessions' cwd strings as SessionFanout does.
    public static func offeredFolders(_ folders: [String], sessions: [BackendSessionMeta], hidden: (@Sendable (String) throws -> Bool)?) -> [String] {
        let secret = Set(sessions.filter { isHidden($0.id, ask: hidden) }.map(\.cwd))
        return folders.filter { !secret.contains($0) }
    }
    public static func noSuchSession(_ id: String) -> String { "No session \(id) is running." }
    public static let unsharedMessage = "That session is no longer shared with this device."
}

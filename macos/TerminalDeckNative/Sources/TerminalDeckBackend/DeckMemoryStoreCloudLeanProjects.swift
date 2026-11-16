import Foundation
import TerminalDeckNativeCore

/// Lean first version (spec AM10, scope item 2): memory for a project is merged only when the project id is THE SAME
/// on both Macs. "On this Mac" means this Mac's memory already has that project's own folder. Anything else waits,
/// kept durably and untouched, and is listed as "waiting for a project on this Mac"; it is placed by itself once
/// the project exists here. Nothing is matched by name or by guess, and there is no lane-A2 resolver in this version.
public enum DeckMemoryCloudLeanProjects {
    /// The rule as the memory store's project resolver: the same id when this Mac has it, otherwise nil (it waits).
    public static func resolver(known: @escaping @Sendable () -> Set<String>) -> DeckMemoryCloudProjectResolver {
        { incoming, _ in known().contains(incoming) ? incoming : nil }
    }
    /// The project ids this Mac's memory holds: the folders directly under `projects/`. Read when asked, so a
    /// project created later is seen without a restart.
    public static func known(memoryRoot: URL) -> Set<String> {
        let folder = memoryRoot.appendingPathComponent("projects", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var found: Set<String> = []
        for name in names where !name.hasPrefix(".") && DeckMemoryOwner.folderName(name) == name {
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &directory), directory.boolValue {
                found.insert(name)
            }
        }
        return found
    }
    /// The one line shown with coverage while such memory waits.
    public static func waitingLine(_ count: Int) -> String {
        count == 1 ? "1 item of memory is waiting for a project on this Mac." : "\(count) items of memory are waiting for a project on this Mac."
    }
}

extension DeckMemoryStore {
    /// Puts the lean project rule on this store (it looks at this store's own `projects/` folder each time it is
    /// asked) and places anything that was waiting for a project that now exists here. Returns how many were placed.
    @discardableResult
    public func cloudUseLeanProjectRule() async throws -> Int {
        try await cloudUseLeanProjectRule(then: nil)
    }
    /// The lean rule first (a project whose memory folder is already on this Mac), then `second` for anything it does
    /// not know: lane A2's rule for a project that ARRIVED through Cloud, which answers with the same id once the
    /// person has chosen a folder for it on this Mac (lean scope item 7). Memory for a project is merged once the
    /// project exists here with the same id; anything else still waits and is listed. Places what was waiting for a
    /// project that now exists; returns how many were placed.
    @discardableResult
    public func cloudUseLeanProjectRule(then second: DeckMemoryCloudProjectResolver?) async throws -> Int {
        let memoryRoot = root
        let lean = DeckMemoryCloudLeanProjects.resolver(known: { DeckMemoryCloudLeanProjects.known(memoryRoot: memoryRoot) })
        guard let second else { return try await cloudSetProjectResolver(lean) }
        return try await cloudSetProjectResolver({ incoming, origin in lean(incoming, origin) ?? second(incoming, origin) })
    }
}

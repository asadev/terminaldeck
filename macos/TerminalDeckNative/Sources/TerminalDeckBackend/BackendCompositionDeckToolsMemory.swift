import Foundation
import TerminalDeckNativeCore

/// memory.search / memory.read over the one memory actor the Memory page uses
/// (index.ts:5392 `memoryTools({ memory: currentMemory, storeOf: storeOfSession })`).
///
/// Caller scope (session-own / Hoot-own plus a named open project / everyone
/// else refused) stays in `BackendDeckToolsAppMemory.scope`; this adapter only
/// answers its questions. When `BackendCompositionClients.memory` is nil, pass
/// `nil` to `BackendDeckToolsAppMemory.definitions(service:)`: the factory then
/// refuses with the source sentence "Memory is not available in this build."
public struct BackendCompositionDeckToolsMemory: BackendDeckToolsAppMemoryService, Sendable {
    private let memory: BackendMemoryService
    private let profiles: BackendAccountProfileStore
    public init(memory: BackendMemoryService, profiles: BackendAccountProfileStore) {
        self.memory = memory; self.profiles = profiles
    }

    /// memory/ipc.ts:51-56 `storeOfSession`: the session's own profile, else the
    /// provider's system profile, and only when that profile is the same agent's.
    public func storeOf(_ session: NativeRPCValue) async throws -> String? {
        guard let provider = session["provider"].string, provider == "claude" || provider == "codex" else { return nil }
        var profile: BackendAccountProfile?
        if let named = session["profileId"].string, !named.isEmpty { profile = try await profiles.find(named) }
        if profile == nil { profile = try await profiles.find(BackendAccountProfile.systemID(provider)) }
        guard let profile, profile.provider == provider else { return nil }
        return profile.configDir
    }
    public func codexSpaceFor(_ store: String) async throws -> NativeRPCValue? {
        try await memory.codexSpaceFor(configDir: store)?.wire
    }
    public func claudeSpaceFor(_ store: String, cwd: String) async throws -> NativeRPCValue? {
        try await memory.claudeSpaceFor(configDir: store, cwd: cwd)?.wire
    }
    public func hootSpace() async throws -> NativeRPCValue? { try await memory.hootSpace()?.wire }
    public func spacesForProject(_ folder: String) async throws -> [NativeRPCValue] {
        try await memory.spacesForProject(folder).map(\.wire)
    }
    public func searchIn(_ query: String, spaces: [String], limit: Int) async throws -> [NativeRPCValue] {
        await memory.searchIn(query, spaceIDs: spaces, limit: limit)
    }
    public func notes(_ space: String) async throws -> [NativeRPCValue] { try await memory.notes(space) }
    /// Same nodes/edges/dangling wire the `memory:notes` channel returns.
    public func graph(_ space: String) async throws -> NativeRPCValue {
        BackendMemoryParsing.graphWire(try await memory.graph(space))
    }
    /// ok/path/text/note/links/backlinks/truncated, or ok:false/error — the
    /// actor's own confined note read (no path outside the memory folder).
    public func read(_ space: String, path: String) async throws -> NativeRPCValue {
        await memory.read(space, path: .string(path))
    }
}

import Foundation
import Darwin
import TerminalDeckNativeCore

/// shared-projects.ts: only managed Claude projects/ links into the existing system history.
public actor BackendAppSharedProjects {
    public struct State: Sendable, Equatable {
        public let profileID: String, link: String, target: String?, root: String
        public let ownProjects: Int
        public var wire: NativeRPCValue { .object([.init("profileId", .string(profileID)), .init("link", .string(link)),
            .init("target", target.map(NativeRPCValue.string) ?? .null), .init("root", .string(root)), .init("ownProjects", .number(Double(ownProjects)))]) }
    }
    public let root: URL, managedRoot: URL
    private let writable: Bool
    private let changed: @Sendable () async -> Void
    private let now: @Sendable () -> Double
    public init(systemConfig: URL, managedRoot: URL, writable: Bool = false,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }, changed: @escaping @Sendable () async -> Void) {
        root = systemConfig.appendingPathComponent("projects").standardizedFileURL
        self.managedRoot = managedRoot; self.writable = writable; self.changed = changed; self.now = now
    }
    public func canShare(_ profile: BackendAccountProfile) -> Bool {
        guard profile.provider == "claude", !profile.system, profile.configDir.hasPrefix("/") else { return false }
        // profiles.ts's managed-directory decision is lexical. Resolving links
        // would let an outside alias claim ownership of an existing directory.
        let directory = URL(fileURLWithPath: profile.configDir).standardizedFileURL.path
        return directory.hasPrefix(managedRoot.standardizedFileURL.path + "/")
    }
    private func path(_ profile: BackendAccountProfile) -> URL { URL(fileURLWithPath: profile.configDir).appendingPathComponent("projects") }
    public func state(_ profile: BackendAccountProfile) -> State {
        func answer(_ link: String, _ target: String? = nil, _ count: Int = 0) -> State { State(profileID: profile.id, link: link, target: target, root: root.path, ownProjects: count) }
        guard canShare(profile) else { return answer("unmanaged") }
        let url = path(profile); var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else { return answer("absent") }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            guard let value = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return answer("elsewhere") }
            let target = (value.hasPrefix("/") ? URL(fileURLWithPath: value) : url.deletingLastPathComponent().appendingPathComponent(value)).standardizedFileURL.path
            return answer(target == root.path ? "shared" : "elsewhere", target)
        }
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        let count = children.filter { child in
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }.count
        return answer("separate", nil, count)
    }
    public func readsShared(_ profile: BackendAccountProfile) -> Bool {
        profile.provider == "claude" && (path(profile).standardizedFileURL.path == root.path || state(profile).link == "shared")
    }
    public func canJoin(_ profile: BackendAccountProfile) -> Bool {
        readsShared(profile) || (canShare(profile) && ["separate", "absent"].contains(state(profile).link))
    }
    public func share(_ profile: BackendAccountProfile) async throws -> NativeRPCValue {
        guard canShare(profile) else { throw BackendAccountFailure("Only an account this app created its own folder for can share history — an account pointed at a directory you already had is left exactly as you set it up, and an agent that keeps its conversations in another shape has nothing to share.") }
        let before = state(profile)
        if before.link == "shared" { return result(before, 0, 0, nil) }
        if before.link == "elsewhere" { throw BackendAccountFailure("This account's projects folder is already a link to \(before.target ?? "somewhere else"). Nothing here will replace a link somebody else made.") }
        try requireWriter()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let own = path(profile)
        var moved = 0, kept = 0; var aside: URL?
        if before.link == "separate" {
            let merged = try merge(from: own, to: root); moved = merged.moved; kept = merged.conflicts
            if kept > 0 {
                let destination = URL(fileURLWithPath: own.path + ".not-merged-" + String(Int64(now())))
                try FileManager.default.moveItem(at: own, to: destination); aside = destination
            } else { try FileManager.default.removeItem(at: own) }
        }
        // If the source step fails, its bytes or set-aside folder remain intact.
        try FileManager.default.createSymbolicLink(at: own, withDestinationURL: root)
        await changed()
        return result(state(profile), moved, kept, aside?.path)
    }
    public func unshare(_ profile: BackendAccountProfile) async throws -> State {
        let before = state(profile)
        guard before.link == "shared" else { return before }
        try requireWriter()
        let own = path(profile)
        guard Darwin.unlink(own.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        await changed(); return state(profile)
    }
    public func join(_ profile: BackendAccountProfile) async throws -> Bool {
        if readsShared(profile) { return true }
        if !canJoin(profile) { return false }
        _ = try await share(profile); return readsShared(profile)
    }
    public func adopt(_ profiles: [BackendAccountProfile]) async -> NativeRPCValue {
        var joined: [NativeRPCValue] = [], already: [NativeRPCValue] = [], left: [NativeRPCValue] = [], failed: [NativeRPCValue] = []
        for profile in profiles {
            do {
                if readsShared(profile) { already.append(.string(profile.id)); _ = await restoreSetAside(profile); continue }
                if !canJoin(profile) { left.append(.string(profile.id)); continue }
                _ = try await share(profile); joined.append(.string(profile.id))
            } catch { failed.append(.object([.init("id", .string(profile.id)), .init("reason", .string(error.localizedDescription))])) }
        }
        return .object([.init("joined", .array(joined)), .init("already", .array(already)), .init("left", .array(left)), .init("failed", .array(failed))])
    }
    public func restoreSetAside(_ profile: BackendAccountProfile) async -> Int {
        guard writable, readsShared(profile), canShare(profile), let names = try? FileManager.default.contentsOfDirectory(atPath: profile.configDir) else { return 0 }
        var restored = 0
        for name in names where name.hasPrefix("projects.not-merged-") {
            let aside = URL(fileURLWithPath: profile.configDir).appendingPathComponent(name)
            do {
                var info = stat(); guard stat(aside.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
                let merged = try merge(from: aside, to: root); restored += merged.moved
                if merged.conflicts == 0 { try FileManager.default.removeItem(at: aside) }
            } catch { continue }
        }
        if restored > 0 { await changed() }; return restored
    }
    private func merge(from: URL, to: URL) throws -> (moved: Int, conflicts: Int) {
        var moved = 0, conflicts = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: from.path) {
            let source = from.appendingPathComponent(name), destination = to.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.moveItem(at: source, to: destination); moved += 1; continue }
            var origin = stat(), target = stat()
            guard Darwin.lstat(source.path, &origin) == 0, stat(destination.path, &target) == 0 else { throw POSIXError(.EIO) }
            let a = origin.st_mode & S_IFMT, b = target.st_mode & S_IFMT
            if a == S_IFDIR && b == S_IFDIR {
                let inner = try merge(from: source, to: destination); moved += inner.moved; conflicts += inner.conflicts
                if inner.conflicts == 0 { try FileManager.default.removeItem(at: source) }; continue
            }
            if a == S_IFREG && b == S_IFREG, origin.st_size == target.st_size,
               let original = try? Data(contentsOf: source), let existing = try? Data(contentsOf: destination), original == existing {
                try FileManager.default.removeItem(at: source); continue
            }
            conflicts += 1
        }
        return (moved, conflicts)
    }
    private func requireWriter() throws { guard writable else { throw NativeRPCError(code: "unavailable", message: "Native shared-history changes are unavailable until account persistence has one native writer") } }
    private func result(_ state: State, _ moved: Int, _ kept: Int, _ keptAt: String?) -> NativeRPCValue {
        .object([.init("state", state.wire), .init("moved", .number(Double(moved))), .init("kept", .number(Double(kept))), .init("keptAt", keptAt.map(NativeRPCValue.string) ?? .null)])
    }
    public static func describeShare(_ state: State) -> String {
        let text = "Conversations will be kept in \(state.root), which is also where your own terminal `claude` writes them — so this account and your normal login will see one history, and a conversation survives switching between them. Logins, permissions and settings stay separate."
        return state.link == "separate" && state.ownProjects > 0 ? text + " This account already has \(state.ownProjects) folder\(state.ownProjects == 1 ? "" : "s") of its own history; every conversation in them is moved into the shared history, including folders both histories already have." : text
    }
    public static func describeUnshare(_ state: State) -> String {
        "This account goes back to its own history and starts empty. Nothing is deleted — the conversations it can see now stay in \(state.root) and belong to your own install — but this account will no longer continue them."
    }
    public static func describeDelete(_ state: State) -> String {
        if state.link == "shared" { return "No conversations are lost: this account's history is shared, so its projects folder is a link into \(state.root) and only the link is removed. Its own settings and permission grants go." }
        if state.link == "separate" && state.ownProjects > 0 { return "\(state.ownProjects) folder\(state.ownProjects == 1 ? "" : "s") of conversation history belonging to this account will be deleted along with its settings. They are not shared with any other account, so nothing else can read them afterwards." }
        return "This account has no conversation history on disk. Its settings and permission grants go."
    }
    public static func register(registry: NativeChannelRegistry, ownerID: String, service: BackendAppSharedProjects, profiles: BackendAccountProfileStore) async throws -> [String] {
        let channels = ["accounts:history-state", "accounts:history-share", "accounts:history-unshare"]
        for channel in channels {
            try await registry.register(channel, ownerID: ownerID) { context, args in
                try context.require(channel == "accounts:history-state" ? "accounts.read" : "accounts.write")
                guard let id = context.argument(0, in: args).string, !id.isEmpty else { throw BackendAccountFailure("an account id is required") }
                guard let profile = try await profiles.find(id) else { throw BackendAccountFailure("no account with id \(id)") }
                if channel == "accounts:history-share" { return try await service.share(profile) }
                if channel == "accounts:history-unshare" { return try await service.unshare(profile).wire }
                let state = await service.state(profile)
                return .object([.init("state", state.wire), .init("share", .string(describeShare(state))), .init("unshare", .string(describeUnshare(state))), .init("remove", .string(describeDelete(state)))])
            }
        }
        return channels
    }
}

import Foundation
import TerminalDeckNativeCore

/// "See what an agent changed" on a paired phone (31 Oct 2026, Asad: "3 … is good to do now"): the remote `git`
/// capability (`git.status` → `git.state`, `git.diff` → `git.patch`), which the protocol named and no native Mac
/// served, and `git.write` (`git.commit`, `git.push` → `git.done`), new.
///
/// The phone reads only inside the folders this device reaches, as `folders.browse` does. Commit and Push change data
/// and Push sends it off the Mac with this Mac's own Git login, so both are Full control (the access level already
/// refuses them below Full; this checks again) and the phone asks the person before it sends either.
public struct BackendPhoneChanges: Sendable {
    public static let readMessages: Set<String> = ["git.status", "git.diff"]
    public static let writeMessages: Set<String> = ["git.commit", "git.push"]
    /// The longest patch one `git.patch` carries; the rest is cut with a line saying so (a frame has a size limit).
    static let maxPatchBytes = 40_000
    private let git: BackendGitService
    private let context: @Sendable () throws -> NativeRPCContext

    /// `context`: this Mac's own context (its Git login, its folder authority), as the phone's chats use it.
    public init(git: BackendGitService, context: @escaping @Sendable () throws -> NativeRPCContext) {
        self.git = git; self.context = context
    }

    public func features() -> [BackendRemoteHostFeature] {
        [.init(capability: "git", messageTypes: Self.readMessages, policy: .grantedDevice) { message, host in
            [try await self.read(message, host: host)]
        },
         .init(capability: "git.write", messageTypes: Self.writeMessages, policy: .grantedDevice) { message, host in
            [try await self.write(message, host: host)]
        }]
    }

    func read(_ message: BackendRemoteClientMessage, host: BackendRemoteHostContext) async throws -> BackendRemoteServerMessage {
        let path = try reachable(message["path"].string, host)
        let rpc = try context()
        if message.type == "git.status" {
            return try .init(.gitState, fields: [.init("path", .string(path)), .init("status", try await git.status(cwd: path, context: rpc))])
        }
        let file = message["file"].string ?? "", staged = message["staged"].bool == true
        let patch = try await git.diff(cwd: path, path: file, options: .init(staged: staged, untracked: message["untracked"].bool == true), context: rpc)
        return try .init(.gitPatch, fields: [.init("path", .string(path)), .init("file", .string(file)), .init("staged", .bool(staged)),
            .init("patch", .string(Self.cut(patch)))])
    }

    func write(_ message: BackendRemoteClientMessage, host: BackendRemoteHostContext) async throws -> BackendRemoteServerMessage {
        let path = try reachable(message["path"].string, host)
        guard BackendPhoneChats.fullControl(host) else {
            return try .error(code: "unauthorized", message: "Commit and Push need Full control. Change this phone's access on the Mac.")
        }
        let rpc = try context()
        let done = message.type == "git.commit"
            ? try await git.commitAll(cwd: path, message: message["message"].string ?? "", context: rpc)
            : try await git.push(cwd: path, context: rpc)
        return try .init(.gitDone, fields: [.init("path", .string(path)), .init("action", .string(message.type == "git.commit" ? "commit" : "push")),
            .init("ok", .bool(done.ok)), .init("message", .string(done.message)), .init("status", done.status)])
    }

    /// The folder asked about, if this device reaches it (the owner's own device anywhere; a guest only inside its folders).
    private func reachable(_ requested: String?, _ host: BackendRemoteHostContext) throws -> String {
        guard let requested, requested.hasPrefix("/") else { throw NativeRPCError(code: "bad-message", message: "Name the folder by its full path.") }
        guard host.reach.unrestricted || host.reach.folders.contains(where: { BackendRemoteTrustStore.within($0, requested) }) else {
            throw NativeRPCError(code: "unauthorized", message: "This Mac does not share that folder with this device.")
        }
        return requested
    }

    /// A patch cut at a line end below the frame budget, saying where it stops.
    static func cut(_ patch: String) -> String {
        guard patch.utf8.count > maxPatchBytes else { return patch }
        var kept = Substring(""), used = 0
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let size = line.utf8.count + 1
            if used + size > maxPatchBytes { break }
            kept = patch[patch.startIndex..<line.endIndex]; used += size
        }
        return String(kept) + "\n\\ The rest of this change is too long for the phone. Open it on the Mac to see all of it.\n"
    }
}

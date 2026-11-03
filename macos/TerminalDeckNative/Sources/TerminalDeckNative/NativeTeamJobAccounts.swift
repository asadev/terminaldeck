import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// 30 Oct (Decker): which account a seat's job starts on (BackendTeamJobAccount says the order). Reads only through the
/// existing account channels (the levels' answer with the SEAT, the account list in the person's order, each login's
/// sign-in state), so the session helper's account store stays the one owner.
struct NativeTeamJobAccounts {
    typealias Channel = @Sendable (String, [NativeRPCValue], NativeRPCContext) async throws -> NativeRPCValue
    let account: Channel
    let signIn: Channel
    let context: @Sendable () throws -> NativeRPCContext

    init(sessions: BackendCompositionSessions, context: @escaping @Sendable () throws -> NativeRPCContext) {
        // The account owners differ by build (in-app, or the session helper's through its bridge); both answer `invoke`.
        let rpc = sessions.accountRPC, reader = sessions.signIn
        account = { try await rpc.invoke($0, args: $1, context: $2) }
        signIn = { try await reader.invoke($0, args: $1, context: $2) }
        self.context = context
    }

    /// nil: this AI has no logins to choose from (a shell, or an AI without accounts); the launch decides as before.
    func pick(agent: NativeRPCValue, provider: String, folder: String, requested: String?) async throws -> BackendTeamJobAccount.Pick? {
        guard BackendAccountStrategies.hasSignIn(provider) else { return nil }
        let rpc = try context()
        var fields: [NativeRPCValue.Field] = [.init("provider", .string(provider)), .init("projectPath", .string(folder)),
            .init("sessionProfileId", agent["account"].string.map(NativeRPCValue.string) ?? .null)]
        if let seat = await BackendAGTMemoryOwners.shared?.seatKey(agent: agent) { fields.append(.init("seat", .string(seat))) }
        let effective = try await account("profiles:effective", [.object(fields)], rpc)
        let listed = try await account("profiles:list", [.string(provider)], rpc)["profiles"].elements ?? []
        let candidates = listed.compactMap { row -> BackendTeamJobAccount.Candidate? in
            guard let id = row["id"].string, row["provider"].string ?? provider == provider else { return nil }
            return .init(id: id, name: row["name"].string ?? id)
        }
        var chosen: BackendTeamJobAccount.Candidate?
        if let requested, !requested.isEmpty {
            guard let found = candidates.first(where: { $0.id == requested || $0.name.caseInsensitiveCompare(requested) == .orderedSame }) else {
                throw NativeRPCError.invalidArguments("There is no \(CodingAICatalog.label(provider)) account called \u{201C}\(requested)\u{201D}. Ask accounts_list for the names.")
            }
            chosen = found
        }
        let assignedID = try effective["accountId"].requireString("account")
        let assigned = BackendTeamJobAccount.Candidate(id: assignedID, name: effective["name"].string ?? assignedID)
        let signIn = self.signIn, context = self.context
        return try await BackendTeamJobAccount.choose(requested: chosen, assigned: assigned, assignedSource: effective["source"].string ?? "system",
            candidates: candidates, state: { id in
                guard let rpc = try? context() else { return nil }
                let options = NativeRPCValue.object([.init("provider", .string(provider))])
                return (try? await signIn("profiles:signin", [.string(id), options], rpc))?["state"].string
            })
    }
}

/// A saved agent named by its id or, as people and leads write it, by its name (any case).
enum NativeSavedAgentLookup {
    static func find(_ wanted: String, in agents: [NativeRPCValue]) -> NativeRPCValue? {
        agents.first { $0["id"].string == wanted }
            ?? agents.first { ($0["name"].string ?? "").caseInsensitiveCompare(wanted) == .orderedSame }
    }
}

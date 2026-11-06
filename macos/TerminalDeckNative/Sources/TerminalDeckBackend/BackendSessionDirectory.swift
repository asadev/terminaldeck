import Foundation
import TerminalDeckNativeCore

/// All live kinds already belong to the manager. Keep their app id distinct from
/// the tab key, chat-store id and provider conversation id.
public enum BackendSessionDirectory {
    public static func row(_ meta: BackendSessionMeta, owner: DeckMemorySessionOwner? = nil) -> NativeRPCValue {
        let seat = owner ?? DeckMemorySessionCenter.shared?.owner(sessionID: meta.id) ?? .plain
        let key = BackendAGTMemoryOwners.seat(seat)?.key
        return BackendCompositionSuppliers.sessionWire(meta)
            .setting("view", .string(meta.chat == true ? "chat" : "terminal"))
            .setting("kind", .string(meta.chat == true ? (meta.origin == .copilot ? "team-job" : "chat") : "terminal"))
            .setting("agent", seat.name.isEmpty ? .null : .string(seat.name))
            .setting("seat", .object([.init("key", key.map(NativeRPCValue.string) ?? .null),
                .init("kind", .string(seat.kind.rawValue)), .init("name", .string(seat.name)),
                .init("project", seat.project.map(NativeRPCValue.string) ?? .null)]))
    }

    public static func resolve(_ id: String, rows: [NativeRPCValue]) throws -> NativeRPCValue? {
        if let exact = rows.first(where: { $0["id"].string == id }) { return exact }
        let matches = rows.filter { $0["tabKey"].string == id || $0["agentSessionId"].string == id }
        guard matches.count <= 1 else {
            throw NativeRPCError.invalidArguments("That conversation belongs to more than one open session. Use the app id from sessions_list.")
        }
        return matches.first
    }

    public static func permits(_ target: NativeRPCValue, rows: [NativeRPCValue], caller: BackendDeckCoreSecurityCaller,
                               message: Bool = false, directory: Bool = false) -> Bool {
        switch caller.kind {
        case .local, .remote: return true // Remote sharing is checked by the device authority.
        case .key:
            return caller.folders.map { roots in roots.contains { BackendCompositionAuthority.within(target["cwd"].string ?? "", $0) } } ?? true
        case .session:
            if target["id"].string == caller.sessionID { return true }
            guard let own = rows.first(where: { $0["id"].string == caller.sessionID && $0["exitCode"].isNullish }) else { return false }
            if let cwd = own["cwd"].string,
               (try? BackendTAGTaskProjectScope.roots(caller: caller, cwd: cwd).contains { BackendCompositionAuthority.within(target["cwd"].string ?? "", $0) }) == true { return true }
            // A lead may address another lead, without gaining its project files,
            // transcript, controls or ability to stop it. Task workers stay confined.
            return (message || directory) && caller.taskProject == nil && own["seat"]["kind"].string == "lead"
                && target["seat"]["kind"].string == "lead" && target["exitCode"].isNullish
        }
    }

    public static let accessRefusal = "This session is outside your project access. Lead seats can list and message other lead seats; reading or controlling another project needs its project access. The owner chooses the seat in Agents and its allowed tools under Settings → Tools and servers."
    public static let toolRefusal = "This session tool is not allowed for your seat. In Agents, the owner can open its Settings → Tools and servers, then check Allowed tools and Blocked tools. Project and message approval rules still apply."

    public static func say(_ id: String, text: String, chats: BackendSessionChats, rows: [NativeRPCValue],
                           context: NativeRPCValue = .object([]), clientMessageID: String? = nil,
                           readTarget: (@Sendable () async throws -> Void)? = nil) async throws -> NativeRPCValue {
        guard let row = try resolve(id, rows: rows), let canonical = row["id"].string else { throw BackendSessionFailure.missingSession }
        guard row["chat"].bool == true else { throw NativeRPCError.invalidArguments("Choose a Chat session from sessions_list.") }
        let delivery = BackendChatDeliveryQueue.identity(clientMessageID)
        let result = try await chats.say(canonical, text: text, context: context, clientMessageID: delivery)
        // Message permission never grants the recipient's history, thoughts or pending approvals.
        var canRead = false
        if let readTarget { do { try await readTarget(); canRead = true } catch is CancellationError { throw CancellationError() } catch { } }
        return sayReceipt(result, sessionID: canonical, messageID: delivery, canRead: canRead)
    }

    static func sayReceipt(_ snapshot: NativeRPCValue, sessionID: String, messageID: String, canRead: Bool) -> NativeRPCValue {
        if canRead { return snapshot.setting("sessionId", .string(sessionID)).setting("clientMessageId", .string(messageID)) }
        return .object([.init("accepted", .bool(true)), .init("sessionId", .string(sessionID)),
            .init("clientMessageId", .string(messageID)), .init("queued", .bool(snapshot["queued"].bool == true))])
    }

    public static func status(_ snapshot: NativeRPCValue) -> BackendSessionStatus {
        if !(snapshot["pending"].elements ?? []).isEmpty { return .input }
        if BackendHootChatStore.foreground(in: snapshot) { return .working }
        switch BackendSessionChats.turn(of: snapshot).state {
        case .done, .failed: return .completed
        default: return .idle
        }
    }
}

import Foundation
import TerminalDeckNativeCore

extension BackendRoutines21Reports {
    public func readChat(_ routineID: String, seen: Int? = nil) async throws -> NativeRPCValue {
        let entries = try reports(routineID)
        if let seen {
            let newest = entries.indices.last.map { RoutineChatSnapshot.sequence(entries[$0], at: $0) } ?? 0
            guard seen >= 0, seen <= newest else { throw NativeRPCError.invalidArguments("Choose a message in this routine's report chat.") }
        }
        return RoutineChatSnapshot.snapshot(entries, routineID: routineID, limit: Self.chatEntries)
    }
}

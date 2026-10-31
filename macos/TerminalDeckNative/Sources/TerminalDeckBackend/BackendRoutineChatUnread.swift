import Foundation
import TerminalDeckNativeCore

extension BackendRoutines21Reports {
    public func readChat(_ routineID: String, seen: Int? = nil) async throws -> NativeRPCValue {
        let entries = try reports(routineID)
        let markers = ChatSeenMarkers(file: directory.appendingPathComponent("report-chat-seen.json"))
        let key = "routine:" + routineID
        if let seen {
            let newest = entries.indices.last.map { RoutineChatUnread.sequence(entries[$0], at: $0) } ?? 0
            guard seen >= 0, seen <= newest else { throw NativeRPCError.invalidArguments("Choose a message in this routine's report chat.") }
            try markers.advance(seen, conversation: key)
            await changed(routineID)
        }
        return RoutineChatUnread.snapshot(entries, routineID: routineID, seen: try markers.sequence(for: key), limit: Self.chatEntries)
    }
}

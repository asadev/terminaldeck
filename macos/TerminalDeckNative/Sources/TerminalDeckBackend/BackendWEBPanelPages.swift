import Foundation
import TerminalDeckNativeCore

/// A board can contain many action forms. Keep each reply below the wire's
/// 64 KiB envelope without dropping rows; clients continue at nextCursor.
enum BackendWEBPanelPages {
    static let budget = 48_000
    static func page(_ payload: NativeRPCValue, cursor: Int) throws -> NativeRPCValue {
        let rows = payload["rows"].elements ?? []
        guard cursor >= 0, cursor <= rows.count else {
            throw NativeRPCError(code: "panel-changed", message: "This list changed. Refresh it to read the current rows.")
        }
        let base = payload.setting("rows", .array([])).setting("cursor", .number(Double(cursor)))
            .setting("totalRows", .number(Double(rows.count))).setting("nextCursor", .null)
        var used = try base.encodedJSON().count + 128
        guard used <= budget else { throw NativeRPCError(code: "panel-too-large", message: "These details are too large to send at once. Choose a smaller section on the Mac.") }
        var kept: [NativeRPCValue] = []
        for row in rows.dropFirst(cursor) {
            let cost = try row.encodedJSON().count + 1
            if used + cost > budget { break }
            used += cost; kept.append(row)
        }
        guard !kept.isEmpty || rows.isEmpty || cursor == rows.count else {
            throw NativeRPCError(code: "panel-too-large", message: "One item is too large to preview here. Open it on the Mac.")
        }
        let next = cursor + kept.count
        return base.setting("rows", .array(kept)).setting("nextCursor", next < rows.count ? .number(Double(next)) : .null)
    }
}

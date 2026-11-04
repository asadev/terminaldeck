import Foundation
import TerminalDeckNativeCore

extension NativeHootChatModel {
    func renderingTool(width: String?) throws -> NativeRPCValue {
        let available = width.flatMap(Double.init) ?? 360
        guard available.isFinite, available >= 1, available <= 20_000 else {
            throw NativeRPCError.invalidArguments("Choose the chat width in points, from 1 to 20000.")
        }
        func tables(_ blocks: [ChatBlock]) -> [NativeRPCValue] {
            blocks.flatMap { block -> [NativeRPCValue] in
                switch block {
                case .table(let header, let rows):
                    let widths = ChatTableLayout.widths(header: header, rows: rows, available: available)
                    return [.object([.init("layout", .string(widths == nil ? "stacked" : "table")),
                        .init("header", .array(header.map(NativeRPCValue.string))),
                        .init("rows", .array(rows.map { .array($0.map(NativeRPCValue.string)) })),
                        .init("columnWidths", widths.map { .array($0.map(NativeRPCValue.number)) } ?? .null)])]
                case .quote(let inner): return tables(inner)
                case .list(_, _, let items): return items.flatMap(tables)
                default: return []
                }
            }
        }
        return .object([.init("bodyPoints", .number(NativeChatMarkdown.bodyFont.pointSize)),
            .init("avatar", .string("inline-with-name")), .init("bodyAlignment", .string("name-line-left-edge")),
            .init("tableSidewaysScroll", .bool(false)), .init("codeWrap", .bool(false)),
            .init("availableWidth", .number(available)),
            .init("tables", .array(rows.filter { [.message, .textDelta].contains($0.kind) }.flatMap { tables(ChatMarkdown.parse($0.value["text"].string ?? "")) }))])
    }
}

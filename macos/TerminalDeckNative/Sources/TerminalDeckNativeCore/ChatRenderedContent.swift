import Foundation

public enum ChatRenderedContent {
    /// The phone and agent read the same projected message as the Mac, after deltas
    /// have been joined. A raw delta is never treated as a complete visual fence.
    public static func messages(_ events: [NativeRPCValue]) -> NativeRPCValue {
        let decoded = events.compactMap { try? HootChatEvent(wire: $0) }
        return .array(HootChatProjection.rows(decoded).compactMap { row in
            guard [.user, .message, .textDelta].contains(row.kind), let text = row.value["text"].string else { return nil }
            return .object([.init("rowId", .string(row.id)), .init("sequence", .number(Double(row.sequence))),
                .init("text", .string(text)), .init("blocks", ChatMarkdown.renderedBlocks(text, streaming: row.kind == .textDelta))])
        })
    }
    /// A large reply keeps its event identity in the bounded phone frame. New
    /// clients fetch the complete immutable source; older ones retain a real prefix.
    public static func phoneEvent(_ value: NativeRPCValue) -> NativeRPCValue {
        guard let event = try? HootChatEvent(wire: value), [.user, .message, .textDelta].contains(event.record.kind),
              let text = event.record.value["text"].string,
              (text.utf8.count > 32_768 || (text.contains("![") && !ChatMarkdownImages.references(text).isEmpty)),
              let row = HootChatProjection.rows([event]).first(where: { [.user, .message, .textDelta].contains($0.kind) }) else { return value }
        let preview = text.utf8.count > 32_768 ? String(decoding: text.utf8.prefix(8_192), as: UTF8.self) : text
        let source = NativeRPCValue.object([.init("type", .string("richMessage")), .init("rowId", .string(row.id)),
            .init("bytes", .number(Double(text.utf8.count))), .init("revision", .number(Double(event.sequence)))])
        return value.setting("value", event.record.value.setting("text", .string(preview)).setting("richSource", source))
    }

    public static func phoneMessages(_ events: [NativeRPCValue]) -> NativeRPCValue {
        let all = messages(events).elements ?? []
        func visuals(_ blocks: [NativeRPCValue]) -> [NativeRPCValue] {
            blocks.flatMap { block -> [NativeRPCValue] in
                if ["visual", "svg", "mermaid", "math"].contains(block["type"].string ?? "") { return [block] }
                let children = block["children"].elements ?? []
                let items = (block["items"].elements ?? []).flatMap { $0.elements ?? [] }
                return visuals(children + items)
            }
        }
        return .array(all.compactMap { message in
            let blocks = visuals(message["blocks"].elements ?? [])
            guard !blocks.isEmpty else { return nil }
            return .object([.init("rowId", message["rowId"]), .init("sequence", message["sequence"]), .init("blocks", .array(blocks))])
        })
    }
    public static func snapshot(_ value: NativeRPCValue) -> NativeRPCValue {
        value.setting("renderedMessages", messages(value["events"].elements ?? []))
    }
}

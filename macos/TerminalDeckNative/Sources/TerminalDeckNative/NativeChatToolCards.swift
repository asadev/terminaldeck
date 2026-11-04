import SwiftUI
import TerminalDeckNativeCore

extension NativeHootChatModel {
    func toolCardsTool(_ action: String, request: String?, viewID: String? = nil) throws -> NativeRPCValue {
        guard ["read", "expand", "collapse"].contains(action) else { throw NativeRPCError.invalidArguments("Choose read, expand or collapse.") }
        let live = (busy || sending) && !compacting
        let cards: [(id: String, live: Bool, count: Int)] = HootChatItem.items(displayRows).compactMap { item in
            guard case .reply(let key, _, let steps, let open) = item, !steps.isEmpty else { return nil }
            return (key, live && open, steps.count)
        }
        let views = chatViewports.values.filter { viewID == nil || $0.id.uuidString == viewID }
        if viewID != nil, views.isEmpty { throw NativeRPCError.invalidArguments("Choose an open chat view.") }
        if action != "read" {
            guard let card = cards.first(where: { $0.id == request }) else { throw NativeRPCError.invalidArguments("Choose a recorded tool card.") }
            guard !card.live else { throw NativeRPCError.invalidArguments("Wait for this card to finish before folding its steps.") }
            guard !views.isEmpty else { throw NativeRPCError.invalidArguments("Open this chat before folding its tool cards.") }
            withAnimation(.snappy(duration: 0.18)) {
                for view in views {
                    if action == "expand" { view.expandedCards.insert(card.id) } else { view.expandedCards.remove(card.id) }
                }
            }
        }
        return .object([.init("cards", .array(cards.map { card in
            .object([.init("id", .string(card.id)), .init("live", .bool(card.live)), .init("steps", .number(Double(card.count))),
                     .init("views", .array(views.map { view in .object([.init("viewId", .string(view.id.uuidString)), .init("expanded", .bool(view.expandedCards.contains(card.id)))]) }))])
        }))])
    }
}

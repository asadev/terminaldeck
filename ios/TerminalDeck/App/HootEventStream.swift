import Foundation
import Observation

struct HootChatItem: Equatable, Identifiable {
    let id: String
    var kind: HootEvent.Kind
    var text: String
    var name: String?
    var input: String?
    var failed: Bool
}

@MainActor @Observable
final class HootEventStream {
    private(set) var items: [HootChatItem] = []
    private(set) var conversationId: String?
    private(set) var sequence = 0
    private(set) var isStreaming = false
    private(set) var needsReplay = false
    private var finishedMessages: Set<String> = []

    func clear() {
        items = []; conversationId = nil; sequence = 0
        isStreaming = false; needsReplay = false; finishedMessages = []
    }

    func disconnected() { isStreaming = false }

    func apply(_ batch: HootEventBatch) {
        if batch.reset { clear(); conversationId = batch.conversationId }
        guard conversationId == batch.conversationId else { needsReplay = true; return }
        needsReplay = false
        for event in batch.events.sorted(by: { $0.sequence < $1.sequence }) {
            guard event.sequence > sequence else { continue }
            // A delta gap can make a sentence wrong. Request an authoritative replay.
            if !batch.reset, event.sequence != sequence + 1 { needsReplay = true; isStreaming = false; return }
            sequence = event.sequence
            switch event.kind {
            case .session: break
            case .completed, .interrupted: isStreaming = false
            case .textDelta:
                guard !finishedMessages.contains(event.messageId) else { continue }
                isStreaming = true
                upsert(event.messageId, event: event, append: true)
            case .message:
                finishedMessages.insert(event.messageId)
                upsert(event.messageId, event: event, append: false)
            case .user:
                isStreaming = true
                upsert(event.messageId, event: event, append: false)
            case .toolCall, .toolResult:
                upsert(event.toolId ?? event.id, event: event, append: false)
            case .approval:
                isStreaming = false
                upsert(event.requestId ?? event.id, event: event, append: false)
            case .approvalResolved:
                items.removeAll { $0.id == (event.requestId ?? event.id) }
            case .error:
                isStreaming = false
                upsert(event.id, event: event, append: false)
            }
        }
        if items.count > 600 { items.removeFirst(items.count - 600) }
        finishedMessages.formIntersection(Set(items.map(\.id)))
    }

    private func upsert(_ id: String, event: HootEvent, append: Bool) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].kind = event.kind
            items[index].failed = event.failed
            items[index].text = String((append ? items[index].text + event.text : event.text).prefix(64 * 1024))
            if let name = event.name { items[index].name = name }
            if let input = event.input { items[index].input = input }
        } else {
            items.append(.init(id: id, kind: event.kind, text: event.text, name: event.name, input: event.input, failed: event.failed))
        }
    }
}

import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// L8 MENTION-DELIVERY: installs `BackendHootMentionDelivery.shared` once Tasks exist.
extension NativeCompositionProduction {
    func installHootMentionDelivery(detail: BackendTaskDetailService) {
        guard let sessions, let authority else { return }
        let manager = sessions.manager, lifecycle = sessions.lifecycle, registry = root.registry
        let delivery = BackendHootMentionDelivery(detail: detail,
            sessions: { manager.list() },
            // A lead that is a running session is told through the same checked typing a task brief uses.
            tell: { id, line in
                try await BackendTaskBriefDelivery.deliver(id, line: line, manager: manager, write: { text in try await lifecycle.write(sessionID: id, data: text) })
            },
            projects: {
                guard let snapshot = try? await registry.invoke("project-registry:list", context: authority.localContext(), arguments: []) else { return [] }
                return (snapshot["projects"].elements ?? []).compactMap { try? JSONDecoder().decode(PROJProject.self, from: $0.encodedJSON()) }
            })
        BackendHootMentionDelivery.shared = delivery
        #if DEBUG
        // Dev copy only (never in the shipped app): deliver ONE mention from the shell without a chat message,
        // to check delivery → the agent wakes → its answer → the answered signal.
        // Object: JSON {"text": …, "mentions": [{kind,id,name}], "out": "/path/result.json"}.
        HootMentionFeeds.door = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("TerminalDeckDevMention"), object: nil, queue: .main) { note in
            guard let text = note.object as? String, let ask = try? NativeRPCValue.parseJSON(Data(text.utf8)), let out = ask["out"].string else { return }
            Task {
                var lines: [NativeRPCValue] = []
                func save() { try? NativeRPCValue.array(lines).encodedJSON(pretty: true).write(to: URL(fileURLWithPath: out), options: .atomic) }
                let receipts = await delivery.deliver(text: ask["text"].string ?? "", context: .object([.init("mentions", ask["mentions"])]))
                lines.append(.object([.init("receipts", .array(receipts.map(\.wireValue)))])); save()
                let wanted = Set(receipts.map(\.receiptID))
                for await answer in delivery.answers() where wanted.contains(answer.receiptID) {
                    lines.append(.object([.init("answered", answer.wireValue)])); save(); break
                }
            }
        }
        #endif
        // "<seat> answered": every task change is a look at the deliveries still waiting (an event, no timer).
        Task {
            if let feed = try? await registry.subscribe("tasks:changed", ownerID: BackendCompositionRoot.appOwnerID, handler: { _ in await delivery.tasksChanged() }) {
                HootMentionFeeds.keep(feed)
            }
        }
    }
}

private enum HootMentionFeeds {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var feeds: [NativeRPCSubscription] = []
    static func keep(_ feed: NativeRPCSubscription) { lock.withLock { feeds.append(feed) } }
    nonisolated(unsafe) static var door: NSObjectProtocol?
}

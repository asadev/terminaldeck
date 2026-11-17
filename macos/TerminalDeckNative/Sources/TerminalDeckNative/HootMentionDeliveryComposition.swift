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
        // Object: JSON {"token": …, "text": …, "mentions": [{kind,id,name}], "out": "<dev-out>/result.json"}.
        // Locked like every other dev door (DevReload): this launch's secret, and an answer file inside dev-out only.
        HootMentionFeeds.door = DistributedNotificationCenter.default().addObserver(forName: HootMentionDevDoor.name, object: nil, queue: .main) { note in
            guard let door = HootMentionDevDoor.ask(note.object as? String) else { return }
            let ask = door.wire, out = door.out
            Task {
                var lines: [NativeRPCValue] = []
                func save() { try? NativeRPCValue.array(lines).encodedJSON(pretty: true).write(to: out, options: .atomic) }
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

#if DEBUG
/// The mention dev door's lock (17 Nov, Security): the same as DevReload's doors. A request without this launch's
/// secret (TD_DEV_INVOKE_TOKEN) is ignored, and the answer file may only lie inside the dev copy's `dev-out` folder.
/// No secret at launch (every installed app): the door stays shut.
enum HootMentionDevDoor {
    static let name = Notification.Name("TerminalDeckDevMention")
    static func ask(_ text: String?, token: String = DevReload.launchToken, folder: URL? = DevReload.outFolder) -> (wire: NativeRPCValue, out: URL)? {
        guard let text, let ask = DevReload.request(text, token: token), let out = DevReload.output(ask["out"], folder: folder),
              let wire = try? NativeRPCValue.parseJSON(Data(text.utf8)) else { return nil }
        return (wire, out)
    }
}
#endif

private enum HootMentionFeeds {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var feeds: [NativeRPCSubscription] = []
    static func keep(_ feed: NativeRPCSubscription) { lock.withLock { feeds.append(feed) } }
    nonisolated(unsafe) static var door: NSObjectProtocol?
}

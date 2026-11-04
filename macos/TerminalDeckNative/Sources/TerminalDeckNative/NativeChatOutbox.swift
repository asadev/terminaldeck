import Foundation
import TerminalDeckNativeCore

@MainActor enum NativeChatOutbox {
    struct Entry: Codable {
        var id: String
        var draft: HootComposerDraft
        var context: Data?
        var held: Bool
        var problem: String?
        var deliveryPending: Bool? = nil
        var editedPendingDelivery: Bool? = nil
    }
    struct Saved: Codable {
        var name: String
        var entries: [Entry]
        var draft: HootComposerDraft?
        var tabKey: String?
    }
    static var defaults: UserDefaults = .standard
    private static let prefix = "native.chat.outbox."
    private static let index = prefix + "sessions"
    static var sessions: [String] { defaults.stringArray(forKey: index) ?? [] }
    static func load(_ id: String) -> Saved? {
        guard let data = defaults.data(forKey: prefix + id) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }
    static func remove(_ id: String) {
        defaults.removeObject(forKey: prefix + id)
        defaults.set(sessions.filter { $0 != id }, forKey: index)
    }
    static func save(_ id: String, name: String, entries: [Entry], draft: HootComposerDraft? = nil, tabKey: String? = nil) throws {
        // The saved entry is read only for what the caller left out: decoding it on every save was part of each
        // key press's cost (#174).
        let keptDraft = draft ?? load(id)?.draft
        if entries.isEmpty && keptDraft?.canSend != true {
            if defaults.object(forKey: prefix + id) != nil || sessions.contains(id) { remove(id) }
        } else {
            defaults.set(try JSONEncoder().encode(Saved(name: name, entries: entries, draft: keptDraft,
                tabKey: tabKey ?? load(id)?.tabKey)), forKey: prefix + id)
            if !sessions.contains(id) { defaults.set(sessions + [id], forKey: index) }
        }
    }
}

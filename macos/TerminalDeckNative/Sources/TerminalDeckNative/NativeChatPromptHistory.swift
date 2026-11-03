import Foundation

struct NativeChatPromptHistory {
    private(set) var cursor: Int?
    private var messages: [String] = []
    private var recalled: String?
    private var conversation = ""

    mutating func move(previous: Bool, current: String, history: [String], conversation: String) -> String? {
        if self.conversation != conversation || cursor != nil && current != recalled {
            reset()
            self.conversation = conversation
        }
        if cursor == nil {
            guard previous, current.isEmpty, !history.isEmpty else { return nil }
            messages = history
            cursor = messages.count
        }
        guard let index = cursor else { return nil }
        let next = previous ? max(0, index - 1) : index + 1
        if next >= messages.count { reset(); return "" }
        cursor = next
        recalled = messages[next]
        return recalled
    }
    private mutating func reset() { cursor = nil; messages = []; recalled = nil }
}

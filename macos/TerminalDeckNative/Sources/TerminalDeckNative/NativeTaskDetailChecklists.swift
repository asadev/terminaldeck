import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import TerminalDeckBackend
import TerminalDeckNativeCore

extension TaskDetailModel {
    // MARK: Checklists

    func addChecklist(title: String) async {
        let draft = Checklist(id: "draft-\(UUID().uuidString)", title: title, sortOrder: nil, items: [])
        checklists = (checklists ?? []) + [draft]
        switch await call("addChecklist", [taskId, title]) {
        case .failure(let problem):
            checklists?.removeAll { $0.id == draft.id }
            error = "Adding checklist \(q(title)): \(problem.message)"
        case .success(let r):
            if let id = r["id"] as? String, let i = checklists?.firstIndex(where: { $0.id == draft.id }) { checklists?[i].id = id }
        }
    }

    func deleteChecklist(_ list: Checklist) {
        let before = checklists
        checklists?.removeAll { $0.id == list.id }
        Task { if !(await write("deleteChecklist", [list.id], label: "Removing checklist \(q(list.title))")) { checklists = before } }
    }

    /// Renames arrive a keystroke at a time; the engine hears the title once typing
    /// pauses, and a refusal puts the original back.
    func renameChecklist(_ listId: String, _ title: String) {
        guard let i = checklists?.firstIndex(where: { $0.id == listId }) else { return }
        if renameOrigins[listId] == nil { renameOrigins[listId] = checklists![i].title }
        checklists![i].title = title
        renameTimers[listId]?.cancel()
        renameTimers[listId] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.flushRename(listId)
        }
    }

    func flushRename(_ listId: String) async {
        renameTimers[listId] = nil
        guard let origin = renameOrigins.removeValue(forKey: listId),
              let list = checklists?.first(where: { $0.id == listId }), list.title != origin else { return }
        if !(await write("renameChecklist", [listId, list.title], label: "Renaming checklist to \(q(list.title))")) {
            if let i = checklists?.firstIndex(where: { $0.id == listId }) { checklists?[i].title = origin }
        }
    }

    /// A rename still waiting when the popup closes is sent, not lost.
    func flushRenames() {
        for (listId, timer) in renameTimers {
            timer.cancel()
            Task { await flushRename(listId) }
        }
    }

    func addChecklistItem(_ list: Checklist, _ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let li = checklists?.firstIndex(where: { $0.id == list.id }) else { return }
        let draft = ChecklistItem(id: "draft-\(UUID().uuidString)", title: trimmed, done: false, sortOrder: nil, assigneeUserId: nil)
        checklists![li].items.append(draft)
        Task {
            switch await call("addChecklistItem", [list.id, trimmed]) {
            case .failure(let problem):
                updateItem(draft.id, { _ in }, remove: true)
                error = "Adding item \(q(trimmed)): \(problem.message)"
            case .success(let r):
                if let id = r["id"] as? String { updateItem(draft.id) { $0.id = id } }
            }
        }
    }

    func setItemDone(_ item: ChecklistItem, _ done: Bool) {
        updateItem(item.id) { $0.done = done }
        Task {
            if !(await write("setChecklistItemDone", [item.id, done], label: "\(done ? "Ticking" : "Unticking") \(q(item.title))")) {
                updateItem(item.id) { $0.done = !done }
            }
        }
    }

    func setItemAssignee(_ item: ChecklistItem, _ userId: String?) {
        let prev = item.assigneeUserId
        updateItem(item.id) { $0.assigneeUserId = userId }
        joinLocally(userId)
        Task {
            if !(await write("setChecklistItemAssignee", [item.id, userId ?? NSNull()],
                             label: "\(userId != nil ? "Assigning" : "Unassigning") \(q(item.title))")) {
                updateItem(item.id) { $0.assigneeUserId = prev }
            }
        }
    }

    func deleteItem(_ item: ChecklistItem) {
        let before = checklists
        updateItem(item.id, { _ in }, remove: true)
        Task { if !(await write("deleteChecklistItem", [item.id], label: "Removing item \(q(item.title))")) { checklists = before } }
    }

    func updateItem(_ id: String, _ change: (inout ChecklistItem) -> Void, remove: Bool = false) {
        guard var lists = checklists else { return }
        for li in lists.indices {
            if let ii = lists[li].items.firstIndex(where: { $0.id == id }) {
                if remove { lists[li].items.remove(at: ii) } else { change(&lists[li].items[ii]) }
            }
        }
        checklists = lists
    }

}

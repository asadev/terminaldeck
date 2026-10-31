import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import TerminalDeckBackend
import TerminalDeckNativeCore

extension TaskDetailModel {
    // MARK: People

    /// Someone put on the task from @, Share or a slash command.
    func invite(_ person: CrmPerson) {
        guard let cur = people, !cur.has(person.id) else { return }
        let list = cur.list
        let personal = list.isEmpty || (list.count == 1 && cur.primary?.id == me && person.id != me)
        changePeople(personal && cur.primary?.id != person.id ? TaskPeople(primary: person) : cur.adding(person))
    }

    func removeFromTask(_ personId: String) {
        guard let cur = people else { return }
        changePeople(cur.removing(personId))
    }

    /// The people control's own change: the main person, then who joined or left.
    func changePeople(_ next: TaskPeople) {
        guard let prev = people else { return }
        if prev.primary?.id != next.primary?.id && next.primary == nil {
            error = "A task needs a main person. Add someone else before taking \(prev.primary?.name ?? "the main person") off."
            return
        }
        people = next
        Task {
            // A refused step after earlier ones went through shows what was really saved (read again), not the old list.
            var wrote = false
            if let primary = next.primary, primary.id != prev.primary?.id {
                guard await write("assignTask", [taskId, primary.id], label: "Making \(primary.name) the main person") else {
                    people = prev
                    return
                }
                patch(["assigneeUserId": primary.id])
                wrote = true
            }
            let prevIds = Set(prev.list.map(\.id)), nextIds = Set(next.list.map(\.id))
            for p in next.list where !prevIds.contains(p.id) && !(p.id == next.primary?.id && prev.primary?.id != next.primary?.id) {
                if !(await write("addTaskAssignee", [taskId, p.id], label: "Adding \(p.name)")) {
                    if wrote { await loadBundle() } else { people = prev }
                    return
                }
                wrote = true
            }
            for p in prev.list where !nextIds.contains(p.id) && p.id != prev.primary?.id {
                if !(await write("removeTaskAssignee", [taskId, p.id], label: "Removing \(p.name)")) {
                    if wrote { await loadBundle() } else { people = prev }
                    return
                }
                wrote = true
            }
        }
    }

    /// Someone given an item joins the task, on screen.
    func joinLocally(_ userId: String?) {
        guard let userId, let cur = people, !cur.has(userId), let person = team.first(where: { $0.id == userId }) else { return }
        people = cur.adding(person)
    }

}

import AppKit
import SwiftUI
import TerminalDeckNativeCore

extension NativeTaskCreatePopup {
    // MARK: Project

    /// The person's projects (registered, then open in the side panel), each folder once.
    var projectChoices: [TaskProject] {
        var seen = Set<String>()
        return context.projects().filter { seen.insert(TaskProjects.clean($0.path)).inserted && !TaskProjects.clean($0.path).isEmpty }
    }

    func projectSelection(_ open: [TaskProject]) -> String {
        let path = TaskProjects.clean(draft.project)
        if typingFolder { return Self.otherFolder }
        if path.isEmpty { return "" }
        return open.contains { TaskProjects.clean($0.path) == path } ? path : Self.otherFolder
    }

    func pickProject(_ value: String) {
        if value == Self.otherFolder {
            typingFolder = true
            Task { @MainActor in focus = .folder }
        } else {
            typingFolder = false
            draft.project = value
        }
        problem = nil
    }

    /// Said before the task is made, as the old form did: an agent starts only in a folder of one of your projects.
    var folderWarning: String? {
        guard !draft.project.trimmingCharacters(in: .whitespaces).isEmpty, state.agents.contains(where: { $0.id == draft.assignee }),
              !context.projects().contains(where: { TaskProjects.within(draft.project, $0.path) }) else { return nil }
        return "This folder is not part of any of your projects, so an agent cannot start in it. Choose a project's folder, or open this folder as a project first."
    }

}

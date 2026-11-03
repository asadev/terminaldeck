import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import TerminalDeckBackend
import TerminalDeckNativeCore

extension TaskDetailModel {
    // MARK: Sections

    func reveal(_ section: Section) {
        shown.insert(section)
        // A checklist section with no list has nothing to type into, so the first list
        // is made on reveal — on the engine too, so what is on screen exists.
        if section == .checklist, checklists?.isEmpty == true {
            Task { await addChecklist(title: "Checklist") }
        }
        justAdded = section
    }

    func relate(_ kind: DependencyKind) {
        depKind = kind
        depKey += 1
        reveal(.dependencies)
    }

}

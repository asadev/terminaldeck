import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import TerminalDeckBackend
import TerminalDeckNativeCore

extension TaskDetailModel {
    // MARK: The routine

    /// The Recurring panel's Save: the whole routine, one at a time.
    func saveRoutine(_ rule: CrmValue?, legacy: String?) {
        guard !routineSaving else { return }
        routineSaving = true
        routineBusy = true
        let prevRec = task.recurrence
        let prevRoutine = routine
        let onThisTask = routine == nil || routine?.isRoot == true
        if onThisTask { patch(["recurrence": legacy]) }
        if routine != nil {
            routine?.rule = rule
        } else {
            routine = RoutineView(rootTaskId: taskId, rootTitle: task.title, isRoot: true, rule: rule, canEdit: true, history: [],
                                  historyError: nil, lastError: nil, next: [], peopleCount: 1, version: nil, stuck: nil,
                                  canRestart: false, anchor: nil, occurrence: nil, datesSoFar: 0)
        }
        Task {
            defer {
                routineSaving = false
                routineBusy = false
            }
            switch await call("saveRoutine", [taskId, rule?.any ?? NSNull(), prevRoutine?.version ?? NSNull()]) {
            case .failure(let problem):
                if onThisTask { patch(["recurrence": prevRec]) }
                routine = prevRoutine
                error = "Recurring: \(problem.message)"
            case .success(let r):
                if r.keys.contains("version") { routine?.version = TasksJSON.number(r["version"]) }
                await loadRoutine()
                await loadActivity()
            }
        }
    }

    func restartRoutine() {
        Task {
            switch await call("restartRoutine", [taskId]) {
            case .failure(let problem): error = "Restart: \(problem.message)"
            case .success(let r):
                if let warning = r["warning"] as? String { error = "Restart: \(warning)" }
                await loadRoutine()
                await loadActivity()
            }
        }
    }

    func stopRoutine() {
        let prevRec = task.recurrence
        let onThisTask = routine == nil || routine?.isRoot == true
        if onThisTask { patch(["recurrence": nil]) }
        Task {
            switch await call("stopRoutine", [taskId]) {
            case .failure(let problem):
                if onThisTask { patch(["recurrence": prevRec]) }
                error = "Stop recurring: \(problem.message)"
            case .success:
                if !onThisTask { patch(["recurrence": nil]) }
                await loadRoutine()
                await loadActivity()
            }
        }
    }

    func pauseRoutine(_ paused: Bool) {
        Task {
            switch await call("pauseRoutine", [taskId, paused]) {
            case .failure(let problem): error = "\(paused ? "Pause" : "Resume"): \(problem.message)"
            case .success: await loadRoutine()
            }
        }
    }

}

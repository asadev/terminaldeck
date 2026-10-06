import SwiftUI
import TerminalDeckNativeCore

// Settings → Hoot → Routines (web: CopilotSection.tsx `RoutinesGroup`, `RoutineEntry`).

struct CopilotRoutinesGroup: View {
    let model: CopilotSettingsPageModel

    var body: some View {
        CopilotBlock(title: "Routines",
                     says: "Saved instructions the app runs on its own, kept where \(CopilotWords.assistant) cannot reach them — and editable here, by you.",
                     more: "A routine is a trigger, a prompt and a folder — one file each. They are kept in the app’s own storage, which \(CopilotWords.assistant) may read and cannot write, so one can only be created or changed by you: here, in your own editor, or by a tool call you confirm.") {
            if let routines = model.routines {
                if routines.isEmpty {
                    Text("There are none. A routine is a Markdown file in the folder below; the app arms whatever it finds there at launch.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(routines) { routine in CopilotRoutineEntry(routine: routine, model: model) }
                }
            } else {
                Text(model.loading ? "Reading…" : "This build cannot list routines — the channel is not wired.")
                    .foregroundStyle(.secondary)
            }
            Button("Open the routines folder") { model.reveal("routines") }
        }
    }
}

/// `RoutineEntry`: its state, why it is off, its triggers and last run, its file in a box,
/// and the switch, Edit, Run now, Delete.
struct CopilotRoutineEntry: View {
    let routine: CopilotRoutine
    let model: CopilotSettingsPageModel

    @State private var open = false
    @State private var confirm = false
    @State private var text: String?
    @State private var problem: String?
    @State private var note: (text: String, ok: Bool)?

    var body: some View {
        let switchBecause = CopilotRoutineWords.switchBecause(routine)
        let runBecause = CopilotRoutineWords.runBecause(routine)
        let brokenOff = CopilotRoutineWords.brokenOff(routine)
        let when: (Double) -> String = { CopilotWords.when($0) }
        VStack(alignment: .leading, spacing: 8) {
            CopilotPathRow {
                CopilotLabel(text: routine.name, badges: [(CopilotRoutineWords.state(routine.state), true)])
                if brokenOff { NativeCodingAINotice(tone: .warn, text: CopilotRoutineWords.brokenLine(routine, when: when)) }
                if !brokenOff, routine.state != .disabled, let reason = routine.reason { CopilotHelp(reason) }
                CopilotHelp(CopilotRoutineWords.triggers(routine))
                CopilotHelp(CopilotRoutineWords.lastRun(routine, when: when))
                if let refused = CopilotRoutineWords.refused(routine) { CopilotHelp(refused) }
                ForEach(routine.problems, id: \.self) { CopilotHelp($0) }
                if let switchBecause { CopilotHelp(switchBecause) }
                if let runBecause { CopilotHelp("Run now: \(runBecause)") }
            } actions: {
                Toggle(routine.name, isOn: Binding(get: { CopilotRoutineWords.armed(routine) }, set: { arm($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(switchBecause != nil || model.busy != nil)
                Button(open ? "Close" : "Edit", action: toggle)
                Button("Run now") {
                    model.act("routine-run:\(routine.id)") { [model, routine] in
                        CopilotRoutineWords.runLine(try await model.call("routines:run", [routine.id]), name: routine.name)
                    }
                }
                .disabled(runBecause != nil || model.busy != nil)
                Button("Delete") { confirm = true }.disabled(model.busy != nil)
            }

            if open {
                NativeFileEditor(label: CopilotWords.baseName(routine.file), text: text, problem: problem,
                                 effect: "Saved changes are picked up straight away — the next time this routine fires, it fires on the new file.",
                                 saveBecause: nil, saving: model.busy == "routine-save:\(routine.id)", note: note, rows: 14,
                                 onSave: { next in
                                     note = nil
                                     model.act("routine-save:\(routine.id)") { [model, routine] in
                                         switch CopilotRoutineWrite.from(try await model.call("routines:save-text", [routine.id, next])) {
                                         case .saved:
                                             text = next
                                             note = ("Saved. \(routine.name) is running from the new file.", true)
                                         case .problems(let problems):
                                             note = (problems.joined(separator: " "), false)
                                         }
                                         return nil
                                     }
                                 })
            }

            if confirm {
                HStack(spacing: 8) {
                    Text("Delete \(routine.name)? Its file is removed from disk.")
                    Button("Delete it", role: .destructive) {
                        confirm = false
                        model.act("routine-delete:\(routine.id)") { [model, routine] in
                            _ = try await model.call("routines:delete", [routine.id])
                            return "Deleted \(routine.name)."
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy != nil)
                    Button("Cancel") { confirm = false }
                }
            }
        }
    }

    private func arm(_ next: Bool) {
        model.act("routine-arm:\(routine.id)") { [model, routine] in
            if next {
                _ = try await model.call("routines:resume", [routine.id])
                return "\(routine.name) is armed again."
            }
            _ = try await model.call("routines:pause", [routine.id, "Paused from Settings."])
            return "\(routine.name) is paused. Its file is untouched."
        }
    }

    private func toggle() {
        note = nil
        text = nil
        problem = nil
        if open {
            open = false
            return
        }
        open = true
        Task {
            do {
                switch CopilotRoutineText.from(try await model.call("routines:text", [routine.id])) {
                case .text(let read, _): text = read
                case .problems(let problems): problem = problems.joined(separator: " ")
                }
            } catch {
                problem = CodingAIErrorText.from(error, fallback: "That routine could not be read.")
            }
        }
    }
}

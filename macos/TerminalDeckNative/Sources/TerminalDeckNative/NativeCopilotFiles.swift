import SwiftUI
import TerminalDeckNativeCore

// Settings → Hoot → Its files (web: CopilotSection.tsx `FilesGroup`, `FileRow`, `useFileText`).

/// `useFileText`: a file read when its box opens, and again when its key moves.
@MainActor @Observable
final class CopilotFileText {
    var text: String?
    var problem: String?
    @ObservationIgnored private var readKey: String?

    func follow(open: Bool, key: String, read: @escaping @MainActor () async throws -> (text: String?, error: String?)) {
        guard open else {
            readKey = nil
            return
        }
        guard readKey != key else { return }
        readKey = key
        Task {
            do {
                let result = try await read()
                text = result.text
                problem = result.error
            } catch {
                text = nil
                problem = CodingAIErrorText.from(error, fallback: "That file could not be read.")
            }
        }
    }

    /// A save landed: the box holds what is on disk now.
    func accept(_ next: String) { text = next }
}

/// `FileRow`: label and badges, the sentence, why the button cannot act, the box when open.
struct CopilotFileRow<Content: View>: View {
    let label: String
    let badges: [(text: String, quiet: Bool)]
    let says: String
    let action: String
    let onAction: () -> Void
    var disabledBecause: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CopilotPathRow {
                CopilotLabel(text: label, badges: CopilotFilesWords.distinct(badges))
                CopilotHelp(says)
                if let disabledBecause { CopilotHelp("\(action): \(disabledBecause)") }
            } actions: {
                Button(action, action: onAction).disabled(disabledBecause != nil)
            }
            content
        }
    }
}

struct CopilotFilesGroup: View {
    let model: CopilotSettingsPageModel
    enum Open { case yours, contract, composed, folder }

    @State private var confirm = false
    @State private var open: Open?
    @State private var saveNote: (text: String, ok: Bool)?
    @State private var yours = CopilotFileText()
    @State private var contract = CopilotFileText()
    @State private var composed = CopilotFileText()
    @State private var folderText = CopilotFileText()

    var body: some View {
        let state = model.state
        let instructions = state?.instructions ?? .missing
        let note = CopilotFilesWords.instructions(instructions)
        let running = state?.status == .running
        let layer = state?.layerFiles ?? []
        let yoursFile = layer.first { $0.owner == .yours }
        let contractFile = layer.first { $0.path.hasSuffix("tools.md") }
        let composedFile = layer.first { $0.path.hasSuffix("copilot.md") }
        let folderFile = (state?.startupFiles ?? []).first { $0.owner == .folder && $0.purpose != "Memory" && $0.purpose != "Memory index" }
        let keys = (yours: "\(instructions.rawValue):\(yoursFile?.modifiedAt ?? 0)", contract: "\(contractFile?.modifiedAt ?? 0)",
                    composed: "\(composedFile?.modifiedAt ?? 0)",
                    folder: "\(state?.folder?.home ?? ""):\(folderFile?.exists == true ? "has" : "none"):\(folderFile?.modifiedAt ?? 0)")

        CopilotBlock(title: "Its files", says: "What it reads before it answers anything — and what you can change.",
                     more: "This is the answer to “why did it say that”. The list is read off the disk every time this pane opens rather than remembered, so an edit you just made — here or in your own editor — shows up straight away.") {
            // Its instructions: the one editor that changes what it is.
            CopilotFileRow(label: "Its instructions", badges: [(note.badge, note.quiet)], says: note.says,
                           action: open == .yours ? "Close" : "Edit", onAction: { toggle(.yours) }) {
                if open == .yours { instructionsEditor(instructions: instructions, running: running, path: yoursFile?.path) }
            }

            CopilotFileRow(label: "Its tool list", badges: [("generated", true)],
                           says: "What it may do, written fresh from the tools that are actually wired every time it starts.",
                           action: open == .contract ? "Close" : "View", onAction: { toggle(.contract) }) {
                if open == .contract {
                    NativeReadOnlyFile(label: CopilotWords.baseName(contractFile?.path ?? "tools.md"), text: contract.text,
                                       problem: contract.problem,
                                       because: "This one is not editable, because it is a description of what is wired rather than an opinion: hand-edit the tool list and it stops matching the tools that exist, which is how an assistant ends up refusing work it can do. To change what it says, change the thing it describes. To change how it behaves, edit its instructions above.",
                                       rows: 16) {
                        Button("Show the file") { model.reveal("contract") }
                    }
                }
            }

            CopilotFileRow(label: "What it was handed", badges: [("generated", true)],
                           says: "The two halves above, composed — byte for byte what the running \(CopilotWords.assistant) was given, and never written into its folder.",
                           action: open == .composed ? "Close" : "View", onAction: { toggle(.composed) }) {
                if open == .composed {
                    NativeReadOnlyFile(label: CopilotWords.baseName(composedFile?.path ?? "copilot.md"), text: composed.text,
                                       problem: composed.problem ?? (composedFile.map { !$0.exists } == true
                                           ? "It has not been written yet — it is composed when \(CopilotWords.assistant) starts." : nil),
                                       because: "A copy, made at the moment it started. Editing it would change nothing: it is written again from the two halves every time \(CopilotWords.assistant) starts.",
                                       rows: 16) {
                        Button("Show the file") { model.reveal("composed") }
                    }
                }
            }

            CopilotFileRow(label: "The folder’s own instructions", badges: folderFile?.exists == true ? [] : [("not there", true)],
                           says: folderFile?.exists == true
                               ? "Whatever assistant already lives in that folder, read the ordinary way. This app writes it only when you press Save here."
                               : "Nothing in that folder claims to be \(CopilotWords.assistant). Write one here and it does — for \(CopilotWords.assistant) and for any session you start there.",
                           action: open == .folder ? "Close" : "Edit", onAction: { toggle(.folder) }) {
                if open == .folder { folderEditor(running: running) }
            }

            CopilotPathRow {
                HStack(spacing: 4) {
                    CopilotLabel(text: "Its memory", badges: [(CopilotFilesWords.memoryBadge(model.memory), true)])
                    NativeCodingAIInfo(label: "its memory",
                                       text: "One file per fact, and every one of them is its own — never another session’s. What it reads out of another session is evidence it reports on, never a fact it keeps. That is a rule in its instructions rather than something the machine refuses, and this folder is yours to read and prune.")
                }
                CopilotHelp(model.memory.map { !$0.exists } == true
                    ? "One is created the first time it runs."
                    : "What it has learned about you and your projects, one file per fact.")
            } actions: {
                Button("Open the folder") { model.reveal("memory") }
            }

            // Only while there is something to create.
            if instructions == .missing {
                Button("Create its files") {
                    model.act("scaffold") { [model] in
                        CopilotFilesWords.scaffoldLine(CopilotScaffoldResult.from(try await model.call("copilot:scaffold")))
                    }
                }
                .disabled(model.busy != nil)
            }
        }
        .onChange(of: open, initial: true) { _, _ in follow(keys) }
        .onChange(of: keys.yours) { _, _ in follow(keys) }
        .onChange(of: keys.contract) { _, _ in follow(keys) }
        .onChange(of: keys.composed) { _, _ in follow(keys) }
        .onChange(of: keys.folder) { _, _ in follow(keys) }
    }

    private func toggle(_ which: Open) {
        saveNote = nil
        open = open == which ? nil : which
    }

    private func follow(_ keys: (yours: String, contract: String, composed: String, folder: String)) {
        yours.follow(open: open == .yours, key: keys.yours) { [model] in
            switch CopilotInstructionsRead.from(try await model.call("copilot:read-instructions")) {
            case .text(let text, _): return (text, nil)
            case .failed(let error): return (nil, error)
            }
        }
        contract.follow(open: open == .contract, key: keys.contract) { [model] in
            let read = CopilotLayerRead.from(try await model.call("copilot:read-contract"))
            return (read.text, read.error)
        }
        composed.follow(open: open == .composed, key: keys.composed) { [model] in
            let read = CopilotLayerRead.from(try await model.call("copilot:read-composed"))
            return (read.text, read.error)
        }
        folderText.follow(open: open == .folder, key: keys.folder) { [model] in
            let read = CopilotFolderInstructionsRead.from(try await model.call("copilot:read-folder-instructions"))
            return read.error != nil ? (nil, read.error) : (read.text, nil)
        }
    }

    @ViewBuilder
    private func instructionsEditor(instructions: CopilotInstructionsState, running: Bool, path: String?) -> some View {
        NativeFileEditor(label: CopilotWords.baseName(path ?? "instructions.md"), text: yours.text, problem: yours.problem,
                         effect: running
                             ? "Saving changes what it is told the next time it starts. \(CopilotWords.assistant) is still running with the old text — restart it to hand it the new one."
                             : "Saving changes what it is told the next time it starts.",
                         saveBecause: nil, saving: model.busy == "instructions-save", note: saveNote, rows: 18,
                         onSave: { next in
                             saveNote = nil
                             model.act("instructions-save") { [model] in
                                 let result = CopilotWriteResult.write(try await model.call("copilot:write-instructions", [next]))
                                 if let error = result.error {
                                     saveNote = (error, false)
                                 } else {
                                     yours.accept(next)
                                     saveNote = (CopilotFilesWords.savedLine(backup: result.backup, running: running), true)
                                 }
                                 return nil
                             }
                         }) {
            if running { restartButton(key: "restart", done: "Restarted. It has read the current instructions.") }
            Button("Show the file") { model.reveal("instructions") }
        }
        // The way back to the shipped wording, behind a confirmation.
        if let because = CopilotFilesWords.resetBecause(instructions) {
            CopilotHelp("Restore: \(because)")
        } else if confirm {
            HStack(spacing: 8) {
                Text(instructions == .edited
                     ? "Replace your version with the one this build ships? A copy of yours is kept beside it."
                     : "Replace this older default with the one this build ships? A copy of the old one is kept beside it.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Restore the shipped instructions", role: instructions == .edited ? .destructive : nil) {
                    confirm = false
                    saveNote = nil
                    model.act("reset") { [model] in
                        let result = CopilotWriteResult.reset(try await model.call("copilot:reset-instructions"))
                        if let error = result.error {
                            saveNote = (error, false)
                        } else {
                            saveNote = (result.backup.map { "Restored. What was there is at \($0)." }
                                        ?? "Restored. The box above is this build’s wording again.", true)
                        }
                        return nil
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy != nil)
                Button("Cancel") { confirm = false }
            }
        } else {
            if instructions == .superseded {
                Button("Restore the shipped instructions…") { confirm = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy != nil)
            } else {
                Button("Restore the shipped instructions…") { confirm = true }
                    .disabled(model.busy != nil)
            }
        }
    }

    @ViewBuilder
    private func folderEditor(running: Bool) -> some View {
        NativeFileEditor(label: "The folder’s own instructions", text: folderText.text, problem: folderText.problem,
                         effect: running
                             ? "This is a file in your folder. Saving writes it there and nothing else does — it applies the next time \(CopilotWords.assistant) starts, so restart it to hand it the new one."
                             : "This is a file in your folder. Saving writes it there and nothing else does. It applies the next time \(CopilotWords.assistant) starts.",
                         saveBecause: nil, saving: model.busy == "folder-instructions-save", note: saveNote, rows: 18,
                         onSave: { next in
                             saveNote = nil
                             model.act("folder-instructions-save") { [model] in
                                 let result = CopilotWriteResult.write(try await model.call("copilot:write-folder-instructions", [next]))
                                 if let error = result.error {
                                     saveNote = (error, false)
                                 } else {
                                     folderText.accept(next)
                                     saveNote = (CopilotFilesWords.savedLine(backup: result.backup, running: running, created: result.created), true)
                                 }
                                 return nil
                             }
                         }) {
            if running { restartButton(key: "folder-restart", done: "Restarted. It has read the folder’s current instructions.") }
            Button("Show the file") { model.reveal("root") }
        }
    }

    /// Restart, beside Save, only while it runs: stop, then start.
    private func restartButton(key: String, done: String) -> some View {
        Button(model.busy == key ? "Restarting…" : "Restart it") {
            saveNote = nil
            model.act(key) { [model] in
                _ = try await model.call("copilot:stop")
                let next = CopilotState.from(try await model.call("copilot:ensure"))
                saveNote = next?.status == .running ? (done, true) : (next?.problem ?? "It stopped, and did not come back up.", false)
                return nil
            }
        }
        .disabled(model.busy != nil)
    }
}

/**
 * **The copilot's files, on the phone** — the row on the control screen, and the
 * editor behind it.
 *
 * > *"it reads and writes two kinds of prompts and only one is ours … its memory
 * > folder which is actually here, the folder's own instruction, what it was
 * > handed, its tool list, its instructions, its folder…"*
 *
 * He said that looking at the Mac's Copilot pane beside the phone's, and the
 * pane's own answer is a card called **Its files**: five fixed rows and one per
 * memory file, each with the verb the app can honestly offer for it. This is
 * that card, and the screen a row opens.
 *
 * ## The two halves, and why the editor is a pushed screen
 *
 * A row is a reading: what the file is, whose it is, how big and how old. The
 * editor is a screen's worth of text, and a sheet over a phone is a box that
 * loses half its height to the keyboard the moment somebody taps into it. So the
 * list stays on the control screen and the writing gets the whole screen —
 * pushed, with the file's name in the title bar where the person can see which
 * of six files they are typing into.
 *
 * ## Nothing here decides what may be written
 *
 * Every one of those questions is already answered, twice, by somebody who is
 * not this file: `CopilotFileRow.writable` is the machine's answer about the
 * **file** — the two generated ones are rewritten on every start and a hand-made
 * copy would drift from what they describe — and `CopilotLink.canEditCopilotFiles`
 * is the answer about **this phone**, which is the alter tier because *"the
 * instruction file is the agent"*. This screen draws a Save when both say yes
 * and says which one said no when either does. It re-derives neither.
 *
 * The one thing it does own is **asking twice**. `restoreInstructions` and
 * `forgetMemory` both refuse to put a confirmation in the protocol, in as many
 * words — *"whether to ask twice is the screen's decision and it has the
 * sentence for it"* — so both are behind a `confirmationDialog` here.
 *
 * ## Why a save is confirmed by the listing rather than by the button
 *
 * `saveFile` answers whether the **frame went**, which is not the same news as
 * *it is on the disk*. What says that is the machine: the desktop reads the
 * folder again after every write and sends the whole listing back, so the row's
 * `modifiedAt` moving is the machine's own confirmation and is the only thing
 * this screen will call *Saved*. A refusal arrives on the other channel, as a
 * sentence, which is why `lastError` is watched beside it.
 */

import SwiftUI

/* -------------------------------------------------------------------------- */
/* The row, in the card on the control screen                                  */
/* -------------------------------------------------------------------------- */

/**
 * One file, as a row: what it is, whose it is, and what state it is in.
 *
 * Drawn as a plain shape rather than a `Button` because its caller wraps it in a
 * `NavigationLink` — nesting a button inside a link makes the link untappable
 * everywhere but the label's own hit area, which is the note `CopilotControlView.row`
 * already carries about the same trap.
 */
struct CopilotFileRowBody: View {
    let file: CopilotFileRow

    var body: some View {
        HStack(spacing: 12) {
            // The same monoline metric every row in the settings surfaces uses:
            // 19pt light in a 24pt column. See `SettingsRowBody`.
            Image(systemName: CopilotFileText.icon(file))
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(file.exists ? Theme.secondary : Theme.faint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !file.purpose.isEmpty {
                    Text(file.purpose)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(CopilotFileText.facts(file))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/* -------------------------------------------------------------------------- */
/* The editor                                                                  */
/* -------------------------------------------------------------------------- */

/**
 * One file, open.
 *
 * Addressed by **id** rather than handed a row, because a listing can arrive
 * while somebody is typing — after a save, after a restore, after the copilot
 * writes a memory of its own — and the row this screen is about has to follow
 * that rather than be a copy taken at the moment of the tap. `CopilotLink.openFileRow`
 * does the lookup on every read, so the facts under the title stay current and
 * the text in the box stays exactly as it was typed.
 */
struct CopilotFileEditorView: View {
    let model: DeckModel
    let hostID: String
    let fileID: String

    @Environment(\.dismiss) private var dismiss

    /// What is in the box. Seeded once from the machine's answer and owned by the
    /// person after that — a second seeding would take back somebody's typing on
    /// the strength of a listing arriving.
    @State private var draft = ""
    @State private var seeded = false

    /// What this screen last asked the machine to do, so the confirmation can be
    /// worded for the act rather than for the frame. Both land the same way — a
    /// fresh listing — and *Saved* under a restore would be the wrong news.
    @State private var pending: Act?

    @State private var note: Note?
    @State private var confirmingRestore = false
    @State private var confirmingForget = false

    private enum Act { case saving, restoring }
    private struct Note: Equatable {
        let text: String
        let ok: Bool
    }

    private var host: HostLink? { model.host(hostID) }
    private var link: CopilotLink? { host?.copilot }
    private var file: CopilotFileRow? { link?.openFileRow }

    /// Whether a Save may be drawn at all: this phone's tier **and** the
    /// machine's answer about this file. Two different questions with two
    /// different sentences under them — see `readOnlyBecause`.
    private var canSave: Bool {
        link?.canEditCopilotFiles == true && file?.writable == true
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                if let file, !file.purpose.isEmpty { purpose(file) }
                editor
                foot
            }
        }
        .navigationTitle(file?.name ?? "File")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canSave {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .font(.system(size: 16, weight: .semibold))
                        .disabled(pending != nil || draft == link?.openFileText)
                        .accessibilityIdentifier("copilot.file.save")
                }
            }
        }
        .onAppear {
            link?.openFile(fileID)
            // The refusal path inside `openFile` finishes before this view is
            // drawn again — no socket, no read, `isLoadingFileText` back to
            // false — so the change below never fires and the box would sit
            // empty with no explanation under it. Seeding here covers that one
            // case and nothing else, because `seeded` latches.
            if link?.isLoadingFileText != true { seed() }
        }
        .onDisappear { link?.closeFile() }
        .onChange(of: link?.isLoadingFileText ?? false) { _, loading in
            if !loading { seed() }
        }
        /*
         * The machine's confirmation.
         *
         * The desktop reads the folder again after every write and sends the
         * whole listing, so this stamp moving is the file having actually
         * changed on somebody's disk. Nothing else on this screen is allowed to
         * say *Saved*.
         */
        .onChange(of: link?.openFileRow?.modifiedAt) { _, _ in
            guard let act = pending else { return }
            pending = nil
            note = Note(text: act == .saving ? "Saved."
                                             : "The instructions this build ships are back.",
                        ok: true)
        }
        /*
         * The refusal, in the machine's own words.
         *
         * `CopilotLink.onError` writes straight into `HostLink.lastError`, so
         * the sentence explaining a save that did not happen is already composed
         * — by the end that refused it — and this screen prints it rather than
         * writing a second version that could disagree.
         */
        .onChange(of: host?.lastError) { _, sentence in
            guard pending != nil, let sentence else { return }
            pending = nil
            note = Note(text: sentence, ok: false)
        }
        .confirmationDialog("Restore the default instructions?",
                            isPresented: $confirmingRestore,
                            titleVisibility: .visible) {
            Button("Restore", role: .destructive) { restore() }
            Button("Keep mine", role: .cancel) {}
        } message: {
            Text("What is there now is copied to a file beside it on the machine first, so nothing "
                 + "is lost. The copilot follows the new text from its next start.")
        }
        .confirmationDialog("Forget \(file?.name ?? "this memory")?",
                            isPresented: $confirmingForget,
                            titleVisibility: .visible) {
            Button("Forget it", role: .destructive) { forget() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("The file is deleted on the machine. The copilot stops knowing what is in it.")
        }
    }

    // MARK: - The parts

    /// What the file is for, above the box. One line, in the machine's words —
    /// for a memory row it is the `description:` the copilot itself wrote.
    private func purpose(_ file: CopilotFileRow) -> some View {
        VStack(spacing: 0) {
            Text(file.purpose)
                .font(.system(size: 13))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .accessibilityIdentifier("copilot.file.purpose")
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }

    /**
     * The box.
     *
     * A `TextEditor` rather than the read-only `Text` `FileTextView` draws,
     * which is the whole difference between the two screens: that one is a
     * viewer for anything on a disk, this is the four files a person is allowed
     * to author. Monospaced for the reason everything else in this app that is
     * *data* is monospaced — an instruction file has indentation and fenced
     * blocks, and a proportional font hides both.
     *
     * It wraps rather than scrolling sideways, and that is a deliberate
     * difference from the file viewer too. A person editing on a phone needs to
     * see the end of the sentence they are writing; a 400-column minified line,
     * which is the case that argument was made for, cannot occur in a Markdown
     * instruction file somebody hand-wrote.
     */
    @ViewBuilder
    private var editor: some View {
        if link?.isLoadingFileText == true && !seeded {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if canSave {
            TextEditor(text: $draft)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .scrollContentBackground(.hidden)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .accessibilityIdentifier("copilot.file.editor")
        } else {
            // Read-only: the same text, laid out the way the file is written and
            // free to be selected and copied. No greyed-out box — a control that
            // looks like a control and refuses every keystroke is worse than one
            // that was never drawn.
            ScrollView {
                Text(draft)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .accessibilityIdentifier("copilot.file.reading")
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    /// Everything under the box: what the machine said, why there is no Save
    /// when there is none, and the one or two acts this file allows.
    ///
    /// Absent entirely rather than empty when there is nothing to put in it — the
    /// ordinary case for a writable file that read cleanly — because an empty
    /// band under an editor reads as a control that failed to draw.
    @ViewBuilder
    private var foot: some View {
        if hasFoot {
            VStack(alignment: .leading, spacing: 8) {
            if let problem = link?.openFileError {
                Text(problem)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("copilot.file.problem")
            }
            if let why = readOnlyBecause {
                Text(why)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("copilot.file.readonly")
            }
            if let note {
                Text(note.text)
                    .font(.system(size: 12))
                    .foregroundStyle(note.ok ? Theme.positive : Theme.critical)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("copilot.file.note")
            }
            if pending != nil {
                Text("Working…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
            }
                acts
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
    }

    /// Whether anything at all goes under the box.
    private var hasFoot: Bool {
        if link?.openFileError != nil || readOnlyBecause != nil { return true }
        if note != nil || pending != nil { return true }
        guard link?.canEditCopilotFiles == true, let file else { return false }
        return file.isOwnInstructions || file.isMemory
    }

    /// The two destructive verbs, and each is drawn only for the one file it can
    /// address. `restoreInstructions` refuses every other id at the machine and
    /// `forgetMemory` is the only unlink on this surface — so offering either
    /// anywhere else would be a row that exists to be refused.
    @ViewBuilder
    private var acts: some View {
        if let file, link?.canEditCopilotFiles == true {
            if file.isOwnInstructions {
                actRow(title: "Restore the default",
                       icon: "arrow.uturn.backward",
                       id: "copilot.file.restore") { confirmingRestore = true }
            }
            if file.isMemory {
                actRow(title: "Forget this",
                       icon: "trash",
                       id: "copilot.file.forget") { confirmingForget = true }
            }
        }
    }

    private func actRow(title: String, icon: String, id: String,
                        go: @escaping () -> Void) -> some View {
        Button(action: go) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .light))
                Text(title)
                    .font(.system(size: 16))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.critical)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pending != nil)
        .accessibilityIdentifier(id)
    }

    /**
     * Why there is no Save, when there is none — and which of the two ends said
     * so.
     *
     * The machine's own sentence first when it sent one: a file too large to
     * have been sent whole comes back with `writable: false` **and** an
     * explanation, and that explanation is better than anything composed here.
     * Otherwise the two structural answers, kept apart because they send a
     * person to two different places: the file is one the app rewrites, or this
     * phone was not paired with the tier that changes things.
     */
    private var readOnlyBecause: String? {
        guard !canSave else { return nil }
        guard let file else { return nil }
        if link?.canEditCopilotFiles != true {
            return "This phone can read the copilot's files. Changing them is part of answering "
                + "its confirmations, which this phone was not given."
        }
        // A machine sentence is already on screen as the problem line; a second
        // one saying the same thing in this app's words would be two paragraphs
        // where one is the truth.
        guard link?.openFileError == nil else { return nil }
        return file.owner == .app
            ? "The app writes this one every time the copilot starts, so there is nothing to save."
            : "The machine is not offering to save this one."
    }

    // MARK: - Acting

    /// Take the machine's answer into the box, once.
    private func seed() {
        guard !seeded else { return }
        draft = link?.openFileText ?? ""
        seeded = true
    }

    private func save() {
        guard let link else { return }
        note = nil
        pending = link.saveFile(fileID, text: draft) ? .saving : nil
        // A refusal `saveFile` made itself — an empty file, a file over the
        // ceiling — never reaches the machine, so no listing is coming and the
        // `onChange` above will not fire. The sentence is already in `lastError`
        // by the time that call returns, which is what makes reading it here
        // exact rather than a guess.
        if pending == nil { note = Note(text: host?.lastError ?? "That was not saved.", ok: false) }
    }

    private func restore() {
        guard let link else { return }
        note = nil
        pending = link.restoreInstructions() ? .restoring : nil
        if pending == nil {
            note = Note(text: host?.lastError ?? "The instructions were not restored.", ok: false)
            return
        }
        // Read it back. The two frames go down one channel in order, so the
        // machine has finished writing the default before it serves this — and
        // without it the box would still hold the words that were just replaced,
        // one Save away from putting them back.
        seeded = false
        link.openFile(fileID)
    }

    private func forget() {
        guard let link, let name = file?.memoryName else { return }
        note = nil
        if link.forgetMemory(name) {
            // The file is gone and the listing that proves it is on its way.
            // Standing on an editor for it would be a Save button pointed at
            // nothing, which is the state `CopilotLink.forgetMemory` closes its
            // own box to avoid.
            dismiss()
        } else {
            note = Note(text: host?.lastError ?? "That memory was not deleted.", ok: false)
        }
    }
}

/* -------------------------------------------------------------------------- */
/* The words and the glyphs, with no view in them                              */
/* -------------------------------------------------------------------------- */

/**
 * What a row says about a file, decided once.
 *
 * Pure for the reason `CopilotControl` is: every way these can be wrong is
 * silent. A file drawn as *yours* that the app rewrites on every start, or a
 * size printed beside a file that is not there, is a row that reads perfectly
 * and is a lie about somebody's copilot.
 */
enum CopilotFileText {

    /**
     * The glyph, by id rather than by owner.
     *
     * The owner is already a word on the row, and drawing the same three icons
     * over five different files would make the two the app generates
     * indistinguishable from each other — which is exactly the pair he asked to
     * be able to tell apart: *"it reads and writes two kinds of prompts and only
     * one is ours."*
     *
     * Every name here was checked against `symbol_order.plist` before it was
     * used. A misspelt symbol draws nothing at all, silently, which is a blank
     * column nobody notices in review.
     */
    static func icon(_ file: CopilotFileRow) -> String {
        if file.isMemory { return "brain" }
        switch file.id {
        case "yours": return "text.book.closed"
        case "contract": return "wrench.and.screwdriver"
        case "composed": return "text.alignleft"
        case "folder": return "folder"
        default: return "folder"
        }
    }

    /// Whose file it is, in the two or three words the badge on the Mac's own
    /// row uses. Never derived from the id — the desktop decides ownership and
    /// sends it, and a client that worked it out from a filename would be
    /// keeping a copy of a rule that lives on the machine.
    static func owner(_ owner: CopilotFileOwner) -> String {
        switch owner {
        case .yours: return "yours"
        case .app: return "the app's"
        case .folder: return "in the folder"
        }
    }

    /**
     * The third line: whose it is, how big, how long ago.
     *
     * `exists: false` ends the line, and that is the case worth the care. The
     * folder's own `CLAUDE.md` is normally exactly this — and its absence is the
     * most reassuring row on the screen, because it is the proof that nothing in
     * that folder claims to be the copilot. A size or a stamp beside it would
     * contradict the one fact it is there to state.
     */
    static func facts(_ file: CopilotFileRow, now: Date = Date()) -> String {
        var parts = [owner(file.owner)]
        guard file.exists else {
            parts.append("not there")
            return parts.joined(separator: " · ")
        }
        if let size = file.size { parts.append(byteSize(size)) }
        if let line = SessionDetails.activityLine(file.modifiedAt, now: now) { parts.append(line) }
        return parts.joined(separator: " · ")
    }
}

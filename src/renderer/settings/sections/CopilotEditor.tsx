import { useRef, useState, type ReactNode } from 'react'
import { Button, Notice } from '../controls'

/**
 * The one editor Settings → Copilot uses for all three of its files.
 *
 * Asad, 2026-08-17: *"You added all the copilot settings but none of them is
 * clickable or editable. I want all of those folders to be editable directly
 * from the settings … I should be able to click and make changes and click
 * save, and those folders, instructions, everything should be directly changed
 * from here."*
 *
 * Three different files answer that — the copilot's own instructions, one
 * memory fact, one routine — and they are three different things on disk with
 * three different consequences for saving. What they have in common is the *shape* of
 * the interaction, and there is exactly one of it here rather than three
 * hand-written copies, because three copies is three chances for one of them to
 * lose the part that matters: a draft that survives a reload, a Save that is
 * disabled with a reason rather than inert, and a sentence saying when the edit
 * takes effect.
 *
 * ## What it is *not*
 *
 * Not a code editor. No syntax highlighting, no line numbers, no autocomplete —
 * a `<textarea>` in the app's mono face, because every one of those files is
 * meant to be equally editable in the person's own editor (there is a button
 * for that beside every one of them) and an in-app half-implementation of an
 * editor is the surface that ends up disagreeing with the real one about tabs,
 * line endings and what got saved.
 *
 * ## The draft, and the two ways it can be lost
 *
 * The box is uncontrolled by the loaded text after the first render, which is
 * the whole reason `seen` exists. The pane re-reads everything after every
 * action — `act()` in `CopilotSection.tsx` calls `load()` on the way out — so a
 * naive `value={text}` would throw away half-typed edits every time a memory was
 * deleted somewhere else on the pane. A draft therefore survives a reload that
 * brought back the same bytes, and is dropped only when the bytes on disk
 * actually changed underneath it, where keeping it would mean silently saving
 * over somebody else's write.
 *
 * ## Never a Save that does nothing
 *
 * `saveBecause` is the pane's house rule made a prop: a control that cannot act
 * says why, next to itself. The live cases are a build with the channel
 * unwired, a file the reader had to truncate (saving would delete the tail it
 * never showed), and a draft identical to what is already on disk.
 */

export interface FileEditorProps {
  /**
   * What this box is editing, as the person hears it — this is the textarea's
   * `aria-label` and nothing else renders it.
   *
   * It used to be documented as "the file, as a person names it" and every
   * caller obliged by passing `baseName()` of a path. That is right for the
   * boxes over files this app made up and named — `instructions.md`,
   * `tools.md`, `copilot.md` — where the filename is neutral and is the most
   * useful four syllables a screen reader can spend.
   *
   * It is wrong for the one box over a file in somebody else's folder, whose
   * name is one CLI's convention rather than ours. That box passed
   * `baseName(folderFile?.path ?? 'CLAUDE.md')` and so announced a vendor's
   * filename to every screen-reader user on every machine, on a pane where the
   * visible copy had already been swept clean of it — the 2026-08-17 review's
   * complaint, surviving in the one place nobody looks because it is never
   * drawn. So the prop is a *name for the thing*, and a caller may answer with
   * the category ("The folder’s own instructions") where the filename would be
   * a vendor's. See the note at that call site in `CopilotSection.tsx`.
   */
  label: string
  /** What is on disk, or null while it is being read. */
  text: string | null
  /** Why it could not be read, or null. Replaces the box entirely. */
  problem: string | null
  /**
   * One line: what pressing Save does, and **when it takes effect**.
   *
   * Required rather than optional. All three files change something a person
   * cares about at a different moment — the next time the copilot starts, the
   * next time it starts, and immediately — and an editor that did not say which
   * would be teaching somebody that their edit did nothing.
   */
  effect: string
  /** Why Save cannot act, or null when it can. */
  saveBecause: string | null
  /** True while this editor's own save is in flight. */
  saving: boolean
  /**
   * What the last save did, under this box rather than at the foot of the pane.
   *
   * Measured on the real thing and then moved: the pane's own status notice
   * renders after all six blocks, so pressing Save on the instructions box —
   * the top one, near the top of a screen and a half of content — put "Saved,
   * and here is where your old version went" somewhere the person could not
   * see. A result belongs to the control that produced it.
   *
   * `ok` decides the tone rather than a second prop, because the two cases are
   * genuinely different news: a routine that would not parse is a refusal a
   * person has to act on, and drawing it in the same quiet ink as "Saved" is
   * how somebody walks away believing an edit landed.
   */
  note: { text: string; ok: boolean } | null
  /** Rows the box is tall — the files differ by an order of magnitude in size. */
  rows?: number
  onSave(next: string): void
  /** Extra controls beside Save — "open it in Finder", "put the default back". */
  children?: ReactNode
}

export function FileEditor({
  label,
  text,
  problem,
  effect,
  saveBecause,
  saving,
  note,
  rows = 18,
  onSave,
  children,
}: FileEditorProps) {
  const [draft, setDraft] = useState(text ?? '')
  const seen = useRef(text)

  // A reload that brought back the same bytes leaves a half-typed draft alone;
  // a genuine change on disk wins, because the alternative is saving over
  // somebody else's write with text that was composed against the old file.
  if (seen.current !== text) {
    seen.current = text
    if (text !== null && draft !== text) setDraft(text)
  }

  if (problem !== null) {
    return <p className="settings-prose copilot-editor-problem">{problem}</p>
  }
  if (text === null) {
    return <p className="settings-prose">Reading…</p>
  }

  const dirty = draft !== text
  const because = saveBecause ?? (dirty ? null : 'Nothing has changed.')

  return (
    <div className="copilot-editor">
      <textarea
        className="copilot-editor-box"
        aria-label={label}
        value={draft}
        rows={rows}
        spellCheck={false}
        /* Off, all four. These are configuration files: an editor that
           capitalised the first letter of a `when:` line or turned a quote into
           a curly one would be writing something the parser does not accept,
           from a keystroke the person did not make. */
        autoCapitalize="off"
        autoCorrect="off"
        autoComplete="off"
        disabled={saving}
        onChange={(event) => setDraft(event.target.value)}
      />

      <div className="settings-actions">
        <Button
          tone="primary"
          disabled={because !== null || saving}
          onClick={() => onSave(draft)}
        >
          {saving ? 'Saving…' : 'Save'}
        </Button>
        <Button disabled={!dirty || saving} onClick={() => setDraft(text)}>
          Undo my changes
        </Button>
        {children}
      </div>

      {/* The rule, in the place it applies. `dirty` is deliberately excluded
          from the reasons worth printing — "nothing has changed" is visible in
          the box itself, and a sentence for it would appear under every editor
          on the pane at rest. */}
      {saveBecause !== null && <span className="settings-help">Save: {saveBecause}</span>}
      <span className="settings-help">{dirty ? `Unsaved. ${effect}` : effect}</span>
      {note && <Notice tone={note.ok ? 'info' : 'error'}>{note.text}</Notice>}
    </div>
  )
}

/**
 * A file this app generates, shown in full and not editable.
 *
 * ## Why "shown in full" and not "hidden"
 *
 * Asad asked for the copilot's app-side files to be editable in Settings, and
 * said some should be visible and some not. Nothing is hidden, and the argument
 * is his own: the founding reason for this whole feature was *"so we can see and
 * learn how our copilot is working"*, and a hidden instruction file contradicts
 * it exactly. What replaces hiding is a distinction the pane draws out loud —
 * one half of the layer is the person's and gets a {@link FileEditor}, the other
 * describes what is actually wired and gets this.
 *
 * ## Why "not editable" is a decision rather than missing work
 *
 * The generated half is composed from the live tool catalogue, the tiers those
 * tools declare, and the paths the kernel actually refuses. Hand-edit it and it
 * drifts from the thing it describes — which is this project's stated bug class
 * and a defect this feature has already shipped twice: an instruction file
 * claiming a jail that had been removed, and one denying powers the copilot had.
 * Both were hand-written statements of fact about wiring, and both were true the
 * day they were written.
 *
 * So there is no Save here and there is no channel behind one. {@link because}
 * is required rather than optional, because the pane's house rule is that a
 * control which cannot act says why next to itself — and a box with no Save
 * button at all needs the same sentence for the same reason, plus the other half
 * of it: **what to change instead.**
 */
export interface ReadOnlyFileProps {
  /** The file, as a person names it. */
  label: string
  /** What is on disk, or null while it is being read. */
  text: string | null
  /** Why it could not be read, or null. Replaces the box entirely. */
  problem: string | null
  /** Why this one cannot be edited, and what to change instead. Both halves. */
  because: string
  rows?: number
  /** Anything to put beside it — an Open in Finder, a path. */
  children?: ReactNode
}

export function ReadOnlyFile({ label, text, problem, because, rows = 18, children }: ReadOnlyFileProps) {
  if (problem !== null) {
    return <p className="settings-prose copilot-editor-problem">{problem}</p>
  }
  if (text === null) {
    return <p className="settings-prose">Reading…</p>
  }
  return (
    <div className="copilot-editor">
      <textarea
        className="copilot-editor-box"
        aria-label={label}
        value={text}
        rows={rows}
        readOnly
        spellCheck={false}
        /*
         * `readOnly` rather than `disabled`, and the difference is not
         * cosmetic. A disabled textarea cannot be focused, cannot be scrolled
         * with the keyboard, is skipped by the screen reader's tab order and is
         * drawn in a greyed-out ink that reads as broken. This file is meant to
         * be *read* — that is the entire point of showing it — so it stays
         * selectable, scrollable and copyable, and only refuses the typing.
         */
      />
      {children && <div className="settings-actions">{children}</div>}
      <span className="settings-help">{because}</span>
    </div>
  )
}

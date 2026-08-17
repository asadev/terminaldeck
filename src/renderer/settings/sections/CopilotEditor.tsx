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
 * Three different files answer that — the copilot's `CLAUDE.md`, one memory
 * fact, one routine — and they are three different things on disk with three
 * different consequences for saving. What they have in common is the *shape* of
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
  /** The file, as a person names it: `CLAUDE.md`, `nightly-sweep.md`. */
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
   * renders after all six blocks, so pressing Save on `CLAUDE.md` — which sits
   * near the top of a screen and a half of content — put "Saved, and here is
   * where your old version went" somewhere the person could not see. A result
   * belongs to the control that produced it.
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

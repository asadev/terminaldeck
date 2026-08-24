import { useMemo, useState } from 'react'
import {
  BUILTIN_SCHEMES,
  COLOUR_SLOTS,
  FOLLOW_APP_SCHEME_ID,
  MAX_CUSTOM_SCHEMES,
  MAX_SCHEME_NAME,
  PREVIEW_LINE,
  PREVIEW_LINE_TWO,
  SLOT_LABELS,
  TERMINAL_SCHEME_SETTING,
  alphaPart,
  cleanName,
  contrastRatio,
  copyOf,
  customSchemeKey,
  customSchemesFrom,
  exportScheme,
  isBuiltinId,
  isLightScheme,
  normaliseColour,
  opaquePart,
  parseScheme,
  schemeById,
  storedScheme,
  type ColourSlot,
  type TerminalScheme,
} from '../../../shared/terminal-theme'
import { applyTerminalScheme, previewTerminalScheme } from '../../terminal-scheme'
import { Button, Notice, Row } from '../controls'
import type { SettingValues } from '../settings-schema'
import './TerminalColours.css'

/**
 * The terminal's colours, on a screen, as themselves.
 *
 * ## What was here before, and why it was not enough
 *
 * Nothing. The terminal's appearance was the app's appearance: one Theme row
 * with Dark, Light and System on it, and a session took its ground and its ink
 * from whichever of the two was painted. There was no way to say "black, not
 * charcoal", no way to touch any of the sixteen colours a program actually
 * prints in, and no way to keep a light terminal in a dark window or the other
 * way round. Asad, on exactly that:
 *
 *   > *"give some options to choose the colour of dark mode — we can choose
 *   > pure black as background, or give a proper section to do the terminal page
 *   > editing for the colours and everything, text colours and all… so we can
 *   > have choice of how we want to use the terminal — pure black, dark grey,
 *   > text colours, all of these things. Full option choices."*
 *
 * ## Why every scheme is drawn rather than named
 *
 * A picker of scheme names is a picker you cannot use. Nobody knows what
 * Gruvbox looks like from the word, and the two schemes somebody is choosing
 * between differ in twenty-one colours that a list of names shows none of. So
 * each card is the scheme: its own ground, its own ink, a line of the kind of
 * output a session actually prints — every run in the slot it is printed in, so
 * a palette with a dull green in it says so before it is applied — a block
 * cursor, a run of selected text, and all sixteen as swatches underneath.
 *
 * This is the same argument the font row above it already made when it stopped
 * being a text field: a control that cannot show you what it does is a control
 * you have to apply and undo to read.
 *
 * ## Editing never overwrites what shipped
 *
 * Touching any colour of a built-in makes a copy — *"Nord (yours)"* — and moves
 * the selection to it. The alternative was tried on paper and is worse in both
 * directions: a person who nudges one colour of Solarized Dark and comes back a
 * month later has a scheme called Solarized Dark that is not Solarized Dark, and
 * there is no way back to the published one short of reinstalling. A copy costs
 * a line of explanation once and keeps every shipped palette exactly what its
 * author published.
 *
 * ## The colours apply while you are choosing them
 *
 * Every write here also calls `applyTerminalScheme` with the patch, so a session
 * behind this window repaints on the frame the colour moves rather than after a
 * round trip to disk. The store write happens on `change` — when a colour picker
 * is released — and the live repaint on `input`, which is what makes dragging
 * through a hue feel like dragging through the terminal's hue and not like a
 * form being submitted thirty times.
 */

/** How the person's own schemes are read out of the settings map. */
function customsOf(values: SettingValues): TerminalScheme[] {
  return customSchemesFrom(values as Readonly<Record<string, unknown>>)
}

/** The id currently stored, which may be `follow-app` or a scheme that has gone. */
function chosenId(values: SettingValues): string {
  const raw = values[TERMINAL_SCHEME_SETTING]
  return typeof raw === 'string' && raw !== '' ? raw : FOLLOW_APP_SCHEME_ID
}

/* ---------------------------------------------------------------- preview -- */

/**
 * A scheme, drawn as a small terminal.
 *
 * Inline styles rather than classes with custom properties, because every one
 * of these colours comes from data — there is no fixed set of them to declare in
 * a sheet, and a scheme somebody pasted in has to render exactly as correctly as
 * one that shipped.
 */
function SchemePreview({ scheme }: { scheme: TerminalScheme }) {
  return (
    <div className="scheme-preview" style={{ background: scheme.background }} aria-hidden="true">
      <div className="scheme-preview-line" style={{ color: scheme.foreground }}>
        {PREVIEW_LINE.map((run, at) => (
          <span key={at} style={{ color: scheme[run.slot as ColourSlot] }}>
            {run.text}
          </span>
        ))}
        {/* The block cursor, which is the one mark on the surface that has two
            colours: the block itself and whatever character is under it. */}
        <span
          className="scheme-preview-cursor"
          style={{ background: scheme.cursor, color: scheme.cursorAccent }}
        >
          _
        </span>
      </div>
      <div className="scheme-preview-line" style={{ color: scheme.foreground }}>
        {PREVIEW_LINE_TWO.map((run, at) => (
          <span key={at} style={{ color: scheme[run.slot as ColourSlot] }}>
            {run.text}
          </span>
        ))}
      </div>
      {/* Selected text, which is the slot nothing else on the card can show. */}
      <div className="scheme-preview-line" style={{ color: scheme.foreground }}>
        <span style={{ background: scheme.selectionBackground }}>selected output</span>
      </div>
      <div className="scheme-swatches">
        {COLOUR_SLOTS.slice(5).map((slot) => (
          <span key={slot} className="scheme-swatch" style={{ background: scheme[slot] }} />
        ))}
      </div>
    </div>
  )
}

/**
 * The card for "leave it following the app", which is not a scheme.
 *
 * It cannot be previewed the way the others are — what it looks like is
 * whatever the window is set to, and that is two pictures rather than one — so
 * it says so instead of drawing a lie. The two schemes it resolves to are on the
 * grid beside it under their own names, which is where somebody who wants to see
 * them goes.
 */
function FollowCard({ selected, onPick }: { selected: boolean; onPick(): void }) {
  return (
    <li>
      <button
        type="button"
        className="scheme-card scheme-card--follow"
        aria-pressed={selected}
        onClick={onPick}
      >
        <span className="scheme-card-name">Follow the app</span>
        <span className="scheme-card-note">
          Dark colours in the dark theme, light ones in the light theme. What every session has
          always done.
        </span>
      </button>
    </li>
  )
}

function SchemeCard({
  scheme,
  selected,
  onPick,
}: {
  scheme: TerminalScheme
  selected: boolean
  onPick(): void
}) {
  return (
    <li>
      <button type="button" className="scheme-card" aria-pressed={selected} onClick={onPick}>
        <span className="scheme-card-name">
          {scheme.name}
          {/* Said on the card rather than inferred from the ordering: a person
              with fifteen schemes cannot tell which of them they can delete. */}
          {!isBuiltinId(scheme.id) && <span className="scheme-card-tag">yours</span>}
        </span>
        <SchemePreview scheme={scheme} />
      </button>
    </li>
  )
}

/* ----------------------------------------------------------------- editor -- */

/**
 * One colour, twice: a picker and the hex it is.
 *
 * Both, because neither is enough on its own. A picker is how somebody who
 * wants "a bit more orange" gets it, and it cannot express transparency or be
 * pasted from anywhere; the field is how a value copied out of a palette gets
 * in exactly, character for character, which is the whole point of a hex code.
 *
 * The picker writes the six digits and keeps whatever alpha the value had —
 * `<input type="color">` has no opinion about transparency and would silently
 * make a half-transparent selection opaque every time it was touched.
 */
function ColourRow({
  slot,
  value,
  onLive,
  onCommit,
}: {
  slot: ColourSlot
  value: string
  onLive(next: string): void
  onCommit(next: string): void
}) {
  const [text, setText] = useState(value)
  // The field follows the scheme when the scheme changes under it — picking
  // another scheme while the editor is open, or the picker being dragged.
  const [seen, setSeen] = useState(value)
  if (seen !== value) {
    setSeen(value)
    setText(value)
  }
  const alpha = alphaPart(value)
  const legal = normaliseColour(text) !== null

  return (
    <div className="colour-row">
      <label className="colour-row-label" htmlFor={`colour-${slot}`}>
        {SLOT_LABELS[slot]}
      </label>
      <input
        id={`colour-${slot}`}
        type="color"
        className="colour-chip"
        value={opaquePart(value)}
        onInput={(event) => onLive(`${event.currentTarget.value}${alpha}`)}
        onChange={(event) => onCommit(`${event.currentTarget.value}${alpha}`)}
      />
      <input
        type="text"
        className="settings-input colour-hex"
        value={text}
        spellCheck={false}
        aria-invalid={!legal}
        aria-label={`${SLOT_LABELS[slot]} hex`}
        onChange={(event) => {
          setText(event.target.value)
          const colour = normaliseColour(event.target.value)
          if (colour !== null) onLive(colour)
        }}
        onBlur={() => {
          const colour = normaliseColour(text)
          if (colour === null) setText(value)
          else onCommit(colour)
        }}
      />
    </div>
  )
}

/* ------------------------------------------------------------------ pane -- */

export interface TerminalColoursProps {
  values: SettingValues
  save(patch: Record<string, unknown>): void
  disabled?: boolean
}

export function TerminalColours({ values, save, disabled }: TerminalColoursProps) {
  const customs = useMemo(() => customsOf(values), [values])
  const chosen = chosenId(values)
  const active = schemeById(chosen, customs)

  const [editing, setEditing] = useState(false)
  const [importing, setImporting] = useState(false)
  const [pasted, setPasted] = useState('')
  const [note, setNote] = useState<string | null>(null)
  const [problem, setProblem] = useState<string | null>(null)
  const [renaming, setRenaming] = useState<string | null>(null)

  const taken = customs.map((scheme) => scheme.id)
  const full = customs.length >= MAX_CUSTOM_SCHEMES

  /**
   * Write, and repaint every open session on the same frame.
   *
   * The second half is why this is a function rather than `save` used directly:
   * `save` persists and only then tells the app, so without this a colour would
   * land on disk before it landed on the terminal the person is looking at.
   */
  const write = (patch: Record<string, unknown>): void => {
    save(patch)
    applyTerminalScheme({ ...(values as Record<string, unknown>), ...patch })
  }

  const pick = (id: string): void => {
    setProblem(null)
    setNote(null)
    write({ [TERMINAL_SCHEME_SETTING]: id })
  }

  /**
   * A colour changed on whatever is selected.
   *
   * The copy-on-edit rule lives here rather than in the row, because it is the
   * one place that knows whether the scheme under the cursor is one that
   * shipped. `live` writes nothing to disk — it is the drag — and the commit
   * that follows stores the scheme the drag ended on.
   */
  const change = (slot: ColourSlot, colour: string, commit: boolean): void => {
    if (active === null) return
    const edited: TerminalScheme = { ...active, [slot]: colour }
    if (!commit) {
      // The drag: show it and store nothing. For a built-in this also means one
      // edit makes one copy rather than thirty, since the copy is made below,
      // when the picker is let go.
      previewTerminalScheme(edited)
      return
    }
    if (!isBuiltinId(active.id)) {
      write({ [customSchemeKey(active.id)]: storedScheme(edited) })
      return
    }
    if (full) {
      setProblem(`You already have ${MAX_CUSTOM_SCHEMES} of your own schemes. Delete one first.`)
      return
    }
    const copy = copyOf(edited, taken)
    write({
      [customSchemeKey(copy.id)]: storedScheme(copy),
      [TERMINAL_SCHEME_SETTING]: copy.id,
    })
    setNote(`Editing a scheme that came with the app made you a copy — ${copy.name}.`)
  }

  const duplicate = (): void => {
    if (active === null || full) return
    const copy = copyOf(active, taken)
    write({
      [customSchemeKey(copy.id)]: storedScheme(copy),
      [TERMINAL_SCHEME_SETTING]: copy.id,
    })
    setNote(`Copied to ${copy.name}.`)
  }

  const remove = (): void => {
    if (active === null || isBuiltinId(active.id)) return
    // The choice moves before the key goes, so nothing is ever pointing at a
    // scheme that is not there — a window that read the file in between would
    // otherwise fall back to following the app for one frame.
    write({
      [TERMINAL_SCHEME_SETTING]: FOLLOW_APP_SCHEME_ID,
      [customSchemeKey(active.id)]: null,
    })
    setEditing(false)
    setNote(`Deleted ${active.name}.`)
  }

  const rename = (name: string): void => {
    if (active === null || isBuiltinId(active.id)) return
    const cleaned = cleanName(name)
    if (cleaned === '') return
    write({ [customSchemeKey(active.id)]: storedScheme({ ...active, name: cleaned }) })
  }

  const paste = (): void => {
    if (full) {
      setProblem(`You already have ${MAX_CUSTOM_SCHEMES} of your own schemes. Delete one first.`)
      return
    }
    const result = parseScheme(pasted, taken)
    if (!result.ok) {
      setProblem(result.problem)
      return
    }
    write({
      [customSchemeKey(result.scheme.id)]: storedScheme(result.scheme),
      [TERMINAL_SCHEME_SETTING]: result.scheme.id,
    })
    setPasted('')
    setImporting(false)
    setProblem(null)
    setNote(`Added ${result.scheme.name}.`)
  }

  const copyJson = (): void => {
    if (active === null) return
    void navigator.clipboard?.writeText(exportScheme(active)).then(
      () => setNote(`${active.name} copied as JSON.`),
      () => setProblem('This window could not reach the clipboard.'),
    )
  }

  return (
    <>
      <div className="settings-item">
        <Row
          label="Terminal colours"
          help={
            active === null
              ? 'Sessions follow the app’s own light and dark.'
              : `Every session is drawn in ${active.name}.`
          }
          more="Choosing a scheme pins it: the terminal stays in those colours whether the app is light or dark. Follow the app is the first card and is what an untouched install does."
          /*
           * One verb up here and the rest under the grid, which is a split
           * rather than an oversight. This one *adds* a scheme and is available
           * whatever is selected — the same place and the same shape as the
           * "add" action on every other list in this window. Everything below
           * acts on the scheme that is chosen, so it lives beside the choice.
           */
          control={
            <Button onClick={() => setImporting((open) => !open)} disabled={disabled}>
              {importing ? 'Cancel' : 'Paste a scheme'}
            </Button>
          }
        />

        {importing && (
          <div className="settings-item-extra scheme-import">
            <textarea
              className="settings-input scheme-paste"
              value={pasted}
              spellCheck={false}
              placeholder='{ "name": "…", "background": "#000000", … }'
              aria-label="Scheme JSON"
              onChange={(event) => setPasted(event.target.value)}
            />
            <p className="settings-help">
              A scheme in JSON, from this app or from another terminal — the usual spellings of the
              cursor and the two magentas are both understood.
            </p>
            <span className="scheme-actions">
              <Button tone="primary" onClick={paste} disabled={disabled || pasted.trim() === ''}>
                Add scheme
              </Button>
              <Button
                onClick={() => {
                  setImporting(false)
                  setProblem(null)
                }}
              >
                Cancel
              </Button>
            </span>
          </div>
        )}

        {problem !== null && <Notice tone="warn">{problem}</Notice>}
        {problem === null && note !== null && <p className="settings-help">{note}</p>}

        <ul className="scheme-grid">
          <FollowCard selected={active === null} onPick={() => pick(FOLLOW_APP_SCHEME_ID)} />
          {[...BUILTIN_SCHEMES, ...customs].map((scheme) => (
            <SchemeCard
              key={scheme.id}
              scheme={scheme}
              selected={active !== null && scheme.id === active.id}
              onPick={() => pick(scheme.id)}
            />
          ))}
        </ul>

        {active !== null && (
          <div className="settings-item-extra">
            <Button
              onClick={() => {
                /*
                 * Closing the editor lands back on what is stored.
                 *
                 * A drag paints without writing, so a picker abandoned rather
                 * than released — the OS colour panel closed with Escape, a
                 * pointer let go outside it — leaves the session painted in a
                 * colour nothing on disk agrees with, until the next settings
                 * change happens to correct it. One line here makes leaving the
                 * editor the moment that reconciles them.
                 */
                if (editing) applyTerminalScheme(values as Record<string, unknown>)
                setEditing((open) => !open)
              }}
              disabled={disabled}
            >
              {editing ? 'Done editing' : 'Edit colours'}
            </Button>
            <Button onClick={copyJson} disabled={disabled}>
              Copy as JSON
            </Button>
            <Button
              onClick={duplicate}
              disabled={disabled || full}
              title={full ? `You already have ${MAX_CUSTOM_SCHEMES} of your own.` : undefined}
            >
              Duplicate
            </Button>
            {!isBuiltinId(active.id) && (
              <>
                <Button onClick={() => setRenaming(active.name)} disabled={disabled}>
                  Rename
                </Button>
                <Button tone="danger" onClick={remove} disabled={disabled}>
                  Delete
                </Button>
              </>
            )}
          </div>
        )}

        {renaming !== null && active !== null && (
          <div className="settings-item-extra">
            <input
              type="text"
              className="settings-input"
              value={renaming}
              maxLength={MAX_SCHEME_NAME}
              aria-label="Scheme name"
              onChange={(event) => setRenaming(event.target.value)}
            />
            <Button
              tone="primary"
              onClick={() => {
                rename(renaming)
                setRenaming(null)
              }}
              disabled={cleanName(renaming) === ''}
            >
              Save name
            </Button>
            <Button onClick={() => setRenaming(null)}>Cancel</Button>
          </div>
        )}

        {editing && active !== null && (
          <div className="settings-item-extra colour-editor">
            <div className="colour-editing">
              <SchemePreview scheme={active} />
            </div>
            <p className="settings-help">
              {`Text on this background measures ${contrastRatio(active.foreground, active.background).toFixed(1)}:1. Anything under 4.5 is hard to read.`}
              {/* Said before the first colour is touched rather than after,
                  which is the difference between a rule somebody is told and a
                  surprise somebody has to undo. */}
              {isBuiltinId(active.id) &&
                ` ${active.name} came with the app, so changing a colour makes you a copy of it.`}
            </p>
            <div className="colour-grid">
              {COLOUR_SLOTS.map((slot) => (
                <ColourRow
                  key={slot}
                  slot={slot}
                  value={active[slot]}
                  onLive={(next) => change(slot, next, false)}
                  onCommit={(next) => change(slot, next, true)}
                />
              ))}
            </div>
            <p className="settings-help">
              {isLightScheme(active)
                ? 'A light scheme. It stays light while the app is dark — the window’s theme and the terminal’s are separate choices.'
                : 'A dark scheme. It stays dark while the app is light — the window’s theme and the terminal’s are separate choices.'}
            </p>
          </div>
        )}
      </div>
    </>
  )
}

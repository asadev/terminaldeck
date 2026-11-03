/**
 * The terminal colour picker, for the browser client.
 *
 * ## Why this is a file and not another method on `App`
 *
 * `main.ts` is seven thousand lines and every screen in this client is built by
 * a method on one class. This block is a screen's worth of DOM on its own — a
 * grid of fourteen previews, an editor of twenty-one rows, an import box — and
 * putting it in there would be the largest single thing in the file, for a
 * feature that has no business knowing about sockets, pairings or sessions.
 * What it needs from the app is four callbacks, and they are the whole of the
 * interface below.
 *
 * ## Why it draws the same cards the desktop draws
 *
 * Because it is the same feature, and the previews come from the same
 * `PREVIEW_LINE` in `src/shared/terminal-theme.ts` for the same reason the
 * schemes do: two clients drawing one scheme two ways is two previews of one
 * thing, and the one somebody trusts is whichever they saw last.
 *
 * ## What is deliberately not here
 *
 * A separate screen. This client's Settings is one scrolling column and adding
 * a route for a picker would put the colours a tap further away than the text
 * size beside them — which is the split this pass exists to close on the
 * desktop. The editor opens under the grid instead, exactly as it does there.
 */

import {
  COLOUR_SLOTS,
  FOLLOW_APP_SCHEME_ID,
  MAX_CUSTOM_SCHEMES,
  PREVIEW_LINE,
  PREVIEW_LINE_TWO,
  SLOT_LABELS,
  alphaPart,
  cleanName,
  contrastRatio,
  copyOf,
  exportScheme,
  isBuiltinId,
  isLightScheme,
  normaliseColour,
  opaquePart,
  parseScheme,
  schemeById,
  type ColourSlot,
  type TerminalScheme,
} from '../../src/shared/terminal-theme'
import { schemesToOffer } from './terminal-scheme'

/** What the picker needs from the app, and nothing else. */
export interface SchemePickerHost {
  /** The stored choice — a scheme id, or `follow-app`. */
  chosen: string
  /** The schemes this browser holds. */
  customs: TerminalScheme[]
  /** Open editor, open import box, and what is in it. Mutable: the settings
   *  screen is rebuilt from scratch on every change, so state that has to
   *  survive a redraw cannot live inside this file. */
  editing: boolean
  importing: boolean
  draft: string
  problem: string | null
  said: string | null
  /** Persist a choice and repaint every open session. */
  choose(id: string): void
  /** Persist the whole list, optionally choosing one of them. */
  keep(customs: TerminalScheme[], chooseId?: string): void
  /** Paint without storing — what a colour picker being dragged means. */
  preview(scheme: TerminalScheme): void
  /** Rebuild the settings screen. */
  refresh(): void
}

function element<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  className?: string,
  text?: string,
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag)
  if (className !== undefined) node.className = className
  if (text !== undefined) node.textContent = text
  return node
}

function button(className: string, label: string, onPress: () => void): HTMLButtonElement {
  const node = element('button', className, label)
  node.type = 'button'
  node.addEventListener('click', onPress)
  return node
}

/** A scheme drawn as a small terminal — the same picture the desktop draws. */
function preview(scheme: TerminalScheme): HTMLElement {
  const box = element('div', 'scheme__preview')
  box.style.background = scheme.background
  box.setAttribute('aria-hidden', 'true')

  for (const runs of [PREVIEW_LINE, PREVIEW_LINE_TWO]) {
    const line = element('div', 'scheme__line')
    line.style.color = scheme.foreground
    for (const run of runs) {
      const span = element('span', undefined, run.text)
      span.style.color = scheme[run.slot as ColourSlot]
      line.append(span)
    }
    if (runs === PREVIEW_LINE) {
      // The block cursor, which is the one mark that carries two colours: the
      // block, and whatever character is underneath it.
      const cursor = element('span', 'scheme__cursor', '_')
      cursor.style.background = scheme.cursor
      cursor.style.color = scheme.cursorAccent
      line.append(cursor)
    }
    box.append(line)
  }

  const selected = element('div', 'scheme__line')
  selected.style.color = scheme.foreground
  const run = element('span', undefined, 'selected output')
  run.style.background = scheme.selectionBackground
  selected.append(run)
  box.append(selected)

  const swatches = element('div', 'scheme__swatches')
  for (const slot of COLOUR_SLOTS.slice(5)) {
    const swatch = element('span', 'scheme__swatch')
    swatch.style.background = scheme[slot]
    swatches.append(swatch)
  }
  box.append(swatches)
  return box
}

/** One colour: a native picker and the hex it is, for the reasons the desktop's own row gives. */
function colourRow(
  slot: ColourSlot,
  value: string,
  onLive: (next: string) => void,
  onCommit: (next: string) => void,
): HTMLElement {
  const row = element('div', 'scheme-row')
  row.append(element('span', 'scheme-row__label', SLOT_LABELS[slot]))

  const alpha = alphaPart(value)
  const chip = element('input', 'scheme-chip')
  chip.type = 'color'
  chip.value = opaquePart(value)
  chip.setAttribute('aria-label', SLOT_LABELS[slot])
  // `input` while it moves, `change` when it is let go: the first repaints the
  // session, the second is the only one that writes anything down.
  chip.addEventListener('input', () => onLive(`${chip.value}${alpha}`))
  chip.addEventListener('change', () => onCommit(`${chip.value}${alpha}`))

  const hex = element('input', 'scheme-hex')
  hex.type = 'text'
  hex.value = value
  hex.spellcheck = false
  hex.autocapitalize = 'off'
  hex.setAttribute('aria-label', `${SLOT_LABELS[slot]} hex`)
  hex.addEventListener('input', () => {
    const colour = normaliseColour(hex.value)
    hex.classList.toggle('scheme-hex--bad', colour === null)
    if (colour !== null) onLive(colour)
  })
  hex.addEventListener('blur', () => {
    const colour = normaliseColour(hex.value)
    if (colour === null) hex.value = value
    else onCommit(colour)
    hex.classList.remove('scheme-hex--bad')
  })

  row.append(chip, hex)
  return row
}

/**
 * The whole block: a caption's worth of picker, and whatever is open under it.
 *
 * Rebuilt from the host's state on every change rather than mutated in place.
 * This client already redraws a screen for every state change and the grid is
 * fourteen small elements; a diffing layer for it would be more code than the
 * feature.
 */
export function schemeBlock(host: SchemePickerHost): HTMLElement {
  const block = element('div', 'schemes-block')
  const active = schemeById(host.chosen, host.customs)
  const full = host.customs.length >= MAX_CUSTOM_SCHEMES

  const say = (line: string): void => {
    host.said = line
    host.problem = null
    host.refresh()
  }
  const refuse = (line: string): void => {
    host.problem = line
    host.said = null
    host.refresh()
  }

  /* ------------------------------------------------------------ the grid -- */

  const grid = element('div', 'schemes')

  const follow = button('scheme scheme--follow', '', () => {
    host.choose(FOLLOW_APP_SCHEME_ID)
  })
  follow.setAttribute('aria-pressed', String(active === null))
  follow.append(
    element('span', 'scheme__name', 'Follow the app'),
    element(
      'span',
      'scheme__note',
      'Dark colours in the dark theme, light ones in the light theme. What every session has always done.',
    ),
  )
  grid.append(follow)

  for (const scheme of schemesToOffer(host.customs)) {
    const card = button('scheme', '', () => host.choose(scheme.id))
    card.setAttribute('aria-pressed', String(active !== null && scheme.id === active.id))
    const name = element('span', 'scheme__name', scheme.name)
    if (!isBuiltinId(scheme.id)) name.append(element('span', 'scheme__tag', 'yours'))
    card.append(name, preview(scheme))
    grid.append(card)
  }

  /* --------------------------------------------------------- what it says -- */

  block.append(
    element(
      'p',
      'note note--plain',
      active === null
        ? 'Sessions follow this page’s own light and dark. Pick a scheme to pin one instead — it then stays as it is whichever way the page goes.'
        : `Every session is drawn in ${active.name}, whichever way this page is set.`,
    ),
  )
  block.append(grid)

  /* ------------------------------------------------------------- actions -- */

  const actions = element('div', 'scheme-actions')
  actions.append(
    button('button button--quiet', host.importing ? 'Cancel paste' : 'Paste a scheme', () => {
      host.importing = !host.importing
      host.problem = null
      host.refresh()
    }),
  )
  if (active !== null) {
    actions.append(
      button('button button--quiet', host.editing ? 'Done editing' : 'Edit colours', () => {
        host.editing = !host.editing
        host.refresh()
      }),
      button('button button--quiet', 'Duplicate', () => {
        if (full) {
          refuse(`You already have ${MAX_CUSTOM_SCHEMES} of your own schemes. Delete one first.`)
          return
        }
        const copy = copyOf(active, host.customs.map((scheme) => scheme.id))
        host.keep([...host.customs, copy], copy.id)
        say(`Copied to ${copy.name}.`)
      }),
      button('button button--quiet', 'Copy as JSON', () => {
        void navigator.clipboard
          ?.writeText(exportScheme(active))
          .then(() => say(`${active.name} copied as JSON.`), () => refuse('This browser would not give the page its clipboard.'))
      }),
    )
    if (!isBuiltinId(active.id)) {
      actions.append(
        button('button button--quiet', 'Rename', () => {
          const asked = window.prompt('Name this scheme', active.name)
          const name = cleanName(asked)
          if (name === '') return
          host.keep(
            host.customs.map((scheme) => (scheme.id === active.id ? { ...scheme, name } : scheme)),
          )
        }),
        button('button button--quiet button--danger', 'Delete', () => {
          host.editing = false
          // The choice moves first, so nothing is ever pointing at a scheme
          // that is not there.
          host.keep(
            host.customs.filter((scheme) => scheme.id !== active.id),
            FOLLOW_APP_SCHEME_ID,
          )
          say(`Deleted ${active.name}.`)
        }),
      )
    }
  }
  block.append(actions)

  if (host.problem !== null) block.append(element('p', 'note note--warn', host.problem))
  else if (host.said !== null) block.append(element('p', 'note note--plain', host.said))

  /* -------------------------------------------------------------- import -- */

  if (host.importing) {
    const box = element('div', 'scheme-import')
    const field = element('textarea', 'scheme-paste')
    field.value = host.draft
    field.spellcheck = false
    field.setAttribute('aria-label', 'Scheme JSON')
    field.placeholder = '{ "name": "…", "background": "#000000", … }'
    field.addEventListener('input', () => {
      host.draft = field.value
    })
    box.append(field)
    box.append(
      element(
        'p',
        'note note--plain',
        'A scheme in JSON, from this app or from another terminal — the usual spellings of the cursor and the two magentas are both understood.',
      ),
    )
    box.append(
      button('button', 'Add scheme', () => {
        if (full) {
          refuse(`You already have ${MAX_CUSTOM_SCHEMES} of your own schemes. Delete one first.`)
          return
        }
        const result = parseScheme(host.draft, host.customs.map((scheme) => scheme.id))
        if (!result.ok) {
          refuse(result.problem)
          return
        }
        host.draft = ''
        host.importing = false
        host.keep([...host.customs, result.scheme], result.scheme.id)
        say(`Added ${result.scheme.name}.`)
      }),
    )
    block.append(box)
  }

  /* -------------------------------------------------------------- editor -- */

  if (host.editing && active !== null) {
    const editor = element('div', 'scheme-edit')
    editor.append(preview(active))
    editor.append(
      element(
        'p',
        'note note--plain',
        `Text on this background measures ${contrastRatio(active.foreground, active.background).toFixed(1)}:1. Anything under 4.5 is hard to read.` +
          (isBuiltinId(active.id)
            ? ` ${active.name} came with the app, so changing a colour makes you a copy of it.`
            : ''),
      ),
    )

    /**
     * One colour moved.
     *
     * The copy-on-edit rule lives here rather than in the row, because this is
     * the one place that knows whether what is selected is a scheme that
     * shipped. A drag stores nothing; the copy is made when the picker is let
     * go, so one edit makes one copy rather than thirty.
     */
    const change = (slot: ColourSlot, colour: string, commit: boolean): void => {
      const edited: TerminalScheme = { ...active, [slot]: colour }
      if (!commit) {
        host.preview(edited)
        return
      }
      if (!isBuiltinId(active.id)) {
        host.keep(host.customs.map((scheme) => (scheme.id === active.id ? edited : scheme)))
        return
      }
      if (full) {
        refuse(`You already have ${MAX_CUSTOM_SCHEMES} of your own schemes. Delete one first.`)
        return
      }
      const copy = copyOf(edited, host.customs.map((scheme) => scheme.id))
      host.keep([...host.customs, copy], copy.id)
      say(`Editing a scheme that came with the app made you a copy — ${copy.name}.`)
    }

    const rows = element('div', 'scheme-rows')
    for (const slot of COLOUR_SLOTS) {
      rows.append(
        colourRow(
          slot,
          active[slot],
          (next) => change(slot, next, false),
          (next) => change(slot, next, true),
        ),
      )
    }
    editor.append(rows)
    editor.append(
      element(
        'p',
        'note note--plain',
        isLightScheme(active)
          ? 'A light scheme. It stays light while the page is dark — the page’s appearance and the terminal’s colours are separate choices.'
          : 'A dark scheme. It stays dark while the page is light — the page’s appearance and the terminal’s colours are separate choices.',
      ),
    )
    block.append(editor)
  }

  return block
}

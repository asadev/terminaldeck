/**
 * The touch key bar, and the sticky Ctrl behind it.
 *
 * ## Why this exists at all
 *
 * The iOS software keyboard has no Esc, no Tab, no Ctrl and no arrows, and it
 * hides `|`, `/`, `-` and `~` behind two page flips. Every one of those is on
 * the critical path of using a terminal: Ctrl+C stops a runaway process, Tab
 * completes a path, the up arrow recalls the last command, `~` starts a home
 * path and `|` builds a pipeline. Without this row the client renders a
 * terminal that can type prose at a shell and nothing else.
 *
 * ## Why Ctrl is sticky rather than held
 *
 * A finger cannot hold a chord. Ctrl therefore arms, and the next key folds
 * into it — the same interaction every phone keyboard uses for shift. Arming
 * is a toggle, so a mistaken tap is undone by tapping again rather than by
 * being forced to spend it on a key.
 *
 * An armed Ctrl is always spent by the next key, including a key it cannot
 * combine with. Leaving it armed after a key it does not apply to means it
 * fires on the key after that, which is how a sticky modifier turns a `w` into
 * a Ctrl+W and closes something.
 *
 * There is no DOM in this half of the file on purpose: the state machine is
 * where the bugs live, and vitest here runs with no DOM environment.
 */

/* ------------------------------------------------------------------ keys -- */

export type KeyBarKeyId =
  | 'esc'
  | 'tab'
  | 'ctrl'
  | 'up'
  | 'down'
  | 'left'
  | 'right'
  | 'pipe'
  | 'slash'
  | 'dash'
  | 'tilde'

export interface KeyBarKey {
  id: KeyBarKeyId
  /** What the button says. */
  label: string
  /** Read out to screen readers, where the glyph alone is not a word. */
  title: string
}

/**
 * The row, in tap order.
 *
 * Ctrl sits third rather than first: on a phone held one-handed the far left
 * of the row is the least reachable spot, and Esc and Tab are the two that get
 * hit blind. The four punctuation keys are last because they are the ones a
 * user will look down at.
 */
export const KEY_BAR: readonly KeyBarKey[] = [
  { id: 'esc', label: 'esc', title: 'Escape' },
  { id: 'tab', label: 'tab', title: 'Tab' },
  { id: 'ctrl', label: 'ctrl', title: 'Control — applies to the next key' },
  { id: 'up', label: '↑', title: 'Up arrow' },
  { id: 'down', label: '↓', title: 'Down arrow' },
  { id: 'left', label: '←', title: 'Left arrow' },
  { id: 'right', label: '→', title: 'Right arrow' },
  { id: 'pipe', label: '|', title: 'Pipe' },
  { id: 'slash', label: '/', title: 'Slash' },
  { id: 'dash', label: '-', title: 'Hyphen' },
  { id: 'tilde', label: '~', title: 'Tilde' },
]

/* ----------------------------------------------------------------- state -- */

export interface KeyBarState {
  /** Ctrl is armed and folds into the next key pressed. */
  ctrl: boolean
}

export const KEY_BAR_IDLE: KeyBarState = { ctrl: false }

export interface KeyPress {
  /** Bytes for the session. Empty when the press only changed the modifier. */
  data: string
  state: KeyBarState
}

/* ------------------------------------------------------- control mapping -- */

/**
 * The ASCII control byte for a character, or null when there is not one.
 *
 * This is the actual rule rather than a table of guesses: a control character
 * is the printable one with bits 6 and 7 cleared, which is only defined for
 * `@` through `_` (0x40–0x5F) and, by the same masking, the lowercase letters.
 * Space is `@` with a different name, and `?` is the odd one out at 0x7F.
 *
 * Everything else returns null, deliberately. Terminals disagree about
 * Ctrl+`/` — the mask says 0x0F, several emulators send 0x1F — and this client
 * has no way to check which one is on the other end of the socket, so it does
 * not invent an answer. `|` is in the same position.
 */
export function controlByteForChar(char: string): string | null {
  if (char.length !== 1) return null
  if (char === ' ') return '\x00'
  if (char === '?') return '\x7f'
  const code = char.charCodeAt(0)
  if (code >= 0x40 && code <= 0x5f) return String.fromCharCode(code & 0x1f)
  if (code >= 0x61 && code <= 0x7a) return String.fromCharCode(code & 0x1f)
  return null
}

/**
 * The control byte for a `KeyboardEvent.code`, used only for hardware keyboards.
 *
 * `code` names the physical key. `key` and `keyCode` name what the character
 * layer decided the key produced, and on iOS with a hardware keyboard that
 * layer is wrong: through xterm.js 6.0.0, Safari reports Ctrl+C as
 * `keyCode: 13`. xterm's key handler reads `keyCode`, matches Enter, and sends
 * a carriage return — so the one keystroke whose entire job is to stop a
 * runaway process instead submits a blank line to it, and the process keeps
 * running. `code` still reads `KeyC`, because it never passes through the
 * layer that gets it wrong.
 *
 * So Ctrl chords are decoded here from `code` and written to the session
 * directly, and xterm is told not to handle the event.
 *
 * Driven rather than assumed: the malformed event was dispatched at a real
 * xterm 6.0.0 in this client — `{ key: 'c', code: 'KeyC', ctrlKey: true }` with
 * `keyCode` forced to 13 — and the frame that went out carried byte 0x03, not
 * 0x0d. What has *not* been reproduced here is the bug itself on real hardware;
 * there is no iOS device in this loop. That is why the workaround is written to
 * be harmless where the bug is absent: on a correct browser it produces exactly
 * the byte xterm would have produced anyway.
 */
export function controlByteForCode(code: string): string | null {
  const letter = /^Key([A-Z])$/.exec(code)
  if (letter) return controlByteForChar(letter[1].toLowerCase())
  // The four bracket-ish keys are worth having: Ctrl+[ is Escape on a keyboard
  // that has no Escape, which is every recent MacBook-style layout under iOS.
  if (code === 'BracketLeft') return '\x1b'
  if (code === 'Backslash') return '\x1c'
  if (code === 'BracketRight') return '\x1d'
  if (code === 'Space') return '\x00'
  return null
}

/* ---------------------------------------------------------------- presses -- */

/** Arrow keys, plain and with Ctrl (CSI 1;5 is the modifier terminals expect). */
const ARROWS: Record<'up' | 'down' | 'left' | 'right', { plain: string; ctrl: string }> = {
  up: { plain: '\x1b[A', ctrl: '\x1b[1;5A' },
  down: { plain: '\x1b[B', ctrl: '\x1b[1;5B' },
  right: { plain: '\x1b[C', ctrl: '\x1b[1;5C' },
  left: { plain: '\x1b[D', ctrl: '\x1b[1;5D' },
}

const LITERALS: Record<'pipe' | 'slash' | 'dash' | 'tilde', string> = {
  pipe: '|',
  slash: '/',
  dash: '-',
  tilde: '~',
}

/**
 * One key-bar tap: the bytes it produces and the state it leaves behind.
 *
 * Pure, and returns a new state rather than mutating one, so the caller can
 * render from the result and a test can assert a whole sequence.
 */
export function pressKeyBarKey(state: KeyBarState, id: KeyBarKeyId): KeyPress {
  if (id === 'ctrl') return { data: '', state: { ctrl: !state.ctrl } }

  const spent: KeyBarState = { ctrl: false }

  if (id === 'esc') {
    // Ctrl+[ *is* Escape, so an armed Ctrl changes nothing here rather than
    // producing a second, different escape.
    return { data: '\x1b', state: spent }
  }
  if (id === 'tab') {
    // Same argument: Ctrl+I is Tab.
    return { data: '\t', state: spent }
  }

  if (id === 'up' || id === 'down' || id === 'left' || id === 'right') {
    const arrow = ARROWS[id]
    return { data: state.ctrl ? arrow.ctrl : arrow.plain, state: spent }
  }

  const literal = LITERALS[id]
  // Ctrl over a character with no control byte sends the character alone. The
  // modifier is still spent — see the note at the top about the key after.
  return { data: (state.ctrl ? controlByteForChar(literal) : null) ?? literal, state: spent }
}

/**
 * A character typed on the soft keyboard, folded through an armed Ctrl.
 *
 * xterm hands us the character it decoded; when Ctrl is armed this is the only
 * place the chord can be formed, because the soft keyboard never reports a
 * modifier that a finger tapped on our own toolbar.
 */
export function pressCharacter(state: KeyBarState, char: string): KeyPress {
  if (!state.ctrl) return { data: char, state }
  return { data: controlByteForChar(char) ?? char, state: { ctrl: false } }
}

/* -------------------------------------------------------------------- DOM -- */

export interface KeyBarHandlers {
  /** Bytes to send to the session. Never called with an empty string. */
  onData(data: string): void
  /** Called whenever the armed state changes, so the caller can restyle. */
  onModifierChange?(state: KeyBarState): void
}

export interface KeyBarHandle {
  readonly element: HTMLElement
  /** Fold a character from the keyboard through the armed modifier. */
  handleCharacter(char: string): string
  state(): KeyBarState
  destroy(): void
}

/**
 * Build the row.
 *
 * `pointerdown` with `preventDefault`, not `click`: on iOS a `click` on a
 * button blurs the terminal's hidden textarea, which dismisses the soft
 * keyboard, and the keyboard reopening under every Ctrl+C makes the row
 * unusable. Preventing the default on pointerdown keeps focus where it is.
 */
export function createKeyBar(handlers: KeyBarHandlers): KeyBarHandle {
  const element = document.createElement('div')
  element.className = 'keybar'
  element.setAttribute('role', 'toolbar')
  element.setAttribute('aria-label', 'Terminal keys')

  let state: KeyBarState = KEY_BAR_IDLE
  const buttons = new Map<KeyBarKeyId, HTMLButtonElement>()

  const paint = (): void => {
    const ctrl = buttons.get('ctrl')
    if (ctrl) {
      ctrl.classList.toggle('is-armed', state.ctrl)
      ctrl.setAttribute('aria-pressed', String(state.ctrl))
    }
    handlers.onModifierChange?.(state)
  }

  const press = (id: KeyBarKeyId): void => {
    const result = pressKeyBarKey(state, id)
    state = result.state
    paint()
    if (result.data !== '') handlers.onData(result.data)
  }

  const onPointerDown = (event: PointerEvent): void => {
    const target = event.target
    if (!(target instanceof HTMLElement)) return
    const id = target.dataset.key as KeyBarKeyId | undefined
    if (!id) return
    event.preventDefault()
    press(id)
  }

  for (const key of KEY_BAR) {
    const button = document.createElement('button')
    button.type = 'button'
    button.className = `keybar__key keybar__key--${key.id}`
    button.dataset.key = key.id
    button.textContent = key.label
    button.title = key.title
    button.setAttribute('aria-label', key.title)
    if (key.id === 'ctrl') button.setAttribute('aria-pressed', 'false')
    buttons.set(key.id, button)
    element.appendChild(button)
  }

  element.addEventListener('pointerdown', onPointerDown)

  return {
    element,
    handleCharacter(char: string): string {
      const result = pressCharacter(state, char)
      if (result.state.ctrl !== state.ctrl) {
        state = result.state
        paint()
      }
      return result.data
    },
    state: () => state,
    destroy(): void {
      element.removeEventListener('pointerdown', onPointerDown)
      element.remove()
    },
  }
}

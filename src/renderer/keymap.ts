/**
 * The keymap — one declaration of every shortcut, and the only thing allowed
 * to decide what a keystroke means.
 *
 * Shortcuts previously lived in three places: a `switch` in `App.tsx`, a second
 * listener in `CommandPalette.tsx`, and a hand-typed list in the preferences
 * dialog. Three copies of one fact drift, and the printed list is the copy that
 * drifts silently, because nothing breaks when it lies. Here the table is the
 * source of truth: the matcher reads it, the sheet renders it, and a test
 * asserts no two bindings in one scope claim the same chord.
 *
 * Scope is the interesting part. A terminal is a full keyboard application —
 * a session is useless if the app is eating its keystrokes — so a binding must
 * say whether it outranks the terminal, and `stealsFromTerminal` encodes the
 * platform rules for when it may. `Ctrl+C` is in the table purely so the sheet
 * can document it, marked `passthrough` so the matcher never claims it.
 */

import { detectPlatform } from './platform'

/* ------------------------------------------------------------------ types -- */

export type KeyScope = 'global' | 'terminal' | 'modal'

export interface Chord {
  /** The platform's primary modifier: ⌘ on macOS, Ctrl elsewhere. */
  mod: boolean
  /** Control specifically, on every platform. */
  ctrl: boolean
  alt: boolean
  shift: boolean
  /** Lowercase base key: 'a', '1', ',', 'escape', 'f5', 'up'. */
  key: string
}

export interface KeyBinding {
  /** Command id the app dispatches on. Unique across the whole keymap. */
  id: string
  /** Chords that trigger it, canonical form, first is the one displayed. */
  keys: readonly string[]
  label: string
  scope: KeyScope
  /** Section heading in the shortcuts sheet. */
  group: string
  /**
   * Documented but never intercepted — the key belongs to whatever is focused.
   * Without this the sheet cannot explain that Ctrl+C interrupts the *agent*,
   * because the only way to list it would be to start stealing it.
   */
  passthrough?: boolean
  /**
   * Render the chords as a range — `⌘1–9` rather than nine rows. Only the
   * base key varies, so the first chord is formatted in full and the last
   * contributes its key alone.
   */
  collapse?: 'range'
}

/* ------------------------------------------------------------- key tokens -- */

/** `event.key` values that are not single characters, mapped to chord tokens. */
const NAMED_KEYS: Readonly<Record<string, string>> = {
  Escape: 'escape',
  Enter: 'enter',
  Tab: 'tab',
  Backspace: 'backspace',
  Delete: 'delete',
  ArrowUp: 'up',
  ArrowDown: 'down',
  ArrowLeft: 'left',
  ArrowRight: 'right',
  Home: 'home',
  End: 'end',
  PageUp: 'pageup',
  PageDown: 'pagedown',
}

/**
 * US-layout shifted punctuation, mapped back to the key that is printed on the
 * unshifted half. `event.key` for Shift+/ is '?', so a `mod+shift+/` binding
 * would never match without this.
 */
const UNSHIFT: Readonly<Record<string, string>> = {
  '?': '/',
  ':': ';',
  '"': "'",
  '<': ',',
  '>': '.',
  '|': '\\',
  '{': '[',
  '}': ']',
  '~': '`',
  _: '-',
  '+': '=',
  '!': '1',
  '@': '2',
  '#': '3',
  $: '4',
  '%': '5',
  '^': '6',
  '&': '7',
  '*': '8',
  '(': '9',
  ')': '0',
}

const FUNCTION_KEY = /^f([1-9]|1[0-2])$/

/** `event.code` → chord token, for the cases where `event.key` is unusable. */
function tokenFromCode(code: string): string | null {
  if (/^Key[A-Z]$/.test(code)) return code.slice(3).toLowerCase()
  if (/^Digit[0-9]$/.test(code)) return code.slice(5)
  const punctuation: Readonly<Record<string, string>> = {
    Slash: '/',
    Backslash: '\\',
    Comma: ',',
    Period: '.',
    Semicolon: ';',
    Quote: "'",
    BracketLeft: '[',
    BracketRight: ']',
    Backquote: '`',
    Minus: '-',
    Equal: '=',
    Space: 'space',
  }
  return punctuation[code] ?? null
}

/** Everything the matcher needs from a KeyboardEvent, so tests need no DOM. */
export interface KeyLike {
  key: string
  code?: string
  metaKey?: boolean
  ctrlKey?: boolean
  altKey?: boolean
  shiftKey?: boolean
}

/**
 * The base key a keystroke represents, independent of the modifiers held.
 *
 * Two real macOS behaviours make this more than `event.key.toLowerCase()`:
 *
 * - Shift+T arrives as `'T'`, not `'t'` — lowercasing is what makes a
 *   `mod+shift+t` binding match at all.
 * - Option rewrites the character outright: ⌥T produces `'†'`, ⌥N produces a
 *   dead-key `'˜'`. There is no lowercase form to recover, so the physical
 *   `code` is the only thing left that still says "T".
 *
 * `code` is only consulted for those two cases. Reaching for it first would
 * break every non-QWERTY layout, where `KeyZ` is not the key marked Z.
 */
export function keyToken(event: KeyLike): string {
  const raw = event.key
  if (!raw) return ''

  const named = NAMED_KEYS[raw]
  if (named) return named
  if (raw === ' ') return 'space'
  if (raw.length > 1) return raw.toLowerCase()

  const lower = raw.toLowerCase()

  // Option-mangled: the character bears no relation to the key that was hit.
  if (event.altKey && !/^[a-z0-9]$/.test(lower)) {
    const fromCode = event.code ? tokenFromCode(event.code) : null
    if (fromCode) return fromCode
  }

  // Shifted punctuation: prefer the physical key, fall back to the US map.
  if (event.shiftKey && !/^[a-z0-9]$/.test(lower)) {
    const fromCode = event.code ? tokenFromCode(event.code) : null
    if (fromCode) return fromCode
    return UNSHIFT[lower] ?? lower
  }

  return lower
}

/* ---------------------------------------------------------------- parsing -- */

/**
 * Parse a canonical chord: modifiers in any order, then exactly one base key.
 * Returns null for anything malformed so a typo in the table fails a test
 * rather than silently binding nothing.
 */
export function parseChord(text: string): Chord | null {
  const parts = text
    .split('+')
    .map((p) => p.trim().toLowerCase())
    .filter(Boolean)
  // A lone '+' is a legal base key, and splitting eats it.
  if (parts.length === 0) return text.trim() === '+' ? blank('+') : null

  const chord = blank('')
  for (const part of parts) {
    if (part === 'mod' || part === 'cmd' || part === 'meta') {
      if (chord.mod) return null
      chord.mod = true
    } else if (part === 'ctrl' || part === 'control') {
      if (chord.ctrl) return null
      chord.ctrl = true
    } else if (part === 'alt' || part === 'option' || part === 'opt') {
      if (chord.alt) return null
      chord.alt = true
    } else if (part === 'shift') {
      if (chord.shift) return null
      chord.shift = true
    } else {
      // Two base keys is a typo, not a chord.
      if (chord.key) return null
      chord.key = part
    }
  }
  return chord.key ? chord : null
}

function blank(key: string): Chord {
  return { mod: false, ctrl: false, alt: false, shift: false, key }
}

/** Canonical string for a chord — the inverse of `parseChord`. */
export function chordToString(chord: Chord): string {
  const parts: string[] = []
  if (chord.mod) parts.push('mod')
  if (chord.ctrl) parts.push('ctrl')
  if (chord.alt) parts.push('alt')
  if (chord.shift) parts.push('shift')
  parts.push(chord.key)
  return parts.join('+')
}

/* --------------------------------------------------------------- matching -- */

/** Modifier state a chord requires on this platform. */
interface Modifiers {
  meta: boolean
  ctrl: boolean
  alt: boolean
  shift: boolean
}

function required(chord: Chord, isMac: boolean): Modifiers {
  return {
    meta: isMac ? chord.mod : false,
    // Off macOS there is no Command, so `mod` and an explicit `ctrl` are the
    // same physical key and collapse into one requirement.
    ctrl: isMac ? chord.ctrl : chord.mod || chord.ctrl,
    alt: chord.alt,
    shift: chord.shift,
  }
}

/**
 * Exact modifier equality, never a subset test: ⌘⇧T must not fire the ⌘T
 * binding on its way past.
 */
export function chordMatches(chord: Chord, event: KeyLike, isMac: boolean): boolean {
  const want = required(chord, isMac)
  return (
    want.meta === Boolean(event.metaKey) &&
    want.ctrl === Boolean(event.ctrlKey) &&
    want.alt === Boolean(event.altKey) &&
    want.shift === Boolean(event.shiftKey) &&
    chord.key === keyToken(event)
  )
}

/**
 * Whether a chord may be taken off a focused terminal.
 *
 * The rules are the platform's, not ours. On macOS ⌘ belongs to the
 * application and Control belongs to the terminal — ⌃C interrupts the agent,
 * and an app that intercepted it would be broken. Everywhere else there is no
 * ⌘, so plain Ctrl chords are the terminal's control codes and only the
 * shifted variants are free. That is why the command palette answers to ⌘K on
 * macOS and Ctrl+Shift+P elsewhere.
 *
 * Function keys are nobody's typing, so they are always available.
 */
export function stealsFromTerminal(chord: Chord, isMac: boolean): boolean {
  if (FUNCTION_KEY.test(chord.key)) return true
  // A modified Tab is a tab-switcher on both platforms; the session only ever
  // wants the bare one, which no binding here claims.
  if (chord.key === 'tab' && (chord.mod || chord.ctrl || chord.alt)) return true
  if (isMac) return chord.mod
  if (!chord.mod && !chord.ctrl) return false
  return chord.shift || chord.alt
}

export interface ResolveOptions {
  /** Which surface has the keyboard. Defaults to 'global'. */
  scope?: KeyScope
  /** Defaults to sniffing the user agent. */
  isMac?: boolean
  /** Defaults to `KEYMAP`. */
  bindings?: readonly KeyBinding[]
}

/**
 * True on macOS.
 *
 * Delegated to `platform.ts` so the app sniffs the platform in exactly one
 * place: the glyphs in this file and the nouns in the remote panel are answers
 * to the same question, and two sniffs would eventually disagree about the same
 * machine.
 */
export function detectMac(): boolean {
  return detectPlatform() === 'mac'
}

/**
 * Which bindings are live in a scope.
 *
 * A modal owns the keyboard completely — while one is open, ⌘W closing the
 * session behind it would be a data-loss bug, so global bindings are excluded
 * rather than merely deprioritised. A terminal is softer: global bindings
 * still apply, but only the ones `stealsFromTerminal` allows.
 */
export function bindingsInScope(
  scope: KeyScope,
  isMac: boolean,
  bindings: readonly KeyBinding[] = KEYMAP,
): KeyBinding[] {
  if (scope === 'modal') return bindings.filter((b) => b.scope === 'modal' && !b.passthrough)
  return bindings.filter((b) => {
    if (b.passthrough) return false
    if (b.scope === 'modal') return false
    if (b.scope === 'terminal') return scope === 'terminal'
    if (scope !== 'terminal') return true
    return b.keys.some((k) => {
      const chord = parseChord(k)
      return chord !== null && stealsFromTerminal(chord, isMac)
    })
  })
}

/**
 * Resolve a keystroke to a command id, or null to let it through.
 *
 * Returning null rather than a "no-op command" is deliberate: the caller uses
 * it to decide whether to `preventDefault`, and swallowing unmatched keys is
 * exactly how an app breaks typing in the terminal it is hosting.
 */
export function resolveCommand(event: KeyLike, options: ResolveOptions = {}): string | null {
  const isMac = options.isMac ?? detectMac()
  const scope = options.scope ?? 'global'
  const live = bindingsInScope(scope, isMac, options.bindings ?? KEYMAP)

  for (const binding of live) {
    for (const text of binding.keys) {
      const chord = parseChord(text)
      if (!chord) continue
      // In terminal scope a global binding is only live via the chord that
      // outranks the terminal — its other chords still belong to the session.
      if (scope === 'terminal' && binding.scope === 'global' && !stealsFromTerminal(chord, isMac)) {
        continue
      }
      if (chordMatches(chord, event, isMac)) return binding.id
    }
  }
  return null
}

/** Minimal shape of a DOM node, so this stays testable without a DOM. */
interface ClosestLike {
  closest(selector: string): unknown
}

function hasClosest(value: unknown): value is ClosestLike {
  return (
    typeof value === 'object' &&
    value !== null &&
    typeof (value as { closest?: unknown }).closest === 'function'
  )
}

/**
 * Scope for a keystroke, from what it landed on.
 *
 * A modal outranks everything, because the terminal underneath it still holds
 * a focusable textarea and would otherwise keep answering to shortcuts the
 * user cannot see.
 */
export function scopeForTarget(target: unknown, options: { modalOpen?: boolean } = {}): KeyScope {
  if (options.modalOpen) return 'modal'
  if (hasClosest(target) && target.closest('.xterm, [data-keyscope="terminal"]')) return 'terminal'
  return 'global'
}

/* -------------------------------------------------------------- formatting -- */

const MAC_SYMBOLS: Readonly<Record<string, string>> = {
  mod: '⌘',
  ctrl: '⌃',
  alt: '⌥',
  shift: '⇧',
}

const PC_NAMES: Readonly<Record<string, string>> = {
  mod: 'Ctrl',
  ctrl: 'Ctrl',
  alt: 'Alt',
  shift: 'Shift',
}

const MAC_KEY_GLYPHS: Readonly<Record<string, string>> = {
  enter: '↩',
  escape: 'Esc',
  tab: '⇥',
  backspace: '⌫',
  delete: '⌦',
  up: '↑',
  down: '↓',
  left: '←',
  right: '→',
  space: 'Space',
  pageup: '⇞',
  pagedown: '⇟',
  home: '↖',
  end: '↘',
}

const PC_KEY_NAMES: Readonly<Record<string, string>> = {
  enter: 'Enter',
  escape: 'Esc',
  tab: 'Tab',
  backspace: 'Backspace',
  delete: 'Del',
  up: '↑',
  down: '↓',
  left: '←',
  right: '→',
  space: 'Space',
  pageup: 'PgUp',
  pagedown: 'PgDn',
  home: 'Home',
  end: 'End',
}

function keyLabel(key: string, isMac: boolean): string {
  const named = isMac ? MAC_KEY_GLYPHS[key] : PC_KEY_NAMES[key]
  if (named) return named
  if (FUNCTION_KEY.test(key)) return key.toUpperCase()
  return key.length === 1 ? key.toUpperCase() : key
}

/**
 * Render a chord for display: `⌘⇧T` on macOS, `Ctrl+Shift+T` elsewhere.
 *
 * The primary modifier leads. Apple's own convention puts Shift first
 * (`⇧⌘T`), but the whole sheet is scanned down a column, and a fixed leading
 * ⌘ makes the two-thirds of the table that share it line up — worth more here
 * than matching the menu bar glyph for glyph.
 */
export function formatChord(chord: Chord | string, isMac: boolean = detectMac()): string {
  const parsed = typeof chord === 'string' ? parseChord(chord) : chord
  if (!parsed) return ''

  const modifiers: string[] = []
  // Off macOS `mod` and `ctrl` are the same key, so a chord carrying both must
  // not render as "Ctrl+Ctrl+…".
  const seen = new Set<string>()
  const push = (name: keyof typeof MAC_SYMBOLS) => {
    const label = isMac ? MAC_SYMBOLS[name] : PC_NAMES[name]
    if (seen.has(label)) return
    seen.add(label)
    modifiers.push(label)
  }

  if (parsed.mod) push('mod')
  if (parsed.ctrl) push('ctrl')
  if (parsed.alt) push('alt')
  if (parsed.shift) push('shift')

  const key = keyLabel(parsed.key, isMac)
  return isMac ? [...modifiers, key].join('') : [...modifiers, key].join('+')
}

/**
 * Every chord of a binding, formatted for this platform.
 *
 * A collapsed range is built from its own chords rather than written out, so
 * it cannot say ⌘1–9 on a machine that has no ⌘ — which is exactly what a
 * hand-written display string did here.
 *
 * De-duplicated, because two distinct chords can render identically: off macOS
 * `mod` and `ctrl` are the same physical key, so a binding declaring both
 * `mod+x` and `ctrl+x` printed "Ctrl+X or Ctrl+X" — and gave the sheet two
 * list children with the same React key.
 */
export function formatBinding(binding: KeyBinding, isMac: boolean = detectMac()): string[] {
  if (binding.collapse === 'range' && binding.keys.length > 1) {
    const first = parseChord(binding.keys[0])
    const last = parseChord(binding.keys[binding.keys.length - 1])
    if (first && last) return [`${formatChord(first, isMac)}–${keyLabel(last.key, isMac)}`]
  }
  return [...new Set(binding.keys.map((k) => formatChord(k, isMac)).filter(Boolean))]
}

/* ---------------------------------------------------------------- the map -- */

export const SCOPE_TITLES: Readonly<Record<KeyScope, string>> = {
  global: 'Anywhere',
  terminal: 'In a session',
  modal: 'In a dialog',
}

export const SCOPE_HINTS: Readonly<Record<KeyScope, string>> = {
  global: 'Works wherever you are in the app.',
  terminal: 'Claimed while a terminal has focus. Everything else reaches the agent.',
  modal: 'While a dialog or panel is open, it owns the keyboard.',
}

/**
 * The keymap.
 *
 * Chords are the ones the app already answers to where one exists — ⌘T, ⌘W,
 * ⌘O, ⌘, and ⌘⇧I from `App.tsx`, ⌘K and ⌘P from `CommandPalette.tsx` — so
 * adopting this table changes no muscle memory.
 */
export const KEYMAP: readonly KeyBinding[] = [
  // -- sessions --
  { id: 'session.new', keys: ['mod+t'], label: 'New session', scope: 'global', group: 'Sessions' },
  {
    id: 'session.resume',
    keys: ['mod+shift+r'],
    label: 'Resume the last session here',
    scope: 'global',
    group: 'Sessions',
  },
  { id: 'session.close', keys: ['mod+w'], label: 'Close session', scope: 'global', group: 'Sessions' },
  // ⌘⇧T belongs to the dialog, because that is the accelerator the application
  // menu has always printed next to "New Session…", and an Electron menu
  // accelerator is what actually fires. This table used to give ⌘⇧T to
  // `session.resume`, so the shortcuts sheet printed a chord the app answered
  // differently. Resume keeps a chord of its own rather than losing one.
  {
    id: 'session.newDialog',
    keys: ['mod+shift+t'],
    label: 'New session, with options',
    scope: 'global',
    group: 'Sessions',
  },
  {
    id: 'session.jump',
    keys: ['mod+1', 'mod+2', 'mod+3', 'mod+4', 'mod+5', 'mod+6', 'mod+7', 'mod+8', 'mod+9'],
    collapse: 'range',
    label: 'Jump to an open session',
    scope: 'global',
    group: 'Sessions',
  },
  {
    id: 'session.next',
    keys: ['ctrl+tab'],
    label: 'Next session',
    scope: 'global',
    group: 'Sessions',
  },
  {
    id: 'session.previous',
    keys: ['ctrl+shift+tab'],
    label: 'Previous session',
    scope: 'global',
    group: 'Sessions',
  },

  // -- project --
  { id: 'project.open', keys: ['mod+o'], label: 'Open a project', scope: 'global', group: 'Project' },
  {
    id: 'palette.quickOpen',
    keys: ['mod+p', 'mod+shift+o'],
    label: 'Quick open a file',
    scope: 'global',
    group: 'Project',
  },
  {
    id: 'palette.commands',
    keys: ['mod+k', 'mod+shift+p'],
    label: 'Command palette',
    scope: 'global',
    group: 'Project',
  },

  // -- panels --
  { id: 'view.board', keys: ['mod+shift+b'], label: 'Task board', scope: 'global', group: 'Panels' },
  {
    id: 'view.dashboard',
    keys: ['mod+shift+d'],
    label: 'Project dashboard',
    scope: 'global',
    group: 'Panels',
  },
  { id: 'view.files', keys: ['mod+shift+e'], label: 'Files', scope: 'global', group: 'Panels' },
  { id: 'view.git', keys: ['mod+shift+g'], label: 'Source control', scope: 'global', group: 'Panels' },
  {
    id: 'view.search',
    keys: ['mod+shift+f'],
    label: 'Search past sessions',
    scope: 'global',
    group: 'Panels',
  },
  {
    id: 'view.inspector',
    keys: ['mod+shift+i'],
    label: 'Session inspector',
    scope: 'global',
    group: 'Panels',
  },
  { id: 'view.swarm', keys: ['mod+\\'], label: 'Swarm view', scope: 'global', group: 'Panels' },
  { id: 'view.sidebar', keys: ['mod+b'], label: 'Toggle the sidebar', scope: 'global', group: 'Panels' },

  // Split panes had three chords documented here for a component that was
  // never rendered. The chords went first; the component and its pane tree are
  // gone too now — swarm mode (⌘\) is this app's answer to "several sessions at
  // once", and see ROADMAP.md for why there is not a second one.

  // -- app --
  // The id stays `app.preferences` because the application menu dispatches it;
  // the *label* is what the user reads, and everywhere else in the app — the
  // sidebar's bottom-left button, the menu item, the page's own title — this
  // is called Settings.
  { id: 'app.preferences', keys: ['mod+,'], label: 'Settings', scope: 'global', group: 'App' },
  {
    id: 'app.shortcuts',
    keys: ['mod+/'],
    label: 'Keyboard shortcuts',
    scope: 'global',
    group: 'App',
  },

  // -- terminal --
  {
    id: 'terminal.find',
    keys: ['mod+f'],
    label: 'Find in the terminal',
    scope: 'terminal',
    group: 'Terminal',
  },
  {
    id: 'terminal.clear',
    keys: ['mod+shift+k'],
    label: 'Clear the terminal',
    scope: 'terminal',
    group: 'Terminal',
  },
  {
    id: 'terminal.copy',
    keys: ['mod+shift+c'],
    label: 'Copy the selection',
    scope: 'terminal',
    group: 'Terminal',
  },
  {
    id: 'terminal.interrupt',
    keys: ['ctrl+c'],
    // Short on purpose: the `passes through` chip beside it already says the
    // app does not intercept it, and a label that repeats the chip wraps onto
    // a second line in the sheet for no gain.
    label: 'Interrupt the agent',
    scope: 'terminal',
    group: 'Terminal',
    passthrough: true,
  },
  {
    id: 'terminal.escape',
    keys: ['escape'],
    label: 'Stop what the agent is doing',
    scope: 'terminal',
    group: 'Terminal',
    passthrough: true,
  },

  // -- dialogs --
  { id: 'modal.close', keys: ['escape'], label: 'Close', scope: 'modal', group: 'Dialogs' },
  { id: 'modal.confirm', keys: ['mod+enter'], label: 'Confirm', scope: 'modal', group: 'Dialogs' },
  { id: 'modal.next', keys: ['down'], label: 'Next item', scope: 'modal', group: 'Dialogs' },
  { id: 'modal.previous', keys: ['up'], label: 'Previous item', scope: 'modal', group: 'Dialogs' },
]

export interface KeymapGroup {
  scope: KeyScope
  title: string
  hint: string
  bindings: KeyBinding[]
}

/**
 * The keymap arranged for display: by scope, then by the group each binding
 * declares, preserving table order inside each so related commands stay
 * together instead of being alphabetised apart.
 */
export function groupedKeymap(bindings: readonly KeyBinding[] = KEYMAP): KeymapGroup[] {
  const scopes: KeyScope[] = ['global', 'terminal', 'modal']
  return scopes
    .map((scope) => ({
      scope,
      title: SCOPE_TITLES[scope],
      hint: SCOPE_HINTS[scope],
      bindings: bindings.filter((b) => b.scope === scope),
    }))
    .filter((group) => group.bindings.length > 0)
}

/** Case-insensitive search over the label, the group and the rendered keys. */
export function searchKeymap(
  query: string,
  bindings: readonly KeyBinding[] = KEYMAP,
  isMac: boolean = detectMac(),
): KeyBinding[] {
  const terms = query.toLowerCase().split(/\s+/).filter(Boolean)
  if (terms.length === 0) return [...bindings]
  return bindings.filter((binding) => {
    const haystack = [
      binding.label,
      binding.group,
      binding.id,
      ...formatBinding(binding, isMac),
      ...binding.keys,
    ]
      .join(' ')
      .toLowerCase()
    return terms.every((term) => haystack.includes(term))
  })
}

/**
 * The chord to print beside a command, for this platform, or null.
 *
 * The reason this exists rather than a hand-typed string in the caller: the
 * sidebar used to carry its own `⌘1` / `⌘2` / `⌘3` tooltips, and every one of
 * them was wrong — ⌘1–9 jumps between open sessions, and those views are bound
 * to ⌘⇧D / ⌘⇧E / ⌘⇧G. A tooltip nobody can act on is worse than no tooltip.
 */
export function chordFor(id: string, isMac: boolean = detectMac()): string | null {
  const binding = KEYMAP.find((b) => b.id === id && !b.passthrough)
  if (!binding) return null
  return formatBinding(binding, isMac)[0] ?? null
}

/** A tooltip: the label, and the chord in brackets when there is one. */
export function tip(label: string, id: string, isMac: boolean = detectMac()): string {
  const chord = chordFor(id, isMac)
  return chord ? `${label} (${chord})` : label
}

/** Command ids with no handler — lets the app assert the sheet is not lying. */
export function unhandledCommands(
  handled: Iterable<string>,
  bindings: readonly KeyBinding[] = KEYMAP,
): string[] {
  const known = new Set(handled)
  return bindings.filter((b) => !b.passthrough && !known.has(b.id)).map((b) => b.id)
}

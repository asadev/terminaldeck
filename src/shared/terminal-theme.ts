/**
 * The terminal's colours, declared once for every client this app has.
 *
 * ## Why this file exists at all
 *
 * Four programs draw a session in this product — the desktop renderer, the
 * browser client, the iOS app, and whatever the next one is — and until now each
 * of them carried its own palette as literals. `TerminalView.tsx` read the
 * app's CSS custom properties, `pwa/src/terminal.ts` restated them as two
 * objects, and the phone had a third copy in Swift. Three copies of one set of
 * colours is three sets of colours, and the way anybody finds out is by opening
 * the same session on two devices and seeing two different terminals.
 *
 * So the *scheme* is declared here, in `src/shared`, which every client can
 * reach: the desktop and the browser import this module directly, and the iOS
 * app mirrors it. A colour changed here is changed everywhere or it is a
 * compile error somewhere — which is the only arrangement that survives a
 * fourth client.
 *
 * ## What a scheme is, exactly
 *
 * Twenty-one colours: five that describe the surface and the marks on it, and
 * the sixteen a program actually prints in. The names are xterm.js's own
 * (`ITheme`), deliberately — this shape is handed almost verbatim to the
 * emulator, so a slot named here that the emulator does not have is a slot
 * that silently does nothing, and a translation table between the two would be
 * one more copy to keep in step.
 *
 * There is no `light` or `dark` flag on a scheme, and that is a decision rather
 * than an omission. A flag is a claim a person can falsify by editing the
 * background — which is exactly what the editor lets them do — and a scheme
 * whose flag says "dark" over a white ground would then be wrong in the one
 * place the flag is read. {@link isLightScheme} measures the background instead,
 * so the answer cannot drift from the colours.
 *
 * ## Where the published palettes came from
 *
 * Every scheme below that is somebody else's carries the source it was taken
 * from, in a comment above it, and the values are that source's own. Nothing is
 * eyeballed or re-derived: a palette people recognise is only recognisable if
 * it is the palette, and "close to Nord" is worse than not shipping Nord.
 */

/* ------------------------------------------------------------------ shape -- */

/**
 * The sixteen, in the order the wire numbers them.
 *
 * ANSI 30–37 then 90–97, which is also the order every published scheme is
 * written in, so a palette can be read off its source top to bottom without
 * anybody re-ordering it on the way in.
 */
export const ANSI_SLOTS = [
  'black',
  'red',
  'green',
  'yellow',
  'blue',
  'magenta',
  'cyan',
  'white',
  'brightBlack',
  'brightRed',
  'brightGreen',
  'brightYellow',
  'brightBlue',
  'brightMagenta',
  'brightCyan',
  'brightWhite',
] as const

export type AnsiSlot = (typeof ANSI_SLOTS)[number]

/** The surface, and the marks this app puts on it rather than a program. */
export const SURFACE_SLOTS = [
  'background',
  'foreground',
  'cursor',
  'cursorAccent',
  'selectionBackground',
] as const

export type SurfaceSlot = (typeof SURFACE_SLOTS)[number]

/** Every colour a scheme holds, surface first — the order the editor draws. */
export const COLOUR_SLOTS = [...SURFACE_SLOTS, ...ANSI_SLOTS] as const

export type ColourSlot = SurfaceSlot | AnsiSlot

/**
 * A terminal colour scheme.
 *
 * `id` is the stable key — what gets stored, and what a saved choice points at
 * through a rename. `name` is the only field a person ever sees.
 */
export interface TerminalScheme {
  id: string
  name: string
  background: string
  foreground: string
  cursor: string
  cursorAccent: string
  selectionBackground: string
  black: string
  red: string
  green: string
  yellow: string
  blue: string
  magenta: string
  cyan: string
  white: string
  brightBlack: string
  brightRed: string
  brightGreen: string
  brightYellow: string
  brightBlue: string
  brightMagenta: string
  brightCyan: string
  brightWhite: string
}

/**
 * What each slot is called on screen.
 *
 * Sentence case and no jargon where there is a plain word: a person changing
 * the colour of the block under the cursor is not looking for `cursorAccent`.
 * The sixteen keep their ANSI names, because those are what the documentation
 * of every program that prints in colour calls them.
 */
export const SLOT_LABELS: Readonly<Record<ColourSlot, string>> = {
  background: 'Background',
  foreground: 'Text',
  cursor: 'Cursor',
  cursorAccent: 'Text under the cursor',
  selectionBackground: 'Selection',
  black: 'Black',
  red: 'Red',
  green: 'Green',
  yellow: 'Yellow',
  blue: 'Blue',
  magenta: 'Magenta',
  cyan: 'Cyan',
  white: 'White',
  brightBlack: 'Bright black',
  brightRed: 'Bright red',
  brightGreen: 'Bright green',
  brightYellow: 'Bright yellow',
  brightBlue: 'Bright blue',
  brightMagenta: 'Bright magenta',
  brightCyan: 'Bright cyan',
  brightWhite: 'Bright white',
}

/* ------------------------------------------------------------- the colour -- */

const HEX = /^#(?:[0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$/i

/**
 * A colour, in the one form everything downstream can take.
 *
 * `#rgb` and `#rgba` are expanded, everything is lower-cased, and anything else
 * is refused. Refusing is the point: a scheme is stored as text and imported
 * from a file somebody found, so the only thing standing between `"red"` — or a
 * `javascript:` URL — and the emulator's theme object is this function.
 *
 * Eight digits are allowed because the selection genuinely needs them. xterm.js
 * parses `#rrggbbaa`, a selection is drawn *under* text that has to stay
 * readable, and every alternative is worse: an opaque selection hides the
 * foreground it covers, and a separate opacity field would be a twenty-second
 * value in a shape whose whole promise is twenty-one.
 */
export function normaliseColour(value: unknown): string | null {
  if (typeof value !== 'string') return null
  const text = value.trim().toLowerCase()
  if (!HEX.test(text)) return null
  if (text.length === 4 || text.length === 5) {
    // #rgb → #rrggbb, #rgba → #rrggbbaa. Doubling each digit is the expansion
    // CSS itself specifies, so a three-digit colour means here what it means
    // in the sheet somebody copied it out of.
    return `#${[...text.slice(1)].map((digit) => digit + digit).join('')}`
  }
  return text
}

/** The six-digit part, for a control that cannot express transparency. */
export function opaquePart(colour: string): string {
  const normalised = normaliseColour(colour) ?? '#000000'
  return normalised.slice(0, 7)
}

/** The two alpha digits, or '' when the colour is opaque. */
export function alphaPart(colour: string): string {
  const normalised = normaliseColour(colour) ?? '#000000'
  return normalised.length === 9 ? normalised.slice(7) : ''
}

/** sRGB channels, 0–255. Alpha is dropped: nothing below reads it. */
function channels(colour: string): [number, number, number] {
  const hex = opaquePart(colour)
  return [
    Number.parseInt(hex.slice(1, 3), 16),
    Number.parseInt(hex.slice(3, 5), 16),
    Number.parseInt(hex.slice(5, 7), 16),
  ]
}

/** WCAG relative luminance. Used for the light/dark question and for contrast. */
export function relativeLuminance(colour: string): number {
  const [r, g, b] = channels(colour).map((channel) => {
    const value = channel / 255
    return value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4
  })
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

/** The WCAG ratio, 1–21. The editor reports the one that matters: text on paper. */
export function contrastRatio(a: string, b: string): number {
  const first = relativeLuminance(a)
  const second = relativeLuminance(b)
  const lighter = Math.max(first, second)
  const darker = Math.min(first, second)
  return (lighter + 0.05) / (darker + 0.05)
}

/**
 * Is this a scheme for a light room?
 *
 * Measured off the background rather than declared, for the reason the shape
 * comment gives. The threshold is the midpoint of the luminance range, which
 * puts every scheme below on the side its own name claims — Solarized Light at
 * 0.87, One Half Light at 0.96, and the darkest light scheme still far above
 * the lightest dark one (Nord's ground is 0.04).
 */
export function isLightScheme(scheme: TerminalScheme): boolean {
  return relativeLuminance(scheme.background) > 0.5
}

/* ---------------------------------------------------------- the built-ins -- */

/** The app's own dark sixteen — Tango, which is what a session has always shown. */
const APP_ANSI_DARK = {
  black: '#2e3436',
  red: '#cc0000',
  green: '#4e9a06',
  yellow: '#c4a000',
  blue: '#3465a4',
  magenta: '#75507b',
  cyan: '#06989a',
  white: '#d3d7cf',
  brightBlack: '#555753',
  brightRed: '#ef2929',
  brightGreen: '#8ae234',
  brightYellow: '#fce94f',
  brightBlue: '#729fcf',
  brightMagenta: '#ad7fa8',
  brightCyan: '#34e2e2',
  brightWhite: '#eeeeec',
} as const

/**
 * The app's light sixteen — the dark set walked down its own hue lines.
 *
 * Not a second palette: `tokens.css` derives these by scaling all three
 * channels toward black by one factor, which preserves hue and saturation and
 * moves only value, and `tokens.test.ts` asserts that derivation. They are
 * restated here because a stylesheet cannot be imported into a colour object,
 * and `terminal-theme.test.ts` holds this copy against that sheet.
 */
const APP_ANSI_LIGHT = {
  black: '#2e3436',
  red: '#cc0000',
  green: '#3b7405',
  yellow: '#7c6500',
  blue: '#3465a4',
  magenta: '#75507b',
  cyan: '#057375',
  white: '#d3d7cf',
  brightBlack: '#555753',
  brightRed: '#951a1a',
  brightGreen: '#335413',
  brightYellow: '#534d1a',
  brightBlue: '#384e65',
  brightMagenta: '#5d445b',
  brightCyan: '#135454',
  brightWhite: '#eeeeec',
} as const

/**
 * The scheme id that means "keep following the app's own light/dark".
 *
 * Not a scheme — a *refusal* to pin one, and the default. It is what every
 * install has effectively been on since the app existed: the terminal takes its
 * ground and its ink from the theme, so switching the window to light switched
 * the session with it. Somebody who has never opened this pane must keep that
 * behaviour exactly, which is what an id outside the list buys.
 *
 * The moment a real scheme is chosen, that link is cut on purpose — see
 * {@link FOLLOW_APP_SCHEME_ID} in the settings pane's copy. A person who picks
 * Solarized Light has picked Solarized Light, and a terminal that threw it away
 * because the desktop went dark at sunset would be the app overruling the one
 * choice this whole screen exists to offer.
 */
export const FOLLOW_APP_SCHEME_ID = 'follow-app'

/**
 * Everything shipped, in the order the picker draws them.
 *
 * The app's own two first, because they are what the window already looks like;
 * then the two Asad named — pure black and a dark grey; then the palettes people
 * arrive already knowing. Each of those carries its source above it.
 */
export const BUILTIN_SCHEMES: readonly TerminalScheme[] = [
  /* The app's dark theme, as a scheme. Values are `tokens.css`'s own
     --terminal-bg / --terminal-fg / --accent and the dark ANSI block. */
  {
    id: 'deck-dark',
    name: 'Deck Dark',
    background: '#191919',
    foreground: '#ededed',
    cursor: '#3b8fee',
    cursorAccent: '#191919',
    /* --accent-soft is rgba(59,143,238,0.16); 0.16 × 255 rounds to 0x29. */
    selectionBackground: '#3b8fee29',
    ...APP_ANSI_DARK,
  },
  /* And its light theme. The paper is deliberately not the chrome's white:
     a white terminal on a white toolbar stops looking like a terminal. */
  {
    id: 'deck-light',
    name: 'Deck Light',
    background: '#e8e8e8',
    foreground: '#141414',
    cursor: '#1a66c4',
    cursorAccent: '#e8e8e8',
    /* --accent-soft in the light theme is rgba(26,102,196,0.1) → 0x1a. */
    selectionBackground: '#1a66c41a',
    ...APP_ANSI_LIGHT,
  },
  /*
   * The one he asked for by name: *"we can choose pure black as background"*.
   *
   * The app's dark scheme over a true black ground rather than a new palette —
   * the sixteen were drawn for a near-black surface and are exactly as legible
   * on #000000. The selection is a step heavier than the app's, because
   * sixteen per cent of the accent over #191919 is visible and over black is
   * very nearly not.
   */
  {
    id: 'pure-black',
    name: 'Pure Black',
    background: '#000000',
    foreground: '#ededed',
    cursor: '#3b8fee',
    cursorAccent: '#000000',
    selectionBackground: '#3b8fee3d',
    ...APP_ANSI_DARK,
  },
  /* The other end of the same idea: a ground light enough to read as grey
     rather than as black, for a bright room. */
  {
    id: 'dark-grey',
    name: 'Dark Grey',
    background: '#262626',
    foreground: '#ededed',
    cursor: '#3b8fee',
    cursorAccent: '#262626',
    selectionBackground: '#3b8fee33',
    ...APP_ANSI_DARK,
  },
  /* Solarized Dark — Ethan Schoonover, ethanschoonover.com/solarized.
     base03 ground, base0 ink, and the accent set unchanged. */
  {
    id: 'solarized-dark',
    name: 'Solarized Dark',
    background: '#002b36',
    foreground: '#839496',
    cursor: '#93a1a1',
    cursorAccent: '#002b36',
    selectionBackground: '#073642',
    black: '#073642',
    red: '#dc322f',
    green: '#859900',
    yellow: '#b58900',
    blue: '#268bd2',
    magenta: '#d33682',
    cyan: '#2aa198',
    white: '#eee8d5',
    brightBlack: '#002b36',
    brightRed: '#cb4b16',
    brightGreen: '#586e75',
    brightYellow: '#657b83',
    brightBlue: '#839496',
    brightMagenta: '#6c71c4',
    brightCyan: '#93a1a1',
    brightWhite: '#fdf6e3',
  },
  /* Solarized Light — the same palette, same source, base3 ground and base00
     ink. The sixteen are identical to the dark scheme's by design: that
     invariance is the whole claim Solarized makes. */
  {
    id: 'solarized-light',
    name: 'Solarized Light',
    background: '#fdf6e3',
    foreground: '#657b83',
    cursor: '#586e75',
    cursorAccent: '#fdf6e3',
    selectionBackground: '#eee8d5',
    black: '#073642',
    red: '#dc322f',
    green: '#859900',
    yellow: '#b58900',
    blue: '#268bd2',
    magenta: '#d33682',
    cyan: '#2aa198',
    white: '#eee8d5',
    brightBlack: '#002b36',
    brightRed: '#cb4b16',
    brightGreen: '#586e75',
    brightYellow: '#657b83',
    brightBlue: '#839496',
    brightMagenta: '#6c71c4',
    brightCyan: '#93a1a1',
    brightWhite: '#fdf6e3',
  },
  /* Nord — nordtheme.com. nord0 ground, nord4 ink; the sixteen are the
     project's own terminal mapping (nord1/3 for the two blacks, nord7 for
     bright cyan, nord5/6 for the two whites). */
  {
    id: 'nord',
    name: 'Nord',
    background: '#2e3440',
    foreground: '#d8dee9',
    cursor: '#d8dee9',
    cursorAccent: '#2e3440',
    selectionBackground: '#434c5e',
    black: '#3b4252',
    red: '#bf616a',
    green: '#a3be8c',
    yellow: '#ebcb8b',
    blue: '#81a1c1',
    magenta: '#b48ead',
    cyan: '#88c0d0',
    white: '#e5e9f0',
    brightBlack: '#4c566a',
    brightRed: '#bf616a',
    brightGreen: '#a3be8c',
    brightYellow: '#ebcb8b',
    brightBlue: '#81a1c1',
    brightMagenta: '#b48ead',
    brightCyan: '#8fbcbb',
    brightWhite: '#eceff4',
  },
  /* Dracula — draculatheme.com, the project's published ANSI set. */
  {
    id: 'dracula',
    name: 'Dracula',
    background: '#282a36',
    foreground: '#f8f8f2',
    cursor: '#f8f8f2',
    cursorAccent: '#282a36',
    selectionBackground: '#44475a',
    black: '#21222c',
    red: '#ff5555',
    green: '#50fa7b',
    yellow: '#f1fa8c',
    blue: '#bd93f9',
    magenta: '#ff79c6',
    cyan: '#8be9fd',
    white: '#f8f8f2',
    brightBlack: '#6272a4',
    brightRed: '#ff6e6e',
    brightGreen: '#69ff94',
    brightYellow: '#ffffa5',
    brightBlue: '#d6acff',
    brightMagenta: '#ff92df',
    brightCyan: '#a4ffff',
    brightWhite: '#ffffff',
  },
  /* Gruvbox Dark — morhetz/gruvbox, the "dark medium" ground with the
     neutral/bright pairs the palette defines. */
  {
    id: 'gruvbox-dark',
    name: 'Gruvbox Dark',
    background: '#282828',
    foreground: '#ebdbb2',
    cursor: '#ebdbb2',
    cursorAccent: '#282828',
    selectionBackground: '#504945',
    black: '#282828',
    red: '#cc241d',
    green: '#98971a',
    yellow: '#d79921',
    blue: '#458588',
    magenta: '#b16286',
    cyan: '#689d6a',
    white: '#a89984',
    brightBlack: '#928374',
    brightRed: '#fb4934',
    brightGreen: '#b8bb26',
    brightYellow: '#fabd2f',
    brightBlue: '#83a598',
    brightMagenta: '#d3869b',
    brightCyan: '#8ec07c',
    brightWhite: '#ebdbb2',
  },
  /* One Half Dark — sonph/onehalf. */
  {
    id: 'one-half-dark',
    name: 'One Half Dark',
    background: '#282c34',
    foreground: '#dcdfe4',
    cursor: '#dcdfe4',
    cursorAccent: '#282c34',
    selectionBackground: '#474e5d',
    black: '#282c34',
    red: '#e06c75',
    green: '#98c379',
    yellow: '#e5c07b',
    blue: '#61afef',
    magenta: '#c678dd',
    cyan: '#56b6c2',
    white: '#dcdfe4',
    brightBlack: '#5a6374',
    brightRed: '#e06c75',
    brightGreen: '#98c379',
    brightYellow: '#e5c07b',
    brightBlue: '#61afef',
    brightMagenta: '#c678dd',
    brightCyan: '#56b6c2',
    brightWhite: '#dcdfe4',
  },
  /* One Half Light — the same project's light half. */
  {
    id: 'one-half-light',
    name: 'One Half Light',
    background: '#fafafa',
    foreground: '#383a42',
    cursor: '#383a42',
    cursorAccent: '#fafafa',
    selectionBackground: '#bfceff',
    black: '#383a42',
    red: '#e45649',
    green: '#50a14f',
    yellow: '#c18301',
    blue: '#0184bc',
    magenta: '#a626a4',
    cyan: '#0997b3',
    white: '#fafafa',
    brightBlack: '#4f525d',
    brightRed: '#df6c75',
    brightGreen: '#98c379',
    brightYellow: '#e4c07a',
    brightBlue: '#61afef',
    brightMagenta: '#c577dd',
    brightCyan: '#56b5c1',
    brightWhite: '#ffffff',
  },
  /* Tango Dark — the GNOME Tango palette over a black ground. This is where
     the app's own dark sixteen came from, which is why the two look related:
     the difference is the ground and the ink, not the palette. */
  {
    id: 'tango',
    name: 'Tango Dark',
    background: '#000000',
    foreground: '#d3d7cf',
    cursor: '#ffffff',
    cursorAccent: '#000000',
    selectionBackground: '#ffffff40',
    black: '#000000',
    red: '#cc0000',
    green: '#4e9a06',
    yellow: '#c4a000',
    blue: '#3465a4',
    magenta: '#75507b',
    cyan: '#06989a',
    white: '#d3d7cf',
    brightBlack: '#555753',
    brightRed: '#ef2929',
    brightGreen: '#8ae234',
    brightYellow: '#fce94f',
    brightBlue: '#729fcf',
    brightMagenta: '#ad7fa8',
    brightCyan: '#34e2e2',
    brightWhite: '#eeeeec',
  },
  /* Campbell — the palette that ships as the default on Windows, and the one
     most people arriving from that platform already have in their eye. */
  {
    id: 'campbell',
    name: 'Campbell',
    background: '#0c0c0c',
    foreground: '#cccccc',
    cursor: '#ffffff',
    cursorAccent: '#0c0c0c',
    selectionBackground: '#ffffff40',
    black: '#0c0c0c',
    red: '#c50f1f',
    green: '#13a10e',
    yellow: '#c19c00',
    blue: '#0037da',
    magenta: '#881798',
    cyan: '#3a96dd',
    white: '#cccccc',
    brightBlack: '#767676',
    brightRed: '#e74856',
    brightGreen: '#16c60c',
    brightYellow: '#f9f1a5',
    brightBlue: '#3b78ff',
    brightMagenta: '#b4009e',
    brightCyan: '#61d6d6',
    brightWhite: '#f2f2f2',
  },
]

/** The two the app falls back to when nothing is pinned. */
export function appScheme(appearance: 'dark' | 'light'): TerminalScheme {
  const id = appearance === 'light' ? 'deck-light' : 'deck-dark'
  // Non-null by construction: both ids are declared above, and
  // `terminal-theme.test.ts` fails if either one is ever renamed away.
  return BUILTIN_SCHEMES.find((scheme) => scheme.id === id) as TerminalScheme
}

/* --------------------------------------------------------------- lookup -- */

/**
 * The scheme an id names, searching the person's own copies first.
 *
 * Customs win a collision on purpose. An id can only collide by being imported
 * or hand-edited to match a built-in, and in that case the one somebody made is
 * the one they meant — a built-in they cannot see past would be a scheme that
 * cannot be deleted either.
 */
export function schemeById(
  id: string,
  customs: readonly TerminalScheme[] = [],
): TerminalScheme | null {
  return (
    customs.find((scheme) => scheme.id === id) ??
    BUILTIN_SCHEMES.find((scheme) => scheme.id === id) ??
    null
  )
}

/** Whether an id belongs to a scheme this build ships — i.e. cannot be edited. */
export function isBuiltinId(id: string): boolean {
  return BUILTIN_SCHEMES.some((scheme) => scheme.id === id)
}

/**
 * One colour changed, as a new scheme.
 *
 * A refused colour returns the scheme unchanged rather than throwing: this is
 * called from a text field on every keystroke, and half a hex code is a normal
 * thing for that field to hold for a moment.
 */
export function withColour(
  scheme: TerminalScheme,
  slot: ColourSlot,
  value: string,
): TerminalScheme {
  const colour = normaliseColour(value)
  if (colour === null) return scheme
  return { ...scheme, [slot]: colour }
}

/* --------------------------------------------------------------- copies -- */

/** How many of somebody's own schemes are kept. */
export const MAX_CUSTOM_SCHEMES = 40

/**
 * The name a copy gets.
 *
 * *"(yours)"* rather than *"(copy)"*, because it answers the question somebody
 * asks when they see two Draculas in the list: which of these is the one I
 * changed. Copying a copy does not stack the suffix.
 */
export function copyName(name: string): string {
  return name.endsWith(' (yours)') ? name : `${name} (yours)`
}

/** An id nothing else is using. */
export function newCustomId(taken: readonly string[]): string {
  const used = new Set(taken)
  for (let n = 1; ; n += 1) {
    const id = `custom-${n}`
    if (!used.has(id)) return id
  }
}

/**
 * A person's copy of a scheme, ready to store.
 *
 * Editing a built-in never overwrites it — the picker keeps every shipped
 * palette exactly as published, which is the only way "Nord" can go on meaning
 * Nord. What an edit produces is this.
 */
export function copyOf(
  scheme: TerminalScheme,
  taken: readonly string[],
  name = copyName(scheme.name),
): TerminalScheme {
  return { ...scheme, id: newCustomId(taken), name }
}

/* ------------------------------------------------------------- transport -- */

/**
 * The alias keys a scheme file from elsewhere uses.
 *
 * A scheme copied off the internet is nearly always in the JSON shape the
 * Windows terminal ships — which is this shape with three different spellings:
 * `cursorColor` for the cursor, and `purple`/`brightPurple` for the two
 * magentas. Accepting those costs six lines and is the difference between
 * "paste a scheme you found" working and not.
 */
const ALIASES: Readonly<Record<string, ColourSlot>> = {
  cursorColor: 'cursor',
  purple: 'magenta',
  brightPurple: 'brightMagenta',
}

/** Anything a scheme file might be, before it is known to be one. */
function record(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null
}

/** Every colour present and legal, and a name. Nothing else is a scheme. */
export function isTerminalScheme(value: unknown): value is TerminalScheme {
  const raw = record(value)
  if (raw === null) return false
  if (typeof raw.id !== 'string' || raw.id === '') return false
  if (typeof raw.name !== 'string' || raw.name === '') return false
  return COLOUR_SLOTS.every((slot) => normaliseColour(raw[slot]) !== null)
}

/** The longest a scheme's name may be. Long enough for a published name. */
export const MAX_SCHEME_NAME = 48

/** Trimmed, collapsed and cut to length; '' when there is nothing left. */
export function cleanName(raw: unknown): string {
  if (typeof raw !== 'string') return ''
  return raw.replace(/\s+/g, ' ').trim().slice(0, MAX_SCHEME_NAME)
}

export type ParseResult =
  | { readonly ok: true; readonly scheme: TerminalScheme }
  | { readonly ok: false; readonly problem: string }

/**
 * A scheme out of pasted text.
 *
 * Three shapes are accepted and they are all the same shape: this app's own
 * export, the same object under the alias spellings above, and either of those
 * wrapped in `{ "schemes": [ … ] }`, which is how a whole settings file carries
 * them — pasting one of those takes the first scheme in it rather than refusing,
 * because somebody who pastes a file of schemes has picked the file, not the
 * scheme, and refusing would send them back to an editor to cut one out.
 *
 * A missing colour is named in the refusal. "Not a valid scheme" is the message
 * that makes somebody paste the same thing again; naming `brightCyan` is the one
 * that gets it fixed.
 */
export function parseScheme(text: string, taken: readonly string[] = []): ParseResult {
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    return { ok: false, problem: 'That is not JSON — check for a missing brace or comma.' }
  }

  let raw = record(parsed)
  if (raw === null) return { ok: false, problem: 'A scheme is a JSON object.' }

  const list = raw.schemes
  if (Array.isArray(list)) {
    const first = record(list[0])
    if (first === null) return { ok: false, problem: 'That file has no schemes in it.' }
    raw = first
  }

  const colours: Partial<Record<ColourSlot, string>> = {}
  const missing: string[] = []
  for (const slot of COLOUR_SLOTS) {
    const alias = Object.entries(ALIASES).find(([, target]) => target === slot)?.[0]
    const direct = normaliseColour(raw[slot])
    const aliased = alias === undefined ? null : normaliseColour(raw[alias])
    const colour = direct ?? aliased
    if (colour === null) missing.push(slot)
    else colours[slot] = colour
  }

  /*
   * Two of the twenty-one are allowed to be absent, and only these two.
   *
   * Almost no published scheme states `cursorAccent` — the colour of the
   * character *under* a block cursor — and a good half do not state a
   * selection either. Both have an obvious right answer taken from the scheme
   * itself (the ground, and the ground lifted toward the ink), so refusing a
   * paste over them would reject most of the schemes in the world for a field
   * their authors never had.
   */
  const still = missing.filter(
    (slot) => slot !== 'cursorAccent' && slot !== 'selectionBackground',
  )
  if (still.length > 0) {
    /*
     * The missing slots by name, and at most three of them.
     *
     * "Not a valid scheme" is the message that makes somebody paste the same
     * thing again; naming `brightCyan` is the one that gets it fixed. Three is
     * where a list stops being readable — a paste of something that is not a
     * scheme at all is missing all twenty-one, and printing twenty-one field
     * names at somebody is a wall, not an error.
     */
    const named = still.slice(0, 3).map((slot) => SLOT_LABELS[slot as ColourSlot].toLowerCase())
    const rest = still.length - named.length
    const list =
      named.length === 1
        ? named[0]
        : `${named.slice(0, -1).join(', ')} or ${named[named.length - 1]}`
    return {
      ok: false,
      problem: `That scheme has no ${list}${rest > 0 ? `, and ${rest} more` : ''}.`,
    }
  }
  const background = colours.background as string
  colours.cursorAccent ??= background
  colours.selectionBackground ??= `${opaquePart(colours.foreground as string)}40`

  const name = cleanName(raw.name)
  const wanted = typeof raw.id === 'string' ? raw.id : ''
  return {
    ok: true,
    scheme: {
      ...(colours as Record<ColourSlot, string>),
      // An imported id is never trusted: it would let a paste silently take over
      // a scheme already in the list, and two schemes with one id is a picker
      // that cannot show both.
      id: newCustomId(taken),
      name: name === '' ? (wanted === '' ? 'Imported scheme' : cleanName(wanted)) : name,
    } as TerminalScheme,
  }
}

/**
 * A scheme as text, for somebody to keep or send.
 *
 * The canonical keys, plus the three aliases, so one paste works in this app
 * and in the other one. Two spellings of one colour cannot disagree here: the
 * alias is written from the same field it duplicates, on the line below it.
 */
export function exportScheme(scheme: TerminalScheme): string {
  const out: Record<string, string> = { name: scheme.name, id: scheme.id }
  for (const slot of COLOUR_SLOTS) out[slot] = scheme[slot]
  out.cursorColor = scheme.cursor
  out.purple = scheme.magenta
  out.brightPurple = scheme.brightMagenta
  return `${JSON.stringify(out, null, 2)}\n`
}

/* --------------------------------------------------------------- storage -- */

/**
 * Where the chosen scheme is stored, and where each of somebody's own lives.
 *
 * **Per machine, not per session and not per person.** A scheme is a fact about
 * the screen it is read on — the panel, the room's light, the eyes in front of
 * it — so it belongs beside the terminal's font size and font family, which are
 * already per install, in this app's `settings.json`. Per session would mean
 * every new terminal starts on the default and somebody re-picks their colours
 * all day; per account would carry a laptop's colours onto a machine plugged
 * into a projector.
 *
 * ## Why one settings key per custom scheme
 *
 * `settings-store.ts` stores primitives and cuts a string at 4096 characters,
 * silently. One key holding a JSON array of everybody's schemes would therefore
 * work perfectly until the ninth or tenth, and then truncate — losing not the
 * newest scheme but *the whole list*, at a length nothing announces. A key each
 * is ~600 characters, can never approach the cap, and deleting one is a null
 * patch on its own key rather than a rewrite of a list.
 */
export const TERMINAL_SCHEME_SETTING = 'appearance.terminalScheme'

/** Every one of somebody's own schemes is a key under this. */
export const CUSTOM_SCHEME_PREFIX = 'appearance.terminalScheme.custom.'

export function customSchemeKey(id: string): string {
  return `${CUSTOM_SCHEME_PREFIX}${id}`
}

/**
 * The schemes somebody has made, read out of a settings map.
 *
 * Anything unreadable under the prefix is skipped rather than thrown on. A
 * settings file is shared with the build that runs next, and one bad key must
 * not be able to take the whole picker down with it.
 */
export function customSchemesFrom(values: Readonly<Record<string, unknown>>): TerminalScheme[] {
  const out: TerminalScheme[] = []
  for (const [key, value] of Object.entries(values)) {
    if (!key.startsWith(CUSTOM_SCHEME_PREFIX)) continue
    if (typeof value !== 'string' || value === '') continue
    let parsed: unknown
    try {
      parsed = JSON.parse(value)
    } catch {
      continue
    }
    const id = key.slice(CUSTOM_SCHEME_PREFIX.length)
    const raw = record(parsed)
    if (raw === null) continue
    const candidate = { ...raw, id }
    if (isTerminalScheme(candidate)) out.push(candidate)
  }
  return out.sort((a, b) => a.name.localeCompare(b.name))
}

/** One scheme, as the string its key holds. */
export function storedScheme(scheme: TerminalScheme): string {
  const out: Record<string, string> = { name: scheme.name }
  for (const slot of COLOUR_SLOTS) out[slot] = scheme[slot]
  return JSON.stringify(out)
}

/* ------------------------------------------------------------- emulator -- */

/**
 * The object xterm.js takes, which is this scheme minus its two labels.
 *
 * Typed structurally rather than as `ITheme` so this module stays free of the
 * emulator: `src/shared` is imported by the main process and by the iOS
 * harness, and pulling `@xterm/xterm` in for a type would put a browser package
 * in both. Every field name matches `ITheme`'s, and the desktop's own test
 * fails if one ever stops matching.
 */
export type XtermTheme = Readonly<Record<ColourSlot, string>>

export function xtermTheme(scheme: TerminalScheme): XtermTheme {
  const out = {} as Record<ColourSlot, string>
  for (const slot of COLOUR_SLOTS) out[slot] = scheme[slot]
  return out
}

/**
 * A line of shell output, as the picker's preview renders it.
 *
 * Declared here rather than in a component because both clients draw it and
 * they have to draw the same one — a preview that differs between the desktop
 * and the browser is two previews of one scheme. Each run names the slot it is
 * printed in, so the preview is a *reading* of the palette rather than a
 * decorative sentence: a scheme whose green has been edited to grey shows it
 * here before anything is applied.
 */
export const PREVIEW_LINE: ReadonlyArray<{ text: string; slot: ColourSlot | 'foreground' }> = [
  { text: '➜ ', slot: 'green' },
  { text: 'app ', slot: 'cyan' },
  { text: 'git:(', slot: 'blue' },
  { text: 'main', slot: 'red' },
  { text: ') ', slot: 'blue' },
  { text: 'npm test', slot: 'foreground' },
]

/**
 * The second preview line: a pass, a warning, a failure.
 *
 * Short on purpose. A card is about two hundred and forty pixels wide and these
 * lines do not wrap — they are terminal output, and terminal output that wraps
 * in a preview reads as a bug in the preview. The first draft carried a file
 * path on the end of this line and every card in the grid ended in an ellipsis.
 */
export const PREVIEW_LINE_TWO: ReadonlyArray<{ text: string; slot: ColourSlot | 'foreground' }> = [
  { text: '✓ 42 passed', slot: 'green' },
  { text: '  ', slot: 'foreground' },
  { text: '! 1 skipped', slot: 'yellow' },
  { text: '  ', slot: 'foreground' },
  { text: '✗ 0', slot: 'red' },
]

/**
 * How dark the scrim outside the focus box is allowed to be, as arithmetic
 * rather than as taste.
 *
 * ## The requirement this exists to make checkable
 *
 * Asad, on what the overlay is for: *"it will make a box around the important
 * thing and other things become dull — decrease the visibility of them and keep
 * the inside-the-box things bright, giving a focus."* And the constraint on top
 * of it: the dimmed part must still be **readable** by somebody who stops to
 * read it. Dim is emphasis, not censorship.
 *
 * Those are two opposing numbers, not one. A scrim light enough to keep every
 * ratio comfortable is a scrim nobody can see; a scrim heavy enough to be
 * unmistakable takes the quietest text in the window below the threshold where
 * it stops being text. So this file states **both ends** and the test beside it
 * fails on either — which matters, because a floor on its own can always be
 * satisfied by making the dim invisible, and that is the failure a well-meaning
 * fix would introduce.
 *
 * ## What the numbers actually are, measured against this app's own palette
 *
 * Both themes, black scrim, contrast of the *dimmed* pair. `keep` is how much
 * of the brighter element's relative luminance survives, which is the honest
 * measure of "does this look dimmer" — contrast is not, because a scrim moves
 * both ends of a pair at once.
 *
 * ```
 *          keep    light: term  muted/sunken     dark: term  muted/tertiary
 *  α=0.18  0.640         10.23          4.18          10.33            3.62
 *  α=0.22  0.572          9.30          4.03           9.42            3.39
 *  α=0.26  0.509          8.43          3.87           8.54            3.16   ← chosen
 *  α=0.30  0.450          7.60          3.70           7.72            2.95   ✗
 *  α=0.38  0.344          6.10          3.33           6.21            2.55   ✗
 *  α=0.45  0.265          4.96          2.99           5.06            2.23   ✗
 * ```
 *
 * Three things fall out of that table, and two of them contradict the design
 * note this was built from (`DRIVING-MODE.md` §3):
 *
 * 1. **The binding pairing is not the terminal.** That note picks the terminal
 *    as "the worst pairing in the window" and budgets against it. It is very
 *    nearly the *best*: `--terminal-fg` on `--terminal-bg` starts at 15:1 in
 *    both themes and has enormous headroom. The pairing that actually fails
 *    first is `--text-muted` on the chrome — the sidebar's section labels, a
 *    timestamp in the chat view — which starts at 4.7–5.0:1 and has almost none.
 *    Budgeting against the terminal permits a scrim that erases every quiet
 *    label in the window while the numbers look fine.
 *
 * 2. **The two themes do not need different alphas.** That note prescribes 0.22
 *    light and 0.45 dark, reasoning that a scrim darkens light text toward its
 *    background but darkens a light *background* along with its dark text. That
 *    is true of contrast and irrelevant to dimming: what a reader perceives as
 *    "dulled" is the drop in the bright element, and a black scrim multiplies
 *    sRGB channels by (1−α) regardless of which element is bright, so `keep` is
 *    the same function in both themes. Same α, same apparent dimming. What does
 *    differ is the *ceiling*: light can afford up to ≈0.44 before its quietest
 *    pairing drops under 3:1, dark only ≈0.28. So the shared value is dark's,
 *    and 0.45 in the dark theme — the note's own recommendation — takes muted
 *    text to **2.23:1**, which is not dim, it is gone.
 *
 * 3. **3:1, not 4.5:1, is the right floor for dimmed text.** 4.5:1 is the bar
 *    for the text a person is reading; it is unreachable here at any visible
 *    alpha (in the dark theme even α=0.05 drops muted-on-secondary to 4.67 and
 *    α=0.10 to 4.32). 3:1 is WCAG's threshold for large text and for non-text
 *    contrast, and it is the line below which glyph shapes stop resolving. It is
 *    the correct bar for content that is deliberately not the subject, and the
 *    terminal — which carries a tour's actual evidence — is held to 4.5:1
 *    separately below.
 */

export type Rgb = readonly [number, number, number]

/**
 * Parse the colour notations `tokens.css` actually uses.
 *
 * Deliberately narrow: `#rrggbb` and `rgb()`/`rgba()` with integer channels.
 * Anything else throws rather than guessing, because a silently-wrong parse
 * here produces a passing test for a budget nobody is keeping. `color-mix()`
 * and `var()` are not accepted — the two tokens this reads are written as
 * literals for exactly that reason, the same way `--terminal-bg` is.
 */
export function parseRgba(value: string): { rgb: Rgb; alpha: number } {
  const text = value.trim()
  const hex = /^#([0-9a-f]{6})$/i.exec(text)
  if (hex) {
    const n = parseInt(hex[1], 16)
    return { rgb: [(n >> 16) & 255, (n >> 8) & 255, n & 255], alpha: 1 }
  }
  const fn = /^rgba?\(\s*([0-9]+)\s*,\s*([0-9]+)\s*,\s*([0-9]+)\s*(?:,\s*([0-9.]+)\s*)?\)$/i.exec(
    text,
  )
  if (fn) {
    return {
      rgb: [Number(fn[1]), Number(fn[2]), Number(fn[3])],
      alpha: fn[4] === undefined ? 1 : Number(fn[4]),
    }
  }
  throw new Error(`not a colour this budget can read: ${value}`)
}

/**
 * `over` composited on `under`, in sRGB space.
 *
 * sRGB and not linear light, because that is what a browser does for a normal
 * `background-color` blend. Compositing in linear light would be more correct
 * physically and would disagree with what is on screen, which makes it wrong
 * for a test whose whole job is to predict the screen.
 */
export function composite(over: { rgb: Rgb; alpha: number }, under: Rgb): Rgb {
  return [0, 1, 2].map((i) => over.rgb[i] * over.alpha + under[i] * (1 - over.alpha)) as unknown as Rgb
}

/** WCAG 2.x relative luminance. Same maths as `styles/tokens.test.ts`. */
export function luminance(colour: Rgb): number {
  const channel = (c: number): number => {
    const s = c / 255
    return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4
  }
  return 0.2126 * channel(colour[0]) + 0.7152 * channel(colour[1]) + 0.0722 * channel(colour[2])
}

/** WCAG 2.x contrast ratio, 1–21. */
export function contrast(a: Rgb, b: Rgb): number {
  const la = luminance(a)
  const lb = luminance(b)
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
}

/** The contrast of a foreground/background pair once the scrim is over both. */
export function dimmedContrast(fg: string, bg: string, scrim: string): number {
  const veil = parseRgba(scrim)
  return contrast(
    composite(veil, parseRgba(fg).rgb),
    composite(veil, parseRgba(bg).rgb),
  )
}

/**
 * The share of a colour's relative luminance that survives the scrim.
 *
 * Fed the *brighter* half of a pair — the paper in a light theme, the ink in a
 * dark one — this is the number a reader perceives as dimming.
 */
export function luminanceKept(colour: string, scrim: string): number {
  const base = parseRgba(colour).rgb
  const before = luminance(base)
  if (before === 0) return 1
  return luminance(composite(parseRgba(scrim), base)) / before
}

/* ------------------------------------------------------------- the budget -- */

/**
 * Dimmed text must still resolve as text.
 *
 * WCAG's large-text and non-text threshold. See the header for why this is 3
 * and not 4.5, and why 4.5 is impossible rather than merely expensive.
 */
export const DIM_MIN_CONTRAST = 3

/**
 * The terminal is held higher, because a tour's evidence is terminal output.
 *
 * A reader whose eye slides one line above the box is reading undimmed-quality
 * text at a dimmed ratio; that line should be as readable as the app's own body
 * copy, not merely legible.
 */
export const DIM_MIN_FOCUS_CONTRAST = 4.5

/**
 * The dim has to be visible, or the box is the only thing doing any work.
 *
 * Without this the whole budget can be satisfied by α ≈ 0.02, which passes
 * every contrast check and produces no focus at all. This is the assertion that
 * makes the pair a *range*.
 */
export const DIM_MAX_LUMINANCE_KEPT = 0.62

/**
 * And it has to stop short of blacking the window out.
 *
 * "Dim is emphasis, not censorship", as a number. Below this the light theme's
 * quietest pairing is already under 3.4:1 and the window reads as disabled
 * rather than as out of focus.
 */
export const DIM_MIN_LUMINANCE_KEPT = 0.3

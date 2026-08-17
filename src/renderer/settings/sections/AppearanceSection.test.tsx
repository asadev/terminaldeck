import { describe, expect, it } from 'vitest'
import { MONO_CANDIDATES, installedFonts } from './AppearanceSection'

/**
 * The terminal-font row, which used to be a row with nothing in it.
 *
 * It rendered as a dim grey `SF Mono` — a placeholder, not a value — with no
 * chevron beside it while Theme and Density both had one, and an unexplained
 * specimen line under it. Worse than the look: a typed font name the system
 * does not have fails *silently*, so the control could not tell you whether
 * what you asked for existed.
 *
 * What replaced it only works if the detection is right, and the detection is
 * the one part of this that can be wrong in a way nobody sees — a false
 * negative simply hides a font. So it is a pure function with the measurement
 * injected, and these are the cases that actually bite.
 */
describe('finding the fonts a machine really has', () => {
  /**
   * A pretend renderer. Every installed face gets its own width; anything not
   * installed falls back to the generic it was listed against, which is exactly
   * what a browser does and exactly what the detection reads.
   */
  const machine =
    (installed: Record<string, number>, generic: Record<string, number>) =>
    (stack: string): number => {
      const named = /^"([^"]+)",\s*(.+)$/.exec(stack)
      if (!named) return generic[stack] ?? 0
      return installed[named[1]] ?? generic[named[2]] ?? 0
    }

  const GENERIC = { serif: 100, 'sans-serif': 110 }

  it('offers a font that is installed', () => {
    const widthOf = machine({ Menlo: 130 }, GENERIC)
    expect(installedFonts(['Menlo', 'Consolas'], widthOf)).toEqual(['Menlo'])
  })

  it('does not offer one that falls back', () => {
    // The whole test: a missing face renders identically to the generic behind
    // it, which is the only signal there is.
    const widthOf = machine({}, GENERIC)
    expect(installedFonts(['Cascadia Code', 'MonoLisa'], widthOf)).toEqual([])
  })

  it('still finds the font the generic itself resolves to', () => {
    /*
     * The bug two baselines exist for.
     *
     * On macOS `monospace` resolves to Menlo, so probing Menlo against
     * `monospace` gives two identical widths and reports the machine's own
     * terminal font as missing. Here the fake machine renders Menlo at the same
     * width as `serif` — a single-baseline check would drop it — and the
     * `sans-serif` probe is what saves it.
     */
    const widthOf = machine({ Menlo: 100 }, GENERIC)
    expect(installedFonts(['Menlo'], widthOf)).toEqual(['Menlo'])
  })

  it('keeps the order the list is written in', () => {
    // The platform's own faces are listed first on purpose, so the menu opens
    // on something the reader recognises rather than alphabetically on "Andale".
    const widthOf = machine({ Menlo: 130, Hack: 140, Monaco: 150 }, GENERIC)
    expect(installedFonts(['Menlo', 'Monaco', 'Hack'], widthOf)).toEqual([
      'Menlo',
      'Monaco',
      'Hack',
    ])
  })

  it('never claims a font that measures as nothing', () => {
    // A canvas that answers 0 to everything is a canvas that cannot measure.
    // Reporting "every font is installed" off that would fill the menu with
    // faces that do not exist — the same silent lie the text field told.
    const widthOf = (): number => 0
    expect(installedFonts(MONO_CANDIDATES, widthOf)).toEqual([])
  })
})

describe('the candidate list', () => {
  it('covers all three desktop platforms, so the menu is never empty', () => {
    // Every desktop this app ships on has at least one of these installed, so
    // "no fonts found" is never the ordinary state of the row.
    for (const shipped of ['Menlo', 'Consolas', 'DejaVu Sans Mono']) {
      expect(MONO_CANDIDATES).toContain(shipped)
    }
  })

  it('lists nothing twice', () => {
    expect(new Set(MONO_CANDIDATES).size).toBe(MONO_CANDIDATES.length)
  })

  it('names faces that are on this machine', () => {
    // Checked against /System/Library/Fonts on the Mac this was written on,
    // rather than assumed: Menlo, Monaco, Courier New, Andale Mono and PT Mono
    // are all shipped by macOS, and SF Mono comes with Terminal.app.
    for (const onThisMac of ['SF Mono', 'Menlo', 'Monaco', 'Andale Mono', 'PT Mono']) {
      expect(MONO_CANDIDATES).toContain(onThisMac)
    }
  })
})

import { readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

const SRC = resolve(__dirname, '..', 'src')

/**
 * The emulator is told, and told through one door.
 *
 * `terminal.ts` is where a colour becomes pixels, and the two ways to get it
 * wrong are both about *order*: a terminal built in the appearance and given
 * its scheme a frame later flashes the wrong colours, and an appearance change
 * arriving after a scheme is pinned must not quietly overrule the pin. Both are
 * pinned here as source, because neither is reachable without a canvas.
 */
describe('the terminal is wired to the scheme', () => {
  it('is built with the scheme rather than corrected afterwards', () => {
    const text = readFileSync(join(SRC, 'terminal.ts'), 'utf8')
    expect(text).toContain('theme: scheme === null ? TERMINAL_THEMES[appearance] : (xtermTheme(scheme) as ITheme)')
    // An appearance change while a scheme is pinned repaints nothing.
    expect(text).toContain('if (pinned === null) term.options.theme = TERMINAL_THEMES[next]')
    // And clearing the scheme lands on the appearance that is on screen now.
    expect(text).toContain('painted = next')
  })
})

import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { UI_COMMANDS, UI_GESTURES } from './ui'

/**
 * Every command the window answers to has a tool or a reason — read from the
 * three files that define them, the way `actions.test.ts` reads the preload.
 *
 * The sources, and why each is one:
 *
 *  - `App.tsx`, between the palette's `commands` list and the end of `run()`:
 *    the palette rows and the aliases the menu bar and chords arrive as.
 *  - `main/menu.ts`: every `send('<id>')` an application-menu item makes.
 *  - `renderer/keymap.ts`: every chord's id, including the ones the terminal
 *    handles itself and the keys inside a dialog.
 *
 * Text rather than imports, for the reason the preload check gives: what is
 * being checked is the set of names, and `App.tsx` cannot be loaded outside a
 * browser.
 */

const SRC = join(__dirname, '../../..')

function appCommands(): string[] {
  const app = readFileSync(join(SRC, 'renderer/App.tsx'), 'utf8')
  const start = app.indexOf('const commands = useMemo<PaletteCommand[]>')
  const end = app.indexOf('window.deck.onMenuCommand', start)
  expect(start, 'the palette list moved; update this reader').toBeGreaterThan(0)
  expect(end, 'the menu dispatcher moved; update this reader').toBeGreaterThan(start)
  const region = app.slice(start, end)
  const found = new Set<string>()
  for (const match of region.matchAll(/\bid: '([a-z][\w.]*)'/g)) found.add(match[1])
  for (const match of region.matchAll(/\bcase '([a-z][\w.]*)':/g)) found.add(match[1])
  // The feature offers are a template, one row per uninstalled feature.
  if (region.includes('`features.install.')) found.add('features.install.*')
  return [...found]
}

function menuCommands(): string[] {
  const menu = readFileSync(join(SRC, 'main/menu.ts'), 'utf8')
  return [...new Set([...menu.matchAll(/\bsend\('([a-z][\w.]*)'\)/g)].map((match) => match[1]))]
}

function chordCommands(): string[] {
  const keymap = readFileSync(join(SRC, 'renderer/keymap.ts'), 'utf8')
  return [...new Set([...keymap.matchAll(/\bid: '([a-z]+\.[\w.]+)'/g)].map((match) => match[1]))]
}

describe('every command the window answers to has a tool or a reason', () => {
  const sources = [...new Set([...appCommands(), ...menuCommands(), ...chordCommands()])].sort()

  it('reads a believable number of commands', () => {
    expect(sources.length).toBeGreaterThan(40)
  })

  it('lists exactly the commands the source has', () => {
    const listed = Object.keys(UI_COMMANDS)
    expect({
      missing: sources.filter((id) => !listed.includes(id)),
      stale: listed.filter((id) => !sources.includes(id)),
    }).toEqual({ missing: [], stale: [] })
  })

  it('has decided every command and every gesture, with a real sentence for each skip', () => {
    const bad = [...Object.entries(UI_COMMANDS), ...Object.entries(UI_GESTURES)].flatMap(([id, entry]) => {
      if (entry === null) return [`${id}: undecided`]
      if ('skip' in entry) return entry.skip.trim().length >= 20 ? [] : [`${id}: skip too short`]
      const ids = typeof entry.tool === 'string' ? [entry.tool] : entry.tool
      return ids.length > 0 && ids.every((tool) => /^[a-z]+(\.[a-zA-Z_]+)+$/.test(tool)) ? [] : [`${id}: bad tool id`]
    })
    expect(bad).toEqual([])
  })
})

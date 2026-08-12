import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { CommandPalette, nextIndex, parseFileQuery, type PaletteCommand } from './CommandPalette'

/**
 * There is no DOM environment in this project's test setup, so these render
 * the palette to static markup instead. That is enough to hold the accessible
 * structure — roles, ids, the combobox wiring — to a contract, which is the
 * part most likely to rot silently during a refactor.
 */

const commands: PaletteCommand[] = [
  { id: 'new', title: 'New Session', group: 'Session', shortcut: '⌘T', run: () => {} },
  { id: 'sidebar', title: 'Toggle Sidebar', keywords: 'hide show panel', run: () => {} },
  { id: 'off', title: 'Unavailable Command', enabled: false, run: () => {} },
]

function render(props: Partial<Parameters<typeof CommandPalette>[0]> = {}): string {
  return renderToStaticMarkup(
    <CommandPalette
      open
      commands={commands}
      projectRoot={null}
      onClose={() => {}}
      onOpenFile={() => {}}
      {...props}
    />,
  )
}

describe('CommandPalette', () => {
  it('renders nothing while closed', () => {
    expect(render({ open: false })).toBe('')
  })

  it('exposes a combobox driving a listbox', () => {
    const html = render({ mode: 'commands' })
    expect(html).toContain('role="combobox"')
    expect(html).toContain('role="listbox"')
    expect(html).toContain('aria-autocomplete="list"')
    expect(html).toContain('aria-modal="true"')
  })

  it('points aria-activedescendant at the selected option', () => {
    const html = render({ mode: 'commands' })
    const active = /aria-activedescendant="([^"]+)"/.exec(html)?.[1]
    expect(active).toBeTruthy()
    // The id it names must exist, and must be the option marked selected.
    expect(html).toContain(`id="${active}" role="option" aria-selected="true"`)
  })

  it('drops aria-activedescendant when there is nothing to select', () => {
    const html = render({ commands: [], mode: 'commands' })
    expect(html).not.toContain('aria-activedescendant')
    expect(html).toContain('aria-expanded="false"')
  })

  it('hides disabled commands', () => {
    const html = render({ mode: 'commands' })
    expect(html).toContain('New Session')
    expect(html).not.toContain('Unavailable Command')
  })

  it('announces the result count to screen readers', () => {
    expect(render({ mode: 'commands' })).toContain('2 results')
  })

  it('labels itself by mode', () => {
    expect(render({ mode: 'commands' })).toContain('aria-label="Command palette"')
    expect(render({ mode: 'files', projectRoot: '/tmp/project' })).toContain('aria-label="Quick open"')
  })

  it('offers the command-mode prefix only when searching files', () => {
    expect(render({ mode: 'files', projectRoot: '/tmp/project' })).toContain('for commands')
    expect(render({ mode: 'commands' })).not.toContain('for commands')
  })

  it('explains itself when no project is open', () => {
    expect(render({ mode: 'files', projectRoot: null })).toContain('Run a command')
  })

  // Regression: the opening mode used to be seeded in an effect, so the very
  // first render of ⌘K with a project open was quick open — wrong label, wrong
  // placeholder, wrong empty state, and no commands in the list.
  it('opens in command mode on the first render, project open or not', () => {
    const html = render({
      mode: 'commands',
      projectRoot: '/tmp/project',
      loadFiles: async () => [],
    })
    expect(html).toContain('aria-label="Command palette"')
    expect(html).toContain('Run a command')
    expect(html).toContain('New Session')
    expect(html).not.toContain('No files found.')
  })

  it('opens in file mode on the first render when asked for files', () => {
    const html = render({
      mode: 'files',
      projectRoot: '/tmp/project',
      loadFiles: async () => [],
    })
    expect(html).toContain('aria-label="Quick open"')
    expect(html).not.toContain('New Session')
  })
})

describe('nextIndex', () => {
  it('wraps arrow movement past either end', () => {
    expect(nextIndex(4, 5, 1, true)).toBe(0)
    expect(nextIndex(0, 5, -1, true)).toBe(4)
  })

  // Regression: page jumps shared the arrows' modulo wrap, so PageDown from
  // the top of a five-row list landed on row three — neither end, and it read
  // as a bug rather than as navigation.
  it('clamps a page jump to the ends instead of wrapping through them', () => {
    expect(nextIndex(0, 5, 8, false)).toBe(4)
    expect(nextIndex(0, 5, -8, false)).toBe(0)
    expect(nextIndex(4, 5, -8, false)).toBe(0)
  })

  it('lands inside the list when the jump fits', () => {
    expect(nextIndex(0, 40, 8, false)).toBe(8)
    expect(nextIndex(20, 40, -8, false)).toBe(12)
  })

  it('survives an empty list and an out-of-range starting point', () => {
    expect(nextIndex(0, 0, 1, true)).toBe(0)
    expect(nextIndex(0, 0, -1, false)).toBe(0)
    expect(nextIndex(99, 5, 1, true)).toBe(0)
    expect(nextIndex(-3, 5, 0, false)).toBe(0)
  })
})

describe('parseFileQuery', () => {
  it('splits a trailing line number off the name', () => {
    expect(parseFileQuery('index.ts:42')).toEqual({ text: 'index.ts', line: 42 })
  })

  it('leaves a plain query alone', () => {
    expect(parseFileQuery('index.ts')).toEqual({ text: 'index.ts' })
  })

  it('ignores a line number with no name in front of it', () => {
    expect(parseFileQuery(':42')).toEqual({ text: ':42' })
  })

  it('takes the last of several colon groups', () => {
    expect(parseFileQuery('a:1:2')).toEqual({ text: 'a:1', line: 2 })
  })

  it('is not fooled by a colon mid-query', () => {
    expect(parseFileQuery('src:main')).toEqual({ text: 'src:main' })
  })

  // Regression: any run of digits used to become a line number, so `:0` asked
  // the opener for a line that does not exist and `:99999999999999999999`
  // handed it 1e20 — while both silently dropped the digits from the name.
  it('rejects a line number no editor could honour', () => {
    expect(parseFileQuery('v0.ts:0')).toEqual({ text: 'v0.ts:0' })
    expect(parseFileQuery('a:99999999999999999999')).toEqual({ text: 'a:99999999999999999999' })
    expect(parseFileQuery('a:2000000000')).toEqual({ text: 'a:2000000000' })
  })

  it('still accepts ordinary line numbers', () => {
    expect(parseFileQuery('a:1')).toEqual({ text: 'a', line: 1 })
    expect(parseFileQuery('a:1000000000')).toEqual({ text: 'a', line: 1_000_000_000 })
  })
})

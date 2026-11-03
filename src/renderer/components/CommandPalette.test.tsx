import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  CommandPalette,
  nextIndex,
  paletteEmptyMessage,
  parseFileQuery,
  sigilLength,
  SessionRow,
  snippetRanges,
  type PaletteCommand,
  type SessionHit,
  type SessionSearchBridge,
} from './CommandPalette'

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

/* ---------------------------------------------------- past-session search -- */

/**
 * The Search page's capability, in its new home.
 *
 * The page was removed because nobody could tell what it searched; the machine
 * behind it — `src/main/session-search.ts` — was never the problem. These pin
 * the parts of the move that could silently regress: that the sigil reaches it,
 * that a project is required, that the row says what Enter will do, and that
 * the mode is discoverable from the modes beside it.
 */
const ROOT = '/Users/a/proj'

function hit(overrides: Partial<SessionHit> = {}): SessionHit {
  return {
    sessionId: 'sess-1234abcd',
    at: Date.now() - 3600_000,
    role: 'user',
    isSidechain: false,
    snippet: {
      text: 'make the alerts panel quieter',
      ranges: [{ start: 9, length: 6 }],
      truncatedStart: false,
      truncatedEnd: false,
    },
    ...overrides,
  }
}

const silentBridge: SessionSearchBridge = {
  searchSessions: async () => ({ ok: true, hits: [], truncated: false }),
  cancelSessionSearch: async () => undefined,
}

describe('the ? mode', () => {
  it('is offered as a hint beside the > one, when a project is open', () => {
    const html = render({ projectRoot: ROOT, mode: 'files', sessionBridge: silentBridge })
    expect(html).toContain('for past sessions')
    expect(html).toContain('for commands')
  })

  it('is not offered with no project open — there would be nothing to search', () => {
    const html = render({ projectRoot: null })
    expect(html).not.toContain('for past sessions')
  })

  it('opens straight into it when the caller asks for it', () => {
    const html = render({ projectRoot: ROOT, mode: 'sessions', sessionBridge: silentBridge })
    expect(html).toContain('Past sessions')
    expect(html).toContain('Search everything past sessions said and did')
  })

  it('falls back to commands when there is no project, whatever the mode says', () => {
    // `?` with nowhere to search must not leave the reader in a dead mode.
    const html = render({ projectRoot: null, mode: 'sessions' })
    expect(html).toContain('Command palette')
  })

  it('says the search syntax at the moment the list is empty', () => {
    const html = render({ projectRoot: ROOT, mode: 'sessions', sessionBridge: silentBridge })
    expect(html).toContain('Type at least two characters')
  })

  it('promises copy, not open, because copy is what it does', () => {
    // The window's rule against dead clicks, kept by labelling the key with
    // the verb the row actually performs.
    const html = render({ projectRoot: ROOT, mode: 'sessions', sessionBridge: silentBridge })
    expect(html).toMatch(/<\/kbd> copy/)
    expect(html).not.toMatch(/<\/kbd> open/)
    // And the other two modes keep their own verbs.
    expect(render({ projectRoot: ROOT, mode: 'files' })).toMatch(/<\/kbd> open/)
    expect(render({ projectRoot: ROOT, mode: 'commands' })).toMatch(/<\/kbd> run/)
  })
})

describe('paletteEmptyMessage', () => {
  const idle = { searching: false, error: null, unavailable: false }
  const files = { loading: false, unavailable: false }

  function ask(overrides: Partial<Parameters<typeof paletteEmptyMessage>[0]> = {}): string {
    return paletteEmptyMessage({
      mode: 'sessions',
      term: 'needle',
      sessionScope: 'project',
      sessions: idle,
      files,
      ...overrides,
    })
  }

  it('points at the wider search when this project has nothing', () => {
    // The measured reality: an agent launched from a parent workspace records
    // its work under *that* project, so "nothing here" is often wrong rather
    // than final, and the way out has to be on screen at the moment it is.
    expect(ask()).toContain('??')
  })

  it('stops offering it once the wider search is the one that found nothing', () => {
    const wide = ask({ sessionScope: 'all' })
    expect(wide).toContain('needle')
    expect(wide).not.toContain('??')
  })

  it('teaches the syntax only while the query is too short to run', () => {
    expect(ask({ term: '' })).toContain('Type at least two characters')
    expect(ask({ term: 'a' })).toContain('Type at least two characters')
  })

  it('says it is reading rather than that there is nothing', () => {
    expect(ask({ sessions: { ...idle, searching: true } })).toBe('Reading past sessions…')
  })

  it('passes the main process’s own refusal through', () => {
    // `(a+)+` and an unparsable regex both come back with a sentence written
    // where the reason is known; replacing it here would lose it.
    const message = 'That pattern repeats inside a repeat.'
    expect(ask({ sessions: { ...idle, error: message } })).toBe(message)
  })

  it('keeps the other two modes’ messages', () => {
    expect(ask({ mode: 'files', term: '' })).toBe('No files found.')
    expect(ask({ mode: 'files', files: { loading: true, unavailable: false } })).toBe(
      'Reading project files…',
    )
    expect(ask({ mode: 'commands', term: '' })).toBe('No commands available.')
    expect(ask({ mode: 'commands', term: 'zzz' })).toContain('zzz')
  })
})

describe('SessionRow', () => {
  const NOW = Date.parse('2026-08-16T12:00:00.000Z')

  it('names the project instead of the role when searching every project', () => {
    const html = renderToStaticMarkup(
      <SessionRow hit={hit({ projectName: 'terminaldeck' })} now={NOW} showProject />,
    )
    expect(html).toContain('terminaldeck')
  })

  it('shows who said it, the snippet, and when', () => {
    const html = renderToStaticMarkup(
      <SessionRow hit={hit({ at: NOW - 7200_000 })} now={NOW} />,
    )
    expect(html).toContain('You')
    expect(html).toContain('make the ')
    expect(html).toContain('2h ago')
  })

  it('highlights the term the main process matched, not one it re-finds', () => {
    const html = renderToStaticMarkup(<SessionRow hit={hit()} now={NOW} />)
    expect(html).toContain('<mark class="palette-hit">alerts</mark>')
  })

  it('names the tool instead of the role when a hit came from one', () => {
    const html = renderToStaticMarkup(
      <SessionRow hit={hit({ role: 'tool', tool: 'Bash' })} now={NOW} />,
    )
    expect(html).toContain('Bash')
  })

  it('marks a sub-agent’s line as one', () => {
    const html = renderToStaticMarkup(<SessionRow hit={hit({ isSidechain: true })} now={NOW} />)
    expect(html).toContain('sub-agent')
  })

  it('keeps the ellipses that say the snippet was cut out of something longer', () => {
    const html = renderToStaticMarkup(
      <SessionRow
        hit={hit({ snippet: { ...hit().snippet, truncatedStart: true, truncatedEnd: true } })}
        now={NOW}
      />,
    )
    expect(html.match(/…/g)).toHaveLength(2)
  })
})

describe('snippetRanges', () => {
  it('converts the main process’s lengths into fuzzy’s end offsets', () => {
    expect(snippetRanges({ text: 'abcdef', ranges: [{ start: 2, length: 3 }], truncatedStart: false, truncatedEnd: false })).toEqual([
      { start: 2, end: 5 },
    ])
  })

  it('drops ranges that cannot land on the text', () => {
    // A snippet is clipped after its ranges are recorded, so a range past the
    // end is a normal thing to receive, not a bug to crash on.
    const snippet = {
      text: 'abc',
      ranges: [{ start: 9, length: 2 }, { start: 0, length: 0 }, { start: -1, length: 2 }],
      truncatedStart: false,
      truncatedEnd: false,
    }
    expect(snippetRanges(snippet)).toEqual([])
  })

  it('returns them in order, whatever order they arrived in', () => {
    const snippet = {
      text: 'abcdefghij',
      ranges: [{ start: 6, length: 2 }, { start: 1, length: 2 }],
      truncatedStart: false,
      truncatedEnd: false,
    }
    expect(snippetRanges(snippet).map((range) => range.start)).toEqual([1, 6])
  })
})

/**
 * Regression: the sigil used to be counted from the *mode* rather than from
 * what the query starts with. With no project open the palette is pinned to
 * command mode whatever is typed, so deleting the seeded `>` and typing `abc`
 * searched for `bc` — the first character of every query, silently eaten.
 */
describe('sigilLength', () => {
  it('counts a prefix that is really there', () => {
    expect(sigilLength('>run', false)).toBe(1)
    expect(sigilLength('?needle', true)).toBe(1)
    expect(sigilLength('??needle', true)).toBe(2)
  })

  it('counts nothing when the reader deleted the prefix', () => {
    // The palette is still in command mode — there is no project — but the
    // query no longer carries a sigil, and eating `a` is the bug.
    expect(sigilLength('abc', false)).toBe(0)
    expect(sigilLength('', false)).toBe(0)
  })

  it('never eats a lone sigil’s worth of a real query', () => {
    expect('abc'.slice(sigilLength('abc', false))).toBe('abc')
    expect('>abc'.slice(sigilLength('>abc', false))).toBe('abc')
    expect('??abc'.slice(sigilLength('??abc', true))).toBe('abc')
  })
})

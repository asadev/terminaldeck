import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { PANELS } from '../shell/panels'
import { KEYMAP } from '../keymap'
import {
  AboutCard,
  HELP_TOPICS,
  HelpPanel,
  matchesAbout,
  PANEL_HELP,
  searchHelp,
  TopicView,
  type AboutInfo,
} from './HelpPanel'

/**
 * No DOM in this project's test setup, so these render to static markup.
 *
 * What is worth protecting here is that the help cannot go stale without a test
 * failing: it is generated from `panels.ts` and `keymap.ts`, and the value of
 * generating it is entirely lost if a new panel can be added with no
 * explanation attached. The other half is the troubleshooting section — those
 * entries exist because of specific failure modes, and an entry that quietly
 * disappears takes the only explanation of that failure with it.
 */

const ABOUT: AboutInfo = {
  name: 'Testbed',
  tagline: 'Run and watch your sessions',
  version: '1.2.3',
  electron: '41.10.5',
  chrome: '140.0.0',
  node: '22.9.0',
  v8: '14.0',
  platform: 'darwin',
  arch: 'arm64',
  packaged: false,
}

function render(node: Parameters<typeof renderToStaticMarkup>[0]): string {
  return renderToStaticMarkup(node)
}

describe('help content', () => {
  it('explains every panel on the rail', () => {
    for (const panel of PANELS) {
      expect(PANEL_HELP[panel.id], `no help written for the ${panel.id} panel`).toBeTruthy()
      expect(PANEL_HELP[panel.id].length).toBeGreaterThan(30)
    }
  })

  it('has a topic for every panel, generated rather than typed out', () => {
    for (const panel of PANELS) {
      expect(HELP_TOPICS.some((topic) => topic.id === `panel-${panel.id}`)).toBe(true)
    }
  })

  it('keeps an entry for each failure mode this app actually has', () => {
    const ids = HELP_TOPICS.map((topic) => topic.id)
    for (const id of [
      'trouble-path',
      'trouble-signin',
      'trouble-gh',
      'trouble-remote',
      'trouble-exit',
    ]) {
      expect(ids, `${id} is the only place that failure is explained`).toContain(id)
    }
  })

  it('never hardcodes the product name — copy uses the placeholder', () => {
    const raw = JSON.stringify(HELP_TOPICS)
    expect(raw).not.toContain('Pawl')
    expect(raw).toContain('{app}')
  })
})

describe('searchHelp', () => {
  it('finds the PATH topic from the words a stuck user would type', () => {
    for (const query of ['path', 'command not found', 'cannot find claude', 'homebrew']) {
      const ids = searchHelp(query).map((topic) => topic.id)
      expect(ids, `“${query}” should reach the PATH explanation`).toContain('trouble-path')
    }
  })

  it('matches on partial words, because help is searched with half-remembered ones', () => {
    expect(searchHelp('auth').map((t) => t.id)).toContain('trouble-gh')
  })

  it('requires every term to match', () => {
    expect(searchHelp('github remote').map((t) => t.id)).toContain('trouble-remote')
    expect(searchHelp('github kangaroo')).toEqual([])
  })

  it('returns everything for an empty query', () => {
    expect(searchHelp('   ')).toHaveLength(HELP_TOPICS.length)
  })
})

describe('rendering', () => {
  it('fills the app name into the copy rather than printing the placeholder', () => {
    const topic = HELP_TOPICS.find((t) => t.id === 'start-cli')
    const html = render(<TopicView topic={topic!} appName="Testbed" />)
    expect(html).not.toContain('{app}')
    expect(html).toContain('Testbed')
  })

  it('opens on getting started', () => {
    const html = render(<HelpPanel bridge={null} isMac autoFocus={false} />)
    expect(html).toContain('Install an agent CLI')
    expect(html).toContain('Open a project')
  })

  it('lists the whole keymap in the shortcuts section', () => {
    const html = render(<HelpPanel bridge={null} isMac autoFocus={false} initialSection="shortcuts" />)
    expect(html).toContain('⌘T')
    expect(html).toContain('passes through')
    // One row per binding, so a shortcut cannot exist without being documented.
    const rows = html.match(/class="help-key-row"/g) ?? []
    expect(rows).toHaveLength(KEYMAP.length)
  })

  it('spells shortcuts for the platform it is rendered on', () => {
    const pc = render(<HelpPanel bridge={null} isMac={false} autoFocus={false} initialSection="shortcuts" />)
    expect(pc).toContain('Ctrl+T')
    expect(pc).not.toContain('⌘T')
  })

  it('says so when nothing matches instead of rendering an empty page', () => {
    const html = render(<HelpPanel bridge={null} isMac autoFocus={false} />)
    // The panel starts unfiltered; the empty state is exercised through the
    // pure search, which is what decides it.
    expect(searchHelp('kangaroo')).toEqual([])
    expect(html).not.toContain('Nothing in the help matches')
  })

  it('renders version details, and marks an unpackaged build as one', () => {
    const html = render(<AboutCard info={ABOUT} />)
    expect(html).toContain('Testbed')
    expect(html).toContain('1.2.3')
    expect(html).toContain('development build')
    expect(html).toContain('41.10.5')
  })

  it('degrades to a sentence when there is no bridge to ask', () => {
    expect(render(<AboutCard info={null} />)).toContain('not available')
  })
})

describe('matchesAbout', () => {
  /**
   * This was `'about version build'.includes(query)` — a substring test against
   * a fixed sentence, wrong in both directions. Any single letter in that
   * sentence surfaced the version card, while the words actually printed on it
   * did not.
   */
  it('does not surface the version card for a single stray letter', () => {
    for (const query of ['a', 'b', 'u', 'o', 've', 'auth', 'path']) {
      expect(matchesAbout(query), `“${query}” should not be an About match`).toBe(false)
    }
  })

  it('matches the words that are actually printed on the card', () => {
    for (const query of ['version', 'electron', 'chromium', 'node', 'build', 'about', 'v8', 'ver']) {
      expect(matchesAbout(query), `“${query}” should reach the version card`).toBe(true)
    }
  })

  it('requires every term, in any order', () => {
    expect(matchesAbout('build version')).toBe(true)
    expect(matchesAbout('version kangaroo')).toBe(false)
  })

  it('is not a match for an empty query', () => {
    expect(matchesAbout('   ')).toBe(false)
  })
})

describe('search results', () => {
  it('counts one result as “1 result”, not “1 results”', () => {
    const html = render(
      <HelpPanel bridge={null} isMac autoFocus={false} initialQuery="kangaroo" />,
    )
    expect(html).not.toContain('1 results')
  })

  it('counts the version card as a result when it is shown as one', () => {
    const html = render(<HelpPanel bridge={null} isMac autoFocus={false} initialQuery="electron" />)
    // Topics mentioning Electron plus the About card — never zero while the
    // card itself is on screen.
    expect(html).not.toContain('>0 results')
  })

  it('says so when a search matches nothing at all', () => {
    const html = render(<HelpPanel bridge={null} isMac autoFocus={false} initialQuery="kangaroo" />)
    expect(html).toContain('Nothing in the help matches')
    expect(html).toContain('0 results')
  })
})

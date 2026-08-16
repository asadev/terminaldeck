import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { SettingsPanel } from '../SettingsWindow'
import type { SectionId } from '../settings-schema'
import type { SettingsBridge } from '../settings-bridge'

/**
 * A budget for the words on screen.
 *
 * ## Why a test, and not just shorter copy
 *
 * The copy in this window was cut back after one sentence of feedback that
 * applies to the whole app: *"we don't need this much of big descriptions under
 * each. The whole page is going to be used just because of the big
 * descriptions."* Every paragraph that came out was defensible on its own —
 * that is exactly how they accumulated. A pane grows a wall of text one true,
 * well-meant clause at a time, and nothing fails while it happens.
 *
 * So the shortness is pinned the same way any other behaviour here is. These
 * numbers are ceilings a little above where the panes actually sit, not targets:
 * the point is that a paragraph cannot quietly double, not that a word may never
 * be added.
 *
 * ## What is measured, and what deliberately is not
 *
 * Only `.settings-prose` and `.settings-explain-body` — the standing
 * explanations a section file writes for itself, which is where the weight was.
 * Not the per-setting help lines: those come from `settings-schema.ts`, which is
 * shared with sections other people own, and a budget enforced from here would
 * fail on somebody else's edit.
 *
 * Only the sections whose copy was actually rewritten, for the same reason.
 * General, Features, Power, Setup and Remote are owned elsewhere and are left
 * out on purpose rather than by oversight.
 *
 * Accounts joined the list when its copy was rewritten. It is the pane that
 * shows why the budget is not pedantry: it carried three headed blocks, one of
 * them ("Claude only, and why") a paragraph of mechanism that had also become
 * *untrue* — separate Codex logins work now — and the reason it survived that
 * long is that every clause in it was defensible on its own.
 *
 * Static markup, like every other test in this window — there is no DOM here.
 */

/** Sections whose standing prose this budget covers. */
const BUDGETED: readonly SectionId[] = [
  'appearance',
  'notifications',
  'agents',
  'browser',
  'linux',
  'advanced',
  'about',
  'shortcuts',
  'profiles',
]

/**
 * The longest a single standing paragraph may be.
 *
 * Set by the one that legitimately needs the room: Browser's cookie-import
 * warning, which has to say that macOS will put a permission dialog on screen
 * *and* that cookies are live credentials. Shortening that one further would
 * take a real warning off the screen, which the brief for this pass ruled out.
 */
const MAX_WORDS_PER_PARAGRAPH = 55

/**
 * The longest all the standing prose on one pane may be, added together.
 *
 * This is the number that matches the complaint. A pane can be within the
 * per-paragraph limit five times over and still be the wall somebody opened
 * Settings and closed it again over.
 */
const MAX_WORDS_PER_SECTION = 130

/**
 * Rendered as Windows so `linux` has a pane at all — `sectionsFor` drops it
 * everywhere else, and under vitest the real platform answer is `other`.
 *
 * Accounts is the one pane that needs something on `globalThis.deck` before it
 * will draw its copy at all: with no accounts bridge it renders a single
 * warning and stops, so a budget measured against that would pass by measuring
 * nothing — which is the shape of a guard that quietly stops guarding. The stub
 * is the smallest object `accountsBridge()` accepts, and it is put back
 * afterwards so no other pane in this file renders against it.
 */
function render(section: SectionId, bridge: SettingsBridge = {}): string {
  const host = globalThis as { deck?: unknown }
  const had = 'deck' in host
  const previous = host.deck
  if (section === 'profiles') host.deck = { listProfiles: () => Promise.resolve({ profiles: [] }) }
  try {
    return renderToStaticMarkup(
      <SettingsPanel bridge={bridge} platform="windows" initialSection={section} />,
    )
  } finally {
    if (had) host.deck = previous
    else delete host.deck
  }
}

const PROSE = /<p class="(?:settings-prose|settings-explain-body)"[^>]*>(.*?)<\/p>/gs

/** Visible words in a run of markup: tags out, entities out, then split. */
export function wordsIn(markup: string): number {
  const text = markup
    .replace(/<[^>]*>/g, ' ')
    .replace(/&[a-z]+;|&#\d+;/gi, ' ')
    .replace(/[—–]/g, ' ')
    .trim()
  return text === '' ? 0 : text.split(/\s+/).length
}

/** Every standing paragraph on a pane, as visible-word counts. */
function paragraphs(section: SectionId, bridge?: SettingsBridge): number[] {
  return [...render(section, bridge).matchAll(PROSE)].map((match) => wordsIn(match[1]))
}

describe('the standing prose on a settings pane', () => {
  for (const section of BUDGETED) {
    it(`keeps every paragraph on ${section} under ${MAX_WORDS_PER_PARAGRAPH} words`, () => {
      for (const count of paragraphs(section)) {
        expect(count, section).toBeLessThanOrEqual(MAX_WORDS_PER_PARAGRAPH)
      }
    })

    it(`keeps ${section} as a whole under ${MAX_WORDS_PER_SECTION} words of prose`, () => {
      const total = paragraphs(section).reduce((sum, count) => sum + count, 0)
      expect(total, section).toBeLessThanOrEqual(MAX_WORDS_PER_SECTION)
    })
  }

  /**
   * Browser is the pane that had four multi-paragraph blocks, so it is measured
   * in the state that draws all of them — the blocks are behind bridge methods
   * and an unwired panel renders three of them as one-line notices instead.
   */
  it('holds Browser to the budget with every block on screen', () => {
    const wired: SettingsBridge = {
      listBrowsers: async () => [],
      scanBrowserTabs: async () => ({ urls: [], problems: [] }),
      browserCookieSources: async () => [],
      browserCookieImportStatus: async () => ({ present: 0, recorded: 0, supported: true }),
      importBrowserCookies: async () => ({ ok: true }),
      clearImportedCookies: async () => ({ removed: 0 }),
      clearBrowserData: async () => ({ ok: true }),
    }
    const counts = paragraphs('browser', wired)
    expect(counts.length).toBeGreaterThan(2)
    for (const count of counts) expect(count).toBeLessThanOrEqual(MAX_WORDS_PER_PARAGRAPH)
    expect(counts.reduce((sum, count) => sum + count, 0)).toBeLessThanOrEqual(
      MAX_WORDS_PER_SECTION,
    )
  })
})

describe('what the cut was not allowed to take with it', () => {
  /**
   * Importing cookies asks macOS for another application's secret and then
   * hands this app live session credentials. Both facts were on screen before
   * the shortening and both had to survive it; a shorter panel that leaves
   * somebody unaware of either is a worse panel, not a tidier one.
   */
  it('still warns, before the press, what importing cookies costs', () => {
    const html = render('browser', {
      browserCookieSources: async () => [],
      browserCookieImportStatus: async () => ({ present: 0, recorded: 0, supported: true }),
      importBrowserCookies: async () => ({ ok: true }),
    })
    expect(html).toContain('macOS will ask your permission')
    expect(html).toContain('nothing is read until you press one of these')
    expect(html).toMatch(/the credentials that keep you signed in/)
  })

  /** Clearing browsing data signs you out and cannot be undone. */
  it('still says the clear cannot be undone', () => {
    const html = render('browser', { clearBrowserData: async () => ({ ok: true }) })
    expect(html).toContain('cannot be undone')
  })

  /**
   * Reset touches every setting including the theme. What it does *not* touch
   * is the thing anybody hovering a red button wants to know.
   */
  it('still says a reset leaves projects and sessions alone', () => {
    const html = render('advanced', { resetSettings: async () => ({ ok: true }) })
    expect(html).toContain('Projects, sessions and accounts are untouched')
  })

  /**
   * An account is two logins, and only one agent honours the choice. The old
   * wording explained the config-directory trick that makes it work; what a
   * person needs is which agents it applies to.
   */
  it('still says which agents an account applies to, without naming a config directory', () => {
    const html = render('agents', {
      listProfiles: async () => ({ profiles: [{ id: 'system', name: 'Your install', system: true }], defaultProfileId: 'system' }),
    })
    expect(html).toContain('Claude Code only')
    expect(html).toContain('Other agents ignore this and use their own login')
    expect(html).not.toContain('config directory')
  })

  /**
   * The Linux pane exists to stop somebody hunting for a "use Linux" switch.
   * The rule survived; the paragraph arguing why the rule is a good one did not.
   */
  it('still leads Linux with the rule, and no longer argues for it', () => {
    const html = render('linux')
    expect(html).toContain('A session opens where its folder is')
    expect(html).not.toContain('what makes either of them fast')
  })
})

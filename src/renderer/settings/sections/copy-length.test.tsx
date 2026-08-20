import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { SettingsPanel } from '../SettingsWindow'
import { sectionsFor, type SectionId } from '../settings-schema'
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
 * Accounts joined the list when its copy was rewritten. It is the pane that
 * shows why the budget is not pedantry: it carried three headed blocks, one of
 * them ("Claude only, and why") a paragraph of mechanism that had also become
 * *untrue* — separate Codex logins work now — and the reason it survived that
 * long is that every clause in it was defensible on its own.
 *
 * ## Every pane is budgeted now
 *
 * The list used to be partial, and the note here said so: General, Features,
 * Power, Setup and Remote were "owned elsewhere and left out on purpose". That
 * exemption is what let the panes nobody was measuring keep their walls of
 * text, and it did not survive the walkthrough:
 *
 *   > "we don't have to give this big descriptions… let's give only one liner
 *   > or two liner descriptions and one eye buttons next to them, but not more
 *   > than one or two lines because it's being too big for them. I'm talking
 *   > about all of the options and overall all of the sections, not only this
 *   > one."
 *
 * So the list below is now derived from the rail rather than typed out: every
 * pane the window can show is measured, and a new one is measured the day it is
 * added. Agents is the interesting entry — it is three former panes rendered
 * together, so it is the pane where the budget does the most work.
 *
 * Static markup, like every other test in this window — there is no DOM here.
 */

/**
 * Every pane in the rail, on the platform that has all of them.
 *
 * Derived, so nothing can be left out "on purpose" again.
 */
const BUDGETED: readonly SectionId[] = sectionsFor('windows').map((section) => section.id)

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
  // Accounts is drawn inside Agents and needs something on `globalThis.deck`
  // before it will draw its copy at all: with no accounts bridge it renders a
  // single warning and stops, so a budget measured against that would pass by
  // measuring nothing — which is the shape of a guard that quietly stops
  // guarding. This is the smallest object `accountsBridge()` accepts.
  if (section === 'agents' || section === 'profiles') {
    host.deck = { listProfiles: () => Promise.resolve({ profiles: [] }) }
  }
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
   * An account is a login of one agent, and only one *default* is stored. The
   * original wording explained the config-directory trick that makes accounts
   * work; what a person needs is what the limit actually is — and after the
   * regroup that answer sits on the row it is about, behind its ⓘ, rather than
   * in a headed paragraph three groups further down.
   *
   * The sentence itself was wrong until 2026-08-20. It read *"Claude Code only.
   * Other agents ignore this…"* while the picker under it offered Codex and
   * Gemini rows — and `resolveProfileId` does honour a Codex default for a
   * Codex session, so the claim was false in one direction and contradicted by
   * its own control in the other. What is true is the singular: one default,
   * used by sessions of its own agent, replaced rather than joined when another
   * agent's account is chosen.
   */
  it('still says what the default account limit is, without naming a config directory', () => {
    const html = render('agents', {
      listProfiles: async () => ({ profiles: [{ id: 'system', name: 'Your install', system: true }], defaultProfileId: 'system' }),
    })
    expect(html).toContain('only sessions of the agent it is a login of use it')
    expect(html).not.toContain('Claude Code only')
    expect(html).not.toContain('config directory')
  })

  /**
   * The three panes that merged each kept the block that was theirs.
   *
   * This is the assertion the whole regroup turns on — *"when you reorganize
   * you mostly miss the things and you drop some stuff"* — checked from the
   * outside, on the rendered pane, rather than by reading the diff.
   */
  it('draws all three former panes on the one Agents page', () => {
    const html = render('agents', {
      checkPrerequisites: async () => ({ tools: [] }),
      setupStatus: async () => null,
      listProfiles: async () => ({ profiles: [], defaultProfileId: null }),
    })
    // Agents' own two questions, and the menu that answers "I want another
    // agent". "What is installed" was the heading over the third; it is gone
    // with "New sessions", because two headings over four rows is most of what
    // made one pane read as three — *"it's too messy and too difficult to
    // understand"*. The rows they were over are still here, which is the whole
    // claim this test makes.
    expect(html).toContain('Default coding tool')
    expect(html).toContain('Primary account')
    expect(html).toContain('Add accounts')
    // Accounts — its own heading. The group that used to carry the whole add
    // form here is a popup, and the *button* that opened it is gone too: it
    // stood one row under a **Sign in** on every signed-out account, which is
    // the pair he collided with — *"why do we have see sign in here separately,
    // add account here separately?"* The **Add accounts** menu asserted above is
    // the pane's one door now, and it opens the same popup. Nothing was
    // dropped, which is what this test is for — the steps are asserted in
    // `AccountsSection.test.tsx`, on the panel itself.
    expect(html).toContain('>Accounts<')
    expect(html).not.toContain('>Add account<')
    // Setup. "Other coding tools" was the heading until GitHub Copilot moved to
    // the GitHub page — what is left under it is git and the GitHub CLI, which
    // are tools this app uses rather than coding tools. See `MOVED_TOOL_IDS`.
    expect(html).toContain('Other tools')
    expect(html).not.toContain('GitHub Copilot')
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

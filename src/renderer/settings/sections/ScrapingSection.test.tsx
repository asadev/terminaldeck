import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { SettingsPanel } from '../SettingsWindow'
import { SECTIONS, sectionsFor } from '../settings-schema'
import { featureOwningSection } from '../../features/registry'
import { ScopeSwitch, scopeAfterDevices, deviceScope } from './AgentsSection'
import { ThisMachine } from '../../platform'
import { DeviceScraping, ServerScraping } from './ScrapingSection'
import { ScrapingBody } from '../../browser/ScrapingPanel'
import type { ScrapingApi } from '../../browser/scraping-bridge'

/**
 * Settings → Scraping: one pane, one switch, and two honest absences.
 *
 * ## What these are written against
 *
 * The real composers, not strings typed here. The parity check below renders
 * the **same component** on both surfaces and compares the two runs, so it
 * cannot be satisfied by a test that agrees with a copy of the copy; and the
 * two away-scope panes are asserted for what they do *not* contain, which is
 * the property a screenshot cannot check and a reviewer stops checking.
 *
 * `renderToStaticMarkup` runs no effects, so nothing any of these panes fetches
 * on mount has arrived. That is the state the whole panel is designed to draw
 * honestly — every section says it is unavailable rather than guessing — so it
 * is a fair state to compare two surfaces in, and it is the only one available
 * in a suite with no DOM.
 */

/**
 * What the *this machine* seat says when nothing has told this window the
 * hostname — which is every render in this file, because `useMachines` needs a
 * bridge and there is none here.
 *
 * Computed rather than spelled, and that is not fussiness: `ThisMachine` reads
 * the platform, so the literal is "This Mac" on his laptop and "This PC" on the
 * Windows runner. A hard-coded phrase here is a test that passes on macOS and
 * fails in CI on the platform most of this app's users are on.
 */
const HERE = ThisMachine()

/** The pane, with no `window.deck` at all: every seam absent, nothing guessed. */
function pane(): string {
  return renderToStaticMarkup(
    <SettingsPanel bridge={{}} platform="mac" initialSection="scraping" />,
  )
}

/**
 * One seam, so the lift has an engine behind it and the panel draws its
 * controls rather than the sentence it draws when nothing can copy a session.
 * Everything else stays unwired, which is what makes the comparison below a
 * comparison of *sections* rather than of one lucky branch.
 */
const WIRED: ScrapingApi = {
  browserScrapingLift: async () => ({ ok: true, message: '', count: 0 }),
}

/** One surface of the panel, drawn by the component both surfaces draw. */
function body(canLift: boolean): string {
  return renderToStaticMarkup(
    <ScrapingBody
      live
      api={WIRED}
      accounts={{}}
      downloads={null}
      profileId="work"
      /* A page exists on the surface that can lift, and never on the other. */
      pageOpen={canLift}
      canLift={canLift}
    />,
  )
}

/** Anything a person could press or type into. */
const CONTROL = /<(?:button|input|select|textarea)\b/

/**
 * Just the Session section of one surface's markup.
 *
 * Sliced between its own heading and the next, because "no control here" is a
 * claim about that section and a whole-pane search would be answered by any
 * control anywhere — including ones that arrive later for good reasons.
 */
function session(markup: string): string {
  const from = markup.indexOf('>Session<')
  const to = markup.indexOf('>Requests<')
  expect(from, 'no Session heading').toBeGreaterThan(-1)
  expect(to, 'no Requests heading').toBeGreaterThan(from)
  return markup.slice(from, to)
}

describe('the rail entry that did not exist', () => {
  it('is in the rail on every platform, because scraping is not a Windows idea', () => {
    for (const platform of ['mac', 'windows', 'other'] as const) {
      expect(sectionsFor(platform).map((section) => section.id)).toContain('scraping')
    }
  })

  it('goes with the browser pane, because that is the browser it configures', () => {
    /*
     * The fleet is a set of that browser's profiles, the request rules are
     * armed on its tabs and the ledger is of assets its windows fetched. Left
     * core, this pane would survive the browser being uninstalled as a rail
     * entry whose every control writes to something that is not there.
     */
    expect(featureOwningSection('scraping')).toBe('browser')
    expect(featureOwningSection('scraping')).toBe(featureOwningSection('browser'))
  })

  it('sits beside Browser rather than at the end of the list', () => {
    /*
     * Ordering is the whole of "somebody would go looking for its subject".
     * Appended after Help it would be below the rail's two reference entries,
     * which is where a reader has already stopped looking.
     */
    const ids = SECTIONS.map((section) => section.id)
    expect(ids.indexOf('scraping')).toBe(ids.indexOf('browser') + 1)
  })
})

describe('what the pane draws', () => {
  it('opens on this machine, with the switch above it', () => {
    const html = pane()
    expect(html).toContain('aria-label="Where scraping runs"')
    /*
     * Named, not pointed at. The seat used to read "This machine" here while the
     * MCP servers page said the hostname and the Servers pane offered no such
     * button at all — three vocabularies for one computer, in one window. The
     * rule is on `scopesFor` in `AgentsSection`: a seat that is one machine
     * carries that machine's name, and this computer is a machine.
     */
    expect(html).toContain(`aria-pressed="true">${HERE}</button>`)
    expect(html).not.toContain('>This machine</button>')
    expect(html).toContain('>Servers</button>')
  })

  it('draws the browser panel itself rather than a second copy of it', () => {
    /*
     * The load-bearing assertion of this whole pane, and the reason it is
     * phrased as a substring of the *other* surface's output rather than as a
     * sentence typed here: what is being checked is that one component draws
     * both. A settings pane that had been re-typed from the panel would pass a
     * test written against a quotation and fail this one the first time either
     * copy was edited.
     */
    const html = pane()
    const panel = body(true)
    const headful = 'Scraping happens in a window you can watch.'
    expect(panel).toContain(headful)
    expect(html).toContain(headful)
  })

  it('carries every heading, sentence and control the browser panel has', () => {
    const settings = body(false)
    const browser = body(true)

    // Every section head, by name — the seven the panel is built out of.
    for (const head of ['Workers', 'Session', 'Requests', 'Capture', 'Assets', 'Checks', 'Store']) {
      expect(browser, head).toContain(`>${head}<`)
      expect(settings, head).toContain(`>${head}<`)
    }

    // And every unavailability sentence, which on an unwired build is what each
    // section says instead of its controls. Same words, both surfaces.
    const notices = [...browser.matchAll(/Not available here — ([^<]+)/g)].map((m) => m[1])
    expect(notices.length).toBeGreaterThan(4)
    for (const notice of notices) expect(settings).toContain(notice)
  })

  it('leaves out exactly one thing, and says why rather than disabling it', () => {
    const settings = body(false)
    const browser = body(true)

    // The lift is the one fact on that screen about a *window* rather than
    // about this machine, so it is the one thing that may differ.
    expect(browser).toContain('Lift this session into the workers')
    expect(settings).not.toContain('Lift this session into the workers')

    // Named absence, not a hidden one: the section is still drawn and still
    // says where the gesture lives.
    expect(settings).toContain('>Session<')
    expect(settings).toContain('there is no page here')
    expect(settings).toMatch(/three dots/)

    // And nothing was disabled in its place — a control that is certain to
    // refuse costs a click to discover the lie. Measured on the section itself
    // rather than on the whole pane, so a control that legitimately disables
    // somewhere else cannot quietly satisfy or break this.
    expect(session(settings)).not.toMatch(CONTROL)
    expect(session(settings)).not.toContain('disabled')

    // The browser surface is the control it is: pickers, targets and a button.
    expect(session(browser)).toMatch(CONTROL)
  })
})

describe('the two scopes that cannot carry these settings', () => {
  it('tells the truth about a server, and draws no control at all', () => {
    const html = renderToStaticMarkup(<ServerScraping />)
    expect(html).not.toMatch(CONTROL)
    // The two measured facts: the SSH server's session scrapes with the browser
    // *here*, and the scraping tools are not on that session's list. It no longer
    // claims the old falsehood that a server has none — a host-installed server
    // runs its own — so the sentence is scoped to the SSH kind this pane means.
    expect(html).not.toContain('A server has no browser')
    expect(html).toContain('scrapes with a browser here, not one of its own')
    // And it points at the button by the button's own name. A paragraph saying
    // "the settings under **This machine**" beside a button reading a hostname
    // is the same confusion one layer down.
    expect(html).toContain(`<strong>${HERE}</strong>`)
    expect(html).toMatch(/refused to\s+every session that is not on the computer the window is on/)
  })

  it('names the device, and points at the machine that can change them', () => {
    const html = renderToStaticMarkup(<DeviceScraping name="Office PC" />)
    expect(html).not.toMatch(CONTROL)
    expect(html).toContain('Office PC keeps its own scraping settings, on Office PC')
    expect(html).toContain('Settings → Scraping')
    // What is missing is a frame on the wire, not a connection — so the pane
    // must not promise that connecting would help.
    expect(html).toContain('connecting Office PC does not add one')
  })

  it('does not say "That machine" when it knows the name, or a blank when it does not', () => {
    expect(renderToStaticMarkup(<DeviceScraping name="Office PC" />)).not.toContain('That machine')
    expect(renderToStaticMarkup(<DeviceScraping name="" />)).toContain('That machine')
  })
})

describe('the prose budget, on the two scopes the rail cannot render', () => {
  /*
   * `copy-length.test.tsx` renders each pane at its default scope, so it
   * measures This machine and never sees these two. They are the panes most at
   * risk of growing a paragraph — an absence has to argue for itself — so the
   * same ceilings are applied here by hand.
   */
  const MAX_WORDS_PER_PARAGRAPH = 55
  const MAX_WORDS_PER_SECTION = 130
  const PROSE = /<p class="settings-prose"[^>]*>(.*?)<\/p>/gs

  function words(markup: string): number[] {
    return [...markup.matchAll(PROSE)].map((match) => {
      const text = match[1]
        .replace(/<[^>]*>/g, ' ')
        .replace(/&[a-z]+;|&#\d+;/gi, ' ')
        .replace(/[—–]/g, ' ')
        .trim()
      return text === '' ? 0 : text.split(/\s+/).length
    })
  }

  for (const [name, markup] of [
    ['servers', renderToStaticMarkup(<ServerScraping />)],
    ['a device', renderToStaticMarkup(<DeviceScraping name="Office PC" />)],
  ] as const) {
    it(`says why in a few sentences on ${name}`, () => {
      const counts = words(markup)
      expect(counts.length, name).toBeGreaterThan(0)
      for (const count of counts) expect(count, name).toBeLessThanOrEqual(MAX_WORDS_PER_PARAGRAPH)
      expect(
        counts.reduce((sum, count) => sum + count, 0),
        name,
      ).toBeLessThanOrEqual(MAX_WORDS_PER_SECTION)
    })
  }
})

describe('a device forgotten while its scope was on screen', () => {
  /*
   * The guard was three lines inside one pane's effect and is now
   * `scopeAfterDevices`, called from both panes that carry the switch. Pure, so
   * it can be asserted here: these tests run no effects, so the version that
   * lived inside one was unreachable from any test in this window.
   */
  it('falls back to this machine rather than to a switch with nothing pressed', () => {
    expect(scopeAfterDevices(deviceScope('m1'), [])).toBe('this-machine')
    expect(scopeAfterDevices(deviceScope('m1'), [{ id: 'm2' }])).toBe('this-machine')
  })

  it('leaves a device that is still linked, and the two fixed scopes, alone', () => {
    expect(scopeAfterDevices(deviceScope('m1'), [{ id: 'm1' }])).toBe(deviceScope('m1'))
    expect(scopeAfterDevices('servers', [])).toBe('servers')
    expect(scopeAfterDevices('this-machine', [])).toBe('this-machine')
  })

  it('is what stops the switch drawing with nothing selected', () => {
    // The state the guard exists to prevent, drawn on purpose so the failure it
    // prevents is visible rather than described.
    const orphaned = renderToStaticMarkup(
      <ScopeSwitch scope={deviceScope('gone')} label="Where scraping runs" onScope={() => {}} />,
    )
    expect(orphaned).not.toContain('aria-pressed="true"')

    const guarded = renderToStaticMarkup(
      <ScopeSwitch
        scope={scopeAfterDevices(deviceScope('gone'), [])}
        label="Where scraping runs"
        onScope={() => {}}
      />,
    )
    expect(guarded).toContain(`aria-pressed="true">${HERE}</button>`)
  })
})

describe('what this computer is called on the switch', () => {
  it('says the hostname when the window knows it', () => {
    /*
     * *"this machine is Office PC, this machine is this machine where I am… I
     * don't know what to trust."* A deictic cannot be resolved by reading it on
     * a bar where every other button carries a hostname; a name can. `here` is
     * `MachinesView.here` straight off `useMachines`, and this is the state that
     * matters — the one where there is an answer.
     */
    const html = renderToStaticMarkup(
      <ScopeSwitch scope="this-machine" here="DESKTOP-DDGMNCV" onScope={() => {}} />,
    )
    expect(html).toContain('aria-pressed="true">DESKTOP-DDGMNCV</button>')
    expect(html).not.toContain('This machine')
  })

  it('falls back to the app’s own phrase, not to a fourth one', () => {
    // A build whose preload predates `MachinesView.here` sends `''`. The fallback
    // is `hereName`'s — the same words the browser's machine picker and the
    // downloads list use — rather than the "This machine" this switch used to
    // invent for itself.
    const html = renderToStaticMarkup(<ScopeSwitch scope="this-machine" here="" onScope={() => {}} />)
    expect(html).toContain(`aria-pressed="true">${HERE}</button>`)
  })
})

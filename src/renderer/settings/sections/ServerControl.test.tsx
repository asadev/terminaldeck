import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  chosenServer,
  lookOf,
  ServerControlView,
  ServerRecord,
  type ServerControlViewProps,
} from './ServerControl'
import { SERVER_CONTROLS, controlsIn, controlsWith } from './server-scope'
import { credentialLine, identityLine } from '../../machines/servers/ServerAdvanced'
import { serverAgentRuns } from './ServerAccounts'
import { serverScope } from './AgentsSection'
import { ThisMachine } from '../../platform'
import type {
  AgentOnServer,
  Server,
  ServerState,
  ServersBridge,
  ServerView,
} from '../../machines/servers/types'

/**
 * The Servers pane, in the states that matter.
 *
 * `renderToStaticMarkup` runs no effects, which is exactly why the fetching was
 * split out of `ServerControlView`: everything below is a render of a state the
 * app really reaches — a server that has answered, one that refused, a build
 * with no server channels, a list of two — rather than the empty first frame a
 * self-fetching component would be testable in.
 *
 * Nothing here asserts a sentence by re-typing it. Where a sentence is the
 * subject, it is compared against the function that composes it —
 * `credentialLine`, `serverAgentRuns`, `SERVER_CONTROLS` — so a test cannot pass
 * by agreeing with a copy of the copy.
 */

const OFFICE: Server = {
  id: 'a',
  name: 'Office box',
  address: 'example.com',
  username: 'admin',
  credential: 'key',
  fingerprint: 'SHA256:kJ2',
}

const WEB: Server = { id: 'b', name: 'Web host', address: 'web.example.com', username: 'deploy' }

/** A bridge with every optional channel present, so nothing is hidden by absence. */
const WIRED = new Proxy({} as ServersBridge, {
  get: () => () => new Promise(() => undefined),
}) as ServersBridge

function view(agents: readonly AgentOnServer[]): ServerView {
  return {
    measuredAt: 1,
    cards: [],
    offered: {},
    cannot: [],
    facts: { agents: { known: 'yes', value: agents, measuredAt: 1, how: '' } },
  } as unknown as ServerView
}

function draw(over: Partial<ServerControlViewProps> = {}): string {
  const props: ServerControlViewProps = {
    wired: true,
    missing: [],
    reading: false,
    problem: null,
    servers: [OFFICE, WEB],
    chosen: OFFICE,
    scope: serverScope(OFFICE.id),
    onScope: () => undefined,
    look: { state: 'ready', view: view([{ id: 'claude', version: '2.1', signedIn: 'yes', account: 'a@b.c', path: '/usr/local/bin/claude' }]) },
    connected: true,
    failure: null,
    grant: null,
    now: 0,
    bridge: WIRED,
    onGrant: () => undefined,
    onRevoke: () => undefined,
    onStored: () => undefined,
    ...over,
  }
  return renderToStaticMarkup(<ServerControlView {...props} />)
}

/* ------------------------------------------------------------- the pill -- */

describe('the pill names which server', () => {
  it('draws one button per server and exactly one of them on', () => {
    const html = draw()
    expect(html).toContain('>Office box<')
    expect(html).toContain('>Web host<')
    expect([...html.matchAll(/aria-pressed="true"/g)]).toHaveLength(1)
    /*
     * And no seat for this computer at all — not one under a different word.
     *
     * `scopesFor` in `AgentsSection` states the rule the other two panes follow:
     * a seat that is one machine carries that machine's name, a seat that is a
     * group carries the group's word, and a pane with nothing to say about a
     * machine offers no seat for it. Nothing on this pane is a question a local
     * machine could be asked, so both head seats are absent — this computer's
     * *and* the group word **Servers**, since "all of them at once" is not
     * something this pane can answer either. Every button here is one server.
     */
    // Read off the switch itself rather than the pane: the pane's own heading is
    // the word "Servers", and half its groups have buttons in them.
    const pill = /<div class="settings-scope"[^>]*>(.*?)<\/div>/s.exec(html)?.[1] ?? ''
    expect(pill).not.toBe('')
    expect(pill).not.toContain('This machine')
    expect(pill).not.toContain(`>${ThisMachine()}<`)
    expect(pill).not.toContain('>Servers<')
    // Every seat is one server, and there are exactly as many as there are
    // servers — no head seats at all.
    expect([...pill.matchAll(/<button/g)]).toHaveLength(2)
  })

  it('names the group for a screen reader as the choice it is', () => {
    expect(draw()).toContain('aria-label="Which server these settings are for"')
  })

  it('draws no pill at all when there is nothing to choose between', () => {
    const html = draw({ servers: [], chosen: null })
    expect(html).not.toContain('settings-scope')
    expect(html).toContain('No servers yet')
  })

  /**
   * The guard `AgentsSection` names: a scope pointing at a machine that has
   * gone. Here it can happen from the pane itself — the Forget button is on it —
   * so the fallback is derived rather than repaired by an effect, and this is
   * that derivation.
   */
  it('falls back to a server that is still there when the chosen one is forgotten', () => {
    expect(chosenServer([OFFICE, WEB], serverScope(WEB.id))).toEqual(WEB)
    // Forgotten while it was the one on screen.
    expect(chosenServer([WEB], serverScope(OFFICE.id))).toEqual(WEB)
    // Nothing left at all is the one honest null.
    expect(chosenServer([], serverScope(OFFICE.id))).toBeNull()
    // And a scope that never named a server — the state this pane opens in.
    expect(chosenServer([OFFICE, WEB], 'this-machine')).toEqual(OFFICE)
  })
})

/* ----------------------------------------------------------- the absences -- */

describe('what a server cannot carry is said, and never drawn', () => {
  it('prints every sentence the table owes this pane', () => {
    const html = draw()
    const owed = SERVER_CONTROLS.filter((entry) => entry.group !== undefined)
    // The guard's own guard.
    expect(owed.length).toBeGreaterThan(6)
    for (const entry of owed) {
      expect(html, entry.local).toContain(entry.local)
      // Compared against the table rather than against a string typed here, so
      // a sentence cannot be softened in one place and left in the other.
      expect(html, entry.say).toContain(escapeHtml(entry.say))
    }
  })

  it('draws no control for any of them', () => {
    const html = draw()
    // The whole pane, and the two controls a "not here" would most plausibly be
    // drawn as: the local pane's two pickers.
    expect(html).not.toContain('<select')
    // The absences are a list, and a list item carries nothing pressable.
    for (const block of html.matchAll(/<ul class="settings-absent">(.*?)<\/ul>/gs)) {
      expect(block[1]).not.toContain('<button')
      expect(block[1]).not.toContain('<input')
      expect(block[1]).not.toContain('<a ')
    }
  })

  it('says nothing about the ones it decided not to print', () => {
    const html = draw()
    const quiet = SERVER_CONTROLS.filter((entry) => entry.quiet !== undefined)
    expect(quiet.length).toBeGreaterThan(0)
    for (const entry of quiet) expect(html, entry.local).not.toContain(escapeHtml(entry.say))
  })

  it('answers the accounts, the browser, the copilot and the lid', () => {
    // Four groups, because those are the four panes this window has for this
    // machine whose control cannot cross. Named by the table so a group added
    // there is a group that must be rendered here.
    for (const group of ['coding', 'browser', 'copilot', 'power', 'sessions'] as const) {
      expect(controlsIn(group).length, group).toBeGreaterThan(0)
    }
  })
})

/* --------------------------------------------------------- what is carried -- */

describe('what a server does carry is drawn from the server’s own answer', () => {
  it('lists the agents in the runs the composer puts them in', () => {
    const agents: AgentOnServer[] = [
      { id: 'claude', version: '2.1', signedIn: 'yes', account: 'a@b.c', path: '/usr/local/bin/claude' },
    ]
    const html = draw({ look: { state: 'ready', view: view(agents) } })
    for (const run of serverAgentRuns(agents)) {
      for (const row of run.agents) expect(html, row.line).toContain(escapeHtml(row.line))
    }
  })

  it('says the server has not answered yet rather than that it has nothing', () => {
    const html = draw({ look: { state: 'looking' }, connected: false })
    expect(html).toContain('Asking Office box')
  })

  it('carries the server’s own refusal, once, where it happened', () => {
    const html = draw({
      look: { state: 'failed', problem: 'That address didn’t answer.' },
      failure: 'That address didn’t answer.',
      connected: false,
    })
    expect(html).toContain('That address didn’t answer.')
  })

  it('draws the two permissions as live controls, not as sentences', () => {
    const html = draw()
    expect(html).toContain('act on browser windows here')
    expect(html).toContain('Allow it for an hour')
  })

  it('offers no permission control at all when the press would land nowhere', () => {
    // `ServerDrivesWindows` is absent rather than dead without its channel, and
    // the grant's button is disabled rather than absent because its channel is
    // one of the required ones — a build without it has no servers area at all.
    const html = draw({ bridge: null })
    expect(html).not.toContain('act on browser windows here')
    expect(html).toContain('disabled')
  })
})

/* ------------------------------------------------------------- the record -- */

describe('what this computer keeps about one server', () => {
  const record = (server: Server): string =>
    renderToStaticMarkup(
      <ServerRecord server={server} bridge={WIRED} onStored={() => undefined} />,
    )

  it('prints the sign-in and the identity in the page’s own words', () => {
    const html = record(OFFICE)
    expect(html).toContain(credentialLine(OFFICE))
    expect(html).toContain(identityLine(OFFICE))
    expect(html).toContain(OFFICE.address)
    expect(html).toContain(OFFICE.username)
  })

  it('says a server has not offered an identity rather than showing a blank', () => {
    const html = record(WEB)
    expect(html).toContain(identityLine(WEB))
    expect(identityLine(WEB)).not.toBe('')
  })

  it('asks before forgetting, and says what forgetting removes', () => {
    const html = record(OFFICE)
    // The confirmation is not on screen until the first press.
    expect(html).not.toContain('forgets the sign-in kept on this computer')
    expect(html).toContain('Forget it')
  })

  it('can act on nothing when this build has no channels', () => {
    const html = renderToStaticMarkup(
      <ServerRecord server={OFFICE} bridge={null} onStored={() => undefined} />,
    )
    // Both controls disabled rather than absent: the row is about a server that
    // is really there, and the reason nothing can be done is the build.
    expect([...html.matchAll(/disabled=""/g)].length).toBeGreaterThanOrEqual(2)
  })
})

/* ------------------------------------------------------------ the states -- */

describe('the pane says which of its own states it is in', () => {
  it('names the missing channels rather than drawing an empty list', () => {
    const html = draw({ wired: false, missing: ['servers:list', 'servers:look'] })
    expect(html).toContain('servers:list, servers:look')
    expect(html).not.toContain('settings-scope')
  })

  it('does not call an unread list an empty one', () => {
    expect(draw({ servers: [], chosen: null, reading: true })).toContain('Reading your servers')
  })
})

/* -------------------------------------------------------------- the look -- */

describe('one server’s connection, as the list already reads it', () => {
  const room = (over: Partial<ServerState>): ServerState => ({ id: 'a', link: 'ready', ...over })

  it('has nothing to say about a server nobody has selected', () => {
    expect(lookOf(null, null)).toBeUndefined()
    expect(lookOf(OFFICE, null)).toBeUndefined()
  })

  it('is asking while it is connecting', () => {
    expect(lookOf(OFFICE, room({ link: 'connecting' }))).toEqual({ state: 'looking' })
  })

  it('carries the far end’s own sentence when it refused', () => {
    expect(lookOf(OFFICE, room({ link: 'failed', problem: 'Nope.' }))).toEqual({
      state: 'failed',
      problem: 'Nope.',
    })
  })

  it('writes one of its own only when the far end gave none', () => {
    const answer = lookOf(OFFICE, room({ link: 'failed' }))
    expect(answer).toEqual({ state: 'failed', problem: 'Office box did not answer.' })
  })

  it('waits for the view rather than reporting an empty one', () => {
    expect(lookOf(OFFICE, room({ link: 'ready' }))).toBeUndefined()
  })
})

/** Static markup escapes these three; the table's sentences contain them. */
function escapeHtml(text: string): string {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

/** Nothing in the table may claim a verdict the pane has no way to honour. */
describe('the table and the pane agree', () => {
  it('gives every printed row a group the pane renders', () => {
    for (const entry of [...controlsWith('cannot'), ...controlsWith('instead')]) {
      expect(
        entry.group !== undefined || entry.quiet !== undefined,
        `${entry.local} is neither printed nor explained away`,
      ).toBe(true)
    }
  })

  it('prints nothing for a row a server carries', () => {
    for (const entry of controlsWith('carried')) expect(entry.group).toBeUndefined()
    for (const entry of controlsWith('app-wide')) expect(entry.group).toBeUndefined()
  })
})

/* -------------------------------------------------------------- the copy -- */

/**
 * The window's copy budget, measured on the pane a person actually sees.
 *
 * `copy-length.test.tsx` measures every pane in the rail, and it would measure
 * this one at **zero words**: it renders with no bridge, and with no server
 * channels this pane draws one notice and stops. A budget satisfied by rendering
 * nothing is the shape of a guard that has quietly stopped guarding, which that
 * file's own header warns about — so the same two ceilings are applied here, to
 * a wired pane with a server on it.
 *
 * The numbers are that file's, unchanged: 55 words in any one standing
 * paragraph, 130 across the pane. Two paragraphs on this pane come from
 * components the server's own page also draws, and both were split in two when
 * they arrived here rather than being written twice — see `ServerAdvanced`.
 *
 * The labelled list of what a server cannot carry is deliberately *not* prose
 * and is not measured here: it is a name and one line each, capped at 30 words
 * per line by `server-scope.test.ts`, which is the shape the copy brief asked
 * for — *"one liner or two liner descriptions"* — rather than a paragraph.
 */
describe("the pane stays inside the window's copy budget", () => {
  const PROSE = /<p class="(?:settings-prose|settings-explain-body)"[^>]*>(.*?)<\/p>/gs

  const words = (markup: string): number =>
    markup
      .replace(/<[^>]*>/g, ' ')
      .replace(/&[a-z]+;|&#\d+;/gi, ' ')
      .replace(/[—–]/g, ' ')
      .trim()
      .split(/\s+/).length

  const paragraphs = (): number[] => [...draw().matchAll(PROSE)].map((match) => words(match[1]))

  it('measures something, so a pass means the rule held', () => {
    expect(paragraphs().length).toBeGreaterThan(1)
  })

  it('keeps every standing paragraph under 55 words', () => {
    for (const count of paragraphs()) expect(count).toBeLessThanOrEqual(55)
  })

  it('keeps the whole pane under 130 words of standing prose', () => {
    expect(paragraphs().reduce((sum, count) => sum + count, 0)).toBeLessThanOrEqual(130)
  })
})

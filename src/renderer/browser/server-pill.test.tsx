import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { WorkspaceTabStrip } from './WorkspaceTabStrip'
import {
  KIND_ICON,
  MACHINE_ICON,
  serverTabId,
  tabIdentities,
  tabTooltip,
  type WorkspaceTab,
} from '../shell/workspace-tabs'
import { SERVER_ICON } from '../machines/servers/glyph'

/**
 * A terminal on a server gets a pill on the top strip, and it is the same pill a
 * local session gets.
 *
 * ## Why this exists
 *
 * `SERVERS-DESIGN.md` §5.5 argued the opposite and named the risk exactly: *"a
 * pill carrying six controls that all do nothing is the exact defect `panels.ts`
 * records the copilot page having had, in reverse."* That half of the argument
 * is right and is kept — the model, effort and connector cluster is **absent**
 * over a server session, and `server-session-wiring.test.ts` pins that. What was
 * wrong was concluding that the *pill* had to go with them. A pill is not a
 * control cluster; it is the answer to *what do I have open*, and a shell on
 * somebody's server is one of those.
 *
 * The instruction that overrules it is the one Asad has now given three nights
 * running about machines that are not this one: *"the shape of the application
 * should not be changing for local and remote devices. It should act like that
 * same."*
 *
 * ## The two halves, which pull against each other
 *
 * The pill has to be **indistinguishable** from a local one — same glyph, same
 * dot — and its ✕ has to be **distinguishable in what it says and does**,
 * because on a local pill the ✕ takes the tab off the bar and leaves the session
 * running. That tension is why both halves need a test.
 */

const SERVER = { id: '11111111-2222-3333-4444-555555555555', name: 'the shop' }
const OTHER = { id: '99999999-8888-7777-6666-555555555555', name: 'db-01' }
const SHELL_ID = serverTabId(SERVER.id, 'k1')

const LOCAL: WorkspaceTab = {
  id: 's1',
  kind: 'session',
  label: 'Session 1',
  status: 'idle',
  projectPath: '/p',
  closable: true,
}

const SHELL: WorkspaceTab = {
  id: SHELL_ID,
  kind: 'session',
  label: '',
  status: 'idle',
  server: SERVER,
  closable: true,
}

/** A storage holding a promoted order, so every pill is on the bar at once. */
function promoting(ids: readonly string[]): Storage {
  const held = new Map<string, string>([['terminaldeck.strip.promoted', JSON.stringify(ids)]])
  return {
    get length() {
      return held.size
    },
    clear: () => held.clear(),
    getItem: (key: string) => held.get(key) ?? null,
    key: (index: number) => [...held.keys()][index] ?? null,
    removeItem: (key: string) => void held.delete(key),
    setItem: (key: string, value: string) => void held.set(key, value),
  }
}

function strip(
  tabs: readonly WorkspaceTab[],
  props: { onEndRemote?: (id: string) => void; activeTabId?: string | null } = {},
): string {
  const { activeTabId = 's1', onEndRemote } = props
  return renderToStaticMarkup(
    <WorkspaceTabStrip
      tabs={tabs}
      activeTabId={activeTabId}
      onSelect={() => {}}
      onShowInstead={() => {}}
      {...(onEndRemote ? { onEndRemote } : {})}
      storage={promoting(tabs.map((tab) => tab.id))}
    />,
  )
}

/** The markup of one tab, sliced out of the strip by its id. */
function pill(html: string, id: string): string {
  const at = html.indexOf(`data-tab-id="${id}"`)
  expect(at, `no tab ${id} in the strip`).toBeGreaterThan(-1)
  const start = html.lastIndexOf('<div', at)
  const next = html.indexOf('data-strip-tab', at + 1)
  return html.slice(start, next === -1 ? undefined : html.lastIndexOf('<div', next))
}

describe('a terminal on a server is drawn as a tab', () => {
  it('appears in the strip at all', () => {
    // The whole of the defect: before this, opening one produced a rectangle
    // inside a panel, and the strip had nothing to draw because the shell was
    // not a tab.
    expect(strip([LOCAL, SHELL])).toContain(`data-tab-id="${SHELL_ID}"`)
  })

  it('wears the session glyph and not the server mark', () => {
    /*
     * The mark belongs on the rail heading, which is what says where the row is
     * running. Repeating it on the pill would make one session look like a
     * different kind of object from the one beside it, which is precisely the
     * complaint about the machine rows that was fixed by taking their marks off.
     */
    const html = pill(strip([LOCAL, SHELL]), SHELL_ID)
    expect(html).toContain(KIND_ICON.session)
    expect(html).not.toContain(SERVER_ICON)
    expect(html).not.toContain(MACHINE_ICON)
  })

  it('carries a status dot, like the local pill beside it', () => {
    const html = strip([LOCAL, SHELL])
    expect(pill(html, SHELL_ID)).toContain('class="status-dot"')
    expect(pill(html, 's1')).toContain('class="status-dot"')
  })

  it('is draggable, which is half of what he asked for', () => {
    // *"I cannot drag it up there."* A pill that could not be rearranged would
    // be a pill in name only.
    expect(pill(strip([LOCAL, SHELL]), SHELL_ID)).toContain('draggable="true"')
  })
})

describe('the ✕ on a server pill ends the terminal', () => {
  it('says so, and says what it leaves alone', () => {
    /*
     * A local pill's ✕ means *remove from the top bar*, and that reading is only
     * available because the rail still holds the row and the process is this
     * app's. This one ends a shell. The two sentences have to differ, or the
     * same glyph is doing opposite things a centimetre apart — and the second
     * clause answers the question a person actually has, which is whether this
     * stops their website.
     */
    const html = pill(strip([LOCAL, SHELL], { onEndRemote: () => {} }), SHELL_ID)
    expect(html).toContain(`ends this terminal on ${SERVER.name}`)
    expect(html).toContain('The server itself is left alone.')
    expect(html).toContain('data-ends')
    // And the local pill keeps the sentence it already had.
    const local = pill(strip([LOCAL, SHELL], { onEndRemote: () => {} }), 's1')
    expect(local).toContain('Remove from the top bar')
    expect(local).not.toContain('data-ends')
  })

  it('is absent rather than inert when the host cannot end one', () => {
    /*
     * A strip mounted without `onEndRemote` — a test, the harness — draws no ✕
     * on a server pill at all rather than one that swallows the press. The same
     * rule the remote pill follows, and this product's rule generally.
     */
    const html = pill(strip([LOCAL, SHELL]), SHELL_ID)
    expect(html).not.toContain('strip-tab-close')
    // The local one still has its own, which is what makes this "absent here"
    // rather than "absent in this render".
    expect(pill(strip([LOCAL, SHELL]), 's1')).toContain('strip-tab-close')
  })
})

describe('two servers’ terminals are told apart by name, not by a fragment of an id', () => {
  it('qualifies colliding pills with the server they are on', () => {
    /*
     * Both are called *Session 1* — the numbering counts siblings on the same
     * machine, deliberately, so that a second server does not start at three —
     * and in the strip there is no heading above either of them. The folder
     * cannot separate them either, because a shell on a server has none this app
     * knows.
     *
     * What was left was the id rung, and on these ids it is close to useless: a
     * server tab's id begins `server ` followed by a UUID, and `shortSessionId`
     * cuts at the first hyphen, so the qualifier a person would have read is
     * `server 1`. The name is the fact that actually separates them, and it is
     * the same word on the rail heading, so a pill can be matched by eye to the
     * row it belongs to.
     */
    const other: WorkspaceTab = { ...SHELL, id: serverTabId(OTHER.id, 'k1'), server: OTHER }
    const identities = tabIdentities([SHELL, other])
    expect(identities.get(SHELL.id)).toEqual({ label: 'Session 1', qualifier: SERVER.name })
    expect(identities.get(other.id)).toEqual({ label: 'Session 1', qualifier: OTHER.name })
  })

  it('leaves a session running here unqualified beside one that is not', () => {
    /*
     * This computer is the default place and has no name in this window's
     * vocabulary, so *Session 1 · your Mac* beside *Session 1 · the shop* would
     * be labelling the ordinary case to explain the unusual one. The pair is
     * already separated, because only one of them carries a name.
     */
    const here: WorkspaceTab = { id: 'l1', kind: 'session', label: '', closable: true }
    const identities = tabIdentities([here, SHELL])
    expect(identities.get('l1')).toEqual({ label: 'Session 1', qualifier: null })
    expect(identities.get(SHELL.id)).toEqual({ label: 'Session 1', qualifier: SERVER.name })
  })

  it('says which server in the pill’s own hover, collision or not', () => {
    /*
     * The qualifier only appears when two pills collide, and one terminal on one
     * server produces no collision at all — so without this the ordinary case is
     * a pill reading *Session 1* and nothing else, over a shell on somebody's
     * live machine, sitting between two sessions running here. The rail row
     * already answers this in its own hover.
     *
     * No folder on the line: a shell starts wherever that sign-in lands and this
     * app has not asked where that is.
     */
    expect(tabTooltip(SHELL, 'Session 1')).toBe(`Session 1\non ${SERVER.name}`)
    // And a session running here is unchanged.
    expect(tabTooltip(LOCAL, 'Session 1')).toBe('Session 1\n/p')
  })
})

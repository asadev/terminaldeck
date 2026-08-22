import { describe, expect, it } from 'vitest'
import { readServerTabId, serverTabId, tabLabel } from '../../shell/workspace-tabs'
import {
  newShellKey,
  renameServersIn,
  serverSessionEnded,
  serverSessionGroups,
  serverTabs,
  withoutServer,
  withoutServerSession,
  withServerSession,
  type ServerSession,
} from './server-sessions'

/**
 * The rules that make a shell on a server a **session** rather than a rectangle
 * on a page.
 *
 * These are pinned here, away from React, because every one of them is a rule
 * about a list and each was decided against an alternative that also worked on
 * the day: what a row is called, which heading it belongs under, what closing
 * one takes with it, and how a tab id comes apart again. The rendering is
 * checked by looking at it; this is the part a screenshot cannot hold still.
 */

const A = '11111111-2222-3333-4444-555555555555'
const B = '99999999-8888-7777-6666-555555555555'

function twoOn(serverId: string, name: string): ServerSession[] {
  return withServerSession(withServerSession([], serverId, name, 'k1'), serverId, name, 'k2')
}

describe('the two handles a server tab joins', () => {
  it('comes back apart into exactly what went in', () => {
    expect(readServerTabId(serverTabId(A, 'k1'))).toEqual({ serverId: A, shellKey: 'k1' })
  })

  it('answers null for every id that is not one, rather than throwing', () => {
    /*
     * Null and not a throw, for the reason the machine pair gives: every caller
     * is asking the *question* — is this thing somewhere else — rather than
     * asserting the answer. `selectTab` and `closeTab` both take an id from a
     * click and have to route it, and a routing decision that throws on the
     * ordinary case is not a routing decision.
     */
    for (const id of ['s1', 'machine m-1 r1', 'server', 'server ', 'server  ', 'server x']) {
      expect(readServerTabId(id), id).toBeNull()
    }
  })

  it('does not answer a machine tab, and a machine reader does not answer this one', () => {
    // The two prefixes are what routing is done by. If either reader accepted
    // the other's ids, a click on one kind would be sent down the other's road.
    expect(readServerTabId(`machine ${A} r1`)).toBeNull()
  })

  it('mints a key that is different every time', () => {
    // Two tabs with one id is a strip where closing one closes the other.
    const keys = new Set(Array.from({ length: 50 }, () => newShellKey()))
    expect(keys.size).toBe(50)
  })
})

describe('the list', () => {
  it('keeps the order things were opened in, newest last', () => {
    const open = twoOn(A, 'web-01')
    expect(open.map((entry) => entry.shellKey)).toEqual(['k1', 'k2'])
  })

  it('starts a shell idle, because nothing here classifies what it is doing', () => {
    /*
     * Every other status in this window is produced by reading a local pty's
     * output. Inventing `working` from a byte count would make the dot mean
     * something different on this row than on the row above it.
     */
    expect(withServerSession([], A, 'web-01', 'k1')[0].status).toBe('idle')
  })

  it('closes one without touching its neighbour on the same server', () => {
    const open = twoOn(A, 'web-01')
    const left = withoutServerSession(open, open[0].tabId)
    expect(left.map((entry) => entry.shellKey)).toEqual(['k2'])
  })

  it('closes every shell on one server and leaves the other server alone', () => {
    const open = [...twoOn(A, 'web-01'), ...twoOn(B, 'db-01')]
    const left = withoutServer(open, A)
    expect(left).toHaveLength(2)
    expect(left.every((entry) => entry.serverId === B)).toBe(true)
  })

  it('marks a shell the far end closed as ended, and keeps the row', () => {
    /*
     * The row stays, which is what a local session does when its process ends.
     * Removing it here would take the last thing the shell printed off the
     * screen at the exact moment somebody wants to read it.
     */
    const open = twoOn(A, 'web-01')
    const after = serverSessionEnded(open, open[0].tabId)
    expect(after).toHaveLength(2)
    expect(after[0].status).toBe('exited')
    expect(after[1].status).toBe('idle')
  })

  it('brings a renamed server’s rows into step', () => {
    const open = twoOn(A, 'web-01')
    const after = renameServersIn(open, [{ id: A, name: 'the shop' }])
    expect(after.map((entry) => entry.serverName)).toEqual(['the shop', 'the shop'])
  })

  it('hands back the same array when a rename changed nothing', () => {
    // So a caller can put this straight into a state setter without a render per
    // keystroke of the rename field.
    const open = twoOn(A, 'web-01')
    expect(renameServersIn(open, [{ id: A, name: 'web-01' }])).toBe(open)
    expect(renameServersIn(open, [])).toBe(open)
  })
})

describe('the headings the rail draws', () => {
  it('draws one per server, in the order they were first opened on', () => {
    const open = [...twoOn(A, 'web-01'), ...twoOn(B, 'db-01')]
    const groups = serverSessionGroups(open)
    expect(groups.map((group) => group.name)).toEqual(['web-01', 'db-01'])
    expect(groups[0].sessions).toHaveLength(2)
  })

  it('draws nothing at all when nothing is open', () => {
    /*
     * The one place this rail is deliberately *not* shaped like the machines
     * rail above it. A machine's heading is drawn whenever the machine is
     * reachable, empty or not, because being up is a live fact about a paired
     * desktop. A server has no equivalent state — it is a stored address this
     * app never dials to find out about — so a heading per stored server would
     * be a permanent row saying nothing, in the list whose entire job is to
     * answer what you have open.
     */
    expect(serverSessionGroups([])).toEqual([])
  })

  it('keeps one server’s shells together even when they were opened apart', () => {
    // Interleaved: A, B, A. Grouping by arrival rather than by server would put
    // the same server under two headings.
    const open = [
      ...withServerSession([], A, 'web-01', 'k1'),
      ...withServerSession([], B, 'db-01', 'k2'),
      ...withServerSession([], A, 'web-01', 'k3'),
    ]
    const groups = serverSessionGroups(open)
    expect(groups).toHaveLength(2)
    expect(groups[0].sessions.map((entry) => entry.shellKey)).toEqual(['k1', 'k3'])
  })
})

describe('what a server tab is', () => {
  it('is a session tab, so everything that asks about sessions says yes', () => {
    // Not a third `TabKind`. Every place in the window that asks
    // `kind === 'session'` is asking a question whose answer here is yes: draw a
    // status dot, carry a ✕, put it in the strip.
    const [tab] = serverTabs(withServerSession([], A, 'web-01', 'k1'))
    expect(tab.kind).toBe('session')
    expect(tab.server).toEqual({ id: A, name: 'web-01' })
    expect(tab.machine).toBeUndefined()
  })

  it('is closable without asking anything at the far end', () => {
    /*
     * Unlike a machine's, which carries the far end's `close` capability. There
     * is nothing on a server to refuse: the shell exists because this window is
     * holding a connection to it.
     */
    expect(serverTabs(withServerSession([], A, 'web-01', 'k1'))[0].closable).toBe(true)
  })

  it('numbers shells per server, so a second server does not start at three', () => {
    /*
     * The sibling rule in `tabLabel` counts sessions in the same folder **on the
     * same machine**, and a server is now one of the things that can be "the
     * same machine". Without that half, every folderless shell in the window
     * fell into one run: two servers with one terminal each would have read
     * "Session 1" and "Session 2", under two different headings, with nothing on
     * screen explaining why the second one starts at two.
     */
    const tabs = serverTabs([...twoOn(A, 'web-01'), ...twoOn(B, 'db-01')])
    expect(tabs.map((tab) => tabLabel(tab, tabs))).toEqual([
      'Session 1',
      'Session 2',
      'Session 1',
      'Session 2',
    ])
  })

  it('is not numbered against the local sessions beside it', () => {
    // A shell on somebody's server is not the third session in this window's
    // untitled run, and numbering it as one would be the rail claiming a
    // relationship that does not exist.
    const local = [
      { id: 'l1', kind: 'session' as const, label: '', closable: true },
      { id: 'l2', kind: 'session' as const, label: '', closable: true },
    ]
    const tabs = [...local, ...serverTabs(withServerSession([], A, 'web-01', 'k1'))]
    expect(tabLabel(tabs[2], tabs)).toBe('Session 1')
  })
})

describe('a shell opened to run an agent', () => {
  it('carries the command on the row, and defaults to a plain prompt', () => {
    // The account chip's "New terminal running …" rows mint the command; every
    // other opener leaves it null and gets exactly the shell it always got.
    const plain = withServerSession([], 'srv-1', 'web-01', 'k1')
    expect(plain[0].run).toBeNull()
    const running = withServerSession([], 'srv-1', 'web-01', 'k2', null, 'claude')
    expect(running[1] ?? running[0]).toMatchObject({ run: 'claude', startIn: null })
  })
})

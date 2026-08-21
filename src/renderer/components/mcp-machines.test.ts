import { describe, expect, it } from 'vitest'
import { pickSurvives, reportableMachines } from './mcp-machines'
import type { MachineWithLink } from '../machines/useMachines'
import type { MachineLinkState, RemoteSession } from '../machines/types'

/**
 * Which machines the MCP page may offer a pill for.
 *
 *   > *"As soon as we connect to one machine, that machine's things should come
 *   > here and start showing here."*
 *
 * Every condition below is a state where the pill would lead somewhere with
 * nothing in it, which is the one thing this window is not allowed to have — so
 * the rule is a pure function with a test rather than three `&&`s inside a
 * render.
 */

function session(over: Partial<RemoteSession> = {}): RemoteSession {
  return { id: 's1', title: 'AAAA', cwd: '/home/imza/AAAA', provider: 'claude', status: 'idle', exitCode: null, ...over }
}

function link(over: Partial<MachineLinkState> = {}): MachineLinkState {
  return {
    id: 'm1',
    state: 'online',
    reason: null,
    sessions: [session()],
    folders: null,
    capabilities: ['controls'],
    copilot: null,
    ports: [],
    hostPlatform: 'win32',
    retryAt: null,
    ...over,
  }
}

function machine(over: Partial<MachineWithLink> = {}): MachineWithLink {
  return {
    machine: {
      id: 'm1',
      name: 'DESKTOP-DDGMNCV',
      hostId: 'h',
      fingerprint: 'f',
      platform: 'win32',
      pairedAt: 0,
      lastConnectedAt: null,
    },
    link: link(),
    ...over,
  }
}

describe('reportableMachines', () => {
  it('offers a connected machine, and names the session it will read through', () => {
    const [target] = reportableMachines([machine()])
    expect(target?.machineId).toBe('m1')
    expect(target?.name).toBe('DESKTOP-DDGMNCV')
    expect(target?.sessionId).toBe('s1')
    // The folder travels too: it is what the far end resolved the list for, and
    // two of the three MCP scopes are keyed on it.
    expect(target?.cwd).toBe('/home/imza/AAAA')
  })

  it('skips a machine that is not connected', () => {
    expect(reportableMachines([machine({ link: link({ state: 'offline' }) })])).toEqual([])
    expect(reportableMachines([machine({ link: null })])).toEqual([])
  })

  /**
   * The connectors ride the `controls` capability. A machine on a build older
   * than that never sends them, so a pill for it would be a press followed by
   * an apology — which is the shape of thing this round exists to remove.
   */
  it('skips a machine whose build cannot report its configuration', () => {
    expect(reportableMachines([machine({ link: link({ capabilities: ['create', 'close'] }) })])).toEqual([])
  })

  /**
   * MCP scope is resolved against a working directory, and the only directory
   * this wire knows over there is a running session's. No session, nothing to
   * resolve, no pill.
   */
  it('skips a machine with no session to resolve a folder from', () => {
    expect(reportableMachines([machine({ link: link({ sessions: [] }) })])).toEqual([])
  })

  it('falls back to a name for a session that never gave itself one', () => {
    const [target] = reportableMachines([machine({ link: link({ sessions: [session({ title: '' })] }) })])
    expect(target?.sessionTitle).toBe('a session')
  })

  it('keeps every machine that qualifies, in the order the estate lists them', () => {
    const second = machine({
      machine: {
        id: 'm2',
        name: 'Office PC',
        hostId: 'h2',
        fingerprint: 'f2',
        platform: 'linux',
        pairedAt: 0,
        lastConnectedAt: null,
      },
      link: link({ id: 'm2', sessions: [session({ id: 's2' })] }),
    })
    expect(reportableMachines([machine(), second]).map((entry) => entry.name)).toEqual([
      'DESKTOP-DDGMNCV',
      'Office PC',
    ])
  })
})

/**
 * The guard the Coding AI pane has had since a device could be forgotten while
 * its scope was on screen, and this page had not.
 *
 * Worth its own tests rather than trusted to the effect that calls it, because
 * the interesting states are the ones no static render produces: a machine that
 * disconnects, and — the one that actually bites — a machine that comes back.
 */
describe('the pick a machine leaving takes with it', () => {
  const target = {
    machineId: 'm1',
    name: 'DESKTOP-DDGMNCV',
    sessionId: 's1',
    sessionTitle: 'AAAA',
    cwd: '/home/imza/AAAA',
  }

  it('keeps a pick that is still on the switch', () => {
    expect(pickSurvives('m1', [target])).toBe(true)
  })

  it('drops a pick whose machine went offline', () => {
    expect(pickSurvives('m1', [])).toBe(false)
  })

  /**
   * The case the derived `target` alone does not cover. With the pick left in
   * state, the page drew this machine while the PC was away and then moved
   * itself back to the PC the moment it reconnected — a page changing what it
   * reports on with nobody having pressed anything.
   */
  it('drops it while it is gone, so a reconnect cannot move the page on its own', () => {
    expect(pickSurvives('m1', [])).toBe(false)
    expect(pickSurvives(null, [target])).toBe(true)
  })

  /**
   * Still paired, still online, last session closed. `reportableMachines` drops
   * it from the switch, so the pick has to go with it or the page is pointed at
   * a button that is not drawn.
   */
  it('drops a pick whose machine lost the session the reading goes through', () => {
    expect(pickSurvives('m1', [{ ...target, machineId: 'm2' }])).toBe(false)
  })

  it('never drops this computer, which is the one row that cannot go away', () => {
    expect(pickSurvives(null, [])).toBe(true)
  })
})

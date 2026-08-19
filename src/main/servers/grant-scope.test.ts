/**
 * The copilot's permission over a server: default no, one server at a time, and
 * never a guest.
 *
 * `SERVERS-DESIGN.md` §6.2. Four properties, and this file exists because each
 * of them decays in a different direction and none of the decays is visible in
 * review:
 *
 *  - a grant that becomes global, because "all my servers" was convenient;
 *  - a grant that stops expiring, because the timer was hard to test;
 *  - a grant that a remote caller can use, because `caller` stopped being
 *    passed down — which is precisely the regression `deck-control/surface.ts`
 *    records having had to fix on `sessions.start`;
 *  - an action reaching `act` on a server nobody granted, because the escalate
 *    hook fell back to the wrong side.
 *
 * The last one is the sharpest. `control.ts` takes the **higher** of the
 * declared tier and the escalation, so `servers.control` declares `alter` and
 * the hook can only ever move it *down* to `act` for a granted server. A bug in
 * the hook cannot weaken the gate below `alter` — but a bug that grants `act`
 * where it should not is a production website restarted with no dialog, so it
 * is pinned from both ends.
 */

import { describe, expect, it } from 'vitest'
import type { ToolContext } from '../deck-control/catalogue'
import type { Caller } from '../deck-control/surface'
import { DEFAULT_GRANT_MS, GrantRefused, MAX_GRANT_MS, ServerGrants } from './grants'
import { serverTools } from './tools'
import { fakeRoom } from './test-fixtures'

const local: Caller = { kind: 'local', tiers: { read: true, act: true, alter: true } }
const remote: Caller = { kind: 'remote', deviceId: 'phone-1', tiers: { read: true, act: true, alter: true } }

function contextFor(caller: Caller): ToolContext {
  // Only `caller` is read by `escalate` and `precheck`; the rest of the context
  // is the dispatcher's business and constructing it here would be inventing a
  // second `DeckControl`.
  return { caller } as unknown as ToolContext
}

function controlTool(grants: ServerGrants, room = fakeRoom()) {
  const tool = serverTools({ room, grants }).find((spec) => spec.id === 'servers.control')
  if (tool === undefined) throw new Error('servers.control is missing')
  return tool
}

describe('a grant covers one server, for a while, for the person at this machine', () => {
  it('starts with nothing granted', () => {
    const grants = new ServerGrants()
    expect(grants.granted('s1', local)).toBe(false)
    expect(grants.state('s1')).toBeNull()
    expect(grants.list()).toEqual([])
  })

  it('does not spread to a second server', () => {
    const grants = new ServerGrants()
    grants.grant('s1', local)
    expect(grants.granted('s1', local)).toBe(true)
    expect(grants.granted('s2', local)).toBe(false)
  })

  it('runs out', () => {
    let clock = 1_000
    const grants = new ServerGrants({ now: () => clock })
    grants.grant('s1', local)
    clock += DEFAULT_GRANT_MS - 1
    expect(grants.granted('s1', local)).toBe(true)
    clock += 2
    expect(grants.granted('s1', local)).toBe(false)
    // …and stops being reported on the page, rather than lingering as a row
    // that says "granted" while answering no.
    expect(grants.state('s1')).toBeNull()
  })

  it('cannot be asked for longer than the ceiling', () => {
    let clock = 0
    const grants = new ServerGrants({ now: () => clock })
    const state = grants.grant('s1', local, 30 * 24 * 60 * 60 * 1000)
    expect(state.expiresAt).toBe(MAX_GRANT_MS)
  })

  it('refuses a server this app does not know', () => {
    const grants = new ServerGrants({ knows: (id) => id === 's1' })
    expect(() => grants.grant('made-up', local)).toThrow(GrantRefused)
    expect(grants.granted('made-up', local)).toBe(false)
  })
})

describe('a guest never gets it, under any circumstances', () => {
  it('cannot be given one', () => {
    const grants = new ServerGrants()
    expect(() => grants.grant('s1', remote)).toThrow(GrantRefused)
    expect(grants.granted('s1', remote)).toBe(false)
  })

  it('cannot ride on one somebody else was given', () => {
    /*
     * The second of the two checks. One stops a grant existing for a remote
     * caller; this one stops a remote caller using a grant that legitimately
     * exists for the person at the keyboard. Two checks for one rule is
     * normally a smell — here they guard different events, and a hole in either
     * is a hole.
     */
    const grants = new ServerGrants()
    grants.grant('s1', local)
    expect(grants.granted('s1', local)).toBe(true)
    expect(grants.granted('s1', remote)).toBe(false)
  })

  it('is refused at the tool before any dialog is drawn', () => {
    const grants = new ServerGrants()
    grants.grant('s1', local)
    const tool = controlTool(grants)
    expect(() =>
      tool.precheck?.({ serverId: 's1', cardId: 'service:td-scratch.service', action: 'restart' }, contextFor(remote)),
    ).toThrow(/only works for the person at this machine/i)
  })

  it('never reaches act for a remote caller, whatever the map says', () => {
    const grants = new ServerGrants()
    grants.grant('s1', local)
    const tool = controlTool(grants)
    expect(tool.escalate?.({ serverId: 's1' }, contextFor(remote))).toBe('alter')
  })
})

describe('the tier follows the grant, per server', () => {
  it('asks a person when nothing is granted', () => {
    const tool = controlTool(new ServerGrants())
    expect(tool.tier).toBe('alter')
    expect(tool.escalate?.({ serverId: 's1' }, contextFor(local))).toBe('alter')
  })

  it('drops to act only for the granted server', () => {
    const grants = new ServerGrants()
    grants.grant('s1', local)
    const tool = controlTool(grants)
    expect(tool.escalate?.({ serverId: 's1' }, contextFor(local))).toBe('act')
    expect(tool.escalate?.({ serverId: 's2' }, contextFor(local))).toBe('alter')
  })

  it('goes back to asking when the grant runs out', () => {
    let clock = 0
    const grants = new ServerGrants({ now: () => clock })
    grants.grant('s1', local)
    const tool = controlTool(grants)
    expect(tool.escalate?.({ serverId: 's1' }, contextFor(local))).toBe('act')
    clock += DEFAULT_GRANT_MS + 1
    expect(tool.escalate?.({ serverId: 's1' }, contextFor(local))).toBe('alter')
  })

  it('asks a person when the call names no server at all', () => {
    // A malformed call must not be the cheapest route to `act`.
    const grants = new ServerGrants()
    grants.grant('s1', local)
    const tool = controlTool(grants)
    expect(tool.escalate?.({}, contextFor(local))).toBe('alter')
  })

  it('refuses a server the app has never looked at, rather than asking about it', () => {
    /*
     * §6.2's second precheck is *"any action on a server whose facts say the
     * action cannot be performed"*, and those facts come from a look. Refusing
     * with an instruction makes the fact check unconditional instead of
     * conditional on a warm cache — and "look before you act" is a rule a model
     * can obey.
     */
    const tool = controlTool(new ServerGrants(), fakeRoom({ seen: null }))
    expect(() =>
      tool.precheck?.({ serverId: 's1', cardId: 'service:td-scratch.service', action: 'restart' }, contextFor(local)),
    ).toThrow(/Call servers.look/)
  })

  it('refuses an action the card’s own facts do not support', () => {
    const room = fakeRoom({
      seen: {
        cards: [
          {
            id: 'service:one.service',
            kind: 'app',
            name: 'one',
            detail: '',
            running: true,
            managedBy: null,
            url: null,
            engine: null,
            repoDir: null,
          },
        ],
        facts: {
          privilege: { known: 'no', measuredAt: 0, how: 'asked' },
          init: { known: 'cannot', measuredAt: 0, why: 'we could not tell how this server starts and stops things' },
          containerRuntime: { known: 'no', measuredAt: 0, how: 'asked' },
        },
        composeAvailable: false,
        offered: { 'service:one.service': [] },
        absent: {
          'service:one.service': [
            { actionId: 'restart', because: 'We can’t tell how this server starts and stops things.' },
          ],
        },
        how: [],
        cannot: [],
        measuredAt: 0,
      },
    })
    const tool = controlTool(new ServerGrants(), room)
    expect(() =>
      tool.precheck?.({ serverId: 's1', cardId: 'service:one.service', action: 'restart' }, contextFor(local)),
    ).toThrow(/can’t tell how this server starts and stops things/)
    expect(room.acted).toEqual([])
  })
})

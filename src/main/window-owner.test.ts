import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { beforeEach, describe, expect, it } from 'vitest'
import {
  noteWindowOwner,
  resetWindowOwnersForTests,
  routeWindowVerb,
  windowOwnerOf,
} from './window-owner'

/**
 * Which app holds the window a session's browser verb is about.
 *
 * The whole feature turns on this one answer, and it was wrong in the way that
 * matters most on the evening of 2026-08-21: it was read off the *spawn*. A
 * session a paired device had asked for was routed to that device, and every
 * other session on the machine — one already running, one restored, one started
 * at that keyboard — answered "nobody", was served locally, and told its agent
 * *"no browser window is attached to this session"* about a page the person was
 * looking at. That is the first thing anybody tests, so it is the first thing
 * here.
 */

const HERE = { sessionId: 'sess-1', machineId: '' }

function deps(
  options: { attached?: boolean; holders?: string[]; machineHolders?: string[] } = {},
) {
  return {
    attachedHere: () => options.attached ?? false,
    holders: () => options.holders ?? [],
    machineHolders: () => options.machineHolders ?? [],
  }
}

beforeEach(() => {
  resetWindowOwnersForTests()
})

describe('routing a browser verb to the app that holds the window', () => {
  it('sends a session nobody spawned to the device that says it holds its window', () => {
    /*
     * The defect, stated as a test. Nothing spawned this session for anybody —
     * `windowOwnerOf` is empty — and it still has a window, in the app of the
     * machine that attached one and said so over `window.holds`.
     */
    expect(windowOwnerOf(HERE.sessionId)).toBeNull()

    expect(routeWindowVerb(HERE, deps({ holders: ['mac'] }))).toEqual({
      kind: 'peer',
      holder: { kind: 'device', id: 'mac' },
    })
  })

  it('sends it to a machine this app dialled out to when that is where the window is', () => {
    /*
     * The mirror, and the cell that did not exist before tonight. A session
     * running *here* whose window is in the app of a machine this desktop
     * dialled — announced over `CAPABILITY.hostWindows` and landing in the second
     * desk. The route has to carry which id space the answer came from, or the
     * verb goes to the wrong wire.
     */
    expect(routeWindowVerb(HERE, deps({ machineHolders: ['office-pc'] }))).toEqual({
      kind: 'peer',
      holder: { kind: 'machine', id: 'office-pc' },
    })
  })

  it('reads a build with no machine desk as no machine holding anything', () => {
    // The dep is optional so every caller written before the mirror compiles.
    // Absent must mean "none" rather than throw: the headless host has no second
    // desk and every session on it is routed through this same function.
    expect(
      routeWindowVerb(HERE, { attachedHere: () => false, holders: () => [] }),
    ).toEqual({ kind: 'here' })
  })

  it('keeps a session its device started pointed at that device, window here or not', () => {
    /*
     * The security rule the round before this one is built on, unchanged and
     * unchangeable: no local fallback. A window attached *here* to a guest's
     * session must not become a way for that guest's agent to drive the browser
     * holding this account's logins.
     */
    noteWindowOwner('guest-session', 'phone-1')

    expect(
      routeWindowVerb(
        { sessionId: 'guest-session', machineId: '' },
        deps({ attached: true, holders: ['mac'] }),
      ),
    ).toEqual({ kind: 'peer', holder: { kind: 'device', id: 'phone-1' } })
  })

  it('keeps it pointed there even when a machine this app dialled claims the window', () => {
    // The same rule, one hop further out. A machine this desktop dialled naming
    // somebody else's session would be a third computer inserting itself between
    // a guest and its own browser, so branch 1 has no machine fallback either.
    noteWindowOwner('guest-session', 'phone-1')

    expect(
      routeWindowVerb(
        { sessionId: 'guest-session', machineId: '' },
        deps({ machineHolders: ['office-pc'] }),
      ),
    ).toEqual({ kind: 'peer', holder: { kind: 'device', id: 'phone-1' } })
  })

  it('serves a local session against the window on this screen before any claim', () => {
    // The person's own session with their own window attached in this app. No
    // frame goes anywhere, and a paired machine naming that session in a
    // `window.holds` cannot take it away.
    expect(routeWindowVerb(HERE, deps({ attached: true, holders: ['mac'] }))).toEqual({
      kind: 'here',
    })
  })

  it('is served here when no window is attached anywhere, so the refusal is the local one', () => {
    // The true and ordinary state for a session that has not opened a page yet.
    // Served locally means it gets the sentence that says how to attach one,
    // rather than a frame to a machine that would answer the same thing slower.
    expect(routeWindowVerb(HERE, deps())).toEqual({ kind: 'here' })
  })

  it('refuses rather than guessing when two computers hold a window for one session', () => {
    // Two people can each attach a window of their own to one session here and
    // neither of them is wrong. A verb with two destinations has no correct one.
    expect(routeWindowVerb(HERE, deps({ holders: ['mac', 'laptop'] }))).toEqual({
      kind: 'ambiguous',
      holders: [
        { kind: 'device', id: 'mac' },
        { kind: 'device', id: 'laptop' },
      ],
    })
  })

  it('counts a device and a machine together, because neither of them is wrong', () => {
    /*
     * The two id spaces are gathered into one list rather than checked in an
     * order, and this is why: a device that dialled in and a machine this app
     * dialled out to can each have a window attached to one session here. There
     * is no order that would be right, and preferring either would be driving one
     * person's browser on a guess.
     */
    expect(
      routeWindowVerb(HERE, deps({ holders: ['mac'], machineHolders: ['office-pc'] })),
    ).toEqual({
      kind: 'ambiguous',
      holders: [
        { kind: 'device', id: 'mac' },
        { kind: 'machine', id: 'office-pc' },
      ],
    })
  })

  it('forgets nothing about a session id it has never heard of', () => {
    expect(routeWindowVerb({ sessionId: '', machineId: '' }, deps({ holders: ['mac'] }))).toEqual({
      kind: 'here',
    })
  })
})

/* -------------------------------------------------------------------------- */

describe('the route is wired to the app rather than only written', () => {
  /*
   * "Built, tested, and never wired to boot" is the bug class this app keeps
   * catching itself in, and this feature has three ends that can each be wired
   * or not: the rule above, the fact that feeds it, and the launch gate that
   * decides whether a session gets the verbs at all. None of them can be reached
   * from a unit test — they live in `index.ts`, which needs an Electron app
   * around it — so the wiring is read the way `session-restore.test.ts` reads
   * its own.
   */
  const index = readFileSync(join(__dirname, 'index.ts'), 'utf8')

  it('routes every verb through the one rule, spawned session or not', () => {
    expect(index).toContain('routeWindowVerb(session, {')
    // Both halves of the lookup the rule cannot do for itself.
    expect(index).toMatch(/attachedHere:.*windowsOf\(/s)
    expect(index).toMatch(/holders:.*holdersOf\(/s)
    // And the third: the machines this app dialled out to, which is the half the
    // rule had no way to hear about until the frames ran both ways.
    expect(index).toContain('machineHolders: (sessionId) => machineWindowAsks.holdersOf(sessionId)')
  })

  it('wires the return path end to end, not only the rule that would use it', () => {
    /*
     * "Built, tested, and never wired to boot" again, for the direction added
     * tonight. Four things have to be true at once or a session here can never
     * reach a window over there: a second desk, a wire under it, somewhere for
     * the far machine's holdings to land, and a way to serve the mirror when this
     * app is the one holding the window.
     */
    expect(index).toContain('const machineWindowAsks = createWindowAsks()')
    expect(index).toContain('machineWindowAsks.serve({')
    expect(index).toContain('windowsHeldThere: (machineId, sessions) => machineWindowAsks.held(')
    expect(index).toContain('serveWindows: (deviceId, call)')
    expect(index).toContain('windowsHeldFor: (deviceId)')
    // And the fact travels down both kinds of link on the one subscription.
    expect(index).toContain('remote.server.windowsHeldChanged()')
  })

  it('tells the paired machines which of their sessions has a window here', () => {
    // The fact only this app can know. Without it, the rule above has nothing to
    // read on the machine the pty is on.
    expect(index).toContain('windowsHeld: (machineId)')
    expect(index).toMatch(/subscribeToBindings\(/)
    expect(index).toContain('machinesIpc?.announceWindows()')
  })

  it('asks the desk whether a device can be reached, rather than answering yes', () => {
    // The constant `true` this replaced handed a phone six verbs that could only
    // ever refuse.
    expect(index).toContain('reachesDeviceWindows: (deviceId) => windowAsks.reaches(')
  })
})

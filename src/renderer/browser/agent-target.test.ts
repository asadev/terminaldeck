import { describe, expect, it } from 'vitest'
import { readSessions, resolveAgentSessions, resolveTarget, whyDisabled } from './agent-target'

/**
 * "It will just randomly send to anyone whatever I say here."
 *
 * He is describing the old behaviour exactly: every send from the browser went
 * to `activeSessionId`, whichever session happened to be focused behind the
 * page. His rules, and one case each:
 *
 *   - nothing is chosen to begin with;
 *   - the button stays grey until something is;
 *   - the choice sticks until he changes it;
 *   - a session that has died is not a target.
 *
 * And the fifth thing, which is not a rule of his but a fact about the wire:
 * a session on another machine is *listed* and cannot be typed into. The block
 * of cases at the bottom is that one. See the header of `agent-target.ts` for
 * why the far machine refuses it and what would let it stop.
 */

const LIVE = [
  { id: 'a', cwd: '/Users/apple/Projects/terminaldeck', provider: 'claude', exitCode: null },
  { id: 'b', cwd: '/Users/apple/Projects/terminaldeck', provider: 'shell', exitCode: null },
  { id: 'c', cwd: '/Users/apple/Projects/science-locus', provider: 'claude', exitCode: null },
]

/** One paired PC, connected, running two agents in one folder and one in another. */
const MACHINES = {
  machines: [{ id: 'm1', name: 'Studio PC', platform: 'win32' }],
  links: [
    {
      id: 'm1',
      state: 'online',
      sessions: [
        { id: 'r1', cwd: 'C:\\Users\\Imza\\Projects\\terminaldeck', provider: 'claude', exitCode: null },
        { id: 'r2', cwd: 'C:\\Users\\Imza\\Projects\\terminaldeck', provider: 'shell', exitCode: null },
        { id: 'r3', cwd: 'C:\\Users\\Imza\\Projects\\imza', provider: 'claude', exitCode: null },
      ],
      capabilities: ['create'],
      hostPlatform: 'win32',
    },
  ],
  blocked: null,
}

describe('readSessions', () => {
  it('numbers within a project, the way the rail does', () => {
    // So the picker says the same words as the row he would otherwise click.
    expect(readSessions(LIVE).map((session) => session.label)).toEqual([
      'terminaldeck · Session 1',
      'terminaldeck · Session 2',
      'science-locus · Session 1',
    ])
  })

  it('reads a dead session as dead', () => {
    const rows = readSessions([{ id: 'a', cwd: '/x', provider: 'claude', exitCode: 0 }])
    expect(rows[0].ended).toBe(true)
  })

  it('survives anything at all coming back across the bridge', () => {
    expect(readSessions(null)).toEqual([])
    expect(readSessions('nope')).toEqual([])
    expect(readSessions([null, 7, {}, { id: '' }])).toEqual([])
  })

  it('numbers a session with no folder in its own group', () => {
    const rows = readSessions([
      { id: 'a', cwd: '/x/one', provider: 'shell', exitCode: null },
      { id: 'b', cwd: '', provider: 'shell', exitCode: null },
    ])
    expect(rows.map((row) => row.label)).toEqual(['one · Session 1', 'Session 1'])
  })

  it('lists the connected machine’s sessions after this machine’s, named after it', () => {
    // The gap this closed: he opens the PC's localhost in this browser, inspects
    // something on the page, and the picker offers only the Mac's sessions —
    // without ever saying it had left the PC's out.
    const rows = readSessions({ here: LIVE, elsewhere: MACHINES })
    expect(rows.map((row) => row.label)).toEqual([
      'terminaldeck · Session 1',
      'terminaldeck · Session 2',
      'science-locus · Session 1',
      'Studio PC · terminaldeck · Session 1',
      'Studio PC · terminaldeck · Session 2',
      'Studio PC · imza · Session 1',
    ])
    expect(rows.map((row) => row.machineId)).toEqual(['', '', '', 'm1', 'm1', 'm1'])
  })

  it('numbers a remote folder from one rather than continuing this machine’s count', () => {
    // Two `terminaldeck` sessions are open here. The PC's first one is still
    // its Session 1 — anything else would be a number matching nothing on
    // either screen.
    const rows = readSessions({ here: LIVE, elsewhere: MACHINES })
    expect(rows[3].label).toContain('Session 1')
  })

  it('still reads a bare array as this machine’s sessions', () => {
    // Not a legacy shape: it is the honest answer from a preload with no
    // machines half, and from every test and host component that hands one in.
    expect(readSessions(LIVE).every((row) => row.machineId === '')).toBe(true)
  })

  it('drops a link whose machine it cannot name', () => {
    // Forgotten mid-connection, or two halves of the view disagreeing. A row
    // that cannot say which computer it is on is not a row.
    const rows = readSessions({
      here: [],
      elsewhere: { machines: [], links: MACHINES.links, blocked: null },
    })
    expect(rows).toEqual([])
  })

  it('survives an unreadable machines half without losing this machine’s sessions', () => {
    const rows = readSessions({ here: LIVE, elsewhere: 'nonsense' })
    expect(rows).toHaveLength(3)
  })
})

describe('resolveTarget', () => {
  const sessions = readSessions(LIVE)

  it('is nothing until something is chosen', () => {
    // The whole point. Not the first, not the only one, not the newest.
    expect(resolveTarget('', sessions)).toBeNull()
  })

  it('is the chosen session once one is', () => {
    expect(resolveTarget('b', sessions)?.label).toBe('terminaldeck · Session 2')
  })

  it('is nothing when the chosen session has gone', () => {
    expect(resolveTarget('zzz', sessions)).toBeNull()
  })

  it('is nothing when the chosen session has exited', () => {
    // His case: "if that session dies, I need to select again another session."
    const dead = readSessions([{ id: 'a', cwd: '/x', provider: 'claude', exitCode: 1 }])
    expect(resolveTarget('a', dead)).toBeNull()
  })

  it('is nothing when the chosen session is on another machine', () => {
    // Not a rule about what he may do — a refusal to report a send that the far
    // machine will drop. `input` is refused there unless this desktop is
    // attached (`src/main/remote/server.ts:2867-2878`) and the refusal comes
    // back on a frame no popup is listening for, so the button would say Sent.
    const rows = readSessions({ here: LIVE, elsewhere: MACHINES })
    expect(resolveTarget('r1', rows)).toBeNull()
  })
})

describe('whyDisabled', () => {
  const sessions = readSessions(LIVE)

  it('says which of the reasons it is', () => {
    expect(whyDisabled('', sessions, true)).toMatch(/Choose a session/)
    expect(whyDisabled('', [], true)).toMatch(/No sessions are open/)
    expect(whyDisabled('', [], false)).toMatch(/cannot list your sessions/)
    expect(whyDisabled('gone', sessions, true)).toMatch(/gone/i)
  })

  it('names the session that exited, rather than saying "a session"', () => {
    const dead = readSessions([{ id: 'a', cwd: '/x/proj', provider: 'claude', exitCode: 0 }])
    expect(whyDisabled('a', dead, true)).toContain('proj · Session 1')
  })

  it('says nothing at all once a send would work', () => {
    expect(whyDisabled('a', sessions, true)).toBe('')
  })

  it('names the machine a chosen remote session is on', () => {
    const rows = readSessions({ here: LIVE, elsewhere: MACHINES })
    const reason = whyDisabled('r1', rows, true)
    expect(reason).toContain('Studio PC')
    expect(reason).toContain('this machine')
  })

  it('says the whole list is elsewhere before he picks a row that cannot work', () => {
    // The case that made this worth building: nothing running on this Mac, the
    // PC's page on screen, three of its sessions in the dropdown.
    const rows = readSessions({ here: [], elsewhere: MACHINES })
    expect(rows).toHaveLength(3)
    expect(whyDisabled('', rows, true)).toMatch(/on another machine/)
  })

  it('says nothing about machines when there are none', () => {
    // A desktop that has never been paired to anything reads this sentence
    // before every send it ever makes. It does not get a word about machines.
    expect(whyDisabled('', sessions, true)).not.toMatch(/machine/i)
  })
})

describe('resolveAgentSessions', () => {
  const complete = {
    listSessions: () => Promise.resolve([]),
    writeToSession: () => undefined,
    onSessionCreated: () => () => undefined,
    onSessionExit: () => () => undefined,
  }

  it('accepts a preload that has all four', () => {
    expect(resolveAgentSessions(complete)).not.toBeNull()
  })

  it('refuses one missing any single method, rather than half-working', () => {
    for (const absent of Object.keys(complete)) {
      const partial: Record<string, unknown> = { ...complete }
      delete partial[absent]
      expect(resolveAgentSessions(partial), `accepted a bridge without ${absent}`).toBeNull()
    }
  })

  it('refuses nothing at all', () => {
    expect(resolveAgentSessions(null)).toBeNull()
    expect(resolveAgentSessions(undefined)).toBeNull()
    expect(resolveAgentSessions('deck')).toBeNull()
  })

  it('asks both channels and lists both answers, when the preload has machines', async () => {
    const api = resolveAgentSessions({
      ...complete,
      listSessions: () => Promise.resolve(LIVE),
      listMachines: () => Promise.resolve(MACHINES),
      onMachinesState: () => () => undefined,
    })
    expect(readSessions(await api?.listSessions())).toHaveLength(6)
  })

  it('keeps this machine’s sessions when the machines half fails', async () => {
    const api = resolveAgentSessions({
      ...complete,
      listSessions: () => Promise.resolve(LIVE),
      listMachines: () => Promise.reject(new Error('link is reconnecting')),
      onMachinesState: () => () => undefined,
    })
    expect(readSessions(await api?.listSessions())).toHaveLength(3)
  })

  it('refreshes on a machines push as well as on a session starting', () => {
    // A session started on the PC arrives inside `machines:state` and nowhere
    // else — the remote wire has no "a session appeared" event of its own. Left
    // out, the picker would be stale for exactly the rows this file was
    // extended to show.
    let sessionPushes = 0
    let machinePushes = 0
    let unsubscribed = 0
    const api = resolveAgentSessions({
      ...complete,
      onSessionCreated: (cb: () => void) => {
        sessionPushes += 1
        void cb
        return () => {
          unsubscribed += 1
        }
      },
      listMachines: () => Promise.resolve(MACHINES),
      onMachinesState: (cb: () => void) => {
        machinePushes += 1
        void cb
        return () => {
          unsubscribed += 1
        }
      },
    })
    const off = api?.onSessionCreated(() => undefined)
    expect([sessionPushes, machinePushes]).toEqual([1, 1])
    off?.()
    // Both let go, or a browser window closed while it was open leaves a
    // listener writing into a dead hook.
    expect(unsubscribed).toBe(2)
  })
})

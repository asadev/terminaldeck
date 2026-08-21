import { describe, expect, it } from 'vitest'
import {
  type AgentServerShell,
  attachableSessions,
  namesFrom,
  readSessions,
  resolveAgentSessions,
  resolveTarget,
  type SendOutcome,
  sendPayload,
  submitLine,
  whyDisabled,
} from './agent-target'

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
 * And two things from the 2026-08-20 recording, both of which had been refused
 * or missing rather than wrong:
 *
 *   - a session on another machine is a target like any other — *"if they are
 *     visible here, they should be working too"* — since `session.send` gave
 *     the wire a verb that types without attaching;
 *   - a session somebody has named says its name, not `Session 1` under the
 *     name of the folder it happens to live in.
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

/**
 * One computer that dialled **in**, with two terminals of its own.
 *
 * The shape `remote:status` answers with: a roster of connections, each carrying
 * whatever that device announced is running on its own machine. A phone is on
 * the same roster and announces nothing, which is why one is here.
 */
const GUESTS = {
  connections: [
    {
      id: 'c1',
      deviceId: 'd1',
      deviceName: 'Office PC',
      platform: 'win32',
      connectedAt: 100,
      sessionIds: [],
      tunnels: [],
      sessions: [
        { id: 'g1', title: 'terminaldeck', cwd: 'C:\\Users\\Imza\\Projects\\terminaldeck', provider: 'claude', status: 'idle', exitCode: null },
        { id: 'g2', title: 'terminaldeck', cwd: 'C:\\Users\\Imza\\Projects\\terminaldeck', provider: 'shell', status: 'idle', exitCode: null },
      ],
    },
    {
      id: 'c2',
      deviceId: 'd2',
      deviceName: 'Asad’s iPhone',
      platform: 'iOS',
      connectedAt: 200,
      sessionIds: [],
      tunnels: [],
      sessions: [],
    },
  ],
}

/** Two terminals this window has open on one server, plus one still opening. */
const SHELLS: AgentServerShell[] = [
  { tabId: 't1', serverId: 's1', serverName: 'Office PC', shellId: 'sh-1', startIn: '', ended: false },
  { tabId: 't2', serverId: 's1', serverName: 'Office PC', shellId: 'sh-2', startIn: '/srv/paperclip', ended: false },
]

describe('readSessions', () => {
  it('numbers within a project, the way the rail does', () => {
    // So the picker says the same words as the row he would otherwise click.
    expect(readSessions(LIVE).map((session) => session.label)).toEqual([
      'terminaldeck · Session 1',
      'terminaldeck · Session 2',
      'science-locus · Session 1',
    ])
  })

  it('says the name somebody typed, where the number would have been', () => {
    /*
     * Asad, 2026-08-20, looking at the copilot in this dropdown: *"Let's say
     * copilot session one — and it should call commander also, because I name it
     * as commander, but it is showing copilot."*
     *
     * `copilot · Session 1` was computed entirely from the folder. The map is
     * how the window's own names — a rail rename, and the copilot's name out of
     * its instruction file — reach a list that has never carried either.
     */
    const named = new Map([['b', 'commander']])
    expect(readSessions(LIVE, named).map((session) => session.label)).toEqual([
      'terminaldeck · Session 1',
      // The name and nothing else. It read `copilot · Commander` when he filmed
      // this, and `copilot` was the word he had just replaced.
      'commander',
      'science-locus · Session 1',
    ])
  })

  it('keeps numbering the rows it did not name', () => {
    // The number is a position in a folder, so naming the first session must not
    // renumber the second — it would be a row that changed its name because
    // somebody typed into a different one.
    const named = new Map([['a', 'commander']])
    expect(readSessions(LIVE, named)[1].label).toBe('terminaldeck · Session 2')
  })

  it('takes a title the far machine sent, but not one that is only its folder', () => {
    /*
     * Both arrive in the same field. The main process seeds every session's
     * title with `basename(cwd)` at spawn and the far machine sends that seed
     * back, so a title equal to the folder is the *absence* of a name — printing
     * it gives `terminaldeck · terminaldeck`.
     */
    const links = [
      {
        ...MACHINES.links[0],
        sessions: [
          { ...MACHINES.links[0].sessions[0], title: 'deploy the relay' },
          { ...MACHINES.links[0].sessions[1], title: 'terminaldeck' },
        ],
      },
    ]
    const rows = readSessions({ here: [], elsewhere: { ...MACHINES, links } })
    expect(rows.map((session) => session.label)).toEqual([
      'Studio PC · deploy the relay',
      'Studio PC · terminaldeck · Session 2',
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

  it('is the chosen session even when it is on another machine', () => {
    /*
     * This case asserted `toBeNull()` for a day, and the day it did was the day
     * he found it: *"I cannot send from my local browser to remote one, remote
     * session… If they are visible here, they should be working too."*
     *
     * The refusal was never about permission. `input` is refused on the far side
     * unless this desktop is attached, and attaching to send would have replayed
     * a whole scrollback into a pane he was reading. `session.send` types with
     * no attach, so the row resolves and `useAgentTarget` routes on `machineId`.
     */
    const rows = readSessions({ here: LIVE, elsewhere: MACHINES })
    const target = resolveTarget('r1', rows)
    expect(target?.machineId).toBe('m1')
    expect(target?.machineName).toBe('Studio PC')
  })

  it('is still nothing when a remote session has exited', () => {
    // Being reachable and being alive are different questions, and the second
    // one is answered the same way wherever the process was running.
    const rows = readSessions({
      here: [],
      elsewhere: {
        ...MACHINES,
        links: [{ ...MACHINES.links[0], sessions: [{ ...MACHINES.links[0].sessions[0], exitCode: 0 }] }],
      },
    })
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

  it('says nothing at all about a chosen remote session', () => {
    // It used to say "this browser sends only to sessions on this machine", and
    // the sentence went when the limitation did. A refusal that is no longer
    // true is worse than no sentence: it is the app teaching somebody not to try
    // something that works.
    const rows = readSessions({ here: LIVE, elsewhere: MACHINES })
    expect(whyDisabled('r1', rows, true)).toBe('')
  })

  it('says nothing extra when the whole list is elsewhere', () => {
    // Nothing running on this Mac, the PC's page on screen, three of its
    // sessions in the dropdown — the case that made the remote rows worth
    // listing, and now the case that works.
    const rows = readSessions({ here: [], elsewhere: MACHINES })
    expect(rows).toHaveLength(3)
    expect(whyDisabled('', rows, true)).toMatch(/Choose a session/)
    expect(whyDisabled('r1', rows, true)).toBe('')
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

  it('asks the roster too, so a computer that dialled in has rows at all', async () => {
    const api = resolveAgentSessions({
      ...complete,
      listSessions: () => Promise.resolve(LIVE),
      listMachines: () => Promise.resolve(MACHINES),
      onMachinesState: () => () => undefined,
      remoteStatus: () => Promise.resolve(GUESTS),
      onRemoteConnections: () => () => undefined,
    })
    // Three here, three on the machine this desktop dialled, two on the computer
    // that dialled this one.
    expect(readSessions(await api?.listSessions())).toHaveLength(8)
  })

  it('keeps everything else when the roster fails, the way it does for machines', async () => {
    // A remote layer that is off, starting, or mid-restart. The rows this window
    // can actually act on must not go with it.
    const api = resolveAgentSessions({
      ...complete,
      listSessions: () => Promise.resolve(LIVE),
      remoteStatus: () => Promise.reject(new Error('remote access is off')),
      onRemoteConnections: () => () => undefined,
    })
    expect(readSessions(await api?.listSessions())).toHaveLength(3)
  })

  it('adapts on the devices half alone, for a build with no machines half', async () => {
    const api = resolveAgentSessions({
      ...complete,
      listSessions: () => Promise.resolve(LIVE),
      remoteStatus: () => Promise.resolve(GUESTS),
      onRemoteConnections: () => () => undefined,
    })
    expect(readSessions(await api?.listSessions())).toHaveLength(5)
  })

  it('refreshes when a device connects or says what it is running', () => {
    /*
     * A terminal opened on his PC arrives on `remote:connections` and nowhere
     * else — the roster is pushed for every connect, disconnect and
     * announcement. Left out, the attach menu would be a snapshot of the moment
     * the window opened, which is the staleness this picker keeps being fixed
     * for.
     */
    let devicePushes = 0
    let unsubscribed = 0
    const api = resolveAgentSessions({
      ...complete,
      remoteStatus: () => Promise.resolve(GUESTS),
      onRemoteConnections: (cb: () => void) => {
        devicePushes += 1
        void cb
        return () => {
          unsubscribed += 1
        }
      },
    })
    const off = api?.onSessionCreated(() => undefined)
    expect(devicePushes).toBe(1)
    off?.()
    expect(unsubscribed).toBe(1)
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

describe('what actually goes down the pty', () => {
  it('submits a chat message and does not submit context', () => {
    /*
     * One character, two features. The copilot's rail panel is a chat box —
     * *"only one small typing box and send button"* — and a message left sitting
     * on the agent's command line is a box that did nothing. The browser's
     * popups send an element or a flow into a session for somebody to edit
     * before they press Return themselves, and a return there would fire off a
     * half-written prompt.
     */
    expect(sendPayload('what is on this page?', true)).toBe('what is on this page?\r')
    expect(sendPayload('what is on this page?', false)).toBe('what is on this page?')
  })

  it('answers empty for anything there is nothing to send about', () => {
    // The caller refuses on empty rather than writing a bare return into
    // somebody's agent, which on a CLI showing a numbered dialog answers it.
    expect(sendPayload('   ', true)).toBe('')
    expect(sendPayload('', false)).toBe('')
  })
})

/**
 * "It is not even showing this session, by the way, Office PC session."
 *
 * He said it with the server's own page on screen — the browser was pointed at
 * `127.0.0.1:3100`, which was Office PC's, and the one session running on Office
 * PC was the one row the picker did not have. Two lists reached this file and
 * the third never had: a shell on a server is not in `session:list` and not in
 * `machines:list`, because nothing at the far end keeps it.
 */
describe('terminals on servers', () => {
  it('lists them after this machine’s and the paired machines’, under the server’s name', () => {
    const rows = readSessions({ here: LIVE, elsewhere: MACHINES }, undefined, SHELLS)
    expect(rows.map((row) => row.label)).toEqual([
      'terminaldeck · Session 1',
      'terminaldeck · Session 2',
      'science-locus · Session 1',
      'Studio PC · terminaldeck · Session 1',
      'Studio PC · terminaldeck · Session 2',
      'Studio PC · imza · Session 1',
      // No folder: the shell landed wherever the sign-in did, which is what the
      // rail calls `Office PC › Session 1`.
      'Office PC · Session 1',
      'Office PC · paperclip · Session 1',
    ])
  })

  it('carries the server, the shell handle and the server’s name on the row', () => {
    const row = readSessions([], undefined, SHELLS)[0]
    expect(row).toMatchObject({
      id: 't1',
      serverId: 's1',
      shellId: 'sh-1',
      machineId: '',
      machineName: 'Office PC',
    })
  })

  it('numbers per server rather than continuing this machine’s count', () => {
    // Two `terminaldeck` sessions are open here; the server's first shell is
    // still its Session 1, the same rule the machines branch follows.
    const rows = readSessions(LIVE, undefined, SHELLS)
    expect(rows[3].label).toBe('Office PC · Session 1')
  })

  it('lists them even when there is no session list at all', () => {
    // A window with nothing running on this Mac and no paired machine still has
    // the shell it opened on a server, and the picker is the whole route to it.
    expect(readSessions(null, undefined, SHELLS).map((row) => row.label)).toEqual([
      'Office PC · Session 1',
      'Office PC · paperclip · Session 1',
    ])
  })

  it('drops a shell it cannot name a server for', () => {
    // A row that cannot say which computer it is on is not a row — the same line
    // `sessionsElsewhere` takes about a link whose machine has been forgotten.
    const nameless: AgentServerShell[] = [
      { tabId: 't9', serverId: 's9', serverName: '', shellId: 'sh-9', startIn: '', ended: false },
    ]
    expect(readSessions([], undefined, nameless)).toEqual([])
  })

  it('is not a target while the server is still opening it', () => {
    // This window mints the tab id before it asks the server for anything, so
    // for a second there is a row with no channel behind it. Listed, because it
    // is in the rail; refused, because `servers:shell:write` has nothing to take.
    const opening: AgentServerShell[] = [
      { tabId: 't3', serverId: 's1', serverName: 'Office PC', shellId: '', startIn: '', ended: false },
    ]
    const rows = readSessions([], undefined, opening)
    expect(rows).toHaveLength(1)
    expect(resolveTarget('t3', rows)).toBeNull()
    expect(whyDisabled('t3', rows, true)).toBe('That terminal on Office PC is still opening.')
  })

  it('is a target the moment the handle is there', () => {
    const rows = readSessions([], undefined, SHELLS)
    expect(resolveTarget('t1', rows)?.shellId).toBe('sh-1')
    expect(whyDisabled('t1', rows, true)).toBe('')
  })

  it('is not a target once the far end has gone', () => {
    const gone: AgentServerShell[] = [{ ...SHELLS[0], ended: true }]
    const rows = readSessions([], undefined, gone)
    expect(resolveTarget('t1', rows)).toBeNull()
    expect(whyDisabled('t1', rows, true)).toMatch(/has exited/)
  })
})

/**
 * "Why do we have two commander sessions and none of this is calling template?"
 *
 * There was one copilot. The other row was a session he had started in the same
 * folder and named himself, wearing the copilot's name because the rule matched
 * on `cwd` — and matched *after* the line that stores what he typed, so it
 * overwrote his own name with one he had not chosen.
 */
describe('namesFrom', () => {
  const COPILOT_ROOT = '/Users/apple/Templates'
  const stored = [
    { id: 'cop', cwd: COPILOT_ROOT, title: 'Templates' },
    { id: 'mine', cwd: COPILOT_ROOT, title: 'This mac session' },
    { id: 'other', cwd: '/Users/apple/Projects/terminaldeck', title: 'terminaldeck' },
  ]

  it('names the copilot’s own session and no other session in its folder', () => {
    const names = namesFrom(stored, { sessionId: 'cop', name: 'Commander' })
    expect(names.get('cop')).toBe('Commander')
    expect(names.get('mine')).toBe('This mac session')
  })

  it('leaves the name somebody typed alone, even in the copilot’s folder', () => {
    // The exact frame: the rail read "Templates › This mac session" and the
    // picker read "Commander".
    const rows = readSessions(
      [
        { id: 'cop', cwd: COPILOT_ROOT, provider: 'claude', exitCode: null },
        { id: 'mine', cwd: COPILOT_ROOT, provider: 'claude', exitCode: null },
      ],
      namesFrom(stored, { sessionId: 'cop', name: 'Commander' }),
    )
    expect(rows.map((row) => row.label)).toEqual(['Commander', 'This mac session'])
  })

  it('leaves an unnamed session in that folder as its folder and number', () => {
    const names = namesFrom([{ id: 'cop', cwd: COPILOT_ROOT, title: 'Templates' }], {
      sessionId: 'cop',
      name: 'Commander',
    })
    const rows = readSessions(
      [
        { id: 'cop', cwd: COPILOT_ROOT, provider: 'claude', exitCode: null },
        { id: 'fresh', cwd: COPILOT_ROOT, provider: 'claude', exitCode: null },
      ],
      names,
    )
    expect(rows.map((row) => row.label)).toEqual(['Commander', 'Templates · Session 2'])
  })

  it('takes a title only when it has moved on from the folder', () => {
    // The main process seeds every session's title with the folder's name, so a
    // title equal to it is the absence of a name rather than one.
    const names = namesFrom(stored, { sessionId: null, name: 'Commander' })
    expect(names.has('other')).toBe(false)
    expect(names.has('cop')).toBe(false)
  })

  it('names nothing specially when there is no answer about the copilot', () => {
    // No copilot channels in this build, or it is not running. Guessing which
    // row is the copilot is the one thing worse than a folder name.
    const names = namesFrom(stored, { sessionId: null, name: 'Commander' })
    expect([...names.values()]).toEqual(['This mac session'])
  })
})

/**
 * No two rows may read the same words.
 *
 * A label is the only thing a person picks a session by, so two rows wearing one
 * is a dropdown that cannot do its job. The naming defect that produced his two
 * `Commander` rows is fixed above; this is the guard on the shape of it.
 */
describe('two rows never read the same', () => {
  it('qualifies both of them with the folder and number they would have had', () => {
    const rows = readSessions(LIVE, new Map([['a', 'deploy'], ['b', 'deploy']]))
    expect(rows.map((row) => row.label)).toEqual([
      'deploy — terminaldeck · Session 1',
      'deploy — terminaldeck · Session 2',
      'science-locus · Session 1',
    ])
  })

  it('leaves a name reused on another computer alone, because the machine is already on it', () => {
    const links = [
      { ...MACHINES.links[0], sessions: [{ ...MACHINES.links[0].sessions[0], title: 'deploy' }] },
    ]
    const rows = readSessions(
      { here: [LIVE[0]], elsewhere: { ...MACHINES, links } },
      new Map([['a', 'deploy']]),
    )
    // Not a collision at all: a remote row is prefixed with its machine, so the
    // two already read differently and neither gets a qualifier it does not need.
    expect(rows.map((row) => row.label)).toEqual(['deploy', 'Studio PC · deploy'])
  })

  it('leaves a list with no collision exactly as it was', () => {
    const rows = readSessions(LIVE, new Map([['a', 'deploy']]))
    expect(rows.map((row) => row.label)).toEqual([
      'deploy',
      'terminaldeck · Session 2',
      'science-locus · Session 1',
    ])
  })
})

/**
 * "It should not be waiting us to come and send."
 *
 * He pressed Send in the browser's screenshot popup, walked to the session, and
 * found the composed line typed and unsent in its prompt box — twice on camera,
 * with the transcript above it still ending at *"Hi"*. The write carried no
 * return at all, and appending one would not have fixed it: any chunk of 64
 * bytes or more is read as pasted text, and every line this picker composes
 * carries a path and a pixel size.
 */
describe('submitLine', () => {
  const LINE = 'Look [browser screenshot with 1 mark on it of http://127.0.0.1:3100/: /Users/apple/Pictures/Terminal Deck/shot.png (2000 x 1251)]'

  async function record(
    line: string,
    answer: (data: string) => SendOutcome = () => ({ ok: true }),
  ): Promise<{ writes: string[]; waits: number[]; outcome: SendOutcome }> {
    const writes: string[] = []
    const waits: number[] = []
    const outcome = await submitLine(
      line,
      async (data) => {
        writes.push(data)
        return answer(data)
      },
      async (ms) => {
        waits.push(ms)
      },
    )
    return { writes, waits, outcome }
  }

  it('writes the words and then the return, as two writes with a gap between', async () => {
    const { writes, waits, outcome } = await record(LINE)
    expect(writes).toEqual([LINE, '\r'])
    expect(waits).toHaveLength(1)
    // Measured in `chat/attach/mentions.ts`: back to back they are one chunk and
    // nothing is sent; 30 ms apart submits.
    expect(waits[0]).toBeGreaterThanOrEqual(30)
    expect(outcome).toEqual({ ok: true })
  })

  it('never puts the return in the same chunk as the words', async () => {
    // The whole defect in one assertion: a single write of `text + '\r'` is
    // classified as a paste and its return is a newline.
    const { writes } = await record(LINE)
    expect(writes.every((chunk) => chunk === '\r' || !chunk.includes('\r'))).toBe(true)
  })

  it('waits before the return rather than after it', async () => {
    const order: string[] = []
    await submitLine(
      LINE,
      async (data) => {
        order.push(data === '\r' ? 'return' : 'text')
        return { ok: true }
      },
      async () => {
        order.push('wait')
      },
    )
    expect(order).toEqual(['text', 'wait', 'return'])
  })

  it('does not press return on a line that was refused', async () => {
    const { writes, outcome } = await record(LINE, () => ({ ok: false, message: 'That folder is not shared.' }))
    expect(writes).toEqual([LINE])
    expect(outcome).toEqual({ ok: false, message: 'That folder is not shared.' })
  })

  it('reports the refusal when it is the return that failed', async () => {
    // Rare, and honest: the characters landed and the submit did not, so the
    // line is sitting in somebody's prompt. Claiming success because the words
    // arrived is how this defect stayed invisible for a day.
    const { outcome } = await record(LINE, (data) =>
      data === '\r' ? { ok: false, message: 'That session has gone.' } : { ok: true },
    )
    expect(outcome).toEqual({ ok: false, message: 'That session has gone.' })
  })

  it('adds the trailing space a mention needs, and only for a mention', async () => {
    // `terminalWrites` owns that rule; this is the assertion that this file uses
    // it rather than reimplementing the pair.
    expect((await record('@"/a/b.ts" explain')).writes[0]).toBe('@"/a/b.ts" explain ')
    expect((await record('run the tests')).writes[0]).toBe('run the tests')
  })
})

/**
 * The same rows, filtered down to the ones a browser window can be attached to.
 *
 * Sending text and attaching a window are two different verbs with two different
 * reaches, and this list is built for the first. Every row can take text — a
 * shell on a server takes it through `servers:shell:write` — and two kinds of
 * row cannot take a window.
 */
describe('attachableSessions', () => {
  it('leaves out a shell on a server, which nothing could drive', () => {
    /*
     * Case 3 of the browser feature — a session on an SSH server driving a
     * window — is genuinely not built, and saying so is fine. Offering the
     * connection anyway is not: the row would take the tick, be given a `B1`,
     * and be attached to nothing. Its `id` is this window's *tab* id rather than
     * any session id the far end knows, and its `machineId` is empty, which the
     * binding map reads as *this computer* — so the relation would be filed
     * under a key naming a session that does not exist on the machine it claims.
     */
    const rows = readSessions(LIVE, namesFrom([], { sessionId: null, name: '' }), SHELLS)
    expect(rows.some((row) => row.serverId === 's1')).toBe(true)

    const attachable = attachableSessions(rows)
    expect(attachable.some((row) => row.serverId !== '')).toBe(false)
    // And everything that can be attached to is still there: this machine's
    // sessions are untouched by the rule.
    expect(attachable.map((row) => row.id)).toEqual(['a', 'b', 'c'])
  })

  it('leaves out a session whose process has gone', () => {
    // Attaching a window to a dead pty makes a relation nothing can ever act on,
    // and the rail already keeps the row that explains where it went.
    const rows = readSessions([...LIVE, { ...LIVE[0], id: 'd', exitCode: 0 }])
    expect(attachableSessions(rows).map((row) => row.id)).toEqual(['a', 'b', 'c'])
  })

  it('keeps a session on a paired machine, which is the whole point of the feature', () => {
    // The window is here, the pty is there, and `window.holds` is what tells
    // that machine so. A row that could not be attached to would be the feature
    // switched off at the menu.
    const rows = readSessions({ here: [], elsewhere: MACHINES })
    expect(attachableSessions(rows).map((row) => row.id)).toEqual(['r1', 'r2', 'r3'])
  })
})

/**
 * The fourth cell: a computer that dialled **in**.
 *
 * *"From any session from any device to any device's browser in one app."* Three
 * of the four worked. The fourth — an agent on a computer that reached this one,
 * driving a page on this screen — had every part built: the grant store, the
 * `window.holds` this app sends that device, the `window.call` it sends back, and
 * the filter in `index.ts` that answers which of its sessions have a window here.
 * All of it was downstream of a menu with no row, because this picker was built
 * from this machine's ptys plus the machines this desktop *dialled out to*, and a
 * device that dialled in is in neither list.
 */
describe('computers that dialled in', () => {
  it('lists what a device says is running on it, under that device’s name', () => {
    const rows = readSessions({ here: LIVE, elsewhere: null, guests: GUESTS })
    const guests = rows.filter((row) => row.dialledIn)
    expect(guests.map((row) => row.label)).toEqual([
      'Office PC · terminaldeck · Session 1',
      'Office PC · terminaldeck · Session 2',
    ])
    // Numbered per folder per device. Sharing the counter with this computer
    // would make the first one read `Session 3`, which matches nothing on either
    // screen.
    expect(rows.filter((row) => !row.dialledIn).map((row) => row.id)).toEqual(['a', 'b', 'c'])
  })

  it('files them under the device id, which is the half of the binding key that was empty', () => {
    /*
     * `browser-binding.ts` keys a window `<machineId>\0<sessionId>`, and
     * `windowsHeldFor(deviceId)` filters that map for exactly this id. Put
     * anything else in the field — the empty string, the machine store's id for
     * some other computer — and the filter is correct and always empty, which is what
     * it was.
     */
    const rows = readSessions({ here: [], elsewhere: null, guests: GUESTS })
    expect(rows.map((row) => row.machineId)).toEqual(['d1', 'd1'])
    expect(rows.map((row) => row.machineName)).toEqual(['Office PC', 'Office PC'])
    expect(rows.every((row) => row.serverId === '')).toBe(true)
  })

  it('offers them for attaching, which is the whole reason they are listed', () => {
    const rows = readSessions({ here: [], elsewhere: null, guests: GUESTS })
    expect(attachableSessions(rows).map((row) => row.id)).toEqual(['g1', 'g2'])
  })

  it('refuses to send to one, because no frame in this protocol carries a keystroke that way', () => {
    /*
     * `session.send` is a frame a *client* sends its host, and on a link somebody
     * else dialled this app is the host. So the honest answer is a refusal that
     * names the thing the row *can* do — not a press that reaches the machines
     * desk with an id it has never heard of and comes back "not connected" about
     * a computer sitting right there.
     */
    const rows = readSessions({ here: LIVE, elsewhere: null, guests: GUESTS })
    expect(resolveTarget('g1', rows)).toBeNull()
    const why = whyDisabled('g1', rows, true)
    expect(why).toContain('Office PC')
    expect(why).toContain('Attach a window')
    // And the rows that can be sent to are untouched by the rule.
    expect(resolveTarget('a', rows)?.id).toBe('a')
    expect(whyDisabled('a', rows, true)).toBe('')
  })

  it('says nothing about a phone, which has no terminals to announce', () => {
    const rows = readSessions({ here: [], elsewhere: null, guests: GUESTS })
    expect(rows.some((row) => row.machineName.includes('iPhone'))).toBe(false)
  })

  it('takes the newest connection when one device holds two, rather than merging them', () => {
    // A reconnect whose old socket has not been noticed yet. Merging would show a
    // terminal that was closed on whichever list is stale.
    const reconnected = {
      connections: [
        GUESTS.connections[0],
        { ...GUESTS.connections[0], id: 'c3', connectedAt: 300, sessions: [GUESTS.connections[0].sessions[1]] },
      ],
    }
    const rows = readSessions({ here: [], elsewhere: null, guests: reconnected })
    expect(rows.map((row) => row.id)).toEqual(['g2'])
  })

  it('drops a device it cannot name, because a label is what somebody picks by', () => {
    const nameless = { connections: [{ ...GUESTS.connections[0], deviceName: '' }] }
    expect(readSessions({ here: [], elsewhere: null, guests: nameless })).toEqual([])
  })

  it('reads the roster as an array too, which is what the push carries', () => {
    const rows = readSessions({ here: [], elsewhere: null, guests: GUESTS.connections })
    expect(rows.map((row) => row.id)).toEqual(['g1', 'g2'])
  })

  it('leaves a device out of a build with no remote layer, without losing the rest', () => {
    const rows = readSessions({ here: LIVE, elsewhere: null, guests: null })
    expect(rows.map((row) => row.id)).toEqual(['a', 'b', 'c'])
  })
})

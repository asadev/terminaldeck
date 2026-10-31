import { mkdtempSync, rmSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { MachinesView } from '../remote/machines/ipc'
import { ActionLog } from './action-log'
import type { ToolContext, ToolSpec } from './catalogue'
import { createChannelTap, type ChannelCall, type ChannelTap } from './channel-tap'
import { ConsentBroker, WINDOW_SURFACE } from './consent'
import { DeckControl } from './control'
import { machineTools, startedKey, stateWaiter, type MachineChannels, type MachineToolsDeps } from './machine-tools'
import { watchMachines, type MachineWatch } from './machine-watch'
import { ALL_TIERS, Refused, type Caller, type DeckSurface } from './surface'

/* ------------------------------------------------------------- fixtures -- */

const LOCAL: Caller = { kind: 'local', tiers: ALL_TIERS }
const PHONE: Caller = { kind: 'remote', deviceId: 'phone', tiers: ALL_TIERS }

function viewWith(sessions: Array<{ id: string; title?: string }> = []): MachinesView {
  return {
    here: 'Mac mini',
    blocked: null,
    machines: [
      {
        id: 'm1',
        name: 'Office PC',
        hostId: 'm1',
        fingerprint: 'AB:CD',
        platform: 'win32',
        pairedAt: 1,
        lastConnectedAt: 2,
      } as MachinesView['machines'][number],
    ],
    links: [
      {
        id: 'm1',
        state: 'online',
        reason: null,
        sessions: sessions.map((row) => ({
          id: row.id,
          title: row.title ?? row.id,
          cwd: '/work',
          provider: 'claude',
          status: 'waiting',
          exitCode: null,
        })),
        folders: ['/work'],
        capabilities: [],
        ports: [{ port: 3000, process: 'node', guessed: false }],
        copilot: null,
        hostPlatform: 'win32',
        hostVersion: '0.15.0',
        hostKind: null,
        retryAt: null,
      } as unknown as MachinesView['links'][number],
    ],
  }
}

interface Rig {
  tap: ChannelTap
  watch: MachineWatch
  calls: unknown[][]
  answers: Partial<Record<keyof MachineChannels, (...args: unknown[]) => unknown>>
  tools: ToolSpec[]
  tool(id: string): ToolSpec
  started: Set<string>
  context(caller?: Caller): ToolContext
}

let rig: Rig
let userData = ''

function makeRig(): Rig {
  const tap = createChannelTap()
  const watch = watchMachines(tap)
  const calls: unknown[][] = []
  const answers: Rig['answers'] = { 'machines:list': () => viewWith([{ id: 's-theirs' }]) }
  const call = (async (channel: keyof MachineChannels, ...args: unknown[]) => {
    calls.push([channel, ...args])
    const answer = answers[channel]
    if (answer === undefined) throw new Error(`the test did not expect ${channel}`)
    return answer(...args)
  }) as ChannelCall<MachineChannels>
  const deps: MachineToolsDeps = { call, nextState: stateWaiter(tap), watch, userData: () => userData }
  const tools = machineTools(deps)
  const started = new Set<string>()
  return {
    tap,
    watch,
    calls,
    answers,
    tools,
    tool: (id) => {
      const found = tools.find((spec) => spec.id === id)
      if (!found) throw new Error(`no tool ${id}`)
      return found
    },
    started,
    context: (caller = LOCAL) =>
      ({
        surface: {} as DeckSurface,
        callId: 'row-1',
        caller,
        attended: true,
        startedByCopilot: (id: string) => started.has(id),
        noteStarted: (id: string) => started.add(id),
        now: () => 1_700_000_000_000,
      }) as ToolContext,
  }
}

beforeEach(() => {
  userData = mkdtempSync(join(tmpdir(), 'machine-tools-'))
  rig = makeRig()
})

afterEach(() => {
  rig.watch.dispose()
  rmSync(userData, { recursive: true, force: true })
  vi.useRealTimers()
})

/* ---------------------------------------------------------------- tests -- */

describe('machines.look', () => {
  it('joins each machine to its live link, so a model cannot read one machine’s state off another’s row', async () => {
    const out = await rig.tool('machines.look').run({}, rig.context())
    const value = out.value as { thisComputer: string; machines: Array<Record<string, unknown>> }
    expect(value.thisComputer).toBe('Mac mini')
    expect(value.machines).toEqual([
      expect.objectContaining({
        id: 'm1',
        name: 'Office PC',
        online: true,
        folders: ['/work'],
        sessions: [expect.objectContaining({ id: 's-theirs', folder: '/work', agent: 'claude', status: 'waiting' })],
      }),
    ])
  })

  it('reads one session without ever asking for the expensive usage refresh', async () => {
    rig.answers['machines:controls:read'] = () => ({ model: 'opus' })
    rig.answers['machines:account:read'] = () => ({ account: 'work' })
    rig.answers['machines:usage:read'] = (_id, _session, want) => ({ want })
    const out = await rig.tool('machines.look').run({ machineId: 'm1', sessionId: 's-theirs' }, rig.context())
    const wants = rig.calls.filter((row) => row[0] === 'machines:usage:read').map((row) => row[3])
    expect(wants.sort()).toEqual(['context', 'plan'])
    expect(rig.calls.some((row) => row[0] === 'machines:usage:read' && row[4] === true)).toBe(false)
    expect((out.value as { screen: unknown }).screen).toBeNull()
    expect((out.value as { screenNote: string }).screenNote).toContain('watch')
  })

  it('refuses a paired device before anything is asked', () => {
    expect(() => rig.tool('machines.look').precheck?.({}, rig.context(PHONE))).toThrow(Refused)
  })
})

describe('machines.session', () => {
  it('starts a session and learns its id from the push that lists it', async () => {
    rig.answers['machines:create'] = () => {
      // The far machine answering: a fresh list with one more session in it.
      setTimeout(() => rig.tap.pushed('machines:state', [viewWith([{ id: 's-theirs' }, { id: 's-new' }])]), 5)
      return true
    }
    const out = await rig.tool('machines.session').run({ machineId: 'm1', do: 'start', folder: '/work', agent: 'claude' }, rig.context())
    expect((out.value as { id: string }).id).toBe('s-new')
    expect(rig.started.has(startedKey('m1', 's-new'))).toBe(true)
    expect(rig.calls).toContainEqual(['machines:create', 'm1', '/work', 'claude'])
  })

  it('is act on the copilot’s own session and alter on anybody else’s', () => {
    const session = rig.tool('machines.session')
    rig.started.add(startedKey('m1', 's-mine'))
    const ctx = rig.context()
    expect(session.escalate?.({ machineId: 'm1', do: 'send', sessionId: 's-mine', text: 'go' }, ctx)).toBe('act')
    expect(session.escalate?.({ machineId: 'm1', do: 'send', sessionId: 's-theirs', text: 'go' }, ctx)).toBe('alter')
    expect(session.escalate?.({ machineId: 'm1', do: 'stop', sessionId: 's-theirs' }, ctx)).toBe('alter')
    expect(session.escalate?.({ machineId: 'm1', do: 'start' }, ctx)).toBe('act')
  })

  it('keeps the permission mode and a login switch behind a person, even on its own session', () => {
    const session = rig.tool('machines.session')
    rig.started.add(startedKey('m1', 's-mine'))
    const ctx = rig.context()
    expect(session.escalate?.({ machineId: 'm1', do: 'set', sessionId: 's-mine', control: 'permission', value: 'x' }, ctx)).toBe('alter')
    expect(session.escalate?.({ machineId: 'm1', do: 'set', sessionId: 's-mine', control: 'model', value: 'x' }, ctx)).toBe('act')
    expect(session.escalate?.({ machineId: 'm1', do: 'switch-login', sessionId: 's-mine', loginId: 'a' }, ctx)).toBe('alter')
  })

  it('presses named keys as the bytes a terminal expects', async () => {
    rig.answers['machines:send'] = () => ({ ok: true, message: 'sent' })
    await rig.tool('machines.session').run({ machineId: 'm1', do: 'keys', sessionId: 's-theirs', keys: ['up', 'enter'] }, rig.context())
    // One key per write: a terminal reads two keys in one chunk as one input.
    expect(rig.calls.filter((call) => call[0] === 'machines:send')).toEqual([
      ['machines:send', 'm1', 's-theirs', '\u001b[A'],
      ['machines:send', 'm1', 's-theirs', '\r'],
    ])
  })

  it('refuses a newline inside sent text before a dialog could quote it', () => {
    expect(() =>
      rig.tool('machines.session').precheck?.({ machineId: 'm1', do: 'send', sessionId: 's1', text: 'a\nrm -rf' }, rig.context()),
    ).toThrow(/printable/)
  })

  it('sends a line with return by default, and without it when asked', async () => {
    rig.answers['machines:send'] = () => ({ ok: true, message: 'sent' })
    const session = rig.tool('machines.session')
    await session.run({ machineId: 'm1', do: 'send', sessionId: 's-theirs', text: 'hello' }, rig.context())
    await session.run({ machineId: 'm1', do: 'send', sessionId: 's-theirs', text: 'draft', submit: false }, rig.context())
    // The line and its Enter as two writes, never `hello\r` in one — that is a
    // paste to the agent on the far computer and is never sent.
    expect(rig.calls.filter((call) => call[0] === 'machines:send')).toEqual([
      ['machines:send', 'm1', 's-theirs', 'hello'],
      ['machines:send', 'm1', 's-theirs', '\r'],
      ['machines:send', 'm1', 's-theirs', 'draft'],
    ])
  })

  it('names a session the machine does not have', async () => {
    await expect(
      rig.tool('machines.session').run({ machineId: 'm1', do: 'stop', sessionId: 'nope' }, rig.context()),
    ).rejects.toThrow(/no session nope/)
  })
})

describe('machines.manage', () => {
  it('pairs without handing back the credential or the private key the far machine issued', async () => {
    rig.answers['machines:pair'] = () => ({
      ok: true,
      offer: { hostId: 'm1', name: 'Office PC' },
      credential: 'BEARER-SECRET-123',
      deviceId: 'd1',
      deviceName: 'Mac mini',
      guestKeys: { publicKey: Buffer.from('PUB'), secretKey: Buffer.from('PRIVATE-KEY-BYTES') },
    })
    const out = await rig.tool('machines.manage').run({ do: 'pair', code: '123456' }, rig.context())
    const seen = JSON.stringify(out)
    expect(seen).not.toContain('BEARER-SECRET-123')
    expect(seen).not.toContain(Buffer.from('PRIVATE-KEY-BYTES').toString('base64'))
    expect(seen).not.toContain('secretKey')
    expect(seen).not.toContain('credential')
    expect((out.value as { machineId: string }).machineId).toBe('m1')
  })

  it('returns a code shown for another computer, and keeps it out of the record', async () => {
    rig.answers['machines:code'] = () => ({ ok: true, code: { token: '424242', expiresAt: 99 } })
    const out = await rig.tool('machines.manage').run({ do: 'show-code' }, rig.context())
    expect((out.value as { code: string }).code).toBe('424242')
    expect(JSON.stringify(out.summary)).not.toContain('424242')
  })

  it('refuses a machine it does not know, once it has a list to check against', async () => {
    await rig.tool('machines.look').run({}, rig.context())
    expect(() => rig.tool('machines.manage').precheck?.({ do: 'forget', machineId: 'ghost' }, rig.context())).toThrow(
      /no machine with the id ghost/,
    )
  })
})

describe('machines.upload', () => {
  it('never sends anything out of the credential folders or this app’s own data', () => {
    const upload = rig.tool('machines.upload')
    expect(() => upload.precheck?.({ machineId: 'm1', do: 'send', path: join(homedir(), '.ssh', 'id_ed25519') }, rig.context())).toThrow(
      /sign-in keys and credentials/,
    )
    expect(() => upload.precheck?.({ machineId: 'm1', do: 'send', path: join(userData, 'machines.json') }, rig.context())).toThrow(Refused)
    expect(() => upload.precheck?.({ machineId: 'm1', do: 'send', path: 'relative.txt' }, rig.context())).toThrow(/absolute/)
  })

  it('asks a person before a file leaves, and not to cancel one', () => {
    const upload = rig.tool('machines.upload')
    expect(upload.escalate?.({ do: 'send' }, rig.context())).toBe('alter')
    expect(upload.escalate?.({ do: 'cancel' }, rig.context())).toBe('act')
  })
})

describe('machines.copilot', () => {
  it('says one line and waits for the answer to that line, not the one already on screen', async () => {
    vi.useFakeTimers()
    const chat = (messages: Array<{ id: string; role: 'you' | 'agent'; text: string }>, reset = false): void =>
      rig.tap.pushed('machines:copilot:chat', [
        { machineId: 'm1', chat: { run: 'r1', messages: messages.map((one) => ({ ...one, at: 0 })), ...(reset ? { reset: true } : {}) } },
      ])
    rig.answers['machines:copilot:attach'] = () => {
      chat([{ id: '1', role: 'you', text: 'earlier' }, { id: '2', role: 'agent', text: 'earlier answer' }], true)
      return { ok: true, message: 'watching' }
    }
    rig.answers['machines:copilot:refresh'] = () => ({ ok: true, message: 'asked' })
    rig.answers['machines:copilot:say'] = () => {
      setTimeout(() => chat([{ id: '3', role: 'you', text: 'is the build green?' }]), 100)
      setTimeout(() => chat([{ id: '4', role: 'agent', text: 'Yes — all 412 tests pass.' }]), 400)
      return { ok: true, message: 'said' }
    }
    const pending = rig.tool('machines.copilot').run({ machineId: 'm1', do: 'say', text: 'is the build green?', waitSeconds: 30 }, rig.context())
    await vi.advanceTimersByTimeAsync(5000)
    const out = (await pending).value as { answered: boolean; messages: Array<{ text: string }> }
    expect(out.answered).toBe(true)
    expect(out.messages.at(-1)?.text).toBe('Yes — all 412 tests pass.')
  })
})

describe('through the dispatcher', () => {
  let logDir = ''
  let asked = 0

  beforeEach(() => {
    logDir = mkdtempSync(join(tmpdir(), 'machine-tools-log-'))
    asked = 0
  })
  afterEach(() => rmSync(logDir, { recursive: true, force: true }))

  function deck(): DeckControl {
    const broker: ConsentBroker = new ConsentBroker({
      ask: (request) => {
        asked += 1
        broker.respond(request.id, true, WINDOW_SURFACE)
        return true
      },
      timeoutMs: 50,
    })
    return new DeckControl({ surface: {} as DeckSurface, log: new ActionLog({ dir: logDir }), consent: broker, extraTools: rig.tools })
  }

  it('asks a person before forgetting a machine, and then forgets it', async () => {
    rig.answers['machines:forget'] = () => ({ ...viewWith(), machines: [] })
    const result = await deck().call('machines.manage', { do: 'forget', machineId: 'm1' }, { caller: LOCAL })
    expect(result.ok).toBe(true)
    expect(asked).toBe(1)
    expect(rig.calls).toContainEqual(['machines:forget', 'm1'])
  })

  it('refuses a paired phone without putting a dialog in front of anybody', async () => {
    const result = await deck().call('machines.manage', { do: 'forget', machineId: 'm1' }, { caller: PHONE })
    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('not-granted')
    expect(asked).toBe(0)
    expect(rig.calls.some((row) => row[0] === 'machines:forget')).toBe(false)
  })
})

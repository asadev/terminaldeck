import { describe, expect, it, vi } from 'vitest'
import { portsFrom, registerServerReachIpc, type ServerPortsAnswer, type ServerReachDeps } from './reach'
import { WILL_NOT_FORWARD, type ForwardChannel, type ForwardingConnection } from './forward'
import { ServerProblem } from './connection'
import { factCannot, factYes, type ListenerFact, type ServerFacts } from './facts'
import type { ReachAnswer } from '../localhost-reach'

/**
 * The two channels the browser calls, and the connection they hold.
 *
 * The pipe itself is proved in `reach.ssh.test.ts` against a real SSH server;
 * what is decided here is everything *around* it — which answers disable a row
 * in the picker and which merely annotate it, whether a question that can end
 * lets go of the connection, and whether the answer shape is the same one the
 * relay path already returns. That last one is not cosmetic: the window narrows
 * both with one `readReach` and draws both with one badge, so a field renamed
 * here would silently cost a server the badge that says where its page came
 * from.
 */

/** The listeners the real test box reports, including the duplicate families. */
const REAL_LISTENERS: ListenerFact[] = [
  { address: '0.0.0.0', port: 8000, program: 'docker-proxy', pid: 196824, unit: 'docker.service' },
  { address: '0.0.0.0', port: 22, program: 'sshd', pid: 4066365, unit: 'ssh.service' },
  { address: '127.0.0.53%lo', port: 53, program: 'systemd-resolve', pid: 4062476, unit: '' },
  { address: '[::]', port: 8000, program: 'docker-proxy', pid: 196830, unit: 'docker.service' },
  { address: '0.0.0.0', port: 6001, program: '', pid: null, unit: '' },
]

function someFacts(listeners: ServerFacts['listeners']): ServerFacts {
  // Only `listeners` is read, so only `listeners` is real. A fixture that
  // invented twenty other facts would suggest this module looks at them.
  return { listeners } as ServerFacts
}

function channel(): ForwardChannel {
  return {
    on: () => undefined,
    write: () => true,
    end: () => undefined,
    destroy: () => undefined,
    pause: () => undefined,
    resume: () => undefined,
  }
}

/** A connection that answers every channel request the same way. */
function connection(answer: 'opens' | 'prohibited' | 'refused'): ForwardingConnection {
  return {
    on: () => undefined,
    forwardOut: (_srcIp, _srcPort, _dstIp, _dstPort, callback) => {
      if (answer === 'opens') return void callback(undefined, channel())
      const error = Object.assign(new Error('(SSH) Channel open failure'), {
        reason: answer === 'prohibited' ? 1 : 2,
      })
      return void callback(error, channel())
    },
  }
}

function app(overrides: Partial<ServerReachDeps> = {}) {
  const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()
  const holds: string[] = []
  const deps: ServerReachDeps = {
    servers: () => [{ id: 's1', name: 'the box' }],
    withConnection: async (serverId, fn) => {
      holds.push(`open ${serverId}`)
      try {
        return await fn(connection('refused'))
      } finally {
        holds.push(`close ${serverId}`)
      }
    },
    facts: async () => someFacts(factYes(REAL_LISTENERS, 1, 'asked what is listening')),
    ...overrides,
  }
  const ipc = registerServerReachIpc(
    { handle: (channelName, listener) => void handlers.set(channelName, listener) },
    deps,
  )
  return {
    ipc,
    holds,
    ports: (id: unknown) => handlers.get('servers:ports')?.(null, id) as Promise<ServerPortsAnswer>,
    reach: (id: unknown, port: unknown) =>
      handlers.get('servers:reach')?.(null, id, port) as Promise<ReachAnswer>,
  }
}

describe('what a server says it is serving', () => {
  it('collapses the two address families a server reports one port on', () => {
    // Measured on the test box: `0.0.0.0:8000` and `[::]:8000` are one
    // container, listed twice. Two rows would offer the same page twice with
    // no way to tell them apart.
    expect(portsFrom(REAL_LISTENERS).map((entry) => entry.port)).toEqual([8000, 6001])
  })

  it('does not offer a port whose holder cannot answer a browser', () => {
    /*
     * `22 sshd` and `53 systemd-resolve` are in the fixture because they were
     * on the real box, and until 2026-08-18 this list offered both as pages to
     * open. Pressing the first gets an identification string and a closed
     * socket; the second does not speak HTTP at all.
     *
     * The rule is the one this computer's own scan has always applied — see
     * `shared/not-a-page.ts`. The server list simply never had it.
     */
    const ports = portsFrom(REAL_LISTENERS).map((entry) => entry.port)
    expect(ports).not.toContain(22)
    expect(ports).not.toContain(53)
    // And what a person actually wants is still there.
    expect(ports).toContain(8000)
  })

  it('keeps a port whose owner the server would not name, and marks it', () => {
    const unnamed = portsFrom(REAL_LISTENERS).find((entry) => entry.port === 6001)
    // Dropped, this would hide most of what a shared server runs: an ordinary
    // sign-in cannot see another account's programs.
    expect(unnamed).toEqual({ port: 6001, process: '', guessed: true, ours: false })
  })

  it('prefers the row that could name what holds the port', () => {
    const both = portsFrom([
      { address: '[::]', port: 80, program: '', pid: null, unit: '' },
      { address: '0.0.0.0', port: 80, program: 'nginx', pid: 12, unit: '' },
    ])
    expect(both).toEqual([{ port: 80, process: 'nginx', guessed: false, ours: false }])
  })

  it('never claims a server is running this app', () => {
    // The fold below the list hides ports this app holds, and this app never
    // runs on somebody's server — that is what a server is.
    expect(portsFrom(REAL_LISTENERS).every((entry) => entry.ours === false)).toBe(true)
  })
})

describe('asking a server what it is serving', () => {
  it('answers the list, and lets go of the connection when it has it', async () => {
    const deck = app()
    const answer = await deck.ports('s1')
    expect(answer).toMatchObject({ ok: true, cannot: null })
    // A question with an end holds the connection for exactly as long as it
    // takes. §5.4: a server nobody is looking at is not dialled.
    expect(deck.holds).toEqual(['open s1', 'close s1'])
  })

  it('disables the row with its own sentence when the server refuses to forward', async () => {
    const deck = app({
      withConnection: async (_id, fn) => fn(connection('prohibited')),
    })
    expect(await deck.ports('s1')).toEqual({ ok: false, message: WILL_NOT_FORWARD })
  })

  it('keeps the row usable when the server cannot say what is listening', async () => {
    const why = 'this server has no tool installed for listing what is listening'
    const deck = app({ facts: async () => someFacts(factCannot(1, why)) })
    const answer = await deck.ports('s1')
    /*
     * The third state, carried to the screen rather than flattened. An empty
     * list would say "nothing is running here", which is a different claim
     * about somebody's server and a false one — and an address can still be
     * typed, so refusing the row would take away a working feature over a
     * missing tool.
     */
    expect(answer).toEqual({ ok: true, ports: [], cannot: why })
  })

  it('turns a failed dial into the sentence the connection layer wrote', async () => {
    const deck = app({
      withConnection: async () => {
        throw new ServerProblem('no-answer', 'That address did not answer.')
      },
    })
    expect(await deck.ports('s1')).toEqual({ ok: false, message: 'That address did not answer.' })
  })

  it('refuses a server it has never heard of rather than dialling something', async () => {
    const withConnection = vi.fn()
    const deck = app({ withConnection })
    expect(await deck.ports('nobody')).toEqual({
      ok: false,
      message: 'This app does not know that server.',
    })
    expect(await deck.ports(7)).toEqual({ ok: false, message: 'That is not a server.' })
    expect(withConnection).not.toHaveBeenCalled()
  })
})

describe('reaching a port on a server', () => {
  it('answers in the same shape the relay path answers in', async () => {
    const deck = app({ withConnection: async (_id, fn) => fn(connection('opens')) })
    const answer = await deck.reach('s1', 8000)
    expect(answer.ok, answer.ok ? '' : answer.message).toBe(true)
    if (!answer.ok) return
    /*
     * Field for field what `machines:reach` returns. The window narrows both
     * with one `readReach`, draws both with one badge and warns about a changed
     * port with one sentence — a field renamed here costs a server all three,
     * silently, and the picker would look identical while doing less.
     */
    expect(Object.keys(answer).sort()).toEqual(['localPort', 'ok', 'port', 'sameNumber', 'url'])
    expect(answer.url).toMatch(/^http:\/\//)
    expect(answer.port).toBe(8000)
    deck.ipc.stop()
  })

  it('holds one connection for a second port rather than dialling again', async () => {
    const deck = app({
      withConnection: async (serverId, fn) => {
        deck.holds.push(`open ${serverId}`)
        return fn(connection('opens'))
      },
    })
    await deck.reach('s1', 8000)
    await deck.reach('s1', 8080)
    expect(deck.holds).toEqual(['open s1'])
    expect(deck.ipc.openPorts('s1').length).toBeGreaterThan(0)
    deck.ipc.stop()
    expect(deck.ipc.openPorts('s1')).toEqual([])
  })

  it('says why rather than throwing when the server will not forward', async () => {
    const deck = app({ withConnection: async (_id, fn) => fn(connection('prohibited')) })
    expect(await deck.reach('s1', 8000)).toEqual({ ok: false, message: WILL_NOT_FORWARD })
    deck.ipc.stop()
  })

  it('refuses arguments that are not a server and a port', async () => {
    const deck = app()
    expect(await deck.reach(7, 8000)).toEqual({ ok: false, message: 'That is not a server and a port.' })
    expect(await deck.reach('s1', '8000')).toEqual({
      ok: false,
      message: 'That is not a server and a port.',
    })
    expect(await deck.reach('nobody', 8000)).toEqual({
      ok: false,
      message: 'This app does not know that server.',
    })
  })
})

import { describe, expect, it, vi } from 'vitest'
import { generateStatic } from '../../../shared/sealed'
import { hostIdFor } from '../../../shared/relay-wire'
import { serialize, type ServerMessage } from '../protocol'
import type { DialRequest, GuestChannel, GuestHandlers } from './dial'
import { createMachineLink, describeThisMachine, type MachineLinkState } from './guest'
import type { MachineSecrets } from './store'

/**
 * The link's state machine, driven by a channel this file controls.
 *
 * The channel is faked and nothing else is: a real one is exercised end to end
 * against a real relay in `live.test.ts`. What is worth isolating here is every
 * way a connection *ends*, because those are the paths a live test only reaches
 * by unplugging something — and because the difference between "waiting to be
 * approved" and "cannot connect" is a decision this file makes rather than one
 * the wire carries.
 */

function secrets(): MachineSecrets {
  return {
    hostId: hostIdFor(Buffer.alloc(32, 1)),
    hostPublicKey: generateStatic().publicKey,
    relayUrl: 'wss://relay.example',
    credential: 'abcdefghijkl.0123456789',
    guestKeys: generateStatic(),
  }
}

interface Fake {
  sent: string[]
  handlers: GuestHandlers
  channel: GuestChannel
  /** Deliver one frame as the far machine would. */
  say(message: ServerMessage): void
  /** End the channel from the far side. */
  hangUp(reason: string): void
}

function harness(options: { fail?: string } = {}): {
  dial: (request: DialRequest) => Promise<GuestChannel>
  fakes: Fake[]
  dialled: number
} {
  const fakes: Fake[] = []
  const state = { dialled: 0 }
  return {
    get dialled(): number {
      return state.dialled
    },
    fakes,
    dial(request: DialRequest): Promise<GuestChannel> {
      state.dialled += 1
      if (options.fail !== undefined) return Promise.reject(new Error(options.fail))
      const sent: string[] = []
      let open = true
      const channel: GuestChannel = {
        send: (text) => {
          if (open) sent.push(text)
        },
        close: () => {
          open = false
        },
        get open(): boolean {
          return open
        },
      }
      const fake: Fake = {
        sent,
        handlers: request.handlers,
        channel,
        say: (message) => request.handlers.message(serialize(message)),
        hangUp: (reason) => {
          open = false
          request.handlers.closed(reason)
        },
      }
      fakes.push(fake)
      return Promise.resolve(channel)
    },
  }
}

function welcome(partial: Partial<Extract<ServerMessage, { t: 'welcome' }>> = {}): ServerMessage {
  return {
    t: 'welcome',
    protocol: 1,
    deviceId: 'device-1',
    deviceName: 'This Mac',
    token: null,
    sessions: [
      { id: 's1', title: 'agent', cwd: '/tmp/p', provider: 'claude', status: 'running', exitCode: null },
    ],
    capabilities: ['create'],
    hostPlatform: 'win32',
    folders: ['/tmp/p'],
    ...partial,
  }
}

function build(options: { fail?: string } = {}): {
  link: ReturnType<typeof createMachineLink>
  states: MachineLinkState[]
  output: Array<{ id: string; data: string; replay: boolean }>
  welcomes: string[]
  rig: ReturnType<typeof harness>
} {
  const rig = harness(options)
  const states: MachineLinkState[] = []
  const output: Array<{ id: string; data: string; replay: boolean }> = []
  const welcomes: string[] = []
  const link = createMachineLink({
    id: 'machine-1',
    secrets: secrets(),
    onState: (state) => states.push(state),
    onOutput: (id, data, replay) => output.push({ id, data, replay }),
    onWelcome: (platform) => welcomes.push(platform),
    dial: rig.dial,
    baseBackoffMs: 5,
    maxBackoffMs: 10,
  })
  return { link, states, output, welcomes, rig }
}

async function settle(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 0))
}

describe('coming up', () => {
  it('says hello with the credential and nothing else', async () => {
    const { link, rig } = build()
    link.connect()
    await settle()

    expect(rig.fakes).toHaveLength(1)
    const hello: unknown = JSON.parse(rig.fakes[0].sent[0])
    expect(hello).toMatchObject({
      t: 'hello',
      protocol: 1,
      token: 'abcdefghijkl.0123456789',
      device: describeThisMachine(),
    })
    link.disconnect()
  })

  it('is online once a welcome lands, carrying what that machine said', async () => {
    const { link, rig, welcomes } = build()
    link.connect()
    await settle()
    rig.fakes[0].say(welcome())

    const state = link.state()
    expect(state.state).toBe('online')
    expect(state.sessions.map((session) => session.id)).toEqual(['s1'])
    expect(state.capabilities).toEqual(['create'])
    expect(state.hostPlatform).toBe('win32')
    expect(state.folders).toEqual(['/tmp/p'])
    expect(welcomes).toEqual(['win32'])
    link.disconnect()
  })

  it('keeps "never said" and "said none" apart for folders', async () => {
    // Absent means that machine is running a build older than the field; empty
    // means somebody chose no folders for this device. One is a build to update
    // and the other is a person to ask, and flattening them would print the
    // wrong sentence on both.
    const first = build()
    first.link.connect()
    await settle()
    const withoutFolders = welcome()
    if (withoutFolders.t === 'welcome') delete withoutFolders.folders
    first.rig.fakes[0].say(withoutFolders)
    expect(first.link.state().folders).toBeNull()
    first.link.disconnect()

    const second = build()
    second.link.connect()
    await settle()
    second.rig.fakes[0].say(welcome({ folders: [] }))
    expect(second.link.state().folders).toEqual([])
    second.link.disconnect()
  })

  it('refuses a machine speaking a different protocol version', async () => {
    const { link, rig } = build()
    link.connect()
    await settle()
    rig.fakes[0].say(welcome({ protocol: 99 }))
    expect(link.state().state).toBe('error')
    expect(link.state().reason).toMatch(/protocol 99/)
    link.disconnect()
  })
})

describe('being refused', () => {
  it('calls a pending device "waiting to be approved" rather than an error', async () => {
    const { link, rig } = build()
    link.connect()
    await settle()
    rig.fakes[0].say({
      t: 'error',
      code: 'unauthorized',
      message: 'This device is waiting to be approved. Approve it in the desktop app, then reconnect.',
    })

    expect(link.state().state).toBe('awaiting-approval')
    expect(link.state().reason).toMatch(/approve/i)
    link.disconnect()
  })

  it('calls the same refusal an error once that machine has let it in before', async () => {
    // A device that has been welcomed and is now refused has been revoked, not
    // left pending — and telling somebody to go and approve a device they
    // deliberately removed is the wrong instruction.
    const { link, rig } = build()
    link.connect()
    await settle()
    rig.fakes[0].say(welcome())
    rig.fakes[0].say({ t: 'error', code: 'unauthorized', message: 'This device is not allowed in.' })

    expect(link.state().state).toBe('error')
    link.disconnect()
  })

  it('drops the session list when the connection goes', async () => {
    // Rows that survive a disconnection are rows that open nothing, which is the
    // same lie as a hover state on something that is not clickable.
    const { link, rig } = build()
    link.connect()
    await settle()
    rig.fakes[0].say(welcome())
    expect(link.state().sessions).toHaveLength(1)

    rig.fakes[0].hangUp('The relay closed the connection.')
    expect(link.state().sessions).toEqual([])
    expect(link.state().reason).toBe('The relay closed the connection.')
    link.disconnect()
  })

  it('keeps redialling, which is what makes approval work with nothing watching for it', async () => {
    const { link, rig } = build()
    link.connect()
    await settle()
    rig.fakes[0].say({ t: 'error', code: 'unauthorized', message: 'Approve this device.' })
    expect(link.state().state).toBe('awaiting-approval')

    // No poke and no second button: the backoff is already running, so the dial
    // that happens after somebody presses approve is one that was going to
    // happen anyway.
    await vi.waitFor(() => expect(rig.dialled).toBeGreaterThan(1), { timeout: 2000 })
    rig.fakes[rig.fakes.length - 1].say(welcome())
    expect(link.state().state).toBe('online')
    link.disconnect()
  })

  it('reports a dial that never connected, and tries again', async () => {
    const { link, rig } = build({ fail: 'Could not reach that machine: timed out.' })
    link.connect()
    await settle()
    expect(link.state().state).toBe('error')
    expect(link.state().reason).toMatch(/timed out/)
    await vi.waitFor(() => expect(rig.dialled).toBeGreaterThan(1), { timeout: 2000 })
    link.disconnect()
  })
})

describe('driving a session', () => {
  it('refuses every verb until the machine has said welcome', async () => {
    // The alternative is keystrokes that vanish with no explanation, which is
    // what a caller sees when a write silently does nothing.
    const { link, rig } = build()
    link.connect()
    await settle()
    expect(link.attach('s1', 80, 24)).toBe(false)
    expect(link.input('s1', 'ls')).toBe(false)

    rig.fakes[0].say(welcome())
    expect(link.attach('s1', 80, 24)).toBe(true)
    expect(link.input('s1', 'ls')).toBe(true)
    expect(link.resize('s1', 100, 30)).toBe(true)
    expect(link.detach('s1')).toBe(true)

    const sent = rig.fakes[0].sent.map((text): unknown => JSON.parse(text))
    expect(sent).toContainEqual({ t: 'attach', id: 's1', cols: 80, rows: 24 })
    expect(sent).toContainEqual({ t: 'input', id: 's1', data: 'ls' })
    expect(sent).toContainEqual({ t: 'resize', id: 's1', cols: 100, rows: 30 })
    expect(sent).toContainEqual({ t: 'detach', id: 's1' })
    link.disconnect()
  })

  it('will not send a create to a machine that never advertised one', async () => {
    // The far end answers an unadvertised verb by closing the channel, so a
    // button that sent one would disconnect you instead of doing nothing.
    const { link, rig } = build()
    link.connect()
    await settle()
    rig.fakes[0].say(welcome({ capabilities: [] }))
    expect(link.create({ cwd: '/tmp/p' })).toBe(false)

    rig.fakes[0].say(welcome())
    expect(link.create({ cwd: '/tmp/p' })).toBe(true)
    link.disconnect()
  })

  it('passes output through, marking what was replayed', async () => {
    const { link, rig, output } = build()
    link.connect()
    await settle()
    rig.fakes[0].say(welcome())
    rig.fakes[0].say({ t: 'output', id: 's1', data: 'old', replay: true })
    rig.fakes[0].say({ t: 'output', id: 's1', data: 'new' })
    expect(output).toEqual([
      { id: 's1', data: 'old', replay: true },
      { id: 's1', data: 'new', replay: false },
    ])
    link.disconnect()
  })

  it('folds status, exit and created into the list it already has', async () => {
    const { link, rig } = build()
    link.connect()
    await settle()
    rig.fakes[0].say(welcome())

    rig.fakes[0].say({ t: 'status', id: 's1', status: 'waiting' })
    expect(link.state().sessions[0].status).toBe('waiting')

    rig.fakes[0].say({
      t: 'created',
      session: { id: 's2', title: 'new', cwd: '/tmp/p', provider: 'shell', status: 'running', exitCode: null },
    })
    expect(link.state().sessions.map((session) => session.id)).toEqual(['s2', 's1'])

    rig.fakes[0].say({ t: 'exit', id: 's1', exitCode: 0 })
    const exited = link.state().sessions.find((session) => session.id === 's1')
    expect(exited?.status).toBe('exited')
    expect(exited?.exitCode).toBe(0)
    link.disconnect()
  })

  it('takes a pushed folder list', async () => {
    const { link, rig } = build()
    link.connect()
    await settle()
    rig.fakes[0].say(welcome())
    rig.fakes[0].say({ t: 'folders', folders: ['/tmp/other'] })
    expect(link.state().folders).toEqual(['/tmp/other'])
    link.disconnect()
  })

  it('ignores a frame it cannot read rather than dropping the connection', async () => {
    const { link, rig } = build()
    link.connect()
    await settle()
    rig.fakes[0].say(welcome())
    rig.fakes[0].handlers.message('<html>captive portal</html>')
    expect(link.state().state).toBe('online')
    link.disconnect()
  })
})

describe('stopping', () => {
  it('stays stopped, and stops dialling', async () => {
    const { link, rig } = build()
    link.connect()
    await settle()
    rig.fakes[0].say(welcome())
    link.disconnect()

    expect(link.state().state).toBe('offline')
    expect(link.state().sessions).toEqual([])
    const dialled = rig.dialled
    await new Promise((resolve) => setTimeout(resolve, 60))
    expect(rig.dialled).toBe(dialled)
  })

  it('redials on a wake rather than waiting out the backoff', async () => {
    const { link, rig } = build()
    link.connect()
    await settle()
    rig.fakes[0].say(welcome())

    link.wake()
    await settle()
    expect(rig.dialled).toBe(2)
    link.disconnect()
  })
})

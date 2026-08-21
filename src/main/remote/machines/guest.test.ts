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

/** Wait until the link has dialled for the nth time. */
async function waitForFake(rig: ReturnType<typeof harness>, index: number): Promise<void> {
  const deadline = Date.now() + 2000
  while (rig.fakes.length <= index) {
    if (Date.now() > deadline) throw new Error(`no dial ${index + 1} within 2s`)
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
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

  /**
   * The wait between dials stays flat while it is a person being asked, and it
   * is the whole of the seven seconds Asad sat through after pressing *Let it
   * in*. By the fourth refusal the exponential curve puts the next dial eight to
   * sixteen seconds out, so the press appeared to do nothing — and the curve is
   * an answer to a machine that is off, not to a finger on a button.
   */
  it('does not back off while it is waiting for a person to approve it', async () => {
    const rig = harness()
    const states: MachineLinkState[] = []
    const link = createMachineLink({
      id: 'machine-1',
      secrets: secrets(),
      onState: (state) => states.push(state),
      onOutput: () => {},
      onWelcome: () => {},
      dial: rig.dial,
      // A clock that does not move, so `retryAt` *is* the delay.
      now: () => 0,
      baseBackoffMs: 20,
      maxBackoffMs: 5000,
    })

    link.connect()
    for (let round = 0; round < 4; round += 1) {
      await waitForFake(rig, round)
      rig.fakes[round].say({
        t: 'error',
        code: 'unauthorized',
        message: 'This device is waiting to be approved.',
      })
    }
    link.disconnect()

    const waits = states.map((state) => state.retryAt).filter((at): at is number => at !== null)
    expect(waits.length).toBeGreaterThanOrEqual(3)
    // Base is 20 and the jitter runs across the top half of the ceiling, so the
    // flat schedule can only ever produce 20…40. Exponential would have reached
    // 160 by the fourth.
    for (const wait of waits) expect(wait).toBeLessThanOrEqual(40)
  })

  it('calls the same refusal an error once that machine has let it in before', async () => {
    // A device that has been welcomed and is now refused has been revoked, not
    // left pending — and telling somebody to go and approve a device they
    // deliberately removed is the wrong instruction.
    //
    // The hang-up is not decoration. `remote:device:revoke` calls
    // `server.dropDevice`, which sends this frame and then closes the socket in
    // the same breath, so a refusal of the *connection* always arrives with the
    // connection ending. That is exactly what tells it apart from a refused
    // request, which arrives on a channel that stays open.
    const { link, rig } = build()
    link.connect()
    await settle()
    rig.fakes[0].say(welcome())
    rig.fakes[0].say({ t: 'error', code: 'unauthorized', message: 'This device is not allowed in.' })
    rig.fakes[0].hangUp('The relay closed the connection.')

    expect(link.state().state).toBe('error')
    // The far end's sentence, not the socket's: "the relay closed the
    // connection" tells somebody whose device was revoked nothing at all.
    expect(link.state().reason).toBe('This device is not allowed in.')
    link.disconnect()
  })

  it('keeps the link when one request is refused, rather than tearing it down', async () => {
    /*
     * The failure this pins was found between two real machines. A Mac asked a
     * paired Windows PC for a folder that was not on that device's grant list;
     * the PC answered `unauthorized` and — correctly — kept serving. This end
     * dropped the whole link anyway: `online` → `error` with every session row
     * blanked → `connecting` → `online`, 1.9 seconds later, for a mistake whose
     * whole correct outcome is one line of text under the machine's name.
     *
     * `create` is not the only frame that can be refused this way. `attach` to
     * a session that has just exited, a tunnel, an upload and a credential push
     * are all answered and not closed.
     */
    const { link, rig } = build()
    link.connect()
    await settle()
    rig.fakes[0].say(welcome())
    expect(link.state().sessions).toHaveLength(1)

    rig.fakes[0].say({
      t: 'error',
      code: 'unauthorized',
      message: 'This PC is not offering that folder to this device. Pick one from the list it sent.',
    })

    expect(link.state().state).toBe('online')
    expect(link.state().sessions).toHaveLength(1)
    expect(link.state().reason).toMatch(/not offering that folder/)
    expect(rig.dialled).toBe(1)
    link.disconnect()
  })

  it('clears a refusal once a session does start', async () => {
    const { link, rig } = build()
    link.connect()
    await settle()
    rig.fakes[0].say(welcome())
    rig.fakes[0].say({ t: 'error', code: 'unauthorized', message: 'Not that folder.' })
    expect(link.state().reason).toBe('Not that folder.')

    rig.fakes[0].say({
      t: 'created',
      session: { id: 's9', title: 'new', cwd: '/tmp/ok', provider: 'shell', status: 'running', exitCode: null },
    })

    expect(link.state().reason).toBeNull()
    expect(link.state().state).toBe('online')
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

/**
 * Saying something into a session over there without opening it here.
 *
 * The link already has `input`, and `input` is not this: the far end serves it
 * only to a connection holding an attach handle, and taking one out in order to
 * type would displace the handle a terminal pane on this very link already
 * holds — dropping its subscription and replaying its whole scrollback at
 * whoever is reading it. So the wire grew a verb that types without
 * subscribing, and the two properties worth pinning on this side are that it
 * never goes out to a machine that did not offer it, and that it never answers
 * with silence.
 */
describe('sending to a session it is not attached to', () => {
  it('refuses locally when that machine never advertised the verb', async () => {
    const { link, rig } = build()
    link.connect()
    await settle()
    rig.fakes[0].say(welcome({ capabilities: ['create'] }))

    const answer = await link.send('s1', 'look at this')
    expect(answer.ok).toBe(false)
    expect(answer.message).toMatch(/update it/i)
    // And nothing went out. A host that has never heard of a frame answers it by
    // closing the channel, so a hopeful send is not a failed request — it is
    // every terminal session on this link going down with one panel's button.
    expect(rig.fakes[0].sent.some((text) => text.includes('session.send'))).toBe(false)
    link.disconnect()
  })

  it('refuses before the machine is up, with a sentence that has a different remedy', async () => {
    // A link that is down is waited out; a machine whose build has no `send` is
    // updated. Telling somebody "that failed" for either sends them to the wrong
    // screen — the same split `setControl` makes.
    const { link } = build()
    link.connect()
    await settle()

    expect(await link.send('s1', 'look at this')).toEqual({
      ok: false,
      message: 'This desktop is not connected to that machine right now.',
    })
    link.disconnect()
  })

  it('puts the frame on the wire and settles on the answer', async () => {
    const { link, rig } = build()
    link.connect()
    await settle()
    rig.fakes[0].say(welcome({ capabilities: ['send'] }))

    const pending = link.send('s1', 'look at this button\r')
    await settle()
    const frame = JSON.parse(rig.fakes[0].sent.at(-1) as string) as {
      t: string
      rid: string
      id: string
      data: string
    }
    expect(frame).toMatchObject({ t: 'session.send', id: 's1', data: 'look at this button\r' })
    expect(frame.rid).not.toBe('')
    // The whole point of the verb, as an assertion: nothing subscribed. A link
    // that quietly attached first would pass every other line here and take a
    // pane's handle away in the real app.
    expect(rig.fakes[0].sent.some((text) => text.includes('"attach"'))).toBe(false)

    rig.fakes[0].say({ t: 'session.sent', rid: frame.rid, id: 's1', ok: true, message: 'Sent.' })
    expect(await pending).toEqual({ ok: true, message: 'Sent.' })
    link.disconnect()
  })

  it('carries the far machine’s refusal back in its own words', async () => {
    const { link, rig } = build()
    link.connect()
    await settle()
    rig.fakes[0].say(welcome({ capabilities: ['send'] }))

    const pending = link.send('s1', 'ls')
    await settle()
    const rid = (JSON.parse(rig.fakes[0].sent.at(-1) as string) as { rid: string }).rid
    rig.fakes[0].say({ t: 'session.sent', rid, id: 's1', ok: false, message: 'No session s1 is running.' })

    expect(await pending).toEqual({ ok: false, message: 'No session s1 is running.' })
    link.disconnect()
  })

  it('will not file an answer about another session under this one', async () => {
    // An `rid` only proves this is the answer to *a* question this end asked.
    // Two panels sending to two sessions on one machine is a thing this window
    // does, and one comparison makes the mix-up impossible rather than unlikely
    // — the sentence that comes back is the one that does not claim to know.
    const { link, rig } = build()
    link.connect()
    await settle()
    rig.fakes[0].say(welcome({ capabilities: ['send'] }))

    const pending = link.send('s1', 'ls')
    await settle()
    const rid = (JSON.parse(rig.fakes[0].sent.at(-1) as string) as { rid: string }).rid
    rig.fakes[0].say({ t: 'session.sent', rid, id: 's2', ok: true, message: 'Sent.' })

    expect(await pending).toEqual({
      ok: false,
      message: 'That machine did not answer, so it is not known whether the text arrived.',
    })
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

/**
 * Remote localhost, from the side that could not do it.
 *
 * `web.open` has been on this wire since the web client needed it, and until now
 * only the web client sent it — so a Mac reaching a PC could list its sessions
 * and had nothing at all to say about what that PC was serving. Both halves are
 * gated on the far machine's advertisement rather than sent hopefully, which is
 * the standing rule for every capability here and matters more for these two
 * than for most: the far end answers an unadvertised verb by **closing the
 * channel**, so a hopeful send is not a failed request, it is a disconnection.
 */
describe('what the far machine is serving', () => {
  it('asks once, on the welcome, when that machine tunnels', async () => {
    const { link, rig } = build()
    link.connect()
    await settle()
    rig.fakes[0].say(welcome({ capabilities: ['create', 'localhost'] }))

    // The hello, then the question. Asked here rather than when a panel opens,
    // so the panel has a list the instant somebody looks at it.
    const sent = rig.fakes[0].sent.map((text) => JSON.parse(text) as { t: string })
    expect(sent.map((frame) => frame.t)).toEqual(['hello', 'ports'])
  })

  it('does not ask a machine that never offered it', async () => {
    const { link, rig } = build()
    link.connect()
    await settle()
    rig.fakes[0].say(welcome({ capabilities: ['create'] }))

    expect(rig.fakes[0].sent.map((text) => (JSON.parse(text) as { t: string }).t)).toEqual(['hello'])
    // And the refusal is local: the button is never drawn, so nothing can send
    // the verb that would end the channel.
    expect(link.ports()).toBe(false)
  })

  it('publishes the ports it is told about, dropping only the unreadable rows', async () => {
    const { link, states, rig } = build()
    link.connect()
    await settle()
    rig.fakes[0].say(welcome({ capabilities: ['localhost'] }))
    rig.fakes[0].say({
      t: 'ports',
      ports: [
        { port: 5173, process: 'node', guessed: false },
        { port: 8080, process: '', guessed: true },
      ],
    })

    expect(link.state().ports).toEqual([
      { port: 5173, process: 'node', guessed: false },
      { port: 8080, process: '', guessed: true },
    ])
    expect(states.at(-1)?.ports).toHaveLength(2)
  })

  it('forgets them when the link drops', async () => {
    // A port list describes what is running on a machine, and the most likely
    // reason a link dropped is that the machine stopped. Rows left on screen
    // would open nothing.
    const { link, rig } = build()
    link.connect()
    await settle()
    rig.fakes[0].say(welcome({ capabilities: ['localhost'] }))
    rig.fakes[0].say({ t: 'ports', ports: [{ port: 3000, process: 'node', guessed: false }] })
    expect(link.state().ports).toHaveLength(1)

    rig.fakes[0].hangUp('the relay closed the channel')
    expect(link.state().ports).toEqual([])
    link.disconnect()
  })

  it('opens a page on that machine only when it advertised `web`', async () => {
    const { link, rig } = build()
    link.connect()
    await settle()
    rig.fakes[0].say(welcome({ capabilities: ['localhost'] }))

    expect(link.openThere('http://localhost:5173/')).toBe(false)
    expect(rig.fakes[0].sent.some((text) => text.includes('web.open'))).toBe(false)
  })

  it('sends the address verbatim once it has', async () => {
    const { link, rig } = build()
    link.connect()
    await settle()
    rig.fakes[0].say(welcome({ capabilities: ['localhost', 'web'] }))

    expect(link.openThere('http://localhost:5173/')).toBe(true)
    const last: unknown = JSON.parse(rig.fakes[0].sent.at(-1) as string)
    expect(last).toEqual({ t: 'web.open', url: 'http://localhost:5173/' })
  })

  it('says nothing about a confirmation, because the confirmation is the other screen', async () => {
    // `web.opened` is deliberately not published as state: the page appearing on
    // the far machine is the confirmation, and a panel that also announced it
    // would be narrating something the person can see. A *failure* is a plain
    // `error` and does reach `reason`, which is the asymmetry worth pinning.
    const { link, rig } = build()
    link.connect()
    await settle()
    rig.fakes[0].say(welcome({ capabilities: ['localhost', 'web'] }))
    const before = link.state()
    rig.fakes[0].say({ t: 'web.opened', url: 'http://localhost:5173/' })

    expect(link.state()).toEqual(before)
    rig.fakes[0].say({ t: 'error', code: 'unauthorized', message: 'Only your own devices can open pages on this machine.' })
    expect(link.state().reason).toBe('Only your own devices can open pages on this machine.')
    expect(link.state().state).toBe('online')
    link.disconnect()
  })
})

describe('a browser verb arriving from that machine', () => {
  /**
   * The one inbound *question* on this link.
   *
   * Everything else a paired machine sends is an answer to something this end
   * asked, or an event. This is the far end saying *"a session of mine is
   * attached to a window of yours — act on it"*, and the whole of the decision
   * is on this side, where the browser is.
   */
  function link(
    answer?: (call: { sessionId: string; tool: string; args: string }) => Promise<{
      ok: boolean
      body: string
    }>,
  ): { link: ReturnType<typeof createMachineLink>; rig: ReturnType<typeof harness> } {
    const rig = harness()
    const made = createMachineLink({
      id: 'machine-1',
      secrets: secrets(),
      onState: () => undefined,
      onOutput: () => undefined,
      onWelcome: () => undefined,
      dial: rig.dial,
      baseBackoffMs: 5,
      maxBackoffMs: 10,
      ...(answer === undefined ? {} : { onWindowCall: answer }),
    })
    return { link: made, rig }
  }

  it('offers to serve them only when there is something behind the offer', async () => {
    /*
     * A build that listed the capability without a handler would have a far
     * machine sending `window.call` into a socket that answers nothing — inside
     * a tool call somebody's turn is blocked on, waiting out a deadline for a
     * feature that was never there.
     */
    const bare = link()
    bare.link.connect()
    await settle()
    expect(JSON.parse(bare.rig.fakes[0].sent[0])).not.toHaveProperty('capabilities')

    const wired = link(async () => ({ ok: true, body: '{}' }))
    wired.link.connect()
    await settle()
    expect(JSON.parse(wired.rig.fakes[0].sent[0])).toMatchObject({ capabilities: ['windows'] })
  })

  it('answers on the same socket, carrying the handler’s outcome', async () => {
    const seen: unknown[] = []
    const { link: made, rig } = link(async (call) => {
      seen.push(call)
      return { ok: true, body: '{"title":"Example"}' }
    })
    made.connect()
    await settle()
    rig.fakes[0].say(welcome())
    rig.fakes[0].say({
      t: 'window.call',
      id: 'w-1',
      session: 'sess-1',
      tool: 'browser.read',
      args: '{}',
    })
    await settle()

    expect(seen).toEqual([{ sessionId: 'sess-1', tool: 'browser.read', args: '{}' }])
    const last: unknown = JSON.parse(rig.fakes[0].sent.at(-1) ?? '{}')
    expect(last).toEqual({ t: 'window.result', id: 'w-1', ok: true, body: '{"title":"Example"}' })
  })

  it('answers even when nothing here serves them, rather than going quiet', async () => {
    /*
     * Silence costs the far end a whole turn and produces the one thing
     * `session-verbs.ts` was written to stop: an agent that concludes it has not
     * found the way in yet and goes looking for another.
     */
    const { link: made, rig } = link()
    made.connect()
    await settle()
    rig.fakes[0].say(welcome())
    rig.fakes[0].say({
      t: 'window.call',
      id: 'w-2',
      session: 'sess-1',
      tool: 'browser.read',
      args: '{}',
    })
    await settle()

    const last = JSON.parse(rig.fakes[0].sent.at(-1) ?? '{}') as {
      t: string
      ok: boolean
      body: string
    }
    expect(last.t).toBe('window.result')
    expect(last.ok).toBe(false)
    expect(String((JSON.parse(last.body) as { message: string }).message)).toMatch(/not set up/)
  })

  it('turns a handler that threw into a refusal rather than an unanswered call', async () => {
    const { link: made, rig } = link(() => Promise.reject(new Error('the drive is not up')))
    made.connect()
    await settle()
    rig.fakes[0].say(welcome())
    rig.fakes[0].say({
      t: 'window.call',
      id: 'w-3',
      session: 'sess-1',
      tool: 'browser.read',
      args: '{}',
    })
    await settle()

    const last = JSON.parse(rig.fakes[0].sent.at(-1) ?? '{}') as { ok: boolean; body: string }
    expect(last.ok).toBe(false)
    expect((JSON.parse(last.body) as { message: string }).message).toBe('the drive is not up')
  })
})

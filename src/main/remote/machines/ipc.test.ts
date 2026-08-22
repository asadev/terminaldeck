import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { hostname, tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { generateStatic } from '../../../shared/sealed'
import { hostIdFor } from '../../../shared/relay-wire'
import { isCode } from '../../../shared/short-code'
import { PAIRING_TTL_MS, RemoteAuth } from '../device-auth'
import { emptyUsageReading } from '../protocol'
import { pairingDesk, type RemoteStatus } from '../server'
import type { MachineLink, MachineLinkState, MachineLinkOptions } from './guest'
import type { PairResult } from './pair'
import type { Beacon, BeaconOptions } from './rendezvous'
import { MachineStore } from './store'
import {
  MACHINES_COPILOT_CHAT_CHANNEL,
  MACHINES_COPILOT_STATE_CHANNEL,
  MACHINES_OUTPUT_CHANNEL,
  MACHINES_STATE_CHANNEL,
  registerMachinesIpc,
  type InvokeRegistrar,
  type MachinesIpc,
  type MachinesIpcDeps,
  type MachinesView,
} from './ipc'

/**
 * The feature as the app assembles it, with the two seams that would otherwise
 * dial the public internet replaced and nothing else.
 *
 * The first test is the one that matters most and it is not about a button:
 * *registering* this has to connect every machine that is already paired. The
 * bug this repository keeps re-finding is a feature that is complete, tested,
 * and only ever started by visiting its own screen.
 */

const dirs: string[] = []

afterEach(() => {
  while (dirs.length > 0) rmSync(dirs.pop() as string, { recursive: true, force: true })
})

function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'deck-machines-ipc-'))
  dirs.push(dir)
  return dir
}

/** A relay this desktop is happily connected to. */
function connectedStatus(): RemoteStatus {
  return {
    running: true,
    url: null,
    address: null,
    port: 8443,
    reason: null,
    directReason: null,
    relay: {
      url: 'wss://relay.example',
      hostId: hostIdFor(Buffer.alloc(32, 2)),
      publicKey: generateStatic().publicKey.toString('base64url'),
      fingerprint: 'AAAA-BBBB-CCCC-DDDD-EEEE-FFFF',
      connected: true,
      channels: 0,
      reason: null,
      retryAt: null,
    },
    connections: [],
  }
}

function offlineStatus(): RemoteStatus {
  return { ...connectedStatus(), relay: null }
}

interface Rig {
  invoke(channel: string, ...args: unknown[]): Promise<unknown>
  /** What the registration handed back, for the halves nothing invokes. */
  ipc: MachinesIpc
  channels: string[]
  broadcasts: Array<{ channel: string; payload: unknown }>
  links: Array<{
    options: MachineLinkOptions
    connected: number
    disconnected: number
    woken: number
    /**
     * The state this fake reports, mutable, so a case can put a link online.
     *
     * The real one publishes this from a socket. Everything that reads it from
     * the outside — `linkStanding`, and the panel that asks it whether a machine
     * row has anything behind it — is answering a question about *now*, and a
     * fake stuck on one answer could only ever exercise half of it.
     */
    state: MachineLinkState
    /** Everything `machines:send` handed the link, in order. Empty is the assertion. */
    sends: Array<{ sessionId: string; data: string }>
    /** And everything the four copilot channels handed it. Empty is the assertion again. */
    copilot: { attached: number; started: number; refreshed: number; said: string[] }
  }>
  beacons: Array<{ options: BeaconOptions; stopped: boolean }>
  store: MachineStore
  dir: string
}

function rig(
  options: {
    status?: () => RemoteStatus
    pair?: (input: { code: string; relayUrl: string }) => Promise<PairResult>
    dir?: string
    /** False for a relay that accepts the socket and never claims the slot. */
    slotClaimed?: boolean
    /** The app's browser-window server, when a case is about one. */
    serveWindows?: MachinesIpcDeps['serveWindows']
    /** Where a far machine's holdings land, when a case is about the mirror. */
    windowsHeldThere?: MachinesIpcDeps['windowsHeldThere']
    /** And where its answers do. */
    windowAnswered?: MachinesIpcDeps['windowAnswered']
    /** And the settling of everything outstanding when a link goes. */
    windowsUnreachable?: MachinesIpcDeps['windowsUnreachable']
  } = {},
): Rig {
  const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()
  const ipcMain: InvokeRegistrar = {
    handle: (channel, listener) => {
      handlers.set(channel, listener)
    },
  }
  const broadcasts: Array<{ channel: string; payload: unknown }> = []
  const links: Rig['links'] = []
  const beacons: Rig['beacons'] = []
  const dir = options.dir ?? tempDir()

  /*
   * The beacon seam is on the desk, because the desk is what publishes.
   *
   * It used to be a dependency of this registration, and that was the shape of
   * the bug: publishing lived beside one of the two screens that mint codes, so
   * the other one minted codes nobody could look up. Injecting it here is also
   * the only thing standing between this unit test and a real WebSocket to the
   * public relay from whatever machine it runs on.
   */
  const desk = pairingDesk(new RemoteAuth(dir), Date.now, (beaconOptions): Beacon => {
    const record = { options: beaconOptions, stopped: false }
    beacons.push(record)
    return {
      stop: () => {
        record.stopped = true
      },
      connected: () => !record.stopped && options.slotClaimed !== false,
      ready: () => Promise.resolve(options.slotClaimed !== false),
    }
  })

  const ipc = registerMachinesIpc(ipcMain, {
    storageDir: dir,
    desk,
    status: options.status ?? connectedStatus,
    broadcast: (channel, payload) => broadcasts.push({ channel, payload }),
    ...(options.serveWindows === undefined ? {} : { serveWindows: options.serveWindows }),
    ...(options.windowsHeldThere === undefined ? {} : { windowsHeldThere: options.windowsHeldThere }),
    ...(options.windowAnswered === undefined ? {} : { windowAnswered: options.windowAnswered }),
    ...(options.windowsUnreachable === undefined
      ? {}
      : { windowsUnreachable: options.windowsUnreachable }),
    createLink: (linkOptions): MachineLink => {
      const state: MachineLinkState = {
        id: linkOptions.id,
        state: 'offline',
        reason: null,
        sessions: [],
        folders: null,
        capabilities: [],
        ports: [],
        copilot: null,
        hostPlatform: '',
        retryAt: null,
      }
      const record = {
        options: linkOptions,
        connected: 0,
        disconnected: 0,
        woken: 0,
        state,
        sends: [] as Array<{ sessionId: string; data: string }>,
        // What the copilot channels asked this link to do. Counted rather than
        // answered `true`, because the property those channels have to have is
        // that the press reaches the link at all — a handler that resolved a
        // cheerful sentence and sent nothing would look identical from outside.
        copilot: { attached: 0, started: 0, refreshed: 0, said: [] as string[] },
      }
      links.push(record)
      return {
        connect: () => {
          record.connected += 1
        },
        announceWindows: () => true,
        announceSessions: () => true,
        askWindow: () => true,
        servesWindows: () => true,
        disconnect: () => {
          record.disconnected += 1
        },
        wake: () => {
          record.woken += 1
        },
        state: () => state,
        attach: () => true,
        detach: () => true,
        input: () => true,
        // No file ever leaves this fake. The transfer path has its own end-to-end
        // cover in `transfer-live.test.ts`, over a real relay and a real disk.
        sendFile: () => Promise.resolve({ ok: false as const, message: 'not in this fake' }),
        cancelFile: () => {},
        resize: () => true,
        create: () => true,
        close: () => true,
        ports: () => true,
        localhost: () => true,
        copilotAttach: () => {
          record.copilot.attached += 1
          return { ok: true, message: 'Watching that machine’s copilot.' }
        },
        copilotStart: () => {
          record.copilot.started += 1
          return { ok: true, message: 'Asked that machine to start a copilot run.' }
        },
        copilotState: () => {
          record.copilot.refreshed += 1
          return { ok: true, message: 'Asked.' }
        },
        copilotSay: (text: string) => {
          record.copilot.said.push(text)
          return { ok: true, message: 'Sent.' }
        },
        // A link that answers nothing about controls, which is what a machine
        // whose build predates the `controls` capability really does. Null and
        // the refusal sentence are the two shapes the renderer has to be right
        // about, so the fake produces them rather than a working reading.
        readControls: () => Promise.resolve(null),
        setControl: () =>
          Promise.resolve({
            ok: false,
            message: 'That machine is running a build that cannot set a model from here.',
            reading: { value: null, label: null, source: null },
          }),
        openThere: () => true,
        // Same again for usage, and here the shape is the interesting half: this
        // link never answers null, because the bar it feeds has no previous
        // figure to keep the way the control chips do. A machine that cannot
        // report answers with an empty *reading* carrying the sentence, which is
        // what puts the reason on screen before anybody presses anything.
        readUsage: (_id: string, want: 'plan' | 'refresh' | 'context') =>
          Promise.resolve(emptyUsageReading(want, 'That machine cannot report its usage from here.')),
        // Whose login a session over there is on, and running it as another one.
        // `null` on the read and a sentence on the switch, which is the split the
        // real link makes: a chip keeps the last account it genuinely had, and a
        // press must never produce nothing at all.
        readAccount: (_id: string) => Promise.resolve(null),
        switchAccount: (_id: string, _accountId: string) =>
          Promise.resolve({ ok: false, message: 'That machine cannot change an account from here.', session: null }),
        // The machine's own login list, and starting a sign-in over there. Null
        // and a sentence, the same split the account pair above makes and for the
        // same reason.
        readLogins: () => Promise.resolve(null),
        signInLogin: (_accountId: string) =>
          Promise.resolve({ ok: false, message: 'That machine does not manage its logins from here.', session: null }),
        // Typing into a session over there without attaching to it. Recorded
        // rather than answered `true`, because the argument that has to survive
        // this channel is the text: a handler that dropped it would look
        // identical from the outside.
        send: (sessionId: string, data: string) => {
          record.sends.push({ sessionId, data })
          return Promise.resolve({ ok: true, message: 'Sent.' })
        },
      }
    },
    ...(options.pair ? { pair: options.pair } : {}),
  })

  return {
    channels: [...handlers.keys()],
    broadcasts,
    ipc,
    links,
    beacons,
    dir,
    store: new MachineStore(dir),
    invoke: async (channel, ...args) => {
      const handler = handlers.get(channel)
      if (!handler) throw new Error(`no handler for ${channel}`)
      return handler(null, ...args)
    },
  }
}

function paired(dir: string): string {
  const store = new MachineStore(dir)
  const hostId = hostIdFor(Buffer.alloc(32, 11))
  store.remember({
    name: 'Studio PC',
    hostId,
    hostPublicKey: generateStatic().publicKey,
    relayUrl: 'wss://relay.example',
    credential: 'abcdefghijkl.0123456789',
    guestKeys: generateStatic(),
    platform: 'win32',
  })
  return hostId
}

describe('launching', () => {
  it('dials every machine that is already paired, without anybody pressing anything', () => {
    const dir = tempDir()
    const hostId = paired(dir)

    const app = rig({ dir })

    // Not "a button could" — registering did.
    expect(app.links).toHaveLength(1)
    expect(app.links[0].options.id).toBe(hostId)
    expect(app.links[0].connected).toBe(1)
  })

  it('dials nothing when nothing has been paired', () => {
    expect(rig().links).toEqual([])
  })

  it('registers every channel the preload calls', () => {
    // The other half of `src/preload/contract.test.ts`, from this side: that one
    // proves the preload's channels are handled somewhere in `src/main`, this
    // one proves they are handled *here* and therefore by a registration the app
    // actually performs.
    expect(rig().channels.sort()).toEqual(
      [
        'machines:account:read',
        'machines:account:switch',
        'machines:attach',
        // Ending a session over there — `create`'s opposite number, and its own
        // channel rather than a flag on `detach` because the two are opposites
        // rather than variants: `detach` stops the bytes and leaves the process
        // running, this kills it for everyone attached. See `MachineLink.close`.
        'machines:close',
        'machines:code',
        'machines:code:cancel',
        'machines:connect',
        // The model, the effort and fast mode of a session over there. Two
        // channels rather than one because reading is passive and happens every
        // time the session prints anything, while applying **types into
        // somebody's terminal** — folding them together would put a keystroke on
        // a code path that fires on output. See `CAPABILITY.controls`.
        'machines:controls:apply',
        'machines:controls:read',
        // The copilot on that machine, which is what the switcher at the top of
        // the copilot page needs under it. Four channels rather than one
        // because they cost that computer wildly different things: attaching is
        // one callback, refreshing is a memory read, `start` spawns an agent
        // process and spends money, and `say` puts words in its prompt. There
        // is deliberately no `hello` — the link opens the stream on every
        // welcome that carried a copilot, because a window that had to
        // re-open it after every reconnect is a window that will forget.
        'machines:copilot:attach',
        'machines:copilot:refresh',
        'machines:copilot:say',
        'machines:copilot:start',
        'machines:create',
        'machines:detach',
        'machines:disconnect',
        'machines:drive-windows',
        'machines:forget',
        'machines:input',
        'machines:list',
        /*
         * The machine's own logins, and starting a sign-in on it. Two channels
         * beside the two session ones above rather than a flag on them, because
         * neither could express this: `account.read` carries a session id, so a
         * machine with nothing running had no readable logins at all — which is
         * exactly when somebody opens a settings pane to look at it. See
         * `CAPABILITY.logins`.
         */
        'machines:logins:read',
        'machines:logins:signin',
        // The two that make remote localhost work in both directions. `ports`
        // is the refresh — the link asks once per welcome and pushes the answer,
        // so this is the button for "I have just started a dev server over
        // there", which nothing on the far machine watches for. `open` is the
        // verb the phone already had and this desktop did not: put the page on
        // *that* machine's screen.
        'machines:open',
        'machines:pair',
        'machines:ports',
        // Opening a tunnel to one port on that machine, so this desktop's own
        // browser can load it. The counterpart to `ports`, which only lists
        // them: a row you can see and cannot reach is the failure the whole of
        // *"the shape of the application should not be changing for local and
        // remote devices"* is about. It answers `{ ok: false, message }` rather
        // than throwing, because every refusal here is a sentence somebody has
        // to read — not connected, not a port, not granted.
        'machines:reach',
        // And giving one back. The listener keeps the far machine's own port
        // *number* on this computer whenever it was free, which is what makes a
        // dev server's own redirects survive the trip — and it means that until
        // it is closed, that number here *is* that machine. The browser's
        // machine picker moving a page back onto this computer has nowhere to
        // send it until this is called; 0.9.0 navigated to the tunnel and came
        // back from the PC under a picker naming this Mac.
        'machines:reach:close',
        'machines:rename',
        'machines:resize',
        // Typing into a session over there **without attaching to it** — which
        // is what makes it its own channel rather than a flag on
        // `machines:input`. That one is a remote terminal pane's keyboard and
        // the far end serves it only because the pane attached first; this is
        // for a surface with something to say and nothing to read, where taking
        // out an attach would displace the handle that pane already holds. It
        // answers `{ ok, message }` rather than a boolean because there is no
        // terminal on screen to read the outcome off. See `CAPABILITY.send`.
        'machines:send',
        // A file dropped on a pane showing a session over there, and the one
        // control a person has over it once it is going. Two channels rather
        // than one because a cancel has to reach the far machine even when the
        // transfer has stalled — it is what makes that end delete the
        // half-written file rather than leaving it in somebody's downloads
        // folder. The bytes never cross this seam: the renderer hands over a
        // path and `upload-send.ts` streams it. See `MachineLink.sendFile`.
        'machines:upload',
        'machines:upload:cancel',
        // The usage bar's two figures, for a session over there. One channel
        // where the controls above are two, because none of the three readings
        // types anything — the split up there exists to keep a keystroke off a
        // path that fires on output, and there is no keystroke here. Which of
        // the three is asked for is the `want` argument, and it is what decides
        // the cost: two of them read memory and a file on that machine, and the
        // third boots a whole agent CLI there. See `CAPABILITY.usage`.
        'machines:usage:read',
      ].sort(),
    )
  })
})

describe('showing a code', () => {
  it('mints one and publishes a rendezvous for exactly as long as it lives', async () => {
    vi.useFakeTimers()
    try {
      const app = rig()
      const result = await app.invoke('machines:code')
      expect(result).toMatchObject({ ok: true })
      if (typeof result !== 'object' || result === null || !('code' in result)) throw new Error('no code')
      const code = result.code
      if (typeof code !== 'object' || code === null || !('token' in code)) throw new Error('no token')
      expect(typeof code.token === 'string' && isCode(code.token)).toBe(true)

      expect(app.beacons).toHaveLength(1)
      expect(app.beacons[0].options.code).toBe(code.token)
      expect(app.beacons[0].stopped).toBe(false)

      // One timer, tied to the life of one code. No poll, and nothing running
      // when nobody is pairing.
      vi.advanceTimersByTime(PAIRING_TTL_MS + 1)
      expect(app.beacons[0].stopped).toBe(true)
    } finally {
      vi.useRealTimers()
    }
  })

  it('takes the rendezvous down when the code is cancelled, not just the drawing of it', async () => {
    const app = rig()
    await app.invoke('machines:code')
    await app.invoke('machines:code:cancel')
    expect(app.beacons[0].stopped).toBe(true)
  })

  it('refuses a code this machine has no way of publishing', async () => {
    // A code nobody can look up is a code that fails after somebody has typed
    // it, three metres away from the machine that could have explained.
    const app = rig({ status: offlineStatus })
    expect(await app.invoke('machines:code')).toMatchObject({ ok: false })
    expect(app.beacons).toEqual([])
  })

  it('withdraws a code whose slot never comes up, rather than showing it anyway', async () => {
    // The relay took the socket and never confirmed the slot. This screen has no
    // second way in at all — the QR and the link are gone — so the code is minted, found to be
    // unpublishable, and taken back before it reaches anybody's eyes.
    const app = rig({ slotClaimed: false })
    expect(await app.invoke('machines:code')).toMatchObject({
      ok: false,
      message: expect.stringContaining('relay'),
    })
    expect(app.beacons).toHaveLength(1)
    // And the socket it opened does not outlive the attempt.
    expect(app.beacons[0].stopped).toBe(true)
  })

  it('says on the screen why no machine can be added, rather than offering a dead button', async () => {
    const view = await rig({ status: offlineStatus }).invoke('machines:list')
    expect(view).toMatchObject({ blocked: expect.stringContaining('relay') })
    expect(await rig().invoke('machines:list')).toMatchObject({ blocked: null })
  })

  /**
   * And what this machine calls itself, on the same view.
   *
   * Every other machine on it arrives with a name a person recognises and this
   * one had none, so each list that drew them together invented a phrase for it
   * — and on 2026-08-21 three of those phrases were on the browser bar at once,
   * all reading "This machine", each about a different computer:
   *
   *   > *"So I'm confused now what is the truth, because this machine is Office
   *   > PC, this machine is this machine where I am… I don't know what to
   *   > trust."*
   *
   * The hostname rather than a particular string, because a test that pinned one
   * would only be pinning the machine it ran on.
   */
  it('carries this machine’s own name, so no list has to invent a phrase for it', async () => {
    const view = (await rig().invoke('machines:list')) as { here: unknown }
    expect(view.here).toBe(hostname().replace(/\.local$/i, '').trim())
    // Never the stand-in noun the pairing offer uses. "A desktop" beside "Office
    // PC" would be this app naming his computer something nobody calls it.
    expect(view.here).not.toBe('A desktop')
  })
})

describe('adding a machine', () => {
  const offer = {
    relayUrl: 'wss://relay.example',
    hostId: hostIdFor(Buffer.alloc(32, 21)),
    publicKey: generateStatic().publicKey.toString('base64'),
    name: 'Studio PC',
    platform: 'win32',
  }

  it('stores it and dials it straight away', async () => {
    const keys = generateStatic()
    const app = rig({
      pair: () =>
        Promise.resolve({
          ok: true,
          offer,
          credential: 'abcdefghijkl.0123456789',
          deviceId: 'device-1',
          deviceName: 'This Mac',
          guestKeys: keys,
        }),
    })

    expect(await app.invoke('machines:pair', '482913')).toMatchObject({ ok: true })
    const stored = new MachineStore(app.dir).list()
    expect(stored).toHaveLength(1)
    expect(stored[0].hostId).toBe(offer.hostId)
    // Not after the next restart.
    expect(app.links).toHaveLength(1)
    expect(app.links[0].connected).toBe(1)
    expect(app.broadcasts.some((entry) => entry.channel === MACHINES_STATE_CHANNEL)).toBe(true)
  })

  it('passes a refusal back with the far machine’s own sentence', async () => {
    const app = rig({
      pair: () =>
        Promise.resolve({ ok: false, reason: 'refused', message: 'That pairing code is not right.' }),
    })
    expect(await app.invoke('machines:pair', '482913')).toEqual({
      ok: false,
      reason: 'refused',
      message: 'That pairing code is not right.',
    })
    expect(app.links).toEqual([])
  })

  it('refuses anything that is not a string before it reaches the relay', async () => {
    const app = rig({ pair: () => Promise.reject(new Error('should not be called')) })
    expect(await app.invoke('machines:pair', 42)).toMatchObject({ ok: false, reason: 'bad-code' })
  })
})

describe('the rest of the list', () => {
  it('drops the link when a machine is forgotten', async () => {
    const dir = tempDir()
    const hostId = paired(dir)
    const app = rig({ dir })

    const view = await app.invoke('machines:forget', hostId)
    expect(view).toMatchObject({ machines: [] })
    // A forget that only edited the file would leave a socket open to a machine
    // this desktop no longer claims to know.
    expect(app.links[0].disconnected).toBe(1)
    expect(new MachineStore(dir).list()).toEqual([])
  })

  it('renames one, and answers with what it stored', async () => {
    const dir = tempDir()
    const hostId = paired(dir)
    const app = rig({ dir })
    const view: unknown = await app.invoke('machines:rename', hostId, 'The loud one')
    expect(view).toMatchObject({ machines: [{ name: 'The loud one' }] })
  })

  /**
   * The question a screen outside this file asks about one machine, and the two
   * halves it has to answer.
   *
   * The server panel knows a host id out of that server's own `status` and needs
   * to know what this desktop calls it — and, since 2026-08-22, whether the link
   * behind that row is up. Measured that morning: his office PC held a row here,
   * the panel said *"This computer is linked to it"*, and the host had been
   * counting zero open channels for two hours.
   */
  it('says what it calls a machine and whether anything is reaching it', () => {
    const dir = tempDir()
    const hostId = paired(dir)
    const app = rig({ dir })

    expect(app.ipc.linkStanding(hostId)).toEqual({ name: 'Studio PC', online: false })
    app.links[0].state.state = 'online'
    expect(app.ipc.linkStanding(hostId)).toEqual({ name: 'Studio PC', online: true })
    // And a host nothing here has ever paired with is null rather than a row
    // with a false in it: "not linked" and "linked and unreachable" are two
    // different sentences with two different buttons under them.
    expect(app.ipc.linkStanding(hostIdFor(Buffer.alloc(32, 99)))).toBeNull()
  })

  /*
   * And the remedy, which is two remedies: `connect` does nothing to a link that
   * is already running and `wake` does nothing to one that is stopped, so which
   * of them applies is read off the link rather than guessed.
   */
  it('dials a machine again, by whichever of the two ways applies', () => {
    const dir = tempDir()
    const hostId = paired(dir)
    const app = rig({ dir })

    // Stopped: it has to be started. One from launch, one from this.
    expect(app.ipc.redial(hostId)).toBe(true)
    expect(app.links[0].connected).toBe(2)
    expect(app.links[0].woken).toBe(0)

    // Running: it has to be woken, which redials now and forgets the backoff.
    app.links[0].state.state = 'online'
    expect(app.ipc.redial(hostId)).toBe(true)
    expect(app.links[0].woken).toBe(1)
    expect(app.links[0].connected).toBe(2)
  })

  /*
   * The wait the server connector's last sentence depends on. Settled from the
   * link's own `onState`, so a machine that comes up answers immediately rather
   * than at the end of some interval nobody chose.
   */
  it('waits for a link to start carrying, and answers when it does', async () => {
    const dir = tempDir()
    const hostId = paired(dir)
    const app = rig({ dir })

    const waiting = app.ipc.whenReaching(hostId, 5_000)
    app.links[0].state.state = 'online'
    app.links[0].options.onState(app.links[0].state)
    expect(await waiting).toBe(true)

    // And a link that is already carrying answers without waiting at all.
    expect(await app.ipc.whenReaching(hostId, 5_000)).toBe(true)
  })

  /*
   * A stated outcome rather than a safety net: without it the panel that asked
   * sits on "waiting for this computer to reach it" for as long as the machine
   * stays away, which is worse than saying so.
   */
  it('gives up on its own ceiling rather than waiting forever', async () => {
    const dir = tempDir()
    const hostId = paired(dir)
    const app = rig({ dir })
    expect(await app.ipc.whenReaching(hostId, 10)).toBe(false)
    // And a machine this desktop does not hold is answered at once, not waited
    // out — there is nothing that could ever come up.
    expect(await app.ipc.whenReaching(hostIdFor(Buffer.alloc(32, 99)), 60_000)).toBe(false)
  })

  it('says there was nothing to dial for a machine it does not hold', () => {
    const app = rig()
    expect(app.ipc.redial(hostIdFor(Buffer.alloc(32, 99)))).toBe(false)
    expect(app.links).toEqual([])
  })

  it('connects and disconnects one by hand', async () => {
    const dir = tempDir()
    const hostId = paired(dir)
    const app = rig({ dir })
    await app.invoke('machines:disconnect', hostId)
    await app.invoke('machines:connect', hostId)
    expect(app.links[0].disconnected).toBe(1)
    // One from launch, one from the button.
    expect(app.links[0].connected).toBe(2)
  })

  it('answers a session verb with whether it actually went', async () => {
    const dir = tempDir()
    const hostId = paired(dir)
    const app = rig({ dir })
    expect(await app.invoke('machines:attach', hostId, 's1', 80, 24)).toBe(true)
    expect(await app.invoke('machines:input', hostId, 's1', 'ls')).toBe(true)
    // A machine nobody has paired with cannot be typed into, and the caller is
    // told rather than left watching keystrokes vanish.
    expect(await app.invoke('machines:input', 'nobody', 's1', 'ls')).toBe(false)
    expect(await app.invoke('machines:attach', hostId, 's1', 'wide', 24)).toBe(false)
  })

  it('sends to a session over there, and turns every refusal into a sentence', async () => {
    const dir = tempDir()
    const hostId = paired(dir)
    const app = rig({ dir })

    expect(await app.invoke('machines:send', hostId, 's1', 'look at this button')).toEqual({
      ok: true,
      message: 'Sent.',
    })
    // The text reached the link, which is the argument this channel exists to
    // carry and the one a handler can drop without anything looking wrong.
    expect(app.links[0].sends).toEqual([{ sessionId: 's1', data: 'look at this button' }])

    /*
     * Every refusal is a sentence rather than a throw or a bare `false`, because
     * the caller is a panel with no terminal on screen: a send that produced
     * nothing would be indistinguishable from a feature that does not work.
     */
    for (const bad of [
      [42, 's1', 'x'],
      [hostId, 42, 'x'],
      [hostId, 's1', 42],
      // Nothing to send is not a send. It would otherwise reach a pty as a
      // write of no bytes and be reported as having worked.
      [hostId, 's1', ''],
      // A machine nobody paired with.
      ['nobody', 's1', 'x'],
    ]) {
      expect(await app.invoke('machines:send', ...bad), JSON.stringify(bad)).toMatchObject({
        ok: false,
        message: expect.stringMatching(/./),
      })
    }
    // And not one of those reached the link.
    expect(app.links[0].sends).toHaveLength(1)
  })

  it('pushes a machine’s output at the window with the machine it came from', () => {
    const dir = tempDir()
    const hostId = paired(dir)
    const app = rig({ dir })
    app.links[0].options.onOutput('s1', 'hello', false)
    expect(app.broadcasts).toContainEqual({
      channel: MACHINES_OUTPUT_CHANNEL,
      payload: { machineId: hostId, sessionId: 's1', data: 'hello', replay: false },
    })
  })

  it('carries every copilot verb to the link, and refuses the rest with a sentence', async () => {
    const dir = tempDir()
    const hostId = paired(dir)
    const app = rig({ dir })

    expect(await app.invoke('machines:copilot:attach', hostId)).toMatchObject({ ok: true })
    expect(await app.invoke('machines:copilot:start', hostId)).toMatchObject({ ok: true })
    expect(await app.invoke('machines:copilot:refresh', hostId)).toMatchObject({ ok: true })
    expect(await app.invoke('machines:copilot:say', hostId, 'which session is stuck?')).toMatchObject({
      ok: true,
    })
    // Reached the link, all four of them, and the text with the one that
    // carries text. A handler that answered cheerfully and forwarded nothing is
    // the failure this asserts against, and it is the one that looks correct
    // from the window: the sentence arrives, and the far machine never hears.
    expect(app.links[0].copilot).toEqual({ attached: 1, started: 1, refreshed: 1, said: ['which session is stuck?'] })

    /*
     * And every refusal is a sentence, on every path, for the reason
     * `machines:send` above needs one: the copilot page has no terminal on it,
     * so a press that produced nothing at all would be indistinguishable from a
     * control that does not work.
     */
    for (const [channel, ...args] of [
      ['machines:copilot:attach', 42],
      ['machines:copilot:start', 42],
      ['machines:copilot:refresh', 42],
      ['machines:copilot:say', hostId, 42],
      // Nothing to say is not a message. It would otherwise reach the wire
      // parser as an empty `copilot.say` and be refused a layer further out,
      // where the sentence is about a frame rather than about a composer.
      ['machines:copilot:say', hostId, ''],
      // A machine nobody paired with.
      ['machines:copilot:attach', 'nobody'],
      ['machines:copilot:say', 'nobody', 'hello'],
    ] as Array<[string, ...unknown[]]>) {
      expect(await app.invoke(channel, ...args), `${channel} ${JSON.stringify(args)}`).toMatchObject({
        ok: false,
        message: expect.stringMatching(/./),
      })
    }
    // And not one of those reached the link either.
    expect(app.links[0].copilot).toEqual({ attached: 1, started: 1, refreshed: 1, said: ['which session is stuck?'] })
  })

  it('pushes a machine’s copilot state and chat with the machine they came from', () => {
    const dir = tempDir()
    const hostId = paired(dir)
    const app = rig({ dir })

    const state = {
      desk: 'running' as const,
      run: 'run-1',
      profile: 'Personal',
      signedIn: true,
      tools: 14,
      turnTokens: 2200,
      pending: 0,
      grant: { read: true, act: true, alter: true },
      available: true,
      reason: null,
    }
    app.links[0].options.onCopilotState?.(state)
    expect(app.broadcasts).toContainEqual({
      channel: MACHINES_COPILOT_STATE_CHANNEL,
      payload: { machineId: hostId, state },
    })

    /*
     * The chat goes up as the **whole frame**, and that is the assertion rather
     * than a detail of the payload's shape.
     *
     * `run` is what lets a reader drop a frame belonging to a run that has
     * ended instead of splicing it onto a live conversation, and `reset` is the
     * instruction to throw away what is held. Neither can be recovered from the
     * messages, so a push that carried the bubbles alone would force the window
     * to guess — and the guess it would make is the one that shows somebody an
     * answer to a question nobody asked in this run.
     */
    const chat = {
      t: 'copilot.chat' as const,
      run: 'run-1',
      reset: true as const,
      messages: [{ id: 'm1', role: 'agent' as const, text: 'Session 3 is waiting on you.', at: 1 }],
    }
    app.links[0].options.onCopilotChat?.(chat)
    expect(app.broadcasts).toContainEqual({
      channel: MACHINES_COPILOT_CHAT_CHANNEL,
      payload: { machineId: hostId, chat },
    })
  })
})

describe('waking', () => {
  it('redials every link, because a suspended one is dead and still looks fine', () => {
    const dir = tempDir()
    paired(dir)
    const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()
    const links: Array<{ woken: number }> = []
    const machines = registerMachinesIpc(
      {
        handle: (channel, listener) => {
          handlers.set(channel, listener)
        },
      },
      {
        storageDir: dir,
        desk: pairingDesk(new RemoteAuth(dir)),
        status: connectedStatus,
        broadcast: () => {},
        createLink: (linkOptions): MachineLink => {
          const record = { woken: 0 }
          links.push(record)
          const state: MachineLinkState = {
            id: linkOptions.id,
            state: 'offline',
            reason: null,
            sessions: [],
            folders: null,
            capabilities: [],
            ports: [],
            copilot: null,
            hostPlatform: '',
            retryAt: null,
          }
          return {
            connect: () => {},
            disconnect: () => {},
            announceWindows: () => true,
            announceSessions: () => true,
            askWindow: () => true,
            servesWindows: () => true,
            wake: () => {
              record.woken += 1
            },
            state: () => state,
            attach: () => true,
            detach: () => true,
            sendFile: () => Promise.resolve({ ok: false as const, message: 'not in this fake' }),
            cancelFile: () => {},
            input: () => true,
            resize: () => true,
            create: () => true,
            close: () => true,
            ports: () => true,
            localhost: () => true,
            copilotAttach: () => ({ ok: true, message: 'Watching that machine’s copilot.' }),
            copilotStart: () => ({ ok: true, message: 'Asked that machine to start a copilot run.' }),
            copilotState: () => ({ ok: true, message: 'Asked.' }),
            copilotSay: () => ({ ok: true, message: 'Sent.' }),
            // A link that answers nothing about controls, which is what a machine
            // whose build predates the `controls` capability really does. Null and
            // the refusal sentence are the two shapes the renderer has to be right
            // about, so the fake produces them rather than a working reading.
            readControls: () => Promise.resolve(null),
            setControl: () =>
              Promise.resolve({
                ok: false,
                message: 'That machine is running a build that cannot set a model from here.',
                reading: { value: null, label: null, source: null },
              }),
            openThere: () => true,
            // Same again for usage, and here the shape is the interesting half: this
            // link never answers null, because the bar it feeds has no previous
            // figure to keep the way the control chips do. A machine that cannot
            // report answers with an empty *reading* carrying the sentence, which is
            // what puts the reason on screen before anybody presses anything.
            readUsage: (_id: string, want: 'plan' | 'refresh' | 'context') =>
              Promise.resolve(emptyUsageReading(want, 'That machine cannot report its usage from here.')),
            // Whose login a session over there is on, and running it as another one.
            // `null` on the read and a sentence on the switch, which is the split
            // the real link makes.
            readAccount: (_id: string) => Promise.resolve(null),
            switchAccount: (_id: string, _accountId: string) =>
              Promise.resolve({ ok: false, message: 'That machine cannot change an account from here.', session: null }),
            // And the same two asked about the machine rather than a session.
            readLogins: () => Promise.resolve(null),
            signInLogin: (_accountId: string) =>
              Promise.resolve({
                ok: false,
                message: 'That machine does not manage its logins from here.',
                session: null,
              }),
            send: () => Promise.resolve({ ok: true, message: 'Sent.' }),
          }
        },
      },
    )
    machines.wake()
    expect(links[0].woken).toBe(1)

    const view: MachinesView = machines.view()
    expect(view.machines).toHaveLength(1)
    machines.stop()
  })
})

describe('letting a machine act on browser windows here', () => {
  it('starts open because pairing was the allowing, and the switch is the way to say no', async () => {
    /*
     * The fourth grant axis, and since T30 it follows the rule the person
     * accepted: the connection IS the authorization. Every machine in this
     * store was paired by the person at this keyboard with their own hands, so
     * its sessions drive by default and the switch on the card is the
     * off-switch — written through the one store, answered as the whole view.
     */
    const dir = tempDir()
    const hostId = paired(dir)
    const app = rig({ dir })

    const before = ((await app.invoke('machines:list')) as MachinesView)
    expect(before.machines[0].drivesWindows).toBe(true)

    const after = ((await app.invoke('machines:drive-windows', hostId, false)) as MachinesView)
    // The answer is the view, so the panel redraws from what was stored rather
    // than from what it thinks it just set.
    expect(after.machines[0].drivesWindows).toBe(false)
    // Read from disk rather than from the rig's own copy, which was built
    // before the write: the untick has to survive the process, because it is a
    // decision rather than a session.
    expect(new MachineStore(dir).drivesWindows(hostId)).toBe(false)

    // Only a literal boolean is a person pressing the switch. A garbled value
    // over the bridge changes nothing — in either direction.
    expect(
      ((await app.invoke('machines:drive-windows', hostId, 'yes')) as MachinesView).machines[0].drivesWindows,
    ).toBe(false)
    expect(
      ((await app.invoke('machines:drive-windows', hostId, true)) as MachinesView).machines[0].drivesWindows,
    ).toBe(true)
    expect(
      ((await app.invoke('machines:drive-windows', hostId, 0)) as MachinesView).machines[0].drivesWindows,
    ).toBe(true)
  })

  it('reads his machines.json — a row with no drivesWindows key — as allowed, at the seam the dispatcher asks', async () => {
    /*
     * DESKTOP-DDGMNCV in his real file predates the field, and for one release
     * that read as closed: every forwarded cross-machine window verb refused,
     * on the machine he tests against. `index.ts` wires the serve half's
     * `allowed` to exactly this seam — `machinesIpc.drivesWindows` — so what
     * is pinned is the person's path: the real file shape, the real
     * registration, the read the dispatcher makes per call.
     */
    const dir = tempDir()
    const hostId = paired(dir)
    const parsed = JSON.parse(readFileSync(join(dir, 'machines.json'), 'utf8')) as {
      machines: Record<string, unknown>[]
    }
    delete parsed.machines[0].drivesWindows
    writeFileSync(join(dir, 'machines.json'), JSON.stringify(parsed))

    const app = rig({ dir })
    expect(app.ipc.drivesWindows(hostId)).toBe(true)
    expect(((await app.invoke('machines:list')) as MachinesView).machines[0].drivesWindows).toBe(true)

    // The switch is the off-switch, and the untick lands on the same seam the
    // next inbound verb is checked against — per call, no reconnection.
    await app.invoke('machines:drive-windows', hostId, false)
    expect(app.ipc.drivesWindows(hostId)).toBe(false)
  })

  it('is broadcast as well as answered, so every other window hears the grant', async () => {
    /*
     * The same argument `machines:forget` and `machines:rename` already make,
     * and until 2026-08-22 this was the one store write of the three that made
     * it to nobody but its caller — every other surface only stayed honest
     * because the renderer polled the list every four seconds. The poll is
     * gone (events, not polling), so the event has to be real.
     */
    const dir = tempDir()
    const hostId = paired(dir)
    const app = rig({ dir })
    app.broadcasts.length = 0

    await app.invoke('machines:drive-windows', hostId, true)
    const pushed = app.broadcasts.filter((entry) => entry.channel === MACHINES_STATE_CHANNEL)
    expect(pushed.length).toBeGreaterThan(0)
    const view = pushed[pushed.length - 1].payload as MachinesView
    expect(view.machines[0].drivesWindows).toBe(true)
  })

  it('hands an inbound browser verb to whatever the app wired, with the machine on it', async () => {
    const dir = tempDir()
    const hostId = paired(dir)
    const served: unknown[] = []
    const app = rig({ dir, serveWindows: async (machineId, call) => {
      served.push({ machineId, call })
      return { ok: true, body: '{}' }
    } })

    const onWindowCall = app.links[0].options.onWindowCall
    expect(onWindowCall, 'the link was built with no handler, so it never advertises the capability').toBeDefined()
    await onWindowCall?.({ sessionId: 'sess-1', tool: 'browser.read', args: '{}' })
    expect(served).toEqual([
      { machineId: hostId, call: { sessionId: 'sess-1', tool: 'browser.read', args: '{}' } },
    ])
  })

  it('gives the link no handler at all when the app wired none', () => {
    // Absent rather than present-and-refusing: the link reads the absence to
    // decide whether to advertise `windows`, and a machine told it may ask,
    // asking, and being refused every time is a feature that exists only as a
    // timeout.
    const dir = tempDir()
    paired(dir)
    expect(rig({ dir }).links[0].options.onWindowCall).toBeUndefined()
  })
})

describe('acting on a browser window that machine holds', () => {
  /**
   * The mirror, wired the same way and with the same absences.
   *
   * A session running *here* whose window is in the app over there. What this
   * file owns of it is only the plumbing — which machine a frame belongs to, and
   * whether a link exists to carry it — because the desk holds the questions and
   * `window-serve.ts` holds every decision.
   */
  it('routes that machine’s holdings to the desk, with the machine on them', () => {
    const dir = tempDir()
    const hostId = paired(dir)
    const held: { machineId: string; sessions: string[] }[] = []
    const app = rig({ dir, windowsHeldThere: (machineId, sessions) => held.push({ machineId, sessions: [...sessions] }) })

    app.links[0].options.onWindowHolds?.(['sess-1', 'sess-2'])
    expect(held).toEqual([{ machineId: hostId, sessions: ['sess-1', 'sess-2'] }])
  })

  it('hands an answer straight through, keyed by nothing but its own id', () => {
    /*
     * No machine id on this one, deliberately: the id was minted here and handed
     * to exactly one link, so the desk already knows which question it belongs
     * to. A second key would be one that has to agree with the first.
     */
    const dir = tempDir()
    paired(dir)
    const answers: unknown[] = []
    const app = rig({ dir, windowAnswered: (result) => answers.push(result) })

    app.links[0].options.onWindowResult?.({ id: 'w-1', ok: true, body: '{}' })
    expect(answers).toEqual([{ id: 'w-1', ok: true, body: '{}' }])
  })

  it('gives the link no holdings handler when the app wired none', () => {
    // Absent is what the link reads to decide whether to advertise
    // `hostwindows`. A build that claimed it with nowhere to put the answer
    // would receive the frame and drop it.
    const dir = tempDir()
    paired(dir)
    expect(rig({ dir }).links[0].options.onWindowHolds).toBeUndefined()
  })

  it('puts the ask on that machine’s link, and nowhere at all for one it does not know', () => {
    /*
     * A count rather than a boolean, because that is the shape the desk's wire
     * takes on both directions — and on this one it is only ever nought or one:
     * a machine is one link, unlike a device, which can be attached from two
     * windows at once.
     */
    const dir = tempDir()
    const hostId = paired(dir)
    const app = rig({ dir })
    const call = { t: 'window.call', id: 'w-1', session: 'sess-1', tool: 'browser.read', args: '{}' } as const

    expect(app.ipc.askWindow(hostId, { ...call })).toBe(1)
    expect(app.ipc.servesWindows(hostId)).toBe(true)
    // Nought rather than a throw: an id this desktop has never paired is what a
    // stale table looks like, and the desk turns nought into a sentence.
    expect(app.ipc.askWindow('nobody', { ...call })).toBe(0)
    expect(app.ipc.servesWindows('nobody')).toBe(false)
  })

  it('settles everything outstanding when a link stops being online', () => {
    /*
     * A tool call that can be answered in milliseconds must not spend fifty-five
     * seconds finding out the machine hung up. What is deliberately *not*
     * dropped is the table of what that machine said it holds: a laptop that
     * closed its lid still has the window, and "that computer is not connected
     * right now" is true and actionable where "no browser window is attached to
     * this session" is false.
     */
    const dir = tempDir()
    const hostId = paired(dir)
    const gone: string[] = []
    const app = rig({ dir, windowsUnreachable: (machineId) => gone.push(machineId) })

    app.links[0].options.onState({
      id: hostId,
      state: 'offline',
      reason: null,
      sessions: [],
      folders: null,
      capabilities: [],
      ports: [],
      copilot: null,
      hostPlatform: '',
      retryAt: null,
    })
    expect(gone).toEqual([hostId])
  })
})

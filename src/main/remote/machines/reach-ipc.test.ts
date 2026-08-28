import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { generateStatic } from '../../../shared/sealed'
import { hostIdFor } from '../../../shared/relay-wire'
import { RemoteAuth } from '../device-auth'
import { emptyUsageReading } from '../protocol'
import { pairingDesk, type RemoteStatus } from '../server'
import type { LocalhostMessage } from '../tunnel'
import type { MachineLink, MachineLinkOptions, MachineLinkState } from './guest'
import type { Beacon } from './rendezvous'
import { MachineStore } from './store'
import { MACHINES_STATE_CHANNEL, registerMachinesIpc, type InvokeRegistrar } from './ipc'

/**
 * `machines:reach`, the verb the window presses when somebody types an address
 * that belongs to another computer.
 *
 * ## Why it is worth its own file
 *
 * It is the only channel in this module that answers with a **sentence** rather
 * than a boolean, and that is the point of it. Every other verb here can afford
 * `true`/`false` because a boolean means "the request went" and whatever went
 * wrong afterwards went wrong on the far machine, which says so itself. This one
 * fails in ways that are all this end's business — the link is down, that machine
 * no longer serves the port, it never answered, this machine could not open an
 * address — and each of them is a different thing for the person at the keyboard
 * to do. A `false` here would arrive in the browser as a click that did nothing.
 *
 * `localhost-reach.test.ts` covers the pipe itself, byte for byte, against real
 * loopback sockets. What is held here is the seam above it: the handler's own
 * guards, and the two moments a machine's listeners have to be taken down.
 */

const dirs: string[] = []

afterEach(() => {
  while (dirs.length > 0) rmSync(dirs.pop() as string, { recursive: true, force: true })
})

function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'deck-machines-reach-'))
  dirs.push(dir)
  return dir
}

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
      hostId: hostIdFor(Buffer.alloc(32, 3)),
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

interface Rig {
  invoke(channel: string, ...args: unknown[]): Promise<unknown>
  /** The frames the link was asked to put on the wire. */
  sent: LocalhostMessage[]
  /** Everything pushed to the windows, in order. */
  broadcasts: Array<{ channel: string; payload: unknown }>
  machineId: string
}

/**
 * One paired machine, with a link that reports whether it would carry a frame.
 *
 * `online` decides what `localhost()` answers, which is exactly the seam the
 * real link uses: `guest.ts` refuses these frames unless the far machine
 * advertised `localhost`, because a host that never advertised a verb answers it
 * by closing the channel — and a button that disconnects you is worse than one
 * that is not offered. False therefore means both "not connected" and "not
 * shared with this desktop", which is why the sentence covers the ground it
 * does.
 */
function rig(options: { online: boolean }): Rig {
  const dir = tempDir()
  const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()
  const ipcMain: InvokeRegistrar = {
    handle: (channel, listener) => {
      handlers.set(channel, listener)
    },
  }
  const sent: LocalhostMessage[] = []
  const broadcasts: Array<{ channel: string; payload: unknown }> = []

  const store = new MachineStore(dir)
  const machine = store.remember({
    name: 'office-pc',
    hostId: hostIdFor(Buffer.alloc(32, 9)),
    hostPublicKey: generateStatic().publicKey,
    relayUrl: 'wss://relay.example',
    credential: 'abcdefghijkl.0123456789',
    guestKeys: generateStatic(),
    platform: 'win32',
  })

  const desk = pairingDesk(new RemoteAuth(dir), Date.now, (): Beacon => ({
    stop: () => undefined,
    connected: () => true,
    ready: () => Promise.resolve(true),
  }))

  registerMachinesIpc(ipcMain, {
    storageDir: dir,
    desk,
    status: connectedStatus,
    broadcast: (channel, payload) => broadcasts.push({ channel, payload }),
    createLink: (linkOptions: MachineLinkOptions): MachineLink => {
      const state: MachineLinkState = {
        id: linkOptions.id,
        state: options.online ? 'online' : 'offline',
        reason: null,
        sessions: [],
        folders: null,
        capabilities: options.online ? ['localhost'] : [],
        ports: [],
        copilot: null,
        hostPlatform: 'win32',
        hostVersion: '',
        hostKind: null,
        retryAt: null,
      }
      return {
        connect: () => undefined,
        disconnect: () => undefined,
        announceWindows: () => true,
        announceSessions: () => true,
        askWindow: () => true,
        servesWindows: () => true,
        wake: () => undefined,
        state: () => state,
        attach: () => true,
        detach: () => true,
        input: () => true,
        sendFile: () => Promise.resolve({ ok: false as const, message: 'not in this fake' }),
        cancelFile: () => {},
        resize: () => true,
        create: () => true,
        close: () => true,
        // The rename verb, present so this fake still satisfies `MachineLink`.
        // Nothing in this file sends one — it is about reaching a port.
        rename: () => true,
        ports: () => options.online,
        localhost: (message) => {
          if (!options.online) return false
          sent.push(message)
          return true
        },
        // A link that answers nothing about controls, which is what a machine
        // whose build predates the `controls` capability really does. Null and
        // the refusal sentence are the two shapes the renderer has to be right
        // about, so the fake produces them rather than a working reading.
        send: () => Promise.resolve({ ok: true, message: 'Sent.' }),
        readControls: () => Promise.resolve(null),
        setControl: () =>
          Promise.resolve({
            ok: false,
            message: 'That machine is running a build that cannot set a model from here.',
            reading: { value: null, label: null, source: null },
          }),
        openThere: () => true,
        // A machine that never offered this desktop a copilot, which is what
        // `copilot: null` above says and what a link to a machine that paired
        // this one as a guest really answers.
        copilotAttach: () => ({ ok: false, message: 'That machine is not sharing a copilot with this desktop.' }),
        copilotStart: () => ({ ok: false, message: 'That machine is not sharing a copilot with this desktop.' }),
        copilotState: () => ({ ok: false, message: 'That machine is not sharing a copilot with this desktop.' }),
        copilotSay: () => ({ ok: false, message: 'That machine is not sharing a copilot with this desktop.' }),
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
        signOutLogin: (_accountId: string) =>
          Promise.resolve({ ok: false, message: 'That machine does not manage its logins from here.', session: null }),
        // The host over the relay and that machine's GitHub — null, present so
        // this fake still satisfies `MachineLink`. Nothing here presses them; this
        // file is about reaching a port.
        hostStatus: () => Promise.resolve(null),
        hostRestart: () => Promise.resolve(null),
        hostStop: () => Promise.resolve(null),
        githubRead: () => Promise.resolve(null),
        githubConnect: () => Promise.resolve(null),
        githubCancel: () => Promise.resolve(null),
        githubDisconnect: () => Promise.resolve(null),
      }
    },
  })

  return {
    sent,
    broadcasts,
    machineId: machine.id,
    invoke: async (channel, ...args) => {
      const handler = handlers.get(channel)
      if (!handler) throw new Error(`no handler for ${channel}`)
      return handler(null, ...args)
    },
  }
}

describe('asking for a port on another machine', () => {
  it('refuses arguments that are not a machine and a port, in a sentence', () => {
    const app = rig({ online: true })
    return Promise.all([
      app.invoke('machines:reach', 7, 3000),
      app.invoke('machines:reach', app.machineId, '3000'),
      app.invoke('machines:reach', app.machineId, undefined),
    ]).then((answers) => {
      for (const answer of answers) {
        expect(answer).toEqual({ ok: false, message: 'That is not a machine and a port.' })
      }
    })
  })

  it('refuses a machine this desktop has never linked to, and names the reason', async () => {
    const app = rig({ online: true })
    expect(await app.invoke('machines:reach', 'no-such-machine', 3000)).toEqual({
      ok: false,
      message: 'This desktop is not connected to that machine.',
    })
  })

  it('refuses a port number that is not one', async () => {
    const app = rig({ online: true })
    // Answered by the reach itself, before anything is put on the wire. A window
    // is not the only caller of an IPC channel.
    expect(await app.invoke('machines:reach', app.machineId, 0)).toMatchObject({ ok: false })
    expect(await app.invoke('machines:reach', app.machineId, 70_000)).toMatchObject({ ok: false })
    expect(await app.invoke('machines:reach', app.machineId, 1.5)).toMatchObject({ ok: false })
    expect(app.sent).toEqual([])
  })

  /**
   * The link being down and the far machine not sharing its ports arrive here as
   * the same `false`, and the sentence has to work for both.
   *
   * That is not vagueness. `guest.ts` refuses to send a `tunnel.open` at all
   * unless the welcome advertised `localhost` — a machine that treats this
   * desktop as a guest never advertises it, because `capabilitiesFor` in
   * `server.ts` strips it — so from this side there is one observable fact: the
   * frame did not go. The picker in the window is where the two are told apart,
   * because that is where the capability list can be read.
   */
  it('refuses without binding anything when the frame cannot leave this machine', async () => {
    const app = rig({ online: false })
    const answer = await app.invoke('machines:reach', app.machineId, 3000)
    expect(answer).toEqual({
      ok: false,
      message: 'That machine is not connected right now, so its ports cannot be reached.',
    })
    expect(app.sent).toEqual([])
  })

  it('asks the far machine to open the tunnel when it can', async () => {
    const app = rig({ online: true })
    // Not awaited to completion: the far machine never answers in this rig, so
    // the open sits on its twenty-second deadline. What is being held here is
    // that the frame goes, and goes naming the port that was asked for.
    void app.invoke('machines:reach', app.machineId, 5173)
    await Promise.resolve()
    expect(app.sent).toHaveLength(1)
    expect(app.sent[0]).toMatchObject({ t: 'tunnel.open', port: 5173 })
  })

  /**
   * The other half of the verb, and the reason it had to exist.
   *
   * The listener keeps the far machine's own port number on this computer
   * whenever it was free — the whole value of the ladder in
   * `localhost-reach.ts` — so until it is closed, `localhost:3100` here *is*
   * that machine's 3100. The browser's machine picker moving a page back onto
   * this computer had nowhere to send it: 0.9.0 navigated to the tunnel, the
   * page came back from the PC, and the picker kept this Mac's name over it.
   */
  it('answers a hand-back with a boolean, not a sentence', async () => {
    const app = rig({ online: true })
    // Nothing was ever opened on 5173, and that is a true answer about the
    // address rather than a failure: no listener of this desktop's is there.
    expect(await app.invoke('machines:reach:close', app.machineId, 5173)).toBe(true)
    // A machine this desktop has no link to took its listeners with it.
    expect(await app.invoke('machines:reach:close', 'no-such-machine', 5173)).toBe(true)
  })

  it('refuses a hand-back that is not a machine and a port', async () => {
    const app = rig({ online: true })
    // The one answer that is not about a port. `false` here means the request
    // was malformed, which the window must not read as "the address is free".
    expect(await app.invoke('machines:reach:close', 7, 3000)).toBe(false)
    expect(await app.invoke('machines:reach:close', app.machineId, '3000')).toBe(false)
  })

  it('stops serving a machine’s pages the moment it is forgotten', async () => {
    const app = rig({ online: true })
    void app.invoke('machines:reach', app.machineId, 5173)
    await Promise.resolve()
    await app.invoke('machines:forget', app.machineId)
    // A machine this desktop no longer claims to know must not still have
    // listeners on this machine's loopback answering for it.
    expect(await app.invoke('machines:reach', app.machineId, 5173)).toEqual({
      ok: false,
      message: 'This desktop is not connected to that machine.',
    })
  })
})

/**
 * Forgetting a machine has to reach every window, not just the screen that did it.
 *
 * The Remote screen redraws from this channel's *reply*. Nothing else can: the
 * sidebar and the browser panel's machine picker read `machines:state`, and
 * until this pushed, forgetting a machine in Settings left it offered in a
 * dropdown beside the address bar — an address on a computer this desktop had
 * just been told to forget. Watched happening, in the app, on 2026-08-18.
 */
describe('the windows are told when the list changes', () => {
  it('pushes the new list after a machine is forgotten', async () => {
    const app = rig({ online: true })
    const before = app.broadcasts.length
    await app.invoke('machines:forget', app.machineId)
    const pushed = app.broadcasts.slice(before).filter((one) => one.channel === MACHINES_STATE_CHANNEL)
    expect(pushed).toHaveLength(1)
    const payload = pushed[0].payload as { machines: unknown[] }
    expect(payload.machines).toEqual([])
  })

  it('pushes the new list after a machine is renamed', async () => {
    const app = rig({ online: true })
    const before = app.broadcasts.length
    await app.invoke('machines:rename', app.machineId, 'the other one')
    const pushed = app.broadcasts.slice(before).filter((one) => one.channel === MACHINES_STATE_CHANNEL)
    expect(pushed).toHaveLength(1)
    const payload = pushed[0].payload as { machines: Array<{ name: string }> }
    expect(payload.machines[0].name).toBe('the other one')
  })
})

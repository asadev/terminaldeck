/**
 * The machines feature, assembled and wired to the window.
 *
 * ## Why this is a separate registration from `registerRemoteIpc`
 *
 * That one is the host: it owns the trust store, the listener and the relay
 * this machine is reachable *at*. This one is the guest: it owns the list of
 * machines this desktop can reach *out to*, one link per machine, and the two
 * screens that drive them.
 *
 * They share exactly one object, and it is deliberate: the pairing desk. There
 * is one code on screen at a time whether a phone or a second desktop is about
 * to read it, and a second desk would mean two codes could be live and only one
 * of them believed — a pairing screen saying a code is valid while the machine
 * refuses it.
 *
 * Sharing the desk is also what makes the two codes *behave* the same. It did
 * not always: this file published a rendezvous beacon for the code it minted and
 * `remote:pair` published nothing, so the phone panel's code could not be looked
 * up by anybody typing it. Publishing now belongs to the desk — `desk.show`
 * mints and claims the slot in one call — so there is one code, one slot, and no
 * second way to publish one.
 *
 * ## The bug class this file is written against
 *
 * "Built, tested, and never wired to boot." Every paired machine is connected
 * from {@link registerMachinesIpc} itself, at launch, not from a button — and
 * `machines.boot.test.ts` asserts that *constructing* this causes a dial rather
 * than that some control could. A feature whose always-on half only runs when
 * somebody visits its screen is a feature that is off.
 */

import { DEFAULT_RELAY_URL } from '../../../shared/relay-wire'
import type { InvokeRegistrar } from '../../ipc-seam'
import type { PairingToken } from '../device-auth'
import type { PairingDesk, RemoteStatus } from '../server'
import { createMachineLink, type MachineLink, type MachineLinkState } from './guest'
import { pairWithCode, type PairResult } from './pair'
import { offerFrom } from './rendezvous'
import { MachineStore, type Machine } from './store'

/**
 * The one method of Electron's `IpcMain` this file uses.
 *
 * Named rather than imported so that nothing here needs Electron to exist — the
 * same rule `device-auth.ts` and `relay-client.ts` follow, and the reason a test
 * can register the whole feature against a plain object and watch what
 * *launching* it does. `src/preload/contract.test.ts` reads the literal
 * `ipcMain.handle('…')` calls below out of the source, so the parameter keeps
 * that name.
 *
 * The shape itself now lives in `src/main/ipc-seam.ts`: this file, `wsl.ts` and
 * `remote/server.ts` had each written it out separately, and the headless build
 * needs all three to be one type so its own desk satisfies every registration.
 * Re-exported here so nothing that already imported it from this module breaks.
 */
export type { InvokeRegistrar } from '../../ipc-seam'

export const MACHINES_STATE_CHANNEL = 'machines:state'
export const MACHINES_OUTPUT_CHANNEL = 'machines:output'

/** What one screen needs to draw every row, in one message. */
export interface MachinesView {
  machines: Machine[]
  links: MachineLinkState[]
  /**
   * Why no machine can be added right now, or null when one can.
   *
   * Pairing needs this desktop's own relay link, because the code is published
   * through it and because the far machine has to be told an address it can
   * dial back on. Saying so on the screen is the difference between a disabled
   * button and a button that does nothing — see rule 1 in the design brief.
   */
  blocked: string | null
}

export interface MachinesIpcDeps {
  /** Where `machines.json` lives. The same directory the trust store uses. */
  storageDir: string
  /**
   * The one live pairing code, shared with the host half. See above.
   *
   * It is also the only thing here that publishes a rendezvous: `desk.show`
   * mints the code and claims its slot in one call, so this screen and the
   * phone pairing on the Remote panel produce codes that behave identically.
   * A test that must not open a socket injects its beacon seam into
   * `pairingDesk`, not here.
   */
  desk: PairingDesk
  /** Read this desktop's own relay state, for the address inside an offer. */
  status(): RemoteStatus
  /** Pushes a channel to every window. */
  broadcast(channel: string, payload: unknown): void
  /** The relay this desktop dials when looking a code up. */
  relayUrl?: string
  /** Seam for the tests: nothing in a unit test may dial the public internet. */
  pair?: typeof pairWithCode
  /** Seam for the tests, so a link can be driven without a socket. */
  createLink?: typeof createMachineLink
  now?: () => number
}

export interface MachinesIpc {
  /** Every machine and the state of its link, as the window would draw it. */
  view(): MachinesView
  /** The machine woke up. Redial every link that is meant to be up. */
  wake(): void
  /** Drop every link and stop the beacon. For shutdown. */
  stop(): void
}

export function registerMachinesIpc(ipcMain: InvokeRegistrar, deps: MachinesIpcDeps): MachinesIpc {
  const now = deps.now ?? Date.now
  const store = new MachineStore(deps.storageDir, { now })
  const makeLink = deps.createLink ?? createMachineLink
  const pair = deps.pair ?? pairWithCode
  const links = new Map<string, MachineLink>()

  function relayUrl(): string {
    // This desktop's own relay when it has one, because two machines belonging
    // to one person are on the same relay in every case that matters and a
    // second setting would be a second thing to get wrong. The compiled-in
    // default is the fallback for a desktop whose own link has not come up —
    // which is refused before pairing anyway, but a lookup with no URL at all
    // would fail with a sentence about a URL rather than about the relay.
    return deps.relayUrl ?? deps.status().relay?.url ?? DEFAULT_RELAY_URL
  }

  function view(): MachinesView {
    const machines = store.list()
    return {
      machines,
      links: machines.map(
        (machine) =>
          links.get(machine.id)?.state() ?? {
            id: machine.id,
            state: 'offline',
            reason: null,
            sessions: [],
            folders: null,
            capabilities: [],
            hostPlatform: machine.platform,
            retryAt: null,
          },
      ),
      blocked: offerFrom(deps.status().relay) === null
        ? 'This machine is not connected to the relay yet, so it cannot show or read a pairing code. Turn remote access on and wait for it to connect.'
        : null,
    }
  }

  function announce(): void {
    deps.broadcast(MACHINES_STATE_CHANNEL, view())
  }

  /**
   * Bring a machine's link into being, connected.
   *
   * Called at launch for every stored machine and again the moment one is
   * paired, which is what makes a machine that has just been added start trying
   * immediately rather than after the next restart.
   */
  function linkFor(machine: Machine): MachineLink | null {
    const existing = links.get(machine.id)
    if (existing) return existing
    const secrets = store.secrets(machine.id)
    if (secrets === null) return null
    const link = makeLink({
      id: machine.id,
      secrets,
      onState: () => announce(),
      onOutput: (sessionId, data, replay) => {
        deps.broadcast(MACHINES_OUTPUT_CHANNEL, { machineId: machine.id, sessionId, data, replay })
      },
      onWelcome: (platform) => store.sawWelcome(machine.id, platform),
      now,
    })
    links.set(machine.id, link)
    link.connect()
    return link
  }

  /* ----------------------------------------------------------- the channels */

  ipcMain.handle('machines:list', (): MachinesView => view())

  /**
   * Put a code on screen and answer it for as long as it is there.
   *
   * One call, because it is one thing: `desk.show` mints the code — the same
   * desk `remote:pair` uses, so there is one code — and claims the rendezvous
   * slot that code names, publishing this machine's address there. It waits for
   * the slot before answering, because a code shown while its rendezvous is
   * still dialling is a code that tells the person who typed it that no machine
   * is showing it, which is a lie about the one thing this screen is for.
   *
   * Refused, here, when there is no address to publish or the slot will not
   * come up. Eight typed characters are the *only* input this screen has — no
   * QR, no link — so a code that cannot be looked up is a code that fails after
   * somebody has typed it, three metres from the machine that could have said
   * so. The Remote panel's phone pairing makes the opposite call for the
   * opposite reason: its QR carries the address inside the link.
   */
  ipcMain.handle(
    'machines:code',
    async (): Promise<{ ok: true; code: PairingToken } | { ok: false; message: string }> => {
      const offer = offerFrom(deps.status().relay)
      if (offer === null) {
        return {
          ok: false,
          message:
            'This machine is not connected to the relay, so another machine has no way to find it. ' +
            'Turn remote access on and try again once it says connected.',
        }
      }
      const shown = await deps.desk.show(offer)
      if (!shown.findable) {
        // Minted and unpublishable, so it is withdrawn rather than shown. The
        // reason is in the app log — `startBeacon` writes it — and the sentence
        // here is the one that helps somebody standing at the machine.
        deps.desk.cancel()
        return {
          ok: false,
          message: 'This machine could not reach the relay to publish a code. Check the connection and try again.',
        }
      }
      return { ok: true, code: shown.code }
    },
  )

  ipcMain.handle('machines:code:cancel', (): { cancelled: true } => {
    // Both halves, and one call: the desk leaves the rendezvous slot as it
    // forgets the code. Cancel used to need two, and the day one of them was
    // forgotten is the day a slot outlived its code.
    deps.desk.cancel()
    return { cancelled: true }
  })

  ipcMain.handle('machines:pair', async (_event, code: unknown): Promise<PairResult> => {
    if (typeof code !== 'string') {
      return { ok: false, reason: 'bad-code', message: 'That is not a pairing code.' }
    }
    const result = await pair({ code, relayUrl: relayUrl() })
    if (!result.ok) return result
    try {
      const machine = store.remember({
        name: result.offer.name === '' ? result.deviceName : result.offer.name,
        hostId: result.offer.hostId,
        hostPublicKey: Buffer.from(result.offer.publicKey, 'base64'),
        relayUrl: result.offer.relayUrl,
        credential: result.credential,
        guestKeys: result.guestKeys,
        platform: result.offer.platform,
      })
      // Pairing replaces any earlier row for the same machine, so an old link
      // is holding a credential that machine has forgotten. Dropped before the
      // new one is made, or the two would redial past each other forever.
      links.get(machine.id)?.disconnect()
      links.delete(machine.id)
      linkFor(machine)
    } catch (error) {
      return {
        ok: false,
        reason: 'refused',
        message: `That machine paired, but this one could not save it: ${error instanceof Error ? error.message : String(error)}`,
      }
    }
    announce()
    return result
  })

  ipcMain.handle('machines:forget', (_event, id: unknown): MachinesView => {
    if (typeof id === 'string') {
      // The link goes first. A forget that only edited the file would leave a
      // socket open to a machine this desktop no longer claims to know.
      links.get(id)?.disconnect()
      links.delete(id)
      store.forget(id)
    }
    return view()
  })

  ipcMain.handle('machines:rename', (_event, id: unknown, name: unknown): MachinesView => {
    if (typeof id === 'string') store.rename(id, name)
    return view()
  })

  ipcMain.handle('machines:connect', (_event, id: unknown): MachinesView => {
    if (typeof id === 'string') {
      const machine = store.list().find((candidate) => candidate.id === id)
      if (machine) (links.get(id) ?? linkFor(machine))?.connect()
    }
    return view()
  })

  ipcMain.handle('machines:disconnect', (_event, id: unknown): MachinesView => {
    if (typeof id === 'string') links.get(id)?.disconnect()
    return view()
  })

  /*
   * The four verbs that make a remote session feel like a local one.
   *
   * Every one of them answers with a boolean rather than nothing, and that is
   * not decoration: `send` refuses when the link is not online, and a renderer
   * that typed into a machine that had just dropped would otherwise see its
   * keystrokes vanish with no explanation at all.
   */
  ipcMain.handle(
    'machines:attach',
    (_event, id: unknown, sessionId: unknown, cols: unknown, rows: unknown): boolean =>
      typeof id === 'string' &&
      typeof sessionId === 'string' &&
      typeof cols === 'number' &&
      typeof rows === 'number' &&
      (links.get(id)?.attach(sessionId, cols, rows) ?? false),
  )

  ipcMain.handle(
    'machines:detach',
    (_event, id: unknown, sessionId: unknown): boolean =>
      typeof id === 'string' &&
      typeof sessionId === 'string' &&
      (links.get(id)?.detach(sessionId) ?? false),
  )

  ipcMain.handle(
    'machines:input',
    (_event, id: unknown, sessionId: unknown, data: unknown): boolean =>
      typeof id === 'string' &&
      typeof sessionId === 'string' &&
      typeof data === 'string' &&
      (links.get(id)?.input(sessionId, data) ?? false),
  )

  ipcMain.handle(
    'machines:resize',
    (_event, id: unknown, sessionId: unknown, cols: unknown, rows: unknown): boolean =>
      typeof id === 'string' &&
      typeof sessionId === 'string' &&
      typeof cols === 'number' &&
      typeof rows === 'number' &&
      (links.get(id)?.resize(sessionId, cols, rows) ?? false),
  )

  ipcMain.handle(
    'machines:create',
    (_event, id: unknown, cwd: unknown, provider: unknown): boolean => {
      if (typeof id !== 'string') return false
      return (
        links.get(id)?.create({
          ...(typeof cwd === 'string' && cwd !== '' ? { cwd } : {}),
          ...(typeof provider === 'string' && provider !== '' ? { provider } : {}),
        }) ?? false
      )
    },
  )

  /*
   * Every stored machine is dialled here, by the act of registering this — not
   * by a button, not when a panel mounts. See the note at the top of the file:
   * the failure this project keeps re-finding is a feature that is complete and
   * never started, and the only defence is that launching causes it.
   */
  for (const machine of store.list()) linkFor(machine)

  return {
    view,
    wake(): void {
      for (const link of links.values()) link.wake()
    },
    stop(): void {
      // The code goes with the app. A slot left claimed at the relay by a
      // process that is exiting would answer for a machine that is no longer
      // there, until the socket eventually noticed.
      deps.desk.cancel()
      for (const link of links.values()) link.disconnect()
      links.clear()
    },
  }
}

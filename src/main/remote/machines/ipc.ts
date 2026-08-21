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

import { createRemoteReach, type ReachAnswer, type RemoteReach } from '../../localhost-reach'
import { CONTROL_IDS, MAX_URL_LENGTH, USAGE_WANTS, emptyUsageReading, type WindowCallFrame } from '../protocol'
import { DEFAULT_RELAY_URL } from '../../../shared/relay-wire'
import type { InvokeRegistrar } from '../../ipc-seam'
import type { PairingToken } from '../device-auth'
import type { PairingDesk, RemoteStatus } from '../server'
import { thisMachineName } from '../../platform/host'
import { createMachineLink, type MachineLink, type MachineLinkState } from './guest'
import type { SendFileOutcome } from './upload-send'
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

/*
 * The copilot on another machine, pushed rather than asked for.
 *
 * Two channels for the same reason `machines:output` is not `machines:state`:
 * these are events nobody asked a question to get. `copilot.attach` subscribes
 * once and the far machine then pushes a state whenever any of it changes and a
 * chat frame whenever the conversation moves, so a surface that polled either
 * would be asking a computer in another room a question it is already
 * answering.
 *
 * They are not folded into `machines:state`, which the sidebar redraws from.
 * A conversation changes on every token an agent produces; a machine list does
 * not, and putting one inside the other would re-render every row of the
 * Machines panel for each of them.
 */
export const MACHINES_COPILOT_STATE_CHANNEL = 'machines:copilot:state'
export const MACHINES_COPILOT_CHAT_CHANNEL = 'machines:copilot:chat'

/**
 * A file on its way to another machine, slice by slice.
 *
 * Its own channel for the same reason `machines:output` is not
 * `machines:state`: it changes on every acknowledged slice — hundreds of times
 * while a video copies — and folding it into the view the sidebar redraws from
 * would re-render every machine row for each one.
 *
 * The `machineId` rides with it, exactly as it does on the two copilot channels,
 * because a window can have a transfer to one machine and a terminal open on
 * another and the line belongs to a particular pane.
 */
export const MACHINES_UPLOAD_CHANNEL = 'machines:upload:progress'

/** What one screen needs to draw every row, in one message. */
export interface MachinesView {
  machines: Machine[]
  links: MachineLinkState[]
  /**
   * What **this** machine calls itself — its hostname, the same string
   * `describeThisMachine()` puts on a pairing offer.
   *
   * Every other machine on this view arrives with a name a person recognises,
   * and the computer they are sitting at arrived with none — so every list that
   * draws them together had to invent a phrase for it. Three of those phrases
   * were on the browser bar at once, all reading "This machine", each about a
   * different computer. Asad, 2026-08-21, with the picker on Office PC:
   *
   *   > *"So I'm confused now what is the truth, because this machine is Office
   *   > PC, this machine is this machine where I am, and Office PC is the
   *   > server. So it is showing both, selected one and this one. So I don't
   *   > know what to trust."*
   *
   * A name cannot be ambiguous the way a deictic can, so this travels on the
   * view every machine list already reads rather than on a channel of its own.
   * Empty when the hostname could not be read, and a reader that gets an empty
   * string falls back to the phrase it used before — never to a guess at what
   * the computer is called.
   */
  here: string
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
  /**
   * Every loopback listener this desktop was serving for that machine has just
   * been closed, by something other than a browser window asking.
   *
   * The browser's tunnel ledger keeps the rows a window's address bar reads its
   * machine chip off, and a row for a listener that is already gone is a chip
   * naming a machine whose pages have stopped answering - the one thing worse
   * than no chip. Optional because the headless host has no browser to tell.
   */
  tunnelsDropped?(machineId: string): void
  /** The relay this desktop dials when looking a code up. */
  relayUrl?: string
  /** Seam for the tests: nothing in a unit test may dial the public internet. */
  pair?: typeof pairWithCode
  /** Seam for the tests, so a link can be driven without a socket. */
  createLink?: typeof createMachineLink
  /**
   * Serve a browser verb that arrived from a session on that machine.
   *
   * Absent is the switch, as everywhere else: with no handler the link never
   * advertises the `windows` capability, so a session over there is launched
   * knowing it cannot drive rather than holding six verbs whose every call would
   * time out. `index.ts` passes `remote/machines/window-serve.ts`, which is
   * where the grant, the binding lookup and every tier check happen.
   */
  serveWindows?(
    machineId: string,
    call: { sessionId: string; tool: string; args: string },
  ): Promise<{ ok: boolean; body: string }>
  /**
   * Which sessions **on that machine** this app is holding a browser window for.
   *
   * The other half of {@link MachinesIpcDeps.serveWindows}, and the half that
   * decides whether it ever fires for a session this desktop did not start. A
   * window attached here to a session over there is a relation written in *this*
   * process — `browser-binding.ts`, keyed `<machineId>\0<sessionId>` — and the
   * machine the pty is on has no way to derive it. So it is sent, on every
   * welcome and on every attach or detach, and until it was, the feature only
   * worked for sessions this app had started over there.
   *
   * Answered per machine because a link may only be told about its own: the
   * sessions on one paired computer are not facts the next one gets to hear.
   */
  windowsHeld?(machineId: string): readonly string[]
  /**
   * That machine has said which of **this** one's sessions it is holding a
   * browser window for.
   *
   * The mirror of {@link windowsHeld}, arriving rather than leaving. It lands on
   * the machine-side `WindowAskDesk`, which is the same desk type the host side
   * fills in from `server.ts` — one table per direction, and this dep is the
   * only way into the second one.
   *
   * Its presence is also the switch: without it a link never advertises
   * `CAPABILITY.hostWindows`, so no machine ever sends the frame, so a build that
   * cannot use the fact is never told it. See `guest.ts`'s hello.
   */
  windowsHeldThere?(machineId: string, sessions: readonly string[]): void
  /**
   * That machine has answered a browser verb this one asked it to run.
   *
   * Not keyed by machine, deliberately: the id on the answer is one this app
   * minted and handed to exactly one link, so the desk already knows which
   * question it belongs to and a machine id would be a second key that has to
   * agree with the first. An id the desk is not holding is dropped there, which
   * is what an answer that crossed its own deadline looks like.
   */
  windowAnswered?(result: { id: string; ok: boolean; body: string }): void
  /**
   * That machine's link is no longer online, so nothing outstanding to it can
   * still be answered. See the call site for why the *holdings* survive it.
   */
  windowsUnreachable?(machineId: string): void
  now?: () => number
}

export interface MachinesIpc {
  /** Every machine and the state of its link, as the window would draw it. */
  view(): MachinesView
  /**
   * May sessions on that machine act on browser windows here? Read per call.
   *
   * Exposed rather than answered inside, because the thing that asks is a
   * dispatcher in `index.ts` that has no business holding a `MachineStore` of
   * its own — a second store is how a switch and the code reading it come to
   * disagree. Read on every inbound verb for the reason `callers.ts` gives about
   * `TokenGrant.caller`: an untick has to land on the next call, not on the next
   * reconnection.
   */
  drivesWindows(machineId: string): boolean
  /**
   * Put one browser verb on that machine's link, and say whether it was heard.
   *
   * The wire half of the machine-side `WindowAskDesk` — a count rather than a
   * boolean because that is the shape the desk's `WindowWire.ask` takes on both
   * directions, and on this one it is only ever nought or one: a machine is one
   * link, unlike a device, which can be attached from two windows at once.
   *
   * Zero is the answer the desk turns into a sentence in milliseconds instead of
   * a fifty-five second wait: the link is down, or that machine's build never
   * advertised `CAPABILITY.hostWindows` and would close the channel on a frame
   * it has never parsed.
   */
  askWindow(machineId: string, call: WindowCallFrame): number
  /**
   * Could {@link askWindow} reach that machine right now, without sending
   * anything? The same two conditions, asked ahead of time.
   */
  servesWindows(machineId: string): boolean
  /**
   * A browser window here was attached to, or detached from, a session on a
   * paired machine. Tell every machine that is up which of its sessions this app
   * now holds one for.
   *
   * Every link rather than the one that changed, and it costs one small frame
   * per machine: the caller is a subscription to the whole binding map — see
   * `browser-binding.ts`'s `subscribe` — which reports *that* the relation moved
   * rather than which machine it moved for. Working out the difference here
   * would be this file keeping a second copy of a map it does not own.
   *
   * A link that is down, or on a machine too old to know the frame, sends
   * nothing and says so by answering false; it re-announces on its next welcome,
   * which is the moment the far machine's table is empty anyway.
   */
  announceWindows(): void
  /** The machine woke up. Redial every link that is meant to be up. */
  wake(): void
  /** Drop every link and stop the beacon. For shutdown. */
  stop(): void
  /**
   * Send a file to one machine, from inside the main process.
   *
   * The same act `machines:upload` performs for the renderer, exposed because
   * `browser-downloads.ts` has a finished download in its hand in main and
   * bouncing it out to a window and back would put the decision to delete the
   * local copy on the far side of two IPC hops. Answers the far machine's own
   * sentence on a refusal, which is what the downloads row prints.
   */
  sendFile(machineId: string, filePath: string, dir?: string): Promise<SendFileOutcome>
  /**
   * Give a port on that machine an address on this one - the same act
   * `machines:reach` performs, in process.
   *
   * Exposed because the browser's tunnel ledger (`src/main/browser-reach.ts`)
   * counts the windows reading each listener and has to be able to open and
   * close one itself. Going back out through `ipcMain` to reach code in this
   * module would be a second path to the same map.
   */
  reach(machineId: string, port: number): Promise<ReachAnswer>
  /** Hand that port back. True when this desktop is no longer serving it here. */
  closeReach(machineId: string, port: number): boolean
}

export function registerMachinesIpc(ipcMain: InvokeRegistrar, deps: MachinesIpcDeps): MachinesIpc {
  const now = deps.now ?? Date.now
  const store = new MachineStore(deps.storageDir, { now })
  const makeLink = deps.createLink ?? createMachineLink
  const pair = deps.pair ?? pairWithCode
  const links = new Map<string, MachineLink>()
  /** One reach per machine — the loopback listeners this desktop serves *its* ports on. */
  const reaches = new Map<string, RemoteReach>()

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
      // The same hostname the pairing offer introduces this machine with, so the
      // name on the picker here and the name the *other* machine shows for this
      // one are one string from one place. Empty rather than a stand-in noun —
      // see `thisMachineName`.
      here: thisMachineName(),
      links: machines.map(
        (machine) =>
          links.get(machine.id)?.state() ?? {
            id: machine.id,
            state: 'offline',
            reason: null,
            sessions: [],
            folders: null,
            capabilities: [],
            // A machine with no live link is a machine serving nothing this
            // desktop can see. Not "unknown": the panel reads the state beside
            // it, so an empty list under `offline` already says the honest thing.
            ports: [],
            // And nothing dialled has been offered nothing, which is the same
            // answer for the same reason: whether that machine shares its
            // copilot with this desktop is something only its `welcome` says.
            copilot: null,
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
    /*
     * The reach is made with the link and lives exactly as long as it does.
     *
     * It holds loopback listeners on *this* machine that carry bytes to that
     * one, so it is meaningless without a channel — and dangerous to outlive
     * one: a listener still accepting connections after the link has gone is an
     * address in somebody's address bar that answers and then hangs.
     */
    const reach = createRemoteReach({ send: (message) => links.get(machine.id)?.localhost(message) ?? false })
    reaches.set(machine.id, reach)
    const link = makeLink({
      id: machine.id,
      secrets,
      onState: (state) => {
        /*
         * A link that is no longer online takes its tunnels with it.
         *
         * Not a tidying-up: the state that has just changed is the *only* thing
         * that could still be carrying those bytes, so every page open on one of
         * these listeners is already dead. Closing the listener turns a page
         * that hangs into a page that says the connection was refused, which is
         * a thing a browser can explain and a hang is not. They come back the
         * moment somebody opens a port again — the reach re-opens on demand and
         * a redial is one handshake.
         */
        if (state.state !== 'online') {
          reach.closeAll('The connection to that machine dropped, so its pages are no longer being served here.')
          // And the browser, whose rows are the only place those listeners were
          // ever named. Told after the close rather than instead of it: this is
          // bookkeeping catching up with a fact, not a second way to close.
          deps.tunnelsDropped?.(machine.id)
          /*
           * And every browser verb still waiting on that machine, settled now
           * rather than at its deadline.
           *
           * `WindowAskDesk.gone` makes the argument: a tool call that can be
           * answered in milliseconds must not spend fifty-five seconds finding
           * out the machine hung up, because a model waiting that long concludes
           * the tool is broken and starts looking for another way in.
           *
           * What is *not* dropped is the table of what that machine said it
           * holds. A laptop that closed its lid still has the window attached to
           * it, and the honest sentence for a verb sent there is "that computer
           * is not connected right now" — forgetting instead would answer "no
           * browser window is attached to this session", which is false.
           */
          deps.windowsUnreachable?.(machine.id)
        }
        announce()
      },
      onOutput: (sessionId, data, replay) => {
        deps.broadcast(MACHINES_OUTPUT_CHANNEL, { machineId: machine.id, sessionId, data, replay })
      },
      onLocalhost: (message) => reach.handle(message),
      onUpload: (progress) => {
        deps.broadcast(MACHINES_UPLOAD_CHANNEL, { machineId: machine.id, progress })
      },
      /*
       * The machine id rides with both of these, and it is the whole point of
       * them being one channel rather than one per link.
       *
       * The window may have two machines' copilots in play — that is what the
       * switcher at the top of the copilot page is for — and a frame that did
       * not say which machine it came from would be merged into whichever
       * conversation happened to be on screen. The renderer keys on this the
       * same way it keys terminal output.
       */
      onCopilotState: (state) => {
        deps.broadcast(MACHINES_COPILOT_STATE_CHANNEL, { machineId: machine.id, state })
      },
      onCopilotChat: (chat) => {
        // The whole frame, `run` and `reset` included. See `onCopilotChat` in
        // `guest.ts`: the messages alone cannot be merged correctly, because
        // neither "this belongs to a run that is over" nor "throw away what you
        // are holding" can be recovered from them.
        deps.broadcast(MACHINES_COPILOT_CHAT_CHANNEL, { machineId: machine.id, chat })
      },
      onWelcome: (platform) => store.sawWelcome(machine.id, platform),
      /*
       * Spread rather than passed as possibly-undefined, because absence is what
       * the link reads to decide whether to advertise the capability at all. A
       * handler that was present and answered "no" would be a machine told it
       * may ask, asking, and being refused on every call.
       */
      ...(deps.serveWindows === undefined
        ? {}
        : { onWindowCall: (call) => deps.serveWindows!(machine.id, call) }),
      /*
       * And which of that machine's sessions has a window here, whenever the
       * link needs to say so. Read through the dep rather than captured, because
       * the answer changes every time somebody attaches or detaches one.
       */
      ...(deps.windowsHeld === undefined
        ? {}
        : { windowsHeld: () => deps.windowsHeld!(machine.id) }),
      /*
       * And the mirror pair: what that machine says it is holding for *us*, and
       * where its answers land.
       *
       * Spread on the same rule as the two above, and the presence of
       * `onWindowHolds` is what makes the link advertise `hostWindows` at all —
       * so a build with no desk never tells a far machine it may be asked, and
       * never receives a frame it would drop.
       */
      ...(deps.windowsHeldThere === undefined
        ? {}
        : { onWindowHolds: (sessions) => deps.windowsHeldThere!(machine.id, sessions) }),
      ...(deps.windowAnswered === undefined
        ? {}
        : { onWindowResult: (result) => deps.windowAnswered!(result) }),
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
   * come up. Six typed digits are the *only* input this screen has — there is no
   * QR and no link anywhere in the product now — so a code that cannot be looked
   * up is a code that fails after somebody has typed it, three metres from the
   * machine that could have said so.
   *
   * `remote:pair` on the Remote panel still answers with a code either way, and
   * that is now a narrow exception rather than a second path: the only client a
   * code with no rendezvous behind it can reach is the browser client this
   * machine serves on its own tailnet, where the page's origin is the address.
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
      // And its listeners, which are the same argument one layer down: a machine
      // this desktop has forgotten must not still be serving pages here.
      reaches.get(id)?.closeAll('That machine was removed.')
      reaches.delete(id)
      deps.tunnelsDropped?.(id)
      store.forget(id)
    }
    /*
     * Broadcast as well as answered, and the difference is a whole window.
     *
     * The reply goes to whoever called — the Remote screen, which redraws from
     * it. Every *other* surface reading machines learns about them only from
     * this channel, and since the browser panel grew a machine picker that list
     * is on screen in more than one place at once. Without this, forgetting a
     * machine in Settings left it in the picker beside the address bar until
     * some unrelated link state happened to change, offering an address on a
     * computer this desktop had just been told to forget.
     */
    announce()
    return view()
  })

  /**
   * May sessions on that machine act on browser windows in this app?
   *
   * Its own channel rather than a field on a general "update machine" verb,
   * because it is the only setting here that is a *grant* — everything else on
   * a machine row is a label or an address. `MachineStore.drivesWindows` carries
   * the argument for why windows are their own axis and why the axis starts
   * closed.
   *
   * Answers the whole view, like `machines:rename` beside it, so the panel
   * redraws from one truth rather than from what it thinks it just set.
   */
  ipcMain.handle('machines:drive-windows', (_event, id: unknown, allowed: unknown): MachinesView => {
    // Only the literal `true` grants. See `asStoredMachine`: this is the whole
    // of the permission, and a truthy value arriving from a bridge is not a
    // person pressing a switch.
    if (typeof id === 'string') store.setDrivesWindows(id, allowed === true)
    return view()
  })

  ipcMain.handle('machines:rename', (_event, id: unknown, name: unknown): MachinesView => {
    if (typeof id === 'string') store.rename(id, name)
    // The same argument as `forget` above: a machine's name is drawn in the
    // sidebar, in the picker and on its own row, and only one of those three
    // called this.
    announce()
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

  /**
   * End one session on another machine.
   *
   * Its own channel rather than a flag on `machines:detach`, and the difference
   * is the whole point of the verb: `detach` says *stop sending me this
   * session's bytes* and leaves the process running, which is what closing a
   * screen does. This kills it, for everyone attached to it, and it cannot be
   * undone. Two acts that far apart sharing one channel is how a client comes
   * to end somebody's work by passing the wrong argument.
   *
   * The boolean is *the request left this machine*, exactly as `create`'s is —
   * the session ends on the other computer, and whether it did comes back as a
   * `closed` frame that empties the row out of the link's session list. A
   * renderer that treated `true` as "it is gone" would be drawing an answer it
   * has not been given; `useMachines` waits for the row to disappear instead.
   *
   * `false` means the link refused to send: the machine is not linked, the id
   * names nothing, or that machine never advertised `close` — an older build
   * over there, which the window has already asked about before drawing the
   * control. See `MachineLink.close`.
   */
  ipcMain.handle(
    'machines:close',
    (_event, id: unknown, sessionId: unknown): boolean =>
      typeof id === 'string' &&
      typeof sessionId === 'string' &&
      (links.get(id)?.close(sessionId) ?? false),
  )

  /**
   * Ask again what is listening on that machine.
   *
   * A refresh rather than the first read: the link asks once on every `welcome`
   * and pushes the answer, so a panel that has just opened already has a list.
   * This is the button for *"I have just started my dev server over there"*,
   * which is the one case a push cannot cover — nothing on the far machine
   * watches its own process table.
   */
  ipcMain.handle('machines:ports', (_event, id: unknown): boolean => {
    if (typeof id !== 'string') return false
    return links.get(id)?.ports() ?? false
  })

  /*
   * The two halves of remote localhost, as functions rather than as handler
   * bodies, because they now have two callers each: the channel below, and the
   * browser's tunnel ledger in `src/main/browser-reach.ts`, which counts the
   * windows reading a listener so that the last one out is what closes it.
   */
  function openReach(id: string, port: number): Promise<ReachAnswer> {
    const reach = reaches.get(id)
    if (!reach) {
      return Promise.resolve({
        ok: false,
        message: 'This desktop is not connected to that machine.',
      })
    }
    return reach.open(port)
  }

  function closeReach(id: string, port: number): boolean {
    const reach = reaches.get(id)
    // A machine that has gone took its tunnels with it on the way out, so an
    // unknown id is `true` - the address is free, which is the whole question.
    return reach ? reach.close(port) : true
  }

  /**
   * Give a port on that machine an address in this window's browser.
   *
   * The verb behind *"I should be able to type and reach the devices which are
   * not here on this device but they are from the other remote device"*. What
   * comes back is an ordinary `http://` URL on this machine's loopback, which
   * the browser opens exactly the way it opens anything else — that sameness is
   * the whole requirement, and it is why this answers with a URL rather than
   * with some second kind of tab.
   *
   * Answers a refusal *with its sentence* rather than a bare false. Every other
   * verb here can afford a boolean because a boolean means "the request went",
   * and the failure a person needs explaining is on the far machine. This one
   * can fail in four ways that are all this end's business — the link is down,
   * that machine no longer serves the port, it never answered, or this machine
   * could not open an address — and each of them is a different sentence.
   */
  ipcMain.handle('machines:reach', async (_event, id: unknown, port: unknown): Promise<unknown> => {
    if (typeof id !== 'string' || typeof port !== 'number') {
      return { ok: false, message: 'That is not a machine and a port.' }
    }
    return openReach(id, port)
  })

  /**
   * Hand that port back, so the number means this computer again.
   *
   * The other half of the verb above, and it exists because of what makes the
   * verb worth having: the listener keeps the far machine's port *number*
   * whenever this machine had it free, so while a tunnel is up
   * `localhost:3100` here **is** that machine's 3100. The browser's machine
   * picker moving a page back onto this computer therefore had nowhere to send
   * it — 0.9.0 navigated to the same address, the tunnel answered, and the bar
   * was left with the picker naming this Mac over a page from the PC.
   *
   * A boolean rather than a sentence, unlike its neighbour, because there is no
   * failure a person could act on: either this desktop is no longer serving
   * that port on a local address, or the request was not a machine and a port.
   * A machine that has gone took its tunnels with it on the way out, so an
   * unknown id is `true` — the address is free, which is the whole question.
   */
  ipcMain.handle('machines:reach:close', (_event, id: unknown, port: unknown): boolean => {
    if (typeof id !== 'string' || typeof port !== 'number') return false
    return closeReach(id, port)
  })

  /**
   * Open a page in the browser **on that machine**.
   *
   * The URL is typed here and checked over there, which is the same split every
   * verb on this wire follows and is not laziness: the far machine puts it
   * through the gate an untrusted link goes through, and a second check written
   * on this side would be the one somebody later mistook for the real one. What
   * this handler owns is the shape — a string, non-empty, under the wire's cap —
   * because everything past it is an IPC argument from a renderer.
   */
  /**
   * The model, the effort and fast mode of one session on another machine.
   *
   * ## Why these are two channels and not one
   *
   * For the reason `agent-controls.ts` split its own: reading is passive and
   * happens every time the session prints anything, while setting **types into
   * somebody's terminal**. Folding them together would put a keystroke on a code
   * path that fires on output, which is how an app comes to open a dialog in a
   * session while somebody is working in it.
   *
   * ## What each answers with, and why they are different shapes
   *
   * `machines:controls:read` answers `null` when the question could not be asked
   * at all, and the renderer treats that the way it treats a failed local read —
   * it keeps the last values it genuinely had. Blanking the bar because one
   * round trip went missing over a relay would be a regression in honesty rather
   * than an improvement.
   *
   * `machines:controls:apply` always answers with a sentence, on every path,
   * because somebody pressed something. A press that produces nothing is
   * indistinguishable from a control that does not work, which is the defect
   * this whole pass exists to remove.
   */
  ipcMain.handle(
    'machines:controls:read',
    async (_event, id: unknown, sessionId: unknown): Promise<unknown> => {
      if (typeof id !== 'string' || typeof sessionId !== 'string') return null
      return (await links.get(id)?.readControls(sessionId)) ?? null
    },
  )

  /**
   * What one session on another machine has spent, and how full its context
   * window is.
   *
   * ## Why this is one channel where controls are two
   *
   * Because none of the three readings types anything. The controls pair is
   * split because one half of it writes into somebody's terminal on a code path
   * that fires on output; nothing here does, so the split would buy nothing.
   *
   * ## What the `want` costs, which is the thing to be careful about
   *
   * `plan` and `context` are free on the far machine — memory, and a bounded
   * tail read of a file the agent is already writing. `refresh` boots a whole
   * Claude Code over there: **725 MB peak, about three seconds**, measured on
   * 2026-08-19. So `refresh` is only ever passed because a person opened the
   * usage panel or pressed the retry inside it, and `usage-target.ts` in the
   * renderer is the one place that decides which word this gets.
   *
   * Narrowed here rather than passed through, for the reason
   * `machines:controls:apply` narrows its control name: an `ipcMain.handle`
   * argument is whatever the renderer put in it however the type reads, and the
   * expensive branch must not be reachable by a typo. The wire parser checks it
   * again on the far end — that is the check that protects the machine — and
   * this one exists so a renderer bug is an empty reading here instead of a
   * closed socket there.
   *
   * Always answers with a record, never null, because the bar has no previous
   * figure to fall back on the way the control chips do. A link that is down, a
   * machine too old for the capability and a request that names nothing all come
   * back as a reading carrying the sentence that says why — see
   * `emptyUsageReading` in `../protocol.ts`.
   */
  ipcMain.handle(
    'machines:usage:read',
    async (_event, id: unknown, sessionId: unknown, want: unknown, force: unknown): Promise<unknown> => {
      const named = USAGE_WANTS.find((known) => known === want)
      if (named === undefined) return emptyUsageReading('plan', 'That is not a reading this build knows how to ask for.')
      if (typeof id !== 'string' || typeof sessionId !== 'string') {
        return emptyUsageReading(named, 'That is not a machine and a session.')
      }
      const link = links.get(id)
      if (!link) return emptyUsageReading(named, 'This desktop is not connected to that machine.')
      // `force === true` and nothing looser: it is the flag that reaches past
      // the far machine's own throttle, so a stray truthy value must not be able
      // to turn an ordinary look into a spawn on somebody else's computer.
      return await link.readUsage(sessionId, named, force === true)
    },
  )

  ipcMain.handle(
    'machines:controls:apply',
    async (_event, id: unknown, sessionId: unknown, control: unknown, value: unknown): Promise<unknown> => {
      const unread = { value: null, label: null, source: null }
      if (typeof id !== 'string' || typeof sessionId !== 'string') {
        return { ok: false, message: 'That is not a machine and a session.', reading: unread }
      }
      /*
       * Narrowed here rather than passed through, because everything past this
       * line ends in a command typed at somebody's prompt and an `ipcMain.handle`
       * argument is whatever the renderer put in it however the type says
       * otherwise. The wire parser checks it again on the far end — that is the
       * check that actually protects the machine — and this one exists so that a
       * renderer bug is a sentence here instead of a closed socket there.
       */
      const named = CONTROL_IDS.find((name) => name === control)
      if (named === undefined || typeof value !== 'string' || value === '') {
        return { ok: false, message: 'That is not a control this app can set.', reading: unread }
      }
      const link = links.get(id)
      if (!link) return { ok: false, message: 'This desktop is not linked to that machine.', reading: unread }
      return link.setControl(sessionId, named, value)
    },
  )

  /**
   * Whose login one session on another machine is on, and which logins that
   * machine has.
   *
   * `null` when the question could not be asked — not a machine, not paired, a
   * link that is down, a build over there that predates the capability. The
   * renderer treats it the way the control chips treat a missed read: it keeps
   * the last account it genuinely had rather than emptying a menu that had rows
   * in it a moment ago.
   */
  ipcMain.handle(
    'machines:account:read',
    async (_event, id: unknown, sessionId: unknown): Promise<unknown> => {
      if (typeof id !== 'string' || typeof sessionId !== 'string') return null
      return (await links.get(id)?.readAccount(sessionId)) ?? null
    },
  )

  /**
   * Run one session on another machine as a different login.
   *
   * ## Why it is not `machines:controls:apply` with a fifth control name
   *
   * Because it is not a control. The four in {@link CONTROL_IDS} are a slash
   * command typed at a session that survives it; this **ends the agent process
   * and starts another** under a different configuration directory. The session
   * that comes back has a new id, which is the field on this answer that has no
   * counterpart over there: a window that ignored it would stay attached to a pty
   * that has already been killed.
   *
   * Always answers with a sentence, on every path, for the reason
   * `machines:controls:apply` does: somebody pressed a row, and a press that
   * produces nothing is indistinguishable from a control that does not work.
   */
  ipcMain.handle(
    'machines:account:switch',
    async (
      _event,
      id: unknown,
      sessionId: unknown,
      accountId: unknown,
    ): Promise<{ ok: boolean; message: string; session: string | null }> => {
      if (typeof id !== 'string' || typeof sessionId !== 'string') {
        return { ok: false, message: 'That is not a machine and a session.', session: null }
      }
      /*
       * Shape-checked here as well as on the wire, for the reason
       * `machines:controls:apply` narrows its control name: everything past this
       * line selects a configuration directory on somebody else's computer, and an
       * `ipcMain.handle` argument is whatever the renderer put in it. The parser on
       * the far end checks it again — that is the check that protects the machine —
       * and this one exists so a renderer bug is a sentence here rather than a
       * closed socket there, which would take every terminal on the link with it.
       */
      if (typeof accountId !== 'string' || accountId === '') {
        return { ok: false, message: 'That is not an account.', session: null }
      }
      const link = links.get(id)
      if (!link) return { ok: false, message: 'This desktop is not linked to that machine.', session: null }
      return link.switchAccount(sessionId, accountId)
    },
  )

  /**
   * Which logins another machine has, with no session in the question.
   *
   * `null` when the question could not be asked — not a machine, not paired, a
   * link that is down, a build over there that predates the capability, or this
   * desktop being a guest on it. The pane draws the sentence for "nobody
   * answered" rather than an empty list, because an empty list would be a claim
   * about somebody's computer that three of those five cases make false.
   *
   * Deliberately **not** `machines:account:read` with the session argument left
   * out. That channel asks about a terminal and is authorised as one; this asks
   * about a machine and is served only to one of its owner's own devices — two
   * questions, two doors, and a shared channel would have had to pick one.
   */
  ipcMain.handle('machines:logins:read', async (_event, id: unknown): Promise<unknown> => {
    if (typeof id !== 'string') return null
    return (await links.get(id)?.readLogins()) ?? null
  })

  /**
   * Start signing one of another machine's logins in, over there.
   *
   * Always answers with a sentence, on every path, for the reason
   * `machines:account:switch` does: somebody pressed a button, and a press that
   * produces nothing is indistinguishable from a control that does not work.
   *
   * The answer carries the session that machine opened, because the agent CLIs
   * authenticate interactively — the pane offers to open that terminal, which is
   * where the URL to visit is printed. A sign-in that reported only `ok` would be
   * a button that starts something invisible.
   */
  ipcMain.handle(
    'machines:logins:signin',
    async (
      _event,
      id: unknown,
      accountId: unknown,
    ): Promise<{ ok: boolean; message: string; session: string | null }> => {
      if (typeof id !== 'string') {
        return { ok: false, message: 'That is not a machine.', session: null }
      }
      // Shape-checked here as well as on the wire, for the reason
      // `machines:account:switch` narrows its account id: everything past this
      // line selects a configuration directory on somebody else's computer, and
      // an `ipcMain.handle` argument is whatever the renderer put in it.
      if (typeof accountId !== 'string' || accountId === '') {
        return { ok: false, message: 'That is not an account.', session: null }
      }
      const link = links.get(id)
      if (!link) return { ok: false, message: 'This desktop is not linked to that machine.', session: null }
      return link.signInLogin(accountId)
    },
  )

  /**
   * Put text into a session on another machine, without opening it here.
   *
   * ## Why this is not `machines:input`
   *
   * The channel two hundred lines up carries a keystroke from a remote terminal
   * pane, and the far end serves it only because that pane **attached** first —
   * `input` is refused without a handle, and the handle is what the pane holds.
   * This one has no pane behind it. Its callers are surfaces that have something
   * to say and nothing to read: the browser handing an agent the element it just
   * inspected, over a session running on the PC in the other room. Attaching in
   * order to say it would displace the handle a terminal pane on that same link
   * already holds and replay its whole scrollback at whoever is reading it, so
   * the wire grew a verb that authorises typing without subscribing to output —
   * `CAPABILITY.send`, authorised over there by the same per-device folder reach
   * `input` is.
   *
   * ## Why it answers with a sentence rather than a boolean
   *
   * Because nothing on screen would show a failure. A lost keystroke in a
   * terminal pane is visible in that terminal a moment later; a send from a
   * panel with no terminal in it is invisible unless this says so. Every path
   * answers `{ ok, message }` — bad arguments, a machine nobody paired with, a
   * link that is down, a build over there too old for the verb, and the far
   * end's own refusal — because the caller draws that sentence and has no other
   * source for it. It never throws and never returns a bare boolean.
   */
  ipcMain.handle(
    'machines:send',
    async (_event, id: unknown, sessionId: unknown, data: unknown): Promise<{ ok: boolean; message: string }> => {
      // Checked here as well as on the wire, for the reason
      // `machines:controls:apply` narrows its control name: an `ipcMain.handle`
      // argument is whatever the renderer put in it however the type reads, and
      // everything past this line ends up in somebody's pty. The parser on the
      // far end checks it again — that is the check that protects the machine —
      // and this one exists so a renderer bug is a sentence here instead of a
      // closed socket there.
      if (typeof id !== 'string' || typeof sessionId !== 'string') {
        return { ok: false, message: 'That is not a machine and a session.' }
      }
      if (typeof data !== 'string' || data === '') {
        return { ok: false, message: 'There is nothing to send.' }
      }
      const link = links.get(id)
      if (!link) return { ok: false, message: 'This desktop is not linked to that machine.' }
      return link.send(sessionId, data)
    },
  )

  /**
   * A file dropped on a pane showing a session on another machine.
   *
   * ## Why the renderer hands over a path and not the bytes
   *
   * A drop in Chromium produces a `File`, and the obvious wiring reads it in the
   * renderer and posts an ArrayBuffer down this channel. That copies a 200 MB
   * video into the renderer's heap, then structured-clones it across the IPC
   * boundary into the main process's heap, before a single byte has gone
   * anywhere — two copies of a file, in the process that draws the window, to
   * send it somewhere else. `webUtils.getPathForFile` gives the real path
   * instead, and `upload-send.ts` streams it off disk under the far machine's
   * own flow control, which is what keeps the memory cost of a 500 MB file at
   * one 24 KiB slice.
   *
   * ## Why it answers with the path rather than a boolean
   *
   * Because the path *is* the feature. The file lands in the far machine's
   * downloads folder under a name that machine chose — it may not be the name it
   * left with, since a second copy of `photo.jpg` lands beside the first rather
   * than over it — and what the pane then types at the prompt has to be the name
   * it actually got. A boolean would leave the caller quoting a name that is not
   * there.
   *
   * The refusals arrive as sentences for the same reason `machines:send`'s do,
   * and there are five of them: not linked, an older build over there, a file
   * that cannot be read, one over 512 MB, and one already going. Progress in
   * between rides {@link MACHINES_UPLOAD_CHANNEL}.
   */
  ipcMain.handle(
    'machines:upload',
    async (_event, id: unknown, filePath: unknown, dir: unknown): Promise<unknown> => {
      if (typeof id !== 'string' || typeof filePath !== 'string' || filePath === '') {
        return { ok: false, message: 'That is not a machine and a file.' }
      }
      return await sendFile(id, filePath, typeof dir === 'string' && dir !== '' ? dir : undefined)
    },
  )

  /**
   * Stop the transfer going to that machine.
   *
   * Its own channel rather than a flag, because it is the one control a person
   * has over a transfer that has stalled, and because the far machine has to be
   * told: a cancel is what makes it delete the half-written file rather than
   * leaving it in somebody's downloads folder until the socket eventually times
   * out. Safe to send when nothing is going — it answers `false` and does
   * nothing at all.
   */
  ipcMain.handle('machines:upload:cancel', (_event, id: unknown): boolean => {
    if (typeof id !== 'string') return false
    const link = links.get(id)
    if (!link) return false
    link.cancelFile()
    return true
  })

  /**
   * The copilot on another machine, from this window.
   *
   * ## Why this is here at all
   *
   * His words on the 2026-08-20 review: he has two paired machines and *"the
   * same switch we have for sessions"* belongs at the top of the copilot page,
   * so one page can be pointed at either. Until now the copilot page could only
   * ever be about this computer, and the wire it needed had been served by
   * `server.ts` for weeks with nothing on this side sending a single frame down
   * it — the failure this codebase keeps re-finding under a different name:
   * **the mechanism written, the connection absent.**
   *
   * ## Why every one of them answers with a sentence
   *
   * Not a boolean, unlike `machines:attach` and its neighbours, and for the
   * reason `machines:send` gives about itself: there is no terminal on screen
   * to make a lost frame visible. A copilot press that produced nothing at all
   * would be indistinguishable from a control that does not work.
   *
   * `ok` means the frame left this machine. It cannot mean more than that:
   * there is no request id anywhere on the copilot wire, so nothing here can be
   * correlated with an answer. What the far end thinks arrives on
   * {@link MACHINES_COPILOT_STATE_CHANNEL} and
   * {@link MACHINES_COPILOT_CHAT_CHANNEL}, and its refusals arrive as an
   * ordinary `error`, which the link publishes as the row's `reason`.
   *
   * ## Why there is no `machines:copilot:hello`
   *
   * Because a caller must never have to remember one. `copilot.hello` is sent
   * by the link on every `welcome` that carried a copilot, and it has to be:
   * that machine refuses every copilot verb, read tier included, until *this
   * socket* has said it, and the socket is new after every reconnect. A window
   * that owned the opening would be a window that has to notice a laptop
   * waking, which is a thing no window can be relied on to do.
   */
  ipcMain.handle(
    'machines:copilot:attach',
    (_event, id: unknown): { ok: boolean; message: string } => {
      if (typeof id !== 'string') return { ok: false, message: 'That is not a machine.' }
      const link = links.get(id)
      if (!link) return { ok: false, message: 'This desktop is not linked to that machine.' }
      return link.copilotAttach()
    },
  )

  /**
   * Start this desktop's **own run** on that machine.
   *
   * Deliberately its own channel and not a flag on the attach beside it, for
   * the reason `copilot.start` is its own frame: attaching costs that machine
   * one callback, and this spawns an agent process on somebody else's computer
   * and spends money. Two acts that far apart sharing a channel is how a page
   * opening comes to start a run nobody asked for.
   *
   * It is also what makes the composer able to work at all. A device's run is
   * its own — never a second keyboard on the copilot at that desk — so
   * `CopilotStateReport.run` is null over there until this has been sent, and
   * `machines:copilot:say` has nothing to talk to.
   */
  ipcMain.handle(
    'machines:copilot:start',
    (_event, id: unknown): { ok: boolean; message: string } => {
      if (typeof id !== 'string') return { ok: false, message: 'That is not a machine.' }
      const link = links.get(id)
      if (!link) return { ok: false, message: 'This desktop is not linked to that machine.' }
      return link.copilotStart()
    },
  )

  /**
   * Ask that machine what its copilot is doing, again.
   *
   * `machines:copilot:refresh` rather than `…:state`, because the state's own
   * name is taken by the channel it arrives on: this is a question and that is
   * the answer, and one word for both would be two things somebody has to hold
   * apart while reading either.
   *
   * A retry rather than a first read, and it is here for the same narrow reason
   * `machines:ports` is: `machines:copilot:attach` already answers with a state
   * and every later change is pushed, so a panel that has just opened is not
   * waiting on this. What it covers is the round trip that went missing —
   * without it the only way back to a live reading is to reconnect the machine.
   */
  ipcMain.handle(
    'machines:copilot:refresh',
    (_event, id: unknown): { ok: boolean; message: string } => {
      if (typeof id !== 'string') return { ok: false, message: 'That is not a machine.' }
      const link = links.get(id)
      if (!link) return { ok: false, message: 'This desktop is not linked to that machine.' }
      return link.copilotState()
    },
  )

  ipcMain.handle(
    'machines:copilot:say',
    (_event, id: unknown, text: unknown): { ok: boolean; message: string } => {
      if (typeof id !== 'string') return { ok: false, message: 'That is not a machine.' }
      // Checked here as well as on the wire, for the reason
      // `machines:controls:apply` narrows its control name: an `ipcMain.handle`
      // argument is whatever the renderer put in it however the type reads, and
      // everything past this line ends up in an agent's prompt on another
      // computer. `MachineLink.copilotSay` runs the real wire parser over it,
      // which is the check that protects the far machine and the one that stops
      // an oversized paste closing the socket.
      if (typeof text !== 'string' || text === '') return { ok: false, message: 'There is nothing to say.' }
      const link = links.get(id)
      if (!link) return { ok: false, message: 'This desktop is not linked to that machine.' }
      return link.copilotSay(text)
    },
  )

  ipcMain.handle('machines:open', (_event, id: unknown, url: unknown): boolean => {
    if (typeof id !== 'string' || typeof url !== 'string' || url === '') return false
    if (url.length > MAX_URL_LENGTH) return false
    return links.get(id)?.openThere(url) ?? false
  })

  /*
   * Every stored machine is dialled here, by the act of registering this — not
   * by a button, not when a panel mounts. See the note at the top of the file:
   * the failure this project keeps re-finding is a feature that is complete and
   * never started, and the only defence is that launching causes it.
   */
  for (const machine of store.list()) linkFor(machine)

  /**
   * One place both doors into a transfer go through.
   *
   * The renderer's `machines:upload` and the main process's own
   * `MachinesIpc.sendFile` were the same four lines twice, and the second copy
   * is exactly where a refusal sentence drifts from the first.
   */
  async function sendFile(
    machineId: string,
    filePath: string,
    dir?: string,
  ): Promise<SendFileOutcome> {
    const link = links.get(machineId)
    if (!link) return { ok: false, message: 'This desktop is not linked to that machine.' }
    return await link.sendFile(filePath, dir)
  }

  return {
    view,
    drivesWindows: (machineId: string): boolean => store.drivesWindows(machineId),
    announceWindows(): void {
      for (const link of links.values()) link.announceWindows()
    },
    askWindow(machineId: string, call: WindowCallFrame): number {
      const link = links.get(machineId)
      if (!link) return 0
      return link.askWindow(call) ? 1 : 0
    },
    servesWindows(machineId: string): boolean {
      return links.get(machineId)?.servesWindows() ?? false
    },
    sendFile,
    wake(): void {
      for (const link of links.values()) link.wake()
    },
    reach: openReach,
    closeReach,
    stop(): void {
      // The code goes with the app. A slot left claimed at the relay by a
      // process that is exiting would answer for a machine that is no longer
      // there, until the socket eventually noticed.
      deps.desk.cancel()
      for (const link of links.values()) link.disconnect()
      links.clear()
      // After the links, because a reach sends a `tunnel.close` through one on
      // its way out and a closed link simply refuses it — which is fine, and the
      // other order would be a frame sent into a socket that is being torn down.
      for (const reach of reaches.values()) reach.closeAll('This desktop is shutting down.')
      reaches.clear()
    },
  }
}

/**
 * The same machine, without a window.
 *
 * This assembles what `src/main/index.ts` assembles — `createHostCore` for the
 * sessions and grants, `registerRemoteIpc` for the relay and the sockets,
 * `registerMachinesIpc` for the machines this one has paired to — and then
 * stops. There is no renderer to broadcast at, no menu, no updater, no browser
 * pane. Everything a phone can ask this host to do, it can do, because it is the
 * same host: the capability list a client sees is assembled from the same
 * objects (`SessionAccess.create`, `uploadsDir`, `credentials`) and this file
 * supplies all three.
 *
 * ## What is genuinely different, and it is only two things
 *
 * **Notifications.** `HEADLESS.md`: "a headless host has nobody to notify
 * locally. It should forward to the paired devices instead, which is more useful
 * anyway." That already happens without a line of code here, and saying why is
 * worth more than writing one: a session's status changes reach every attached
 * device through the fanout, and the client on the far side is what raises the
 * banner. What is deliberately *not* done is calling Electron's `Notification`
 * on a machine whose screen nobody is looking at — which on a server is not a
 * degraded experience, it is a notification posted into an empty room.
 *
 * **Idle mode.** A desktop has a person in front of it. This does not, and most
 * of the time nothing at all is attached, so it holds the relay connection and
 * lets the rest stop. See `src/main/idle.ts` for why that is driven by the
 * attach and detach events rather than by a timer.
 *
 * ## Why `status` is assembled here rather than in the CLI
 *
 * Because the CLI may be a different process — it usually is, talking down a
 * control socket to a daemon that has been running for a week — and a status
 * assembled on the client side could only ever describe what the client can
 * reach. The daemon is the only thing that knows what it is holding open.
 */

import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { BRAND } from '../shared/brand'
import type { SessionMeta } from '../shared/types'
import { createHostCore, type HostCore } from '../main/host-core'
import { IdleController, type IdleReport } from '../main/idle'
import { logger } from '../main/app-log'
import { bootMapFor, writeAppContext } from '../main/app-context'
import {
  heldRowsFor,
  hookContext,
  MID_TURN_EVENTS,
  recordRemoteHolds,
  sessionRemoved,
  slotName,
  takeAnnouncement,
  view as bindingView,
  subscribe as subscribeToBindings,
} from '../main/browser-binding'
import { noVerbsLine } from '../main/session-verbs'
import { HeadlessDriveHost } from '../main/browser-headless-host'
import { boundKey, BrowserDrive, OWN_TARGET } from '../main/browser-driver'
import type { DriveStatus } from '../main/browser-drive'
import { frontTab, screencastOver, type CastWindow } from '../main/screencast-host'
import { createHeadlessBrowserControl } from '../main/browser-headless-control'
import { startDeckControlServer, stopDeckControlServer } from '../main/deck-control/server'
import { createSessionTools, type SessionTools } from '../main/deck-control/session-tools'
import { serveWindowCall } from '../main/remote/machines/window-serve'
import { installHooksWhereConfigured } from '../main/hooks'
import { resetDevPortsCache } from '../main/dev-ports'
import { currentHookEndpoint, startHookServer, stopHookServer } from '../main/hook-server'
import { currentPlatform, type Platform } from '../main/platform/host'
import { downloadsDir, homeDir, userDataDir } from '../main/platform/paths'
import {
  describeReachability,
  readHostFacts,
  type HostFacts,
  type Reachability,
} from '../main/reachability'
import type { Device } from '../main/remote/device-auth'
import type { DeviceKindRecord } from '../main/remote/device-kind'
import type { DeviceFolderGrant } from '../main/remote/folder-grants'
import { describeThisMachine } from '../main/remote/machines/guest'
import { registerMachinesIpc } from '../main/remote/machines/ipc'
import {
  registerRemoteIpc,
  REMOTE_CONNECTIONS_CHANNEL,
  type RemoteStatus,
} from '../main/remote/server'
import {
  conversationOnDisk,
  folderExists,
  planRestore,
  restoreOpenSessions,
  type RestoreDecision,
} from '../main/session-restore'
import { getState as profilesState, resolveProfile } from '../main/profiles'
import { configureSessionAccounts } from '../main/session-account'
/*
 * Running a session as another login, and opening a sign-in terminal — the
 * same functions the desktop shell hands its core, reached through the same
 * seam. This is the wiring behind *"when I am inside the server, I cannot even
 * change the accounts"*: handing the two verbs over is what makes this host
 * advertise `CAPABILITY.account` and `CAPABILITY.logins`, and the phone and
 * PWA already send the frames.
 */
import { createSessionSwitch, type SessionSwitch } from '../main/session-switch-run'
import { store } from '../main/store'
/*
 * The two catalogues the Store panel serves, and the pieces each is made of.
 *
 * `browser-store-ipc.ts` is imported for `installBrowserStore` alone, and it is
 * the *right* door rather than a shortcut around one: it builds the store over a
 * `userData` and files it where `installedBrowserTools()` reads it, so a tool
 * installed from a phone against this server is a tool `browser.extract` can use
 * in the very next turn. Its only Electron import is `type IpcMain`, which is
 * erased before a byte is emitted — `seam.test.ts` walks this whole graph.
 *
 * The MCP half needs no store at all: `readStoreFacts` looks for `npx`, `uvx`
 * and `docker` on the PATH, `installFromCatalogue` and `removeMcpServer`
 * delegate to the person's own `claude mcp` CLI, and `loadServers` reads the
 * configuration files that CLI writes. `panels/store.ts` says as much —
 * *"the MCP half needs nothing but a child process"*.
 */
import { installBrowserStore } from '../main/browser-store-ipc'
import { quoteArgv, removeMcpServer } from '../main/mcp-add'
import { loadServers } from '../main/mcp-client'
import {
  buildStoreView,
  installFromCatalogue,
  probeBinaries,
  readStoreFacts,
  type ConfiguredServer,
} from '../main/mcp-store'
import { NO_COPILOT_HERE } from './cli'
import { serverMachineBrowser } from './machine-browser'
import { ChannelDesk } from './desk'
import {
  createPublicHost,
  PUBLIC_HOST_OFFER,
  type PublicHost,
  type PublicHostConfig,
} from './public-host'
import { hostVersion } from './version'

/**
 * The longest `remote:device:next` will hold a caller before answering `null`.
 *
 * Three minutes rather than sixty seconds, even though a pairing code dies in
 * sixty: `terminaldeck pair` mints a second code when the first expires and asks
 * again, and a wait that ended on the same schedule as the code would turn every
 * ordinary "I fumbled the first one" into an extra round trip. It is a ceiling on
 * a caller's request, not a policy — see the channel for why there is one at all.
 */
export const MAX_PAIRING_WAIT_MS = 3 * 60_000

/* ----------------------------------------------------------------- status -- */

/**
 * Everything `terminaldeck status` prints, gathered in one round trip.
 *
 * One message rather than four commands because the question a person is asking
 * is never "what is the relay doing" on its own — it is "can my phone reach this
 * machine, and if not, why not". Four answers arriving separately is four
 * chances to read a stale one beside a fresh one.
 */
export interface HostStatus {
  version: string
  pid: number
  startedAt: number
  /** Where this host keeps everything. Printed because it is where a person looks next. */
  stateDir: string
  platform: Platform
  facts: HostFacts
  reachability: Reachability
  idle: IdleReport
  remote: RemoteStatus
  devices: Device[]
  /**
   * What each device is, alongside the roster rather than folded into it.
   *
   * Two lists because they are two files with opposite failure directions —
   * `device-kind.ts` is explicit that a kind must never be a field on a record
   * the trust store rewrites, since `asStoredDevice` drops what it does not
   * recognise and would erase one on the next approve. A device with no row here
   * is not a device with no kind; it is one nobody has decided about, which
   * `kindOf` enforces as `guest` and which the CLI prints as its own state.
   */
  kinds: DeviceKindRecord[]
  folders: DeviceFolderGrant[]
  sessions: SessionMeta[]
  /**
   * Things the desktop build idles that this one has never had, so a reader of
   * the idle report does not go looking for them.
   *
   * An idle mode that lists three subsystems when the specification named six is
   * indistinguishable from an idle mode that forgot three.
   */
  neverRunning: string[]
  /**
   * The public-demo sentence, or null on every host anybody owns.
   *
   * A field rather than a flag, because the honest thing to print is what the
   * mode *does* — auto-approves, grants one folder, ends itself — and a boolean
   * would leave `status` describing that in prose written somewhere else, where
   * it could drift away from the policy. `public-host.ts` owns both.
   */
  publicHost: string | null
}

export interface HeadlessHostOptions {
  /** Overridable so a test never writes to the real state directory. */
  storageDir?: string
  /** Built PWA directory. Absent or missing simply means no web client is served. */
  webRoot?: string
  uploadsDir?: string
  platform?: Platform
  now?: () => number
  /** Seams. A unit test may not dial the public internet or shell out to Tailscale. */
  relayEnabled?: boolean
  readTailnet?: Parameters<typeof registerRemoteIpc>[1]['readTailnet']
  serve?: Parameters<typeof registerRemoteIpc>[1]['serve']
  /**
   * Turn this host into the public demo machine. **Absent on every real host.**
   *
   * Passing it is the whole switch, and it is a parameter rather than an
   * environment variable on purpose: an environment variable is something a
   * machine can inherit, a systemd drop-in can set and a container image can
   * carry by accident, and the thing it would turn on is "approve any device
   * that redeems a code". A caller has to write this out in source to get it,
   * and exactly one file does — `src/headless/demo.ts`, which is not in the
   * npm package's `bin` and is not linked by the desktop.
   *
   * `end` is how the mode stops: on a demo box the host is one visitor's
   * container under `docker run --rm`, so exiting the process is the reset.
   * Injected because *this* module must not be the thing that calls
   * `process.exit` — a test that wanted to exercise the lifecycle would then
   * take the test runner down with it.
   */
  publicHost?: {
    config: PublicHostConfig
    end(reason: string): void
  }
  /**
   * Told when the relay link comes up or goes down.
   *
   * Forwarded rather than watched, because the only caller that needs it is
   * `demo.ts`, whose broker has to hear "this machine is reachable" and for whom
   * "the process started" is a different and misleading fact.
   */
  onRelayState?: Parameters<typeof registerRemoteIpc>[1]['onRelayState']
}

export interface HeadlessHost {
  core: HostCore
  desk: ChannelDesk
  /** Call a channel handler exactly as the renderer would. */
  invoke(channel: string, ...args: unknown[]): Promise<unknown>
  /**
   * Deliver a channel the remote endpoint publishes.
   *
   * The desktop's equivalent is `send`, which pushes into a render frame. There
   * is no frame here, and exactly one channel matters — the connection list,
   * which is what idle mode is driven by.
   *
   * It is on the interface rather than buried in a closure so that the wiring is
   * something a test can point at instead of something it has to trust: this is
   * the very function object handed to `registerRemoteIpc`, so exercising it is
   * exercising the path the server actually uses. A separate hook that only the
   * test called would pass while the real wiring was cut, which is the failure
   * this whole codebase keeps re-finding.
   */
  broadcast(channel: string, payload: unknown): void
  status(): Promise<HostStatus>
  /** Put back the sessions that were open when this host last stopped. */
  restore(): Promise<void>
  stop(): Promise<void>
  /**
   * The public-demo policy, or null on every host anybody owns.
   *
   * Handed back so that `demo.ts` can read the motd it is about to write to
   * disk out of the same object that decided the rules, rather than keeping a
   * second copy of that sentence next to the first.
   */
  publicHost: PublicHost | null
}

/* --------------------------------------------------------------- assembly -- */

/**
 * What one `DriveStatus` is worth telling a phone about.
 *
 * Pulled out of the callback it used to live inside, because that callback is a
 * closure over a running host and there was no way to ask it a question without
 * standing one up — which is exactly how it came to drop a signal it was being
 * handed. Extracted, the whole rule is four lines and a test can state them.
 *
 * Two independent questions off one status, and they are not the same question:
 *
 * - **the handover**, keyed on whether somebody is being asked and what they are
 *   being asked. This is what the callback was written for.
 * - **the address**, which used to be dropped. Measured on the handover harness:
 *   the agent navigated `/login` → `/welcome`, the frames rendered the new page,
 *   and the strip above them read `/login` for the rest of the run.
 *
 * Everything downstream of the address was already right — a
 * `browser.surfaces.rows` push makes the phone re-read the list, and the
 * headless `list()` answers from `page.url()`, which is live. Nothing sent the
 * push. On a desktop a navigation reaches the strip through `windowMoved`, whose
 * only navigation caller is Electron renderer IPC (`browser-binding-ipc.ts`) and
 * so does not exist on a server. The signal was not missing on this host; it was
 * arriving here and being discarded by a return that only cared about handovers.
 *
 * Both are guarded on actually having moved, for the same reason: this is called
 * once per click as well as once per navigation, and a click that navigates
 * nowhere is not news.
 */
export interface DriveAnnouncement {
  handover: string
  url: string
}

export function driveAnnouncements(
  was: DriveAnnouncement,
  status: Pick<DriveStatus, 'state' | 'prompt' | 'url'>,
): { now: DriveAnnouncement; handoverMoved: boolean; addressMoved: boolean } {
  const handover = `${status.state === 'human' ? 'asking' : 'no'}\u0000${status.prompt}`
  const url = typeof status.url === 'string' ? status.url : ''
  return {
    now: { handover, url },
    handoverMoved: handover !== was.handover,
    addressMoved: url !== was.url,
  }
}

export async function createHeadlessHost(
  options: HeadlessHostOptions = {},
): Promise<HeadlessHost> {
  const platform = options.platform ?? currentPlatform()
  const now = options.now ?? Date.now
  const startedAt = now()
  const stateDir = options.storageDir ?? userDataDir()
  const remoteStorageDir = join(stateDir, 'remote')

  const facts = readHostFacts(platform)
  const reachability = describeReachability(facts)

  const desk = new ChannelDesk()

  /*
   * Idle mode, and it starts idle.
   *
   * Nothing is attached to a host that has just booted, and a server may sit
   * that way for a week. Waking on launch and only idling after the first
   * detach would mean the feature never happens on the machine it was written
   * for. See `src/main/idle.ts`.
   */
  const idle = new IdleController()

  /*
   * The desktop's only use for `broadcast` is pushing a channel at a window.
   * There is no window here — and there is exactly one message worth listening
   * to, which is the one idle mode is driven by.
   *
   * `REMOTE_CONNECTIONS_CHANNEL` carries the connection list every time a device
   * authenticates, attaches, detaches or leaves, which is precisely the set of
   * moments that can change whether anybody is watching. Nothing polls, and
   * nothing may: the WebSocket ping/pong inside the relay link is the only
   * heartbeat this process is allowed to have, because a NAT drops an idle
   * connection silently and the socket dies without it. One heartbeat layer, not
   * two.
   */
  /*
   * Assigned below, once the trust store and the grants it needs exist — and
   * declared up here, before the closure that reads it.
   *
   * A `const` further down would have been in its temporal dead zone for as long
   * as construction takes, and construction includes `registerRemoteIpc` dialling
   * the relay. A connection arriving in that window is unlikely and is exactly
   * the kind of unlikely this codebase has been bitten by; `null` is a value the
   * closure can survive reading, a dead zone is a ReferenceError.
   */
  let publicHost: PublicHost | null = null

  const broadcast = (channel: string, payload: unknown): void => {
    if (channel !== REMOTE_CONNECTIONS_CHANNEL || !Array.isArray(payload)) return
    const mode = idle.attached(payload.length)
    logger.debug('headless', `now ${mode}`, { attached: payload.length })
    // The same event, read for a second question. Idle mode asks "is anybody
    // watching"; the demo machine asks "is my visitor still here", and the
    // answer arrives from the connection list rather than from a timer for
    // exactly the reason idle mode's does.
    publicHost?.attached(payload.length)
  }

  /*
   * Devices that have redeemed a code since this host started, and whoever is
   * waiting to hear about the next one.
   *
   * This is the small thing that deletes "Press Enter once the device says it
   * is waiting to be approved" from `terminaldeck pair`. That prompt exists
   * because there was no event to subscribe to and the standing rule here is
   * events, not polling — so a person at a keyboard was used as the event. It
   * works, and it stops working the moment the thing waiting is a broker on a
   * demo box, which cannot press anything and must not loop asking.
   *
   * The list is kept as well as the waiters because of a race that is the
   * ordinary case rather than a corner: `pair` mints a code, prints it, and only
   * then asks to be told about the next device — and a fast reader with the
   * phone already open can redeem inside that gap. A waiter alone would miss it
   * and wait out its whole timeout with the device sitting there paired.
   */
  const paired: Device[] = []
  /**
   * The waiters take `null` as well as a device, and that is not a convenience.
   * A host that is stopping has to be able to answer everyone still holding a
   * control connection, and "nothing paired" is the true answer to give them —
   * the alternative is a `pair` command left hanging against a host that has
   * already closed its socket.
   */
  const waiting = new Set<(device: Device | null) => void>()

  const notePaired = (device: Device): void => {
    /*
     * The public host's decision, taken here because here is where the event
     * lands — and this line's absence was the whole demo.
     *
     * Measured on 2026-08-16 by erasing a simulator, installing 0.1.8 and
     * following App Review Information word for word: the page minted a real
     * code in three seconds, the phone redeemed it, and then the app sat on
     * *"Waiting for approval — approve it in the desktop app, then reconnect"*
     * for as long as anybody cared to watch. The demo container's own log said
     * `a device redeemed a pairing code` and never said `a visitor paired and
     * was let in`, and `status` on the box answered `Devices (1) — pending,
     * never seen`. `createPublicHost` was built, its policy was correct and its
     * unit tests passed, because those tests wire `policy.paired` to the
     * authenticator themselves. The shipping assembly never wired it to
     * anything, so `PublicHost.paired` had exactly one caller in the entire
     * repository and that caller was the test file. A reviewer would have met
     * the same Guideline 2.1 dead end §1 of APPSTORE.md was written to remove,
     * one screen later and with the review notes now promising it worked.
     *
     * It runs before the waiters because a waiter is `terminaldeck pair`
     * printing "approved" to a person: telling them so before the trust store
     * has been written would be a race that reads as a lie on the day it loses.
     * `publicHost` is `null` on every host that is not the demo — this is the
     * closure the `let` at the top of the file exists for.
     */
    publicHost?.paired(device)
    paired.push(device)
    logger.info('headless', 'a device redeemed a pairing code', { device: device.name })
    for (const wake of [...waiting]) {
      waiting.delete(wake)
      wake(device)
    }
  }

  /**
   * Tell every attached device the session list changed — once the remote
   * layer exists to tell them through.
   *
   * Late-bound for the reason the desktop's `remoteLayer` is: the core is
   * constructed here and the wire below it, so a session restored at boot can
   * exist before there is anybody to push at, and pushing to nobody is the
   * correct answer rather than a race to work around. Each connection is sent
   * its *own* `sessionsFor` list — see `tellSessions` in `remote/server.ts` —
   * so this is an event, never a shared payload.
   */
  let tellDevices: (() => void) | null = null

  /**
   * The account switch and the sign-in, once the core exists to build them on.
   *
   * Late-bound because they are made *from* the core the options below
   * construct — the same one-tick gap the desktop shell carries, answered with
   * a sentence rather than a rejected promise if anything could ever ask
   * inside it.
   */
  let accountVerbs: SessionSwitch | null = null
  const stillStarting = Promise.resolve({
    ok: false,
    message: 'This computer is still starting up.',
    session: null,
  })

  /*
   * The server's own tool endpoint, late-bound for the same reason
   * `accountVerbs` above is.
   *
   * `createSessionTools` needs a listening MCP endpoint and the endpoint needs
   * a `DeckControl` built over a browser this function has not made yet, so it
   * is assembled a hundred lines below — while `createHostCore` has to be handed
   * a `prepare` seam here, at construction, because a session can start the
   * instant the core exists. Reading through the binding rather than capturing
   * its value is what makes the seam answer the truth at the moment a session
   * launches instead of the truth at the moment the core was built: null before
   * the endpoint binds, which `host-core.ts` turns into the `early` sentence,
   * and the real thing afterwards.
   */
  let sessionTools: SessionTools | null = null

  const core = createHostCore({
    storageDir: remoteStorageDir,
    userData: stateDir,
    platform,
    // No shell to tell. A session a phone starts is announced to every attached
    // device by the fanout; there is no second audience here, and inventing one
    // would be a broadcast into an empty room.
    onSessionCreated: (meta) => {
      logger.info('headless', 'a device started a session', { folder: meta.cwd, agent: meta.provider })
    },
    /*
     * Every session, the moment it exists — so a terminal the *host itself*
     * opened reaches the devices' lists without being asked for. The two that
     * matter here are the sign-in terminal (`signInAccount` answers its id, and
     * the pane that asked attaches to it) and a switch's replacement; a device
     * that started a session hears about it twice, which `tellSessions` calls
     * a harmless refresh.
     */
    onSessionStarted: () => tellDevices?.(),
    /*
     * The other half of the same push, and the half that was missing: a session
     * *gone* from this host has to leave every attached device's list too, not
     * sit there pointing at a pty this process has already dropped. Without it a
     * session ended on the server — by another device's verb, by the copilot's
     * `sessions_stop`, by the process being killed — stayed in a phone's sidebar
     * until it reconnected. `onSessionStarted` above already pushes the appear
     * side; this closes the disappear side so "delete it on the server and it
     * vanishes from both apps" is finally true on a headless host.
     *
     * `replaced` is filtered here for the same reason and on the same side that
     * knows it as the desktop (see `index.ts`): a `replaced` removal is the
     * account switch stopping one process and starting another *in the same
     * tab*, and `onSessionStarted` fires for the replacement — so pushing on the
     * removal too would be a flicker to an empty-then-full list, never a change.
     * The push itself is `remote.server.sessionsChanged()`, per-connection and
     * per-device — see the `tellDevices` declaration and `tellSessions` in
     * `remote/server.ts`; there is no machines fan-out here because a headless
     * host never dials out, so its `links` map — and thus `announceSessions` —
     * is always empty, which is why `onSessionStarted` omits it too.
     */
    onSessionRemoved: (id, reason) => {
      if (reason === 'replaced') return
      /*
       * The binding rows and the token, in the same breath the devices are told.
       *
       * Both are new here because both only became reachable when a session on
       * this host got a browser of its own. `sessionRemoved` drops the `B1`/`B2`
       * rows and frees their colour — without it a window belonging to a session
       * this process has already let go stays in the map that composes every
       * other session's hook answer. `sessionTools.release` drops the bearer
       * token that let that session drive them: a token left on the table points
       * at a session id nothing can resolve, which is the state
       * `session-tools.ts`'s claim deadline exists to collect and should never
       * have to. `src/main/index.ts` does the same two on the same edge.
       */
      sessionRemoved(id)
      sessionTools?.release(id)
      tellDevices?.()
    },
    /*
     * The server's own tool endpoint, offered to every session that starts here.
     *
     * This is the seam `host-core.ts` composes `--mcp-config` from, and until
     * this line the headless build passed none — so every session on a server
     * was launched with no browser verbs and told, correctly for the build it
     * was then, that *"this app's control endpoint is not running here"*. It is
     * now, over a real Chromium of this host's own; see where `browserControl`
     * and `sessionTools` are assembled below.
     *
     * `hostHoldsWindows` is the other half and the one that matters on a server:
     * almost every session here is started by a device that dialled in, and the
     * desktop's gate refuses those unless the *device* can hold a browser
     * window. On this host the windows are neither the device's nor a phone's —
     * they are this machine's — so the question is answered by the host rather
     * than about the device. `host-core.ts` has the long form.
     *
     * Withheld entirely on the public demo box, which is what makes the sentence
     * over there right rather than merely different: no seam at all is how
     * `host-core.ts` spells *"this build has no control endpoint"*, and on that
     * box it has none. Passing a seam whose `prepare` always answered null would
     * instead tell a visitor's session that it started too early and should be
     * started again, which is a door that is never going to open.
     */
    ...(options.publicHost === undefined
      ? {
          sessionTools: {
            prepare: (inside) => sessionTools?.prepare(inside) ?? null,
            /*
             * True whether or not the endpoint came up, because it answers a
             * question about this machine and not about this boot: the windows a
             * session here would drive are held by this host. A boot where the
             * endpoint failed to bind is then told `early` — "started before the
             * endpoint did" — which is the desktop's own sentence for the same
             * state, rather than being told that the phone that asked cannot
             * show a browser window, which would be false about the wrong
             * computer.
             */
            hostHoldsWindows: () => true,
          },
        }
      : {}),
    /*
     * The two verbs whose absence was the whole defect. `createHostCore`
     * advertises `account` and `logins` exactly when a shell supplies these —
     * see `SessionAccess.account` — so this host used to be a machine whose
     * bar said "no rows to press". They are the desktop's own functions, built
     * over this host's core; there is no headless dialect.
     */
    switchAccount: (sessionId, accountId) =>
      accountVerbs?.switchAccount(sessionId, accountId) ?? stillStarting,
    signInAccount: (accountId) => accountVerbs?.signInAccount(accountId) ?? stillStarting,
  })
  accountVerbs = createSessionSwitch(core, {
    // The tab a desktop would make of it has no equivalent here; the device
    // that asked opens the answered id, and `onSessionStarted` above has
    // already pushed the new list at everybody else. What is left to do is say
    // it happened on the machine where it happened.
    onSessionOpened: (meta) => {
      logger.info('headless', 'a sign-in terminal was opened', { folder: meta.cwd, agent: meta.provider })
    },
  })
  /*
   * And the ladder that answers *whose login is this session on* — the
   * `current` half of the account chip a device draws over one of this host's
   * sessions. The same registration the desktop makes in
   * `registerSessionAccountIpc`, minus the IPC: without it `sessionAccount`
   * answers `withheld` for everything and the chip over a session running on
   * this very host says "No login" above a terminal whose banner names one.
   */
  configureSessionAccounts({
    pidOf: (id) => core.ptys.pidOf(id),
    describeSession: (id) => core.ptys.list().find((session) => session.id === id) ?? null,
    platform,
  })

  /*
   * The server's own browser, and the door a device drives it through. [wave-2 Lane D]
   *
   * This is the whole of what makes "the server is the machine" true for the
   * browser: a real headless Chromium of this host's own, behind the same
   * `DriveHost`/`BrowserDrive` seam the desktop uses, and a `DeckControl` holding
   * the browser verbs over it. `HeadlessDriveHost` launches Chromium lazily on
   * the first drive — a missing binary is a named error, never a crash — so
   * building it here costs nothing until a device actually opens a page.
   *
   * Wave-2 landed the cross-machine half — a device that dialled in drives a
   * window this server holds, over `window.call`/`hostWindows`, served by
   * `serveWindowCall` in the `registerRemoteIpc` options just below — and left
   * *local* sessions out, because giving a session on this machine the browser
   * verbs needs a `deck-control` MCP endpoint here and `deck-control` could not
   * enter this bundle. Both edges that stopped it are cut: `browser-drive-ipc.ts`
   * behind `browser-drive-current.ts`, and `live-surface.ts`'s settings read
   * moved to the store half. So the endpoint is started below and the
   * `cannotDrive` sentence stops being said about a session that can.
   */
  /**
   * The one thing a drive-state change on this host has to reach.
   *
   * `HeadlessDriveHost`'s publisher is the desktop's IPC push to a renderer, and
   * there is no renderer here — so it defaulted to a no-op and **every** state
   * change this server's browser made went nowhere. That is the line that made
   * the handover a desktop-only feature in effect: `browser.handover` on a server
   * curtains the cast, the phone watching it gets a lock card, and nothing ever
   * told the phone there was a question under it that it was allowed to answer.
   *
   * A `let` assigned after the endpoint exists, because the browser is built
   * before the wire is — the same shape `index.ts` uses for `remoteLayer`, and
   * for the same reason: a page can be driven before anything is listening, and
   * pushing to nobody is the correct answer rather than a race to work around.
   */
  let announceDriveState: (status: DriveStatus) => void = () => {}
  const browserHost = new HeadlessDriveHost({
    userData: stateDir,
    publish: (status) => announceDriveState(status),
  })
  const browserDrive = new BrowserDrive(browserHost)
  const browserControl = createHeadlessBrowserControl({
    drive: browserDrive,
    logDir: join(stateDir, 'browser-actions'),
  })

  /*
   * And the live view of that browser — the half the wire had and no host wired.
   *
   * `RemoteEndpointOptions.screencast` is the switch that makes `capabilitiesFor`
   * advertise `watch`, and this host passed none, so the phone's **Windows on
   * this machine** section was empty against a server that had a real Chromium
   * sitting behind `browserDrive` five lines up. `screencast-host.ts` carries the
   * argument for the object and for why a surface is named by its window id
   * rather than by `B2`; what belongs here is which windows a *server* can
   * honestly offer.
   *
   * There are two kinds and this host can reach both:
   *
   *  - **The front tab**, `''`, which is where `openUrl` below lands. It is the
   *    whole of *"it should browser and stream here to interact"*: the address
   *    bar opens a page in the drive's own slot, and on this host `openTab` mints
   *    no shell id for that slot — so without {@link frontTab} the page a person
   *    just asked for would be the one page in the list that was missing.
   *  - **A session's windows**, `B1`, `B2`, minted through `openForSession` by an
   *    agent running on this server. Read out of the binding store rather than
   *    out of a second map, for the reason `machine-browser.ts` reads it: the
   *    store is where both doors write, and a window opened by `open <url>` at a
   *    prompt never passes through any list this file keeps.
   *
   * A window whose target has gone is dropped rather than offered — the same
   * liveness question `machine-browser.ts` asks, through the same call, so the
   * strip and the window list cannot disagree about which pages still exist.
   * Rows for a session on a *paired* machine, and rows whose page is served by
   * one, are skipped: neither is a page this Chromium is holding and neither can
   * be cast from here.
   *
   *  - **A window the phone opened itself**, through New Window. Those hold no
   *    binding row by design — `openWindow` mints a shell id and attaches it to
   *    nothing — so for a while they were *drivable and not watchable*: listed by
   *    `browser.window.rows`, navigable, bindable, and tapping one to look at it
   *    found no surface. Half a feature, and the missing half was the one Asad
   *    asked for in the same breath as the rest: *"it should browser and stream
   *    here to interact."* `serverMachineBrowser.castable()` is that module's own
   *    list of them, folded in below.
   *
   * A window whose target has gone is dropped rather than offered — the same
   * liveness question `machine-browser.ts` asks, through the same call, so the
   * strip and the window list cannot disagree about which pages still exist.
   */
  const front = frontTab(() => browserDrive.where(OWN_TARGET))
  const castWindows = async (): Promise<CastWindow[]> => {
    const rows: CastWindow[] = []
    const seen = new Set<string>()
    const own = front.row()
    if (own !== null) rows.push(own)
    /*
     * The phone's own windows first, so a page somebody just opened is at the
     * top of the strip rather than behind whatever a session was holding.
     * Guarded rather than assumed: this is only ever built for a host that has a
     * machine browser, and `castable` answers an empty list on one whose
     * Chromium is holding nothing.
     */
    for (const held of await machineBrowser?.castable().catch(() => []) ?? []) {
      if (held.viewId === '' || browserHost.contentsFor(held.viewId) === null) continue
      seen.add(held.browserTabId)
      rows.push({
        window: held.browserTabId,
        target: {
          key: boundKey(held.browserTabId),
          viewId: held.viewId,
          browserTabId: held.browserTabId,
          // What a refusal calls it. A window no session owns has no slot name,
          // so it is called what it is rather than given a borrowed `B1`.
          name: 'a window',
        },
        url: held.url,
        title: held.title,
      })
    }
    for (const binding of bindingView().sessions) {
      if (binding.machineId !== '') continue
      for (const window of binding.windows) {
        if (window.hostMachineId !== '' || window.viewId === null) continue
        if (browserHost.contentsFor(window.viewId) === null) continue
        // A window the phone opened and a session then bound is one window, and
        // the first loop already has it under the same shell id.
        if (seen.has(window.browserTabId)) continue
        rows.push({
          window: window.browserTabId,
          target: {
            key: boundKey(window.browserTabId),
            viewId: window.viewId,
            browserTabId: window.browserTabId,
            // What a refusal calls it. Never printed as an id; see `DriveTarget`.
            name: slotName(window.n),
          },
          url: window.url,
          title: window.title,
        })
      }
    }
    return rows
  }

  /*
   * And the door a session *on this host* drives it through.
   *
   * The same `DeckControl` the wire already dispatches a device's `window.call`
   * into, now also behind an MCP endpoint on this machine's loopback — so a
   * Claude session started here is launched with `--mcp-config` naming a
   * per-launch file, exactly as one in the desktop's window is, and its six
   * browser verbs act on this server's own Chromium. One dispatcher for both
   * doors: the tier check, the confirmation gate, the budgets and the action log
   * are `deck-control`'s and there is no second copy of them here. See
   * `browser-headless-control.ts`, which argues that at length.
   *
   * ## What a session on this host is granted, and what it cannot find
   *
   * The endpoint is not "the copilot's tool surface, on a server". The token
   * `session-tools.ts` mints for each launch carries `SESSION_TOOLS`, which is
   * the browser family and `tools.describe` and nothing else, and
   * `deck-control/server.ts` applies that set to **both** `tools/list` and
   * `tools/call` — so a session here cannot list `sessions.send`, cannot call it
   * by guessing the name, and is not handed a paragraph of instructions
   * describing a surface it does not have (`instructionsFor`). That matters more
   * here than on the desktop: this control's non-browser surface is a proxy that
   * throws, because nothing was ever supposed to reach it, and a listing that
   * advertised it would be exactly the control that looks like it works and does
   * not.
   *
   * ## Why the public demo box gets none of it
   *
   * A stranger's container hands out a shell on purpose; handing that shell a
   * browser on the same machine is a fetch primitive pointed at whatever the
   * host can route to, and the action log it would be written into is a log
   * nobody owns. Withholding the endpoint is also what keeps the sentence
   * truthful over there: with no seam passed, `host-core.ts` answers `endpoint`,
   * which says this build has no control endpoint running, and on that box it
   * does not.
   *
   * A failure to bind is logged and is not fatal. Every session then launches
   * exactly as it did before this existed, and is told the `early` sentence
   * rather than being given flags naming a socket that is not there.
   */
  if (options.publicHost === undefined) {
    try {
      const controlEndpoint = await startDeckControlServer({ control: browserControl })
      sessionTools = createSessionTools(controlEndpoint, {
        dir: join(stateDir, 'session-tools'),
      })
      logger.info('headless', 'the browser tools endpoint is up', { port: controlEndpoint.port })
    } catch (error) {
      logger.error('headless', 'the browser tools endpoint did not start; sessions here get no verbs', {
        error: error instanceof Error ? error.message : String(error),
      })
    }
  }

  /*
   * **The machine-browser screen, on a server.** [wave-4]
   *
   * Asad, twice in one day, looking at the Browser tab against his own box:
   * *"I don't see any of them."* The controls he was looking for are the ones
   * the desktop has had for months —
   *
   * > *"recording the clicks flow, creating a screenshot and sending it to the
   * > session (whatever session we want to send, take a screenshot and send to
   * > the session) … making a browsing session into an isolated or shared one …
   * > we don't have an option to connect any browsing window to any session, so
   * > the session knows which browsing window it is working on."*
   *
   * — and not one of them was missing from the wire. `browser-control.ts`
   * carries all of it, and `server.ts` advertises `browser.control` **exactly
   * when this option is present**: `serves` reads the object's presence and
   * nothing else. So on a host that constructed no `MachineBrowser`, the phone
   * drew no machine-browser surface at all, which is precisely the screen he
   * photographed. One argument is the whole feature here.
   *
   * There was a second missing line under it, found by the test rather than by
   * reading: `CAPABILITY.browserControl` was never in `CAPABILITIES`, which is
   * the only list `advertised` filters — so the rule that reads this object ran
   * against a name that could never be a candidate, and *no* host advertised it
   * whatever it passed. `host.test.ts` asks a real endpoint for its welcome
   * instead of asking `serves` what it would have said, which is the difference
   * between the two halves being green and the feature existing.
   *
   * `serverMachineBrowser` is the deps object built over this host's own
   * Chromium; its header records which three of them a server genuinely cannot
   * supply and why each absence is a sentence rather than a dead button.
   *
   * ## Withheld on the public demo box, for the argument the tool endpoint makes
   *
   * A stranger's container hands out a shell on purpose. Handing that shell's
   * visitor the machine's browser as well is a fetch primitive pointed at
   * whatever the host can route to, with an action log nobody owns — the same
   * reason `deck-control` is withheld above. No object, so no capability, so no
   * screen: the absence is the enforcement rather than a refusal a client has to
   * be trusted to respect.
   */
  const machineBrowser = options.publicHost
    ? null
    : serverMachineBrowser({
        windows: browserHost,
        shots: browserDrive,
        // Read per verb, never cached — the picker a window is bound to and the
        // one a screenshot is sent to are both "the sessions running right now".
        sessions: () =>
          core.sessions.list().map((session) => ({
            id: session.id,
            title: session.title,
            // An exited session keeps its row and says so, which is what lets
            // the phone explain a window still on screen instead of going
            // blank. `exitCode` is null for as long as the pty is alive.
            ...(session.exitCode === null ? {} : { ended: true }),
          })),
        /*
         * The same write the wire's `input` frame performs — `sessions.write`,
         * one line above the one that types a person's keystrokes into a pty.
         * That is the assertion rather than a coincidence: a screenshot handed
         * to an agent from a phone must not be a second way of writing to a
         * session, or the two paths will one day disagree about what a submit
         * is. `machine-browser.test.ts` pins the two writes and the gap.
         */
        write: (sessionId, data) => core.sessions.write(sessionId, data),
      })

  /*
   * What the Store panel can reach on a server, and it is both departments.
   *
   * `panels/store.ts` was written for exactly this split — *"a host that can
   * list the catalogue and genuinely cannot write to it lists the catalogue and
   * says so"* — and a daemon turns out to be able to do all six: the browser
   * tools are files under this host's own state directory, and the MCP half is
   * the person's `claude mcp` CLI, which is on a server's PATH for the same
   * reason a session on it can run `claude` at all.
   *
   * Withheld on the demo box, where both halves are writes performed for a
   * stranger: one downloads and installs a scraping recipe into this container's
   * browser, the other rewrites the agent configuration of an account nobody
   * owns. The panel then says it cannot be reached from here, which is true.
   */
  const toolStore = options.publicHost ? null : installBrowserStore({ userData: () => stateDir })
  const storePanel: NonNullable<Parameters<typeof registerRemoteIpc>[1]['storePanel']> | null =
    toolStore === null
      ? null
      : {
          tools: {
            // `ToolStore.view` and `.remove` are synchronous and the panel's
            // shape is a promise for all six; one `async` arrow here is the cost
            // of not putting `Promise<T> | T` on an interface that is read far
            // more often than it is implemented.
            read: async () => toolStore.view(),
            install: (id) => toolStore.install(id),
            remove: async (id) => toolStore.remove(id),
          },
          servers: {
            read: async (projectPath) => {
              const configured = configuredHere(projectPath)
              /*
               * Two probes, in parallel, because they answer different kinds of
               * question — `registerMcpIpc` splits them the same way and for the
               * same reason. `readStoreFacts` looks for the catalogue's three
               * runtimes and does not depend on which folder is in view, so it
               * is deduplicated across concurrent reads; `probeBinaries` looks
               * for whatever the hand-written servers name, which does.
               */
              const [facts, binaries] = await Promise.all([
                readStoreFacts(),
                probeBinaries(configured),
              ])
              return buildStoreView({
                configured,
                runtimes: facts.runtimes,
                environment: facts.environment,
                environmentSource: facts.environmentSource,
                writer: facts.writer,
                projectPath,
                binaries,
              })
            },
            // Re-read rather than taken from the request: whether a name is
            // already taken is a fact about the file at the moment of writing,
            // not about the view the phone was looking at.
            install: (request) => installFromCatalogue(request, configuredHere(request.projectPath)),
            remove: (request) => removeMcpServer(request),
          },
        }

  const remote = registerRemoteIpc(desk, {
    sessions: core.sessions,
    // The two settings this machine owns, served over the wire like everything
    // else here. The headless daemon manages its default coding tool and its
    // restore-sessions choice from a phone the same way a desktop does — one
    // store, the same one a session start reads.
    serverSettings: core.serverSettings,
    folders: core.grants,
    /*
     * And the same login-choice store the endpoint's account filter closes over.
     *
     * Handed in even though this build has no screen that writes it, for the
     * reason `kinds` below is handed in: the headless daemon serves the same
     * protocol from the same fanout, and a rule a shell has to remember to
     * install is a rule the other shell forgets. An empty store shares every
     * login, which is exactly what this build did before it existed — so the
     * only thing this line changes is that a grant written by anything else is
     * honoured here too.
     */
    accountGrants: core.accountGrants,
    // The same store the reach rule closes over. The headless daemon serves the
    // same protocol from the same fanout, so it enforces the same two kinds —
    // and a build where this was the missing argument would be a build where
    // every device is a guest with no folders.
    kinds: core.kinds,
    // The store half of revocation, wired to the same core the CLI's other
    // device channels read. `device-roster.ts` runs it as the forget step of the
    // one cascade the wire, the `terminaldeck revoke` command and the desktop's
    // Settings all reach.
    forgetDevice: (id) => core.forgetDevice(id),
    /*
     * No `copilot`, and that is a limit this build states rather than an
     * argument somebody forgot.
     *
     * It matters because the wire makes "this host has no copilot" and "you are
     * a guest" the **same shape** — `copilotFrame` in `server.ts` argues that
     * those are one fact from the device's point of view and it is entitled to
     * neither more nor less. Between a desktop and a guest that is right. Here
     * it is exactly wrong: the owner's own phone is told nothing, and what it
     * sees is indistinguishable from having been approved as the wrong kind. So
     * `NO_COPILOT_HERE` is said on the side that knows — at the moment a device
     * is approved, and in `status` — and the absence is never met in silence.
     *
     * ## Why it is not simply wired, measured rather than assumed
     *
     * `CopilotRuns` assembles outside Electron; `scripts/remote-host.ts` does
     * it. What it cannot do here is have any tools. A run with no `deck-control`
     * behind it is refused by design and in as many words — *"a Claude CLI in
     * the copilot's folder with no deck-control is not a copilot"* — and
     * `CopilotRuns.state` reports `available: false` with *"The copilot's tools
     * are not running on this machine."* Passing the layer without its tool
     * server would therefore draw a fourth pill on the phone whose every Start
     * button refuses, which is worse than the absence, not better.
     *
     * ## What has changed, and what has not
     *
     * The reason this used to give was that `deck-control` could not be imported
     * into this bundle at all: `deck-control/index.ts` imported `browserDrive`
     * from `../browser-drive-ipc` — `BrowserWindow`, `WebContentsView`,
     * `nativeImage` at module scope — and its `live-surface.ts` imported
     * `settings-extra`, which loads `app`, `session` and `shell`.
     *
     * Both edges are cut. The drive's state moved to `browser-drive-current.ts`
     * and the settings read to `settings-store.ts`, the same treatment
     * `platform/paths.ts` gave `app.getPath`, and `seam.test.ts` walks
     * `deck-control/index.ts` and fails on a single runtime `electron` import.
     * This host already runs a `deck-control` MCP endpoint of its own, above —
     * that is what gives a session here the browser verbs.
     *
     * What is still missing is not an import. `registerDeckControlIpc` wants an
     * `ipcMain` and an `isApprover(WebContents)`, because the confirmation for an
     * `alter`-tier call is a dialog in a window, and there is no window here. A
     * copilot on a server therefore needs its questions routed to a connected
     * device — the `ConsentRelay` seam exists for exactly that and nothing on
     * this host is wired to it — and a live surface built over *this* core rather
     * than the desktop's. That is an assembly, and it is a different lane's.
     */
    /*
     * The git credential proxy, on every host except the public one.
     *
     * Withholding it is what stops the `credential` capability being advertised
     * at all, which is the shape every capability in this build uses: the object
     * that makes the feature possible is the thing that decides whether it is
     * offered. A demo host that advertised it would be telling a stranger's
     * phone it may be asked for a GitHub login by a machine that has no business
     * ever asking anyone for one.
     */
    ...(options.publicHost ? {} : { credentials: core.credentials }),
    // Sign-in off on the demo box, on everywhere else. The same argument as the
    // credential proxy above: a public host that let a stranger sign in with an
    // SSH login would be handing out a road to becoming one of the owner's own
    // devices — and a demo box has no owner to be. Every other headless host
    // serves it, gated only by whether its own sshd answers on loopback.
    signin: options.publicHost ? false : true,
    ...(options.publicHost ? { offer: PUBLIC_HOST_OFFER } : {}),
    onDevicePaired: notePaired,
    storageDir: remoteStorageDir,
    // Served only if it was shipped. A headless install on a server may not
    // carry the web client at all, and a missing directory is a 404 on the
    // static path rather than a failure to start: the native clients come in
    // through the relay and never ask for a file.
    webRoot: options.webRoot ?? '',
    // What this build calls itself, and that it is a headless server rather than
    // a desktop, onto the `welcome`. `hostVersion()` reads the number the
    // packaging stamped beside the bundle (or `TERMINALDECK_VERSION`), so a
    // phone paired to a server can say which build it is talking to — and,
    // because `hostKind` says `server`, the client that is ahead of it says
    // "update this server from a desktop", which is exactly the plane a headless
    // host is replaced on. There is no update verb on the wire to pair it with.
    appVersion: hostVersion(),
    hostKind: 'headless',
    // Where a file sent from a phone lands. The user's downloads folder, in a
    // folder named after the app — somewhere a person already looks, rather than
    // the state directory, which they never do. Passing it is also what
    // advertises the capability.
    //
    // A public demo host is given none, so it does not advertise `upload` and
    // there is nowhere for a stranger to send a file even if it did. Filling a
    // disk is the cheapest attack on a machine that hands out shells, and the
    // container's quota already bounds it — but a capability that is off is
    // better than one that is bounded.
    ...(options.publicHost
      ? {}
      : { uploadsDir: options.uploadsDir ?? join(downloadsDir(), BRAND.name) }),
    // Always on, and there is no switch to find. `stop` stops the process; a
    // host that was running but refusing to answer would be the worst of both.
    autoStart: true,
    onStartFailure: (reason) => {
      logger.error('headless', 'remote access did not come up at launch', { reason })
    },
    ...(options.onRelayState ? { onRelayState: options.onRelayState } : {}),
    ...(options.relayEnabled === undefined ? {} : { relayEnabled: options.relayEnabled }),
    ...(options.readTailnet ? { readTailnet: options.readTailnet } : {}),
    ...(options.serve ? { serve: options.serve } : {}),
    /*
     * A browser verb arriving from a device, for a window this server holds. [wave-2 Lane D]
     *
     * The serving half of `hostWindows` — providing it is what makes
     * `registerRemoteIpc` advertise the capability at all (see `server.ts`, where
     * `hostWindows` is offered exactly when `serveWindows` is present). One
     * decider, the same `serveWindowCall` the desktop uses, so the two doors can
     * never come to allow what each other refuses:
     *  - `allowed` is the default-closed grant axis already on the core —
     *    `WindowGrants`, open for a device approved as the owner's own and closed
     *    for a guest until ticked. A device the grant does not cover is refused
     *    with the sentence that names where to turn it on.
     *  - `control` is this host's browser-verb `DeckControl`, so every forwarded
     *    call carries the real tier check, budget and action log — none of it
     *    re-implemented here.
     *  - `attended` is false: there is no person at the server to answer an
     *    `alter`-tier confirmation, so those steps are refused rather than put to
     *    a broker that cannot reach anyone. Reading and navigating cross the wire;
     *    typing into a public site waits on routing the confirmation to the
     *    connected owner's device.
     */
    /*
     * **Open a page in this server's own browser, from a phone.**
     *
     * Asad, typing `google.com` into the Browser tab against a server and being
     * refused: *"it should browser and stream here to interact."*
     *
     * He is right, and the refusal was not a policy — it was a **missing wire**.
     * This host has had a real Chromium of its own since wave-2, behind
     * `browserDrive` a few lines up, and the phone has been able to watch and
     * drive its windows through `browser.watch` / `browser.input` the whole
     * time. What it had no way to do was *open* one: `web.open` is backed by
     * `openUrl`, this host passed none, and `capabilitiesFor` therefore never
     * advertised `web` — so the phone's address bar took one look at
     * `canOpenPages`, decided the machine could not do it, and printed a
     * sentence explaining that a site would load on the phone instead. The
     * sentence was true of a world where this option did not exist.
     *
     * ## Half of the loop was wired, and the half that streamed was not
     *
     * This comment used to end by saying that the page then *"appears in
     * `browser.surfaces` and therefore under **Windows** on the same screen, and
     * tapping it streams frames back that take his taps"*. That was false, and it
     * was false in a way that reads as true: every `browser.*` live-view frame
     * was on the wire, `PageCast` had held the screencast since wave-3, and the
     * one object that turns all of it on — `RemoteEndpointOptions.screencast` —
     * was passed by no shell in this repository. `capabilitiesFor` therefore
     * never advertised `watch`, `browser.surfaces` was dropped in silence, and
     * the section on his phone was empty on every host that ships.
     *
     * The line that makes it true is `screencast` in this same options object,
     * over the window list assembled where `browserDrive` is built: the page a
     * device opens here lands in the drive's own slot, that slot is a row of
     * `browser.surfaces`, and a device that watches the row is streamed frames
     * that take its taps. `front.opened` is what gives the row its label —
     * `open` answers the page's own address and title, and it is the only moment
     * anything on this host can read the title of a tab that has no shell id;
     * see {@link frontTab} for why the liveness is read live off the slot and
     * only the label is remembered.
     *
     * The whole sentence is true now, *"on the same screen"* included, and it
     * was not for a while. `BrowserSurfacesRowsFrame` has described itself as
     * *"also pushed unsolicited when the strip changes"* since it was written
     * and **nothing sent that push**: `server.ts` answered `browser.surfaces`
     * and had no fan-out, while `WatchLink.ensureRead` on the phone asks once
     * per connection and then waits. So a page opened from a phone's own address
     * bar was in the list the next time something made that phone ask, which on
     * a screen that never re-asks is never.
     *
     * `RemoteEndpoint.surfacesChanged` is that fan-out, and this host fires it
     * off the binding store — see where `tellDevices` is assigned. `attach`,
     * `detach`, `windowClosed` and `windowMoved` all publish there, which covers
     * a window a session opened and a window a phone opened through
     * `machineBrowser`.
     *
     * `isolate: false` so it lands in the window a person is already watching
     * rather than spawning one per address — the desktop's own `openUrl` makes
     * the same choice. Answering `true` is a claim that the *ask* was accepted,
     * not that the page loaded: the drive is asynchronous and the honest report
     * of what it did is the surface list that follows, not a boolean invented
     * here. A refusal is logged rather than thrown, because this runs on the
     * socket's data path.
     */
    openUrl: (url: string): boolean => {
      void browserDrive
        .open({ url, isolate: false })
        .then((page) => front.opened(page))
        .catch((error: unknown) => {
          console.error('[headless] could not open a page in this server\'s browser:', error)
        })
      return true
    },
    serveWindows: (deviceId, call) =>
      serveWindowCall(
        {
          allowed: (id) => core.windowGrants.drives(id),
          grantSwitch:
            'for this device in its remote settings, under the browser-windows permission',
          control: () => browserControl,
          attended: () => false,
        },
        deviceId,
        call,
      ),
    /*
     * And the same browser, watched rather than called. [wave-3, wired here]
     *
     * Passing this is what advertises `watch`; see where the window list is
     * assembled for what a server can and cannot offer. Withheld from the public
     * demo box on the argument its neighbours make — a stranger's container hands
     * out a shell on purpose, and handing that stranger a live view of the
     * machine's browser is the same fetch primitive with pictures.
     *
     * `drivesWindows` is the axis both halves ride, and it is the *same* call
     * `serveWindows` above is gated on rather than a second reading of the same
     * store: watching a signed-in browser is an owner act, and a device whose
     * browser-windows permission a person has unticked must lose the pictures at
     * the same moment it loses the clicks. `mayWatchNow` re-reads it per frame,
     * so unticking it stops a running cast on the next tick.
     */
    ...(options.publicHost
      ? {}
      : {
          screencast: screencastOver({ drive: browserDrive, windows: castWindows }),
          drivesWindows: (deviceId: string) => core.windowGrants.drives(deviceId),
        }),
    // Which of that device's sessions this server is holding a window for, read
    // from the one binding map at the moment of sending — the same builder the
    // desktop uses, keyed on the same `machineId` field. [wave-2 Lane D]
    windowsHeldFor: (deviceId) => heldRowsFor(deviceId, describeThisMachine().name),
    /*
     * And the frame arriving the other way, which on this host is the one that
     * actually carries something.
     *
     * Nothing in this build ever calls `attach()` — there is no renderer here to
     * put a `WebContentsView` beside a pty — so the answer above is honestly
     * empty on every server this ships to. The interesting direction is the
     * mirror: Asad's Mac pairs with this box, attaches one of *its* browser
     * windows to a session running here, and until this line existed the agent in
     * that session was never told. It is the case this whole lane is about, and it
     * is the case the office PC is in.
     *
     * There is no `windows` desk here to route the verb through, so a session on
     * this host still cannot *drive* the window — `noVerbsLine` says so, in the
     * same answer, for the same session. Telling it the window exists is not half
     * a feature: it is the difference between an agent that says "the page is
     * open on your Mac, here is what to click" and one that goes looking for a
     * CDP port.
     */
    onWindowsHeld: (peer, held) => recordRemoteHolds(peer, held),
    /*
     * Where this host keeps its own state, said rather than guessed. [wave-4]
     *
     * `browserProfilesFor` in `server.ts` has read `options.stateDir` since the
     * day it was written and no caller had ever declared it, so every profile
     * read on every host fell back to `homedir()` — the account's home, which is
     * the one directory this shell's paths provider is entitled to move.
     * `XDG_DATA_HOME` and `--state-dir` both point somewhere else here, and a
     * daemon that answered a phone out of a file in a directory the rest of the
     * process is not using would be describing somebody else's install.
     */
    stateDir,
    /*
     * What the four panels can do here, and the two that are deliberately blank.
     *
     * Each of these is present exactly when this host can honestly serve it,
     * because presence is what the panels read to decide whether to draw a
     * button at all — see `panels/contract.ts`, where an action a client was
     * never offered is an action it can never send.
     *
     *  - **`storePanel`** — both departments, assembled above.
     *  - **`mcpPool`** — omitted, and not defaulted, because this host runs no
     *    pool. `mcp-client.ts` keeps its pool as a module-level value behind
     *    `registerMcpIpc`, which wants an `ipcMain` there is none of here, and a
     *    pool minted for the panel would be a *second* copy of every server the
     *    phone connected. Without it the MCP panel offers no Connect and no
     *    Disconnect and reports what is configured, which is the true state of
     *    this machine rather than a reduced one.
     *  - **`staleAgents`** — omitted because it cannot be otherwise:
     *    `browser-signin.ts` imports `shell` from `electron` as a **value**, so
     *    the module throws at load under plain Node and would take the whole
     *    daemon down at import time, not at call time. The readiness panel omits
     *    that single row and says so in its own note.
     */
    ...(storePanel ? { storePanel } : {}),
    /*
     * And the machine's own browser, whose presence is the switch that decides
     * whether `browser.control` is advertised at all. See where it is built.
     */
    ...(machineBrowser ? { machineBrowser } : {}),
    broadcast,
  })

  // The wire exists now. See the declaration for why this is late-bound; the
  // push itself sends every connection its own per-device list.
  tellDevices = () => {
    remote.server.sessionsChanged()
  }

  /*
   * **And the browser's tab strip, when it moves.**
   *
   * `browser.surfaces.rows` has described itself as *"also pushed unsolicited
   * when the strip changes"* since it was written, and nothing sent that push —
   * so a window opened from a phone's own address bar appeared in the list the
   * next time somebody made it ask, and the iOS client asks once per connection
   * and then waits. The feature Asad described — *"it should browser and stream
   * here to interact"* — was a page that opened on the server and never showed
   * up on the phone that opened it.
   *
   * The binding store is the trigger because it is the one thing that already
   * knows: `attach`, `detach`, `windowClosed` and `windowMoved` all publish to
   * it, which covers a window a session opened and a window this phone opened
   * through `machineBrowser`. It fires once immediately on subscribe, which is
   * harmless — `tellSurfaces` sends nothing when nobody is watching.
   *
   * A window opened at the machine's own keyboard that no session ever binds is
   * not covered by this, and there is no such keyboard on a server.
   */
  const stopWatchingBindings = subscribeToBindings(() => {
    remote.server.surfacesChanged()
  })

  /*
   * **And who holds the handover, whenever the baton moves.**
   *
   * The half of *"it should browser and stream here to interact"* that stopped at
   * the login wall. `browser.handover` is the copilot on this server saying it
   * needs a person; the person is whoever is holding the phone that is watching
   * the page, and what the curtain handed them was the agent's sentence with the
   * pixels removed and the keyboard refused. `browser.handover.state` is what
   * turns that lock card into a question with a button under it, and this is the
   * event that sends it.
   *
   * Wired to the drive's own publisher rather than to a second subscription,
   * because `BrowserDrive.move` already fires on exactly the four transitions
   * this cares about — claimed, handed over, resumed, released. `handoverChanged`
   * re-reads the state per window at send time and says nothing at all when no
   * connected device may watch, so this costs a server with no phone on it
   * nothing.
   *
   * Assigned rather than passed because the browser is built long before this
   * endpoint is; see where `announceDriveState` is declared.
   */
  let announced: DriveAnnouncement = { handover: '', url: '' }
  announceDriveState = (status) => {
    const next = driveAnnouncements(announced, status)
    announced = next.now
    if (next.handoverMoved) remote.server.handoverChanged()
    if (next.addressMoved) remote.server.surfacesChanged()
  }

  const machines = registerMachinesIpc(desk, {
    storageDir: remoteStorageDir,
    // The same desk the host half uses. There is one pairing code on screen at a
    // time whether a phone or another machine is about to read it, and two desks
    // would mean two codes could be live with only one believed.
    desk: remote.desk,
    status: () => remote.server.status(),
    broadcast,
  })

  /*
   * The public demo policy, built last because it needs both halves.
   *
   * Approving lives in the trust store that `registerRemoteIpc` just built;
   * granting lives in the folder store the core built before it. Neither exists
   * when the options are read, which is why the policy is handed functions
   * rather than objects — and why `public-host.ts` can be tested without either.
   */
  if (options.publicHost) {
    publicHost = createPublicHost({
      config: options.publicHost.config,
      approve: (id) => remote.auth.approveDevice(id),
      grant: (id, folders) => core.grants.set(id, folders),
      end: options.publicHost.end,
      log: (message, detail) => logger.info('public-host', message, detail),
    })
    publicHost.begin()
    logger.warn('public-host', publicHost.sentence())
  }

  /*
   * Tell the caller about the next device to redeem a code.
   *
   * A channel rather than a push, because the desk answers `invoke` and nothing
   * else — every channel in this build wants an answer, and a fire-and-forget
   * send that routes nowhere is the bug this codebase keeps re-finding. So the
   * caller asks once and this does not answer until there is something to say.
   *
   * That is a held connection, not a poll: nothing wakes up on an interval,
   * nothing asks the host a question it has already asked, and the reply is
   * written the instant `authenticatorFor` reports the redemption. The deadline
   * exists only so a caller that walked away cannot hold a socket forever, and
   * `null` is a real answer — "nothing paired in the time you gave me" — rather
   * than an error.
   *
   * `seen` is how a caller says which devices it already knows about. `pair`
   * passes the roster it read before printing the code, which is what makes the
   * device that redeemed during the printing show up immediately instead of
   * being waited for a second time.
   */
  desk.handle('remote:device:next', async (_event, seen: unknown, timeoutMs: unknown) => {
    const known = new Set(
      Array.isArray(seen) ? seen.filter((id): id is string => typeof id === 'string') : [],
    )
    const already = paired.find((device) => !known.has(device.id))
    if (already !== undefined) return already

    // Bounded here rather than trusted from the caller: the control socket is a
    // local caller, but a wait a caller can set to infinity is a file descriptor
    // a caller can leak.
    const wait =
      typeof timeoutMs === 'number' && Number.isFinite(timeoutMs) && timeoutMs > 0
        ? Math.min(timeoutMs, MAX_PAIRING_WAIT_MS)
        : MAX_PAIRING_WAIT_MS

    return await new Promise<Device | null>((answer) => {
      const wake = (device: Device | null): void => {
        clearTimeout(timer)
        answer(device)
      }
      const timer = setTimeout(() => {
        waiting.delete(wake)
        answer(null)
      }, wait)
      // Never keeps the process alive on its own. A host whose only remaining
      // work is somebody's abandoned `pair` should still be able to stop.
      timer.unref?.()
      waiting.add(wake)
    })
  })

  /*
   * The parts idle mode actually switches off, and only the ones that are real.
   *
   * The specification lists file watchers, transcript tailing, port scanning,
   * usage polling and status detection. Three of those are renderer features this
   * build has never started, and claiming to have stopped them would be the
   * status output lying about work it never did — so they are reported under
   * `neverRunning` instead, and only these are registered.
   */
  idle.register({
    name: 'relay connection',
    // A way in. Never slept: a host that closed its own door while idle could
    // not be woken, which is the opposite of the feature.
    heldWhenIdle: true,
    sleep: () => undefined,
    wake: () => remote.server.wake(),
  })
  idle.register({
    name: 'session status detection',
    // Every live session runs its output through a headless terminal emulator so
    // "waiting for you" can be told from "still working". With nothing attached
    // there is nobody to tell. The emulator keeps being fed — losing the screen
    // would be losing state — but the settle timer and the classification stop.
    sleep: () => core.ptys.setWatched(false),
    wake: () => core.ptys.setWatched(true),
  })
  idle.register({
    name: 'localhost port scan cache',
    // The scan itself was never on a timer, and that is worth knowing rather
    // than fixing: `dev-ports.ts` only runs when something asks. What idling
    // drops is the four-second memo, so the first device to attach after a long
    // silence is answered by a fresh `lsof` rather than by a list from whenever
    // the last one left.
    sleep: () => resetDevPortsCache(),
    wake: () => undefined,
  })

  /*
   * The app's map of itself, before the endpoint that hands it out.
   *
   * This is the half of Asad's *"even from the office PC … or even if it is
   * starting from the server"* that was missing, and it was missing here rather
   * than anywhere near the feature. A session on his Office PC, asked what app
   * it was running inside, answered from `CLAUDE_CODE_ENTRYPOINT` and a `which
   * claude` and never named this one — because the endpoint below was started
   * with no `contextFor` at all, so every knock from every session on this host
   * was answered `204 No Content`. The window has had the channel since
   * 2026-08-19; this host had the socket and nothing to say down it.
   *
   * `opensInApp` is false and honestly so: `writeOpenShim` is a window call and
   * nothing here writes one, so a session on this host has the machine's own
   * `open` on its PATH. The documents say that rather than claiming otherwise.
   */
  const context = writeAppContext({
    dir: stateDir,
    version: hostVersion(),
    machineName: describeThisMachine().name,
    opensInApp: false,
    platform,
  })
  logger.info('headless', 'the app context for sessions on this host is written', {
    dir: context.dir,
  })

  /*
   * The hook endpoint, started the way the tests start it.
   *
   * `registerHookServer` wants an `ipcMain` so it can answer `hooks:server` for
   * a settings pane; there is no settings pane here, and `startHookServer` is
   * the seam that module already documents for exactly this. Failure is not
   * fatal — everything except hook callbacks works without it — which is the
   * same decision `index.ts` makes.
   *
   * `contextFor` is the same composition `index.ts` performs, and it is written
   * out a second time rather than shared, for the reason this whole file exists:
   * the two hosts answer the same question from different objects. `known` is
   * `core.ptys.list()` here and the window's pty manager there; there is no
   * renderer here to ask about a browser window. What must not differ is the
   * *answer*, which is why every piece of it comes out of the same two modules.
   */
  await startHookServer({
    dir: stateDir,
    contextFor: ({ event, sessionId }) =>
      MID_TURN_EVENTS.has(event)
        ? sessionId === null
          ? null
          : takeAnnouncement(sessionId, '', noVerbsLine(sessionId))
        : hookContext(sessionId, '', {
            // A session this host started, exited ones included — the same test
            // `index.ts` applies, so a `claude` somebody ran in an ssh session
            // on this box, whose hook fires anyway, is still told nothing.
            known: sessionId !== null && core.ptys.list().some((meta) => meta.id === sessionId),
            opensInApp: false,
            map: bootMapFor(event, sessionId),
            /*
             * And the sentence every session on this host gets, because this
             * build has no `deck-control` endpoint at all — see where the
             * copilot is declined below for why it cannot have one. So a session
             * here is never given the browser verbs, and the honest thing is for
             * it to know that rather than to go looking. `host-core.ts` writes
             * the reason down; this only reads it.
             */
            cannotDrive: sessionId === null ? null : noVerbsLine(sessionId),
          }),
  })
    .then(() => {
      /*
       * And the entries that make anything call it.
       *
       * The endpoint above has always started here; nothing on this machine has
       * ever been pointed at it. Installing hooks is a button in the desktop's
       * Setup pane and there is no pane here, so a server ran the socket and the
       * agents on it never knocked — no status, and, once there was one, no boot
       * context either. `installHooksWhereConfigured` says what it will and will
       * not touch; the log line is this host's substitute for the pane.
       *
       * The context is built here rather than taken from `hooks.ts`'s
       * `defaultContext`, and the difference is the one field: that one reads
       * `os.homedir()`, which is the account's real home and is right for a
       * desktop. This shell's authority on where anything lives is the paths
       * provider the daemon installed — `XDG_DATA_HOME` and a `--state-dir`
       * both move it — and a startup pass that wrote to a home the rest of this
       * process is not using would be writing into somebody else's account.
       */
      const home = homeDir()
      for (const status of installHooksWhereConfigured({
        home,
        backupDir: join(home, BRAND.projectConfigDir, 'hook-backups'),
        endpoint: currentHookEndpoint(),
      })) {
        logger.info('headless', 'session hooks', {
          provider: status.id,
          state: status.state,
          message: status.message,
        })
      }
    })
    .catch((error: unknown) => {
      logger.error('headless', 'the hook endpoint did not start; hook callbacks are off', {
        error: error instanceof Error ? error.message : String(error),
      })
      return null
    })

  /*
   * Read the installed WSL distributions at launch, not when something asks.
   *
   * A no-op off Windows, which is where this build normally runs — but a
   * headless host started *by* Windows against a distro still has to know which
   * side each remembered folder is on before it restores anything. Nothing is
   * started by the read: `wsl.exe -l -v` lists a registry key.
   */
  await core.wsl.refresh().then(
    () => core.wsl.resolveHome().catch(() => null),
    () => null,
  )

  async function status(): Promise<HostStatus> {
    return {
      version: hostVersion(),
      pid: process.pid,
      startedAt,
      stateDir,
      platform,
      facts,
      reachability,
      idle: idle.report(),
      remote: remote.server.status(),
      devices: remote.auth.listDevices(),
      kinds: core.kinds.list(),
      folders: core.grants.list(),
      sessions: core.ptys.list(),
      neverRunning: [
        'file watchers (a window feature; this build has no project tree)',
        'transcript tailing (a window feature; the clients read their own)',
        'usage polling (a window feature; nothing here draws a chart)',
        // The one entry in this list that changes what a *device* gets rather
        // than what this process spends, which is why it is also said at the
        // moment somebody approves one. This list is where a reader who counts
        // goes looking; `pair` is where they are standing when it matters.
        NO_COPILOT_HERE,
      ],
      publicHost: publicHost?.sentence() ?? null,
    }
  }

  /**
   * Put back the sessions that were open when this host last stopped.
   *
   * This is the half of the feature the headless build needs most. WSL shuts a
   * distribution down when the last terminal closes, taking this process and
   * every session in it — so "it came back and my work was gone" is the ordinary
   * case here, not the crash case. Wired to *starting*, never to a command: a
   * restore behind a button is the bug class this repository has paid for most.
   */
  async function restore(): Promise<void> {
    const saved = store().getOpenSessions()

    /*
     * Every restored folder has to be a known project first.
     *
     * A session in a folder that was never added as a project — one started from
     * a phone, which is every session here — has nowhere to be listed otherwise,
     * and the folder fallback a device sees when nothing has been granted to it
     * is built from the project list. So a host that restored without this would
     * come back with the sessions running and the folders they run in no longer
     * offered.
     */
    if (store().getPreferences().restoreSessions) {
      const known = new Set(store().getProjects().map((project) => project.path))
      for (const session of saved) {
        if (!known.has(session.cwd) && existsSync(core.statablePath(session.cwd))) {
          store().addProject(session.cwd)
          known.add(session.cwd)
        }
      }
    }

    try {
      await restoreOpenSessions({
        saved: () => saved,
        enabled: () => store().getPreferences().restoreSessions,
        plan: (sessions) =>
          planRestore(sessions, {
            folderExists: (cwd) => folderExists(core.statablePath(cwd)),
            // The core's, so a session on an added agent is planned the same
            // way here as in the window — and so an id the shipped table has
            // never had answers false instead of throwing mid-restore.
            canContinue: core.canContinue,
            configDir: (session) =>
              resolveProfile(profilesState(), {
                sessionProfileId: session.profileId ?? undefined,
                projectPath: session.cwd,
              }).configDir,
            conversation: conversationOnDisk,
          }),
        /*
         * The picture, which this host needs more than the desktop does rather
         * than less.
         *
         * There is no window here, and the paint is not for one: it goes into
         * the session's scrollback, and the scrollback is what an attaching
         * phone is sent — already flagged `replay: true` by `server.ts`. So the
         * machine that restarts on its own is exactly the machine where a
         * reconnecting device would otherwise find a live conversation behind a
         * blank screen.
         */
        // The same starter a phone's New Session goes through. A restore path
        // with its own spawn would be a second kind of session that only appears
        // after a restart, which is the hardest kind of difference to notice.
        spawn: core.startSession,
        // Nobody to announce to. Attached devices learn about the session from
        // the fanout's own list the moment they ask for one.
        announce: () => undefined,
        report: reportRestore,
      })
    } catch (error) {
      logger.error('headless', 'restoring the previous sessions failed outright', {
        error: error instanceof Error ? error.message : String(error),
      })
    }
  }

  async function stop(): Promise<void> {
    // The strip watcher first, and it is not tidiness: `subscribe` holds this
    // closure in a module-level set that outlives one host, so a daemon that
    // stopped and started in the same process — which every test in
    // `host.test.ts` does — would leave the previous host's `surfacesChanged`
    // wired to a wire that has gone.
    stopWatchingBindings()
    // And the drive's publisher, for the same reason one line up: the browser
    // host outlives this call by however long its Chromium takes to die, and a
    // late state change announcing down a wire that has gone would be the same
    // leak wearing the other feature's name.
    announceDriveState = () => {}
    // Deadlines first. A twenty-minute cap that fired during teardown would call
    // `end` on a host that is already ending, and on the demo box `end` is
    // `process.exit`.
    publicHost?.dispose()
    // Nobody is coming. A `pair` waiting on the next device would otherwise hold
    // its control connection open until its own deadline, against a host that
    // has stopped answering anything else.
    for (const wake of [...waiting]) {
      waiting.delete(wake)
      wake(null)
    }
    // The list is at its most accurate right now, with every session still
    // alive — and killing them fires an exit each, which would otherwise write
    // down that nothing was open. Freeze immediately after the honest flush.
    core.ledger.flush()
    core.ledger.freeze()
    core.ptys.killAll()
    // Asked is not finished: `killAll` signals, and each process writes its last
    // through `onExit` afterwards. A caller that removes the state directory the
    // instant this resolves would race those writes. See `PtyManager.drain`.
    await core.ptys.drain()
    machines.stop()
    /*
     * The tool endpoint and every token it minted, before the browser it points
     * at goes away.
     *
     * This order rather than the other one: `sessionTools.stop()` revokes the
     * per-launch tokens and removes their config files, and `stopDeckControlServer`
     * closes the socket, so after these two lines no call can arrive for a drive
     * that is being torn down. The reverse would leave a live listener in front
     * of a Chromium that is already closing, which is a refusal a caller reads as
     * a fault rather than as a shutdown.
     */
    sessionTools?.stop()
    await stopDeckControlServer().catch(() => undefined)
    // The server's browser is this host's to end — the CDP pipe closing never
    // kills Chromium, so this is the one place the child processes stop. [wave-2 Lane D]
    await browserHost.stop().catch(() => undefined)
    await remote.server.stop().catch(() => undefined)
    await stopHookServer().catch(() => undefined)
    await core.credentials.stop().catch(() => undefined)
  }

  return {
    core,
    desk,
    invoke: (channel, ...args) => desk.invoke(channel, ...args),
    broadcast,
    status,
    restore,
    stop,
    publicHost,
  }
}

/**
 * The MCP configuration as the Store panel needs to see it.
 *
 * Deliberately lossy, and the projection is the same one `mcp-client.ts`
 * performs behind `registerMcpIpc`: the store asks exactly two questions of what
 * is already configured — *is this row installed*, *is something else wearing
 * its name* — and both are answered by a name, a scope and one string to look a
 * package token up in. Handing it the whole `McpServerConfig`, environment
 * variables and all, would put every configured secret on a wire that has no
 * reason to carry one, which is why the values are dropped and only the key
 * names survive.
 *
 * It is written out a second time here rather than shared because the desktop's
 * copy is a private function inside `registerMcpIpc(ipcMain, …)` — a
 * registration this shell has no `ipcMain` to make — and the alternative was to
 * leave the whole MCP department off a server's Store panel. The two cannot
 * drift far: both are `loadServers` plus `quoteArgv`, the exported pair, so this
 * is a re-spelling of two calls rather than a second idea of what a configured
 * server is. `quoteArgv` in particular is not cosmetic — a server pointed at
 * `/home/me/My Folder` is two arguments in the configuration, and space-joining
 * them reads back as two *different* arguments, so the row would print a command
 * nobody configured.
 */
function configuredHere(projectPath: string | null): ConfiguredServer[] {
  return loadServers(projectPath).map((server) => ({
    name: server.name,
    scope: server.scope,
    commandLine:
      server.transport === 'stdio'
        ? quoteArgv([server.command ?? '', ...server.args].filter((part) => part !== ''))
        : (server.url ?? ''),
    transport: server.transport === 'stdio' ? 'stdio' : server.transport === 'sse' ? 'sse' : 'http',
    // Names only, sorted. The store's custom rows print them and neither the row
    // nor the edit form needs a value.
    envKeys: Object.keys(server.env).sort(),
  }))
}

/**
 * Say what happened, but only where saying it is not noise.
 *
 * Nothing is recorded for a session that came back — that is the entire point of
 * the feature. What *is* recorded is every session that did not, and why,
 * because a session quietly missing with no explanation anywhere is the version
 * of this that lies.
 */
function reportRestore(decisions: readonly RestoreDecision[]): void {
  for (const decision of decisions) {
    if (decision.outcome === 'resume') continue
    const detail = { folder: decision.session.cwd, agent: decision.session.provider }
    if (decision.outcome === 'fresh') logger.info('restore', `started clean: ${decision.reason}`, detail)
    else logger.warn('restore', `did not come back: ${decision.reason}`, detail)
  }
}

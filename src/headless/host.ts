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
import { hookContext, MID_TURN_EVENTS, takeAnnouncement } from '../main/browser-binding'
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
import { store } from '../main/store'
import { NO_COPILOT_HERE } from './cli'
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
  })

  const remote = registerRemoteIpc(desk, {
    sessions: core.sessions,
    folders: core.grants,
    // The same store the reach rule closes over. The headless daemon serves the
    // same protocol from the same fanout, so it enforces the same two kinds —
    // and a build where this was the missing argument would be a build where
    // every device is a guest with no folders.
    kinds: core.kinds,
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
     * And `deck-control` cannot be imported into this bundle today.
     * `deck-control/index.ts` imports `browserDrive` from
     * `../browser-drive-ipc`, which loads `browser-tab` and `browser-driver` —
     * `BrowserWindow`, `WebContentsView`, `nativeImage` — at module scope; and
     * its `live-surface.ts` imports `settings-extra`, which loads `app`,
     * `session` and `shell`. Both are real value imports rather than types, so
     * the bundle would not start. Giving a server a copilot means putting a seam
     * under those two edges the way `platform/paths.ts` did for `app.getPath`,
     * which is a change to the copilot's whole tool surface.
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
    ...(options.publicHost ? { offer: PUBLIC_HOST_OFFER } : {}),
    onDevicePaired: notePaired,
    storageDir: remoteStorageDir,
    // Served only if it was shipped. A headless install on a server may not
    // carry the web client at all, and a missing directory is a 404 on the
    // static path rather than a failure to start: the native clients come in
    // through the relay and never ask for a file.
    webRoot: options.webRoot ?? '',
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
    broadcast,
  })

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
          : takeAnnouncement(sessionId)
        : hookContext(sessionId, '', {
            // A session this host started, exited ones included — the same test
            // `index.ts` applies, so a `claude` somebody ran in an ssh session
            // on this box, whose hook fires anyway, is still told nothing.
            known: sessionId !== null && core.ptys.list().some((meta) => meta.id === sessionId),
            opensInApp: false,
            map: bootMapFor(event, sessionId),
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

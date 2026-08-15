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
import { resetDevPortsCache } from '../main/dev-ports'
import { startHookServer, stopHookServer } from '../main/hook-server'
import { currentPlatform, type Platform } from '../main/platform/host'
import { downloadsDir, userDataDir } from '../main/platform/paths'
import {
  describeReachability,
  readHostFacts,
  type HostFacts,
  type Reachability,
} from '../main/reachability'
import type { Device } from '../main/remote/device-auth'
import type { DeviceFolderGrant } from '../main/remote/folder-grants'
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
import { PROVIDERS } from '../main/providers'
import { store } from '../main/store'
import { ChannelDesk } from './desk'
import { hostVersion } from './version'

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
  const broadcast = (channel: string, payload: unknown): void => {
    if (channel !== REMOTE_CONNECTIONS_CHANNEL || !Array.isArray(payload)) return
    const mode = idle.attached(payload.length)
    logger.debug('headless', `now ${mode}`, { attached: payload.length })
  }

  const core = createHostCore({
    storageDir: remoteStorageDir,
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
    credentials: core.credentials,
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
    uploadsDir: options.uploadsDir ?? join(downloadsDir(), BRAND.name),
    // Always on, and there is no switch to find. `stop` stops the process; a
    // host that was running but refusing to answer would be the worst of both.
    autoStart: true,
    onStartFailure: (reason) => {
      logger.error('headless', 'remote access did not come up at launch', { reason })
    },
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
   * The parts idle mode actually switches off, and only the ones that are real.
   *
   * The specification lists file watchers, transcript tailing, port scanning,
   * cost polling and status detection. Three of those are renderer features this
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
   * The hook endpoint, started the way the tests start it.
   *
   * `registerHookServer` wants an `ipcMain` so it can answer `hooks:server` for
   * a settings pane; there is no settings pane here, and `startHookServer` is
   * the seam that module already documents for exactly this. Failure is not
   * fatal — everything except hook callbacks works without it — which is the
   * same decision `index.ts` makes.
   */
  await startHookServer().catch((error: unknown) => {
    logger.warn('headless', 'the hook endpoint did not start; hook callbacks are off', {
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
      folders: core.grants.list(),
      sessions: core.ptys.list(),
      neverRunning: [
        'file watchers (a window feature; this build has no project tree)',
        'transcript tailing (a window feature; the clients read their own)',
        'cost polling (a window feature; nothing here draws a chart)',
      ],
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
            canContinue: (provider) => PROVIDERS[provider].resumeArgs.length > 0,
            configDir: (session) =>
              resolveProfile(profilesState(), {
                sessionProfileId: session.profileId ?? undefined,
                projectPath: session.cwd,
              }).configDir,
            conversation: conversationOnDisk,
          }),
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
    // The list is at its most accurate right now, with every session still
    // alive — and killing them fires an exit each, which would otherwise write
    // down that nothing was open. Freeze immediately after the honest flush.
    core.ledger.flush()
    core.ledger.freeze()
    core.ptys.killAll()
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

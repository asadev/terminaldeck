/**
 * The copilot, on a headless server, driven from a phone.
 *
 * ## His words, and the reversal they undo
 *
 * > *"with the headless server the features and everything of the copilot will
 * > be there, but since it is headless they cannot be controlled from the
 * > headless server, so the mobile app has all the UI to control these
 * > features."*
 *
 * A headless host has no screen of its own, so the phone is the copilot's only
 * control surface — and until this module existed there was none. `cli.ts`'s
 * `NO_COPILOT_HERE` said, correctly for the build it was written in, that this
 * host *"has no copilot"*: `src/headless/host.ts` ran a `deck-control` endpoint
 * over the browser verbs alone, so a session here could open a page and nothing
 * else, and the owner's own phone was sent the guest shape — no copilot key in
 * its welcome, no fourth pill, the dead-end **Copilot on the server** card. The
 * reasoning `host.ts` gave was honest and is now spent: it said the missing
 * piece was *"an assembly, and it is a different lane's"* — a full `DeckControl`
 * with no window, its confirmations routed to a connected device, and a
 * `CopilotRuns` over this host's own core. This file is that assembly.
 *
 * ## Nothing here is a second implementation, and nothing loosens the boundary
 *
 * Every piece is the app's own, reused with no Electron under it — which is why
 * `createLiveSurface`, `DeckControl`, `ConsentBroker`, `ActionLog`,
 * `CopilotRuns`, `CopilotAccess` and `startCopilotRun` are imported rather than
 * re-written: `src/headless/seam.test.ts` walks this whole graph and fails on a
 * single runtime `electron` import, so the copilot a phone drives on a server is
 * governed by the same tier check, consent gate, budget and action log that
 * govern it on a Mac. The one difference a server forces is the confirmation:
 * there is no window to answer an `alter` call, so the `ConsentBroker` here
 * delivers every question to the connected device through the same
 * `CopilotRuns` relay the desktop uses as its *second* surface — and a device
 * that cannot be reached leaves the question `no-approver`, refused, never
 * waved through.
 *
 * ## The copilot here is a phone's run, not a pinned desk session
 *
 * On the desktop the copilot is a singleton in the sidebar and a phone spawns a
 * *run* of its own beside it. A server has no sidebar and no person pinning one,
 * so there is no desk copilot to start — the phone's run **is** the copilot on
 * this machine. {@link headlessDesk} reports that honestly: `status: stopped`
 * because nothing is pinned, `available` true when the tools are actually
 * listening, so the phone's Start button offers to begin a run rather than
 * refusing against a machine it is standing in for. Each device's run carries
 * its own token and its own device grant, exactly as on the desktop.
 *
 * ## The copilot is never shared with a guest
 *
 * This module advertises nothing on its own. `host.ts` passes what it returns to
 * `registerRemoteIpc` alongside `copilotEligible: (id) => kind === 'mine'`, and
 * that callback is the whole gate: a guest is sent no `copilot` key, draws no
 * pill, and is refused every `copilot.*` frame. `CopilotAccess` here reads the
 * same kind store per call, so revoking a device lands on its next frame.
 */

import { mkdirSync } from 'node:fs'
import { ActionLog } from '../main/deck-control/action-log'
import { browserTools } from '../main/deck-control/browser-tools'
import { ConsentBroker } from '../main/deck-control/consent'
import { DeckControl } from '../main/deck-control/control'
import { createLiveSurface } from '../main/deck-control/live-surface'
import {
  startDeckControlServer,
  type DeckControlEndpoint,
} from '../main/deck-control/server'
import { copilotFilesHere } from '../main/copilot-files'
import { copilotPaths, scaffoldCopilotHome } from '../main/copilot-home'
import { CopilotAccess } from '../main/remote/copilot-access'
import { CopilotRuns } from '../main/remote/copilot-runs'
import type { CopilotFiles } from '../main/remote/copilot-files'
import { typeAndSubmit } from '../main/remote/copilot-say'
import {
  startCopilotRun,
  tailForPhone,
  toCopilotSessions,
  watchRunChat,
} from '../main/remote/copilot-wiring'
import { getState as profilesState, resolveProfile } from '../main/profiles'
import type { SpawnFence } from '../main/copilot-session'
import type { BrowserDrive } from '../main/browser-driver'
import type { PtyManager } from '../main/pty-manager'
import type { CreateSessionInput, SessionMeta, SessionStatus } from '../shared/types'

/** What the copilot needs from the host it runs inside, and nothing else. */
export interface HeadlessCopilotDeps {
  /** `<userData>`. The copilot's own folder is `copilotPaths(userData).root`. */
  userData: string
  /** The server's own Chromium, so a run on this host gets the browser verbs. */
  browserDrive: BrowserDrive
  /** The live sessions. Same object every other surface on this host reads. */
  ptys: Pick<PtyManager, 'list' | 'write' | 'kill' | 'screen' | 'scrollback'>
  /**
   * The one session starter — `core.startSession`, never a second spawner.
   *
   * The full signature `startCopilotRun` needs: no guest and no confinement (the
   * copilot is the owner, not a guest — both spelled `undefined`), a records
   * fence, and the `--mcp-config` flags. `createLiveSurface` reads it as the
   * one-argument shape, which this wider one satisfies.
   */
  startSession(
    input: CreateSessionInput,
    guest?: undefined,
    confine?: undefined,
    fence?: SpawnFence,
    extraArgs?: readonly string[],
  ): Promise<SessionMeta>
  /** What activity last said about a session, for the surface's alerts and dots. */
  sessionStatus(id: string): { status: SessionStatus; at: number } | undefined
  /** Fan a server-owned settings change out to every watching device. */
  noteServerSettingsChanged(): void
  /** Is this device one of the owner's own? `core.kinds.kindOf(id) === 'mine'`. */
  isMine(deviceId: string): boolean
  /** Put a run's new session in front of the watching devices. */
  announce(meta: SessionMeta): void
  /** Fixed port, for tests. Production omits it and the OS picks one. */
  port?: number
  /** Log the tool endpoint coming up, or not. */
  onReady?(endpoint: DeckControlEndpoint): void
}

/** The copilot, assembled — what `host.ts` hands to `registerRemoteIpc`. */
export interface HeadlessCopilot {
  /**
   * The full `DeckControl`, holding this host's whole tool surface.
   *
   * Handed back so `host.ts` can point `serveWindows` and `createSessionTools`
   * at the *same* dispatcher a copilot run reaches — one tier check, one budget,
   * one action log for every door, exactly as `browser-headless-control.ts`
   * argues. A forwarded `window.call` is still gated to the browser family
   * upstream; a session-tools token still carries `SESSION_TOOLS`; only a
   * copilot run's own token sees the whole catalogue, tier-gated per call.
   */
  control: DeckControl
  /** The listening loopback endpoint, so `host.ts` can mint session tokens on it. */
  endpoint: DeckControlEndpoint
  /** The copilot as a paired device reaches it. Passed as `registerRemoteIpc`'s `copilot`. */
  copilot: CopilotRuns
  /** Who reaches it — one of the owner's own, and nobody else. */
  access: CopilotAccess
  /** The copilot's own files, as a phone reads and edits them. Passed as `copilotFiles`. */
  copilotFiles: CopilotFiles
  /** The action log the tool calls land in, for the phone's Activity view. */
  log: ActionLog
  /** Stop the runs and their grace timers. The server is stopped by `host.ts`. */
  stop(): void
}

/**
 * The `desk()` a phone reads about a server's copilot.
 *
 * There is no pinned desk session on a server — see the header — so `status` is
 * always `stopped` and `available` tracks the one thing that actually decides
 * whether a run can begin: are the tools listening. The account is resolved the
 * same way a run resolves it, so the name the phone shows and the name the run
 * spawns as cannot come apart.
 */
function headlessDesk(root: string, available: boolean): {
  status: 'stopped'
  profile: string | null
  signedIn: boolean | null
  available: boolean
  reason: string | null
  interactive: boolean
} {
  let profile: string | null = null
  try {
    profile = resolveProfile(profilesState(), { projectPath: root }).name
  } catch {
    // A profiles.json that is missing or unreadable is not a reason to refuse a
    // read the phone polls on every frame — the run resolves the real account
    // when it spawns, and null here draws as "the copilot" rather than a wrong
    // name.
    profile = null
  }
  return {
    status: 'stopped',
    profile,
    // Not probed here: resolving a sign-in shells out to the CLI and this is
    // read on every state frame. Null is "not asked", which the frame is typed
    // for, and the run surfaces a real sign-out at its first turn.
    signedIn: null,
    available,
    reason: available ? null : 'The copilot’s tools are not running on this server.',
    // No screen to show a driving scan on, so the machine-facing switch is off
    // and there is nothing here for `setInteractive` to move.
    interactive: false,
  }
}

/**
 * Bring the copilot up on this host: the tools, the run manager, the files.
 *
 * Ordered the way the wiring forces it. The consent broker must exist before
 * the control that holds it, and it delivers to a run manager that does not
 * exist until the endpoint does — so `runs` is a late-bound reference the broker
 * closes over, assigned the instant `CopilotRuns` is built, exactly the shape
 * `src/main/index.ts` uses for the same circularity.
 *
 * Never throws for a tool endpoint that will not bind: the host is entirely
 * usable without the copilot, and taking the launch down because a loopback port
 * could not be claimed would be the wrong trade by a wide margin — `host.ts`
 * `void`s this and reads `null` as "no copilot advertised", the same absence a
 * guest sees.
 */
export async function startHeadlessCopilot(deps: HeadlessCopilotDeps): Promise<HeadlessCopilot | null> {
  const paths = copilotPaths(deps.userData)
  // The folder the copilot works in and a run is launched into. Created — and
  // its CLAUDE.md and memory scaffolded — so the Files card has something to
  // show before the first run and a run's cwd exists when it spawns. Best
  // effort: a folder that cannot be made surfaces as a refused run, not a crash.
  try {
    mkdirSync(paths.root, { recursive: true })
    scaffoldCopilotHome(paths)
  } catch (error) {
    console.error('[headless] could not scaffold the copilot folder:', error)
  }

  // Late-bound, so the broker built next can deliver to it. See the header.
  let runs: CopilotRuns | null = null

  /*
   * Every confirmation goes to the connected device, and to nobody else.
   *
   * There is no window on a server, so the desktop's other surface is absent by
   * construction: `ask` returns false when no device is watching, which
   * `ConsentBroker` reads as "delivered to nobody who can answer" and resolves
   * `no-approver` rather than leaving an `alter` call to time out in silence.
   * The relay is `CopilotRuns` itself, the same object the desktop passes as its
   * second approver.
   */
  const consent = new ConsentBroker({
    ask: (request) => {
      try {
        return runs?.ask(request) === true
      } catch (error) {
        console.error('[headless] could not reach a connected device with a confirmation:', error)
        return false
      }
    },
    settled: (id, outcome) => {
      try {
        runs?.settled(id, outcome)
      } catch (error) {
        console.error('[headless] could not tell a connected device a confirmation closed:', error)
      }
    },
  })

  /*
   * The real app surface, over this host's own core — not the throwing proxy the
   * browser-only control used. This is what gives the copilot its sessions,
   * settings, transcripts and files; the browser verbs come in as `extraTools`
   * over this host's Chromium, so one dispatcher holds both.
   */
  // Kept as its own reference — `DeckControl.log` is private — so the run
  // manager's `log()` can tail it and the handle can hand it to `host.ts`.
  const log = new ActionLog({ dir: paths.log })
  const control = new DeckControl({
    surface: createLiveSurface({
      ptys: deps.ptys,
      startSession: deps.startSession,
      sessionStatus: deps.sessionStatus,
      noteServerSettingsChanged: deps.noteServerSettingsChanged,
      // No window to push at on a server; `tellWindow` is left off and its
      // absence reads as "there was nobody to tell", which is the truth.
    }),
    log,
    consent,
    extraTools: browserTools(deps.browserDrive),
  })

  let endpoint: DeckControlEndpoint
  try {
    endpoint = await startDeckControlServer({
      control,
      ...(deps.port === undefined ? {} : { port: deps.port }),
    })
  } catch (error) {
    console.error('[headless] the copilot tool endpoint did not start; no copilot is offered here:', error)
    return null
  }
  deps.onReady?.(endpoint)

  const access = new CopilotAccess({ isMine: deps.isMine })

  runs = new CopilotRuns({
    links: access,
    // The broker built above, so a run can list and answer its own questions.
    consent: () => consent,
    // A run's token lives in the endpoint's caller table, minted per device and
    // dropped when the run ends. `CopilotRuns` owns the token; this is the door.
    callers: {
      set: (token, grant) => endpoint.callers.set(token, grant),
      delete: (token) => endpoint.callers.delete(token),
    },
    endpoint: () => ({ url: endpoint.url }),
    copilotRoot: () => paths.root,
    // A phone's run is the copilot, told what it is by the same generated layer
    // the desk copilot gets, with this host's live tool catalogue behind it.
    spawn: (request) =>
      startCopilotRun(
        {
          startSession: deps.startSession,
          announce: deps.announce,
          stop: (id) => deps.ptys.kill(id),
          userData: () => deps.userData,
          tools: () => control.tools(),
        },
        request,
      ),
    isAlive: (id) => deps.ptys.list().some((meta) => meta.id === id && meta.exitCode === null),
    stop: (id) => deps.ptys.kill(id),
    // Prose into the run's pty as a real submit — a newline is not Return, and
    // one chunk is a paste. `copilot-say.ts` carries the measurement.
    say: (id, text) => typeAndSubmit((data) => deps.ptys.write(id, data), text),
    interrupt: (id) => deps.ptys.write(id, '\x03'),
    desk: () => headlessDesk(paths.root, true),
    cost: () => {
      const catalogue = control.cost()
      return { tools: catalogue.tools, turnTokens: catalogue.tokens }
    },
    // Nothing to move: no screen to show a driving scan on. Kept as a no-op
    // rather than omitted so the frame still answers rather than throwing.
    setInteractive: () => {},
    sessions: () =>
      toCopilotSessions(deps.ptys.list(), (id) => deps.sessionStatus(id)?.status ?? 'unknown'),
    log: (options) => tailForPhone(log.tail(2000), options),
    // This run's own transcript, named by the id `host-core.ts` put on its
    // spawn, so a phone follows the conversation it is having and not a
    // folder-newest one that belongs to a different run.
    chat: (sessionId, onUpdate) =>
      watchRunChat(
        paths.root,
        onUpdate,
        deps.ptys.list().find((meta) => meta.id === sessionId)?.agentSessionId ?? null,
      ),
  })

  return {
    control,
    endpoint,
    copilot: runs,
    access,
    // The folder is resolved on every call, the same "absent is the switch"
    // negotiation the desktop uses — pointing the copilot elsewhere is a setting
    // a person could change while a phone is connected, and a frozen path would
    // list a folder that has moved.
    copilotFiles: copilotFilesHere(() => copilotPaths(deps.userData)),
    log,
    stop: () => runs?.stopAll(),
  }
}

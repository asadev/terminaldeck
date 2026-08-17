/**
 * `deck-control`, assembled and wired.
 *
 * One call from the main process:
 *
 *     const deckControl = await registerDeckControlIpc(ipcMain, {
 *       ptys,
 *       startSession,
 *       sessionStatus: (id) => liveStatus.get(id),
 *       isApprover: (contents) => contents === mainWindow?.webContents,
 *       broadcast: (channel, payload) => send(channel, payload),
 *     })
 *
 * and one at `before-quit`: `await deckControl.stop()`.
 *
 * ## How the copilot is actually given these tools
 *
 * For a while it was not, and that is worth keeping rather than deleting: this
 * module wrote the config file, the server listened, the routine runner passed
 * it — and `copilot-session.ts` spawned the copilot with **no `--mcp-config`**.
 * So the agent a person talks to in the sidebar had the native Claude Code tools
 * and none of these, and every sentence in the product about it being "bounded
 * by the tool tiers and the confirmation gate" described a gate that was not in
 * the path, because there was nothing to gate. The copilot itself was honest
 * about it — its `CLAUDE.md` tells it to read its own tool list and say plainly
 * when a capability is not there — and honest is not the same as finished.
 *
 * The invocation, measured against the real CLI on this machine (Claude Code
 * 2.1.233) pointed at this server while the app was running:
 *
 *     claude --mcp-config <configPath> --strict-mcp-config …
 *
 * It connects with no approval prompt and answers `sessions_list` with the live
 * fleet. `--strict-mcp-config` is the caller's decision and it is the right one:
 * without it the copilot also inherits whatever MCP servers happen to be in the
 * person's own `~/.claude.json`, so its powers — and the action log that is
 * meant to account for them — would depend on something nobody thought of as
 * part of this feature.
 *
 * What blocked it was never knowledge, it was a seam: `CreateSessionInput`
 * carries no arguments and `host-core.ts` built argv from `spec.spawn.args`
 * alone, so there was nowhere for a spawn to put two flags. The seam is now
 * `startSession(input, guest, confine, fence, extraArgs)` — a positional
 * argument beside the other three that only a main-process caller may set,
 * rather than a field on the input, which crosses the preload bridge and would
 * let page code compose a session's argv. `providers.ts`'s `withLaunchArgs`
 * folds the flags in before the launch is wrapped, which matters inside WSL,
 * where the arguments are quoted into a shell command line and appending to the
 * finished array would hand them to the login shell instead of the CLI.
 *
 * Three other ways round it were tried and rejected, and they are written down
 * so nobody repeats them:
 *
 *  - **`.mcp.json` in the copilot's working directory.** Discovered, but held at
 *    "Pending approval" — project-scoped servers need a person to accept them,
 *    and `enableAllProjectMcpServers` in a settings file only bypasses that in
 *    print mode, which the pinned copilot is not.
 *  - **A user-scope `mcpServers` entry in `.claude.json`.** Trusted without a
 *    prompt, and it would now land in *the person's own* config — the copilot
 *    runs under their profile since the sandbox was removed — so every Claude
 *    session on the machine would get these tools. Wrong by a wide margin.
 *  - **An environment variable.** There is none; `claude --help` was read.
 *
 * The path travels as {@link DeckControlHandle.configPath}, read by
 * `src/main/index.ts` off the live handle at the moment the copilot starts —
 * never composed from {@link mcpConfigPath} at the copilot's end. The
 * difference is the whole of it: the path exists whether or not the server came
 * up, and a copilot pointed at a config for a server that failed to bind is one
 * that starts, believes it has tools, and cannot reach a single one.
 *
 * ## Two permission systems, and only one of them is this one
 *
 * The copilot runs as the person, in their own environment, so it reads their
 * `~/.claude/settings.json` like any other session they open — including
 * `permissions.defaultMode`. On a machine where that says `bypassPermissions`,
 * the *CLI* stops asking before it runs a command or edits a file. That is the
 * person's own setting, applied to their own agent, and this app does not
 * override it.
 *
 * It has no effect whatsoever on the gate in this module. A `defaultMode`
 * decides whether the CLI prompts *its own user* before dispatching a tool; the
 * confirmation here is asked by the desktop, of the person at the desk, on the
 * other side of an HTTP request, after `control.ts` has already checked the
 * tier — and an MCP client has no way to answer it or to skip it. The two are
 * not layers of one system, and the cases in `index.test.ts` under "the CLI's
 * permission mode is not this gate" pin that so nobody has to take this
 * paragraph's word for it: the tool call carries every field a client could
 * invent to wave itself through, and the answer still comes from the window.
 *
 * ## Started at boot, not when the copilot appears
 *
 * This repository's most expensive class of bug, stated in `CLAUDE.md` and paid
 * for twice, is a feature wired to a button and never wired to boot. A
 * `deck-control` that only starts when somebody opens the copilot is a
 * `deck-control` that has never run in the case that matters — a session
 * restored at launch, a routine firing before anybody clicked anything — and
 * the failure would be silent. So it starts with the rest of the IPC, exactly
 * as `hook-server.ts` does, and the token is what keeps it shut.
 *
 * A listening socket that can start sessions is a real thing to be careful
 * about, and the care is in `server.ts`: loopback only, a per-run bearer token
 * regenerated at every start, a Host check, and any request carrying an
 * `Origin` refused outright. The token reaches the copilot through a file
 * written by `remote/secret-file.ts` — owner-only on every platform it can be
 * made owner-only on, and not written at all where it cannot — and deleted at
 * shutdown.
 *
 * ## The renderer half
 *
 * The confirmation dialog and the Activity pane are a later pass and are not
 * built here. What is built here is the mechanism they will attach to, and it
 * is closed until they do: with no window registered as the approver, every
 * alter-tier call is refused with `no-approver`. That is the intended
 * behaviour, not a gap — a permission gate that is open by default reads as
 * protection while providing none.
 *
 * Channels:
 *  - `deck-control:status`           → what is running, and whether it is being logged
 *  - `deck-control:activity` (count) → the tail of `log/actions.jsonl`
 *  - `deck-control:consent-attach`   → become the approver; returns anything pending
 *  - `deck-control:consent-respond`  (id, approved) → { accepted }
 *  - pushes `deck-control:consent-request` (ConsentRequest)
 *  - pushes `deck-control:consent-settled` ({ id, outcome })
 *  - pushes `deck-control:action` (ActionRow)
 */

import { rmSync } from 'node:fs'
import { join } from 'node:path'
import { copilotPaths } from '../copilot-home'
import { userDataDir } from '../platform/paths'
import { writeSecretFile } from '../remote/secret-file'
import { onWebContentsDestroyed } from '../web-contents-teardown'
import { ActionLog, type ActionRow } from './action-log'
import { ConsentBroker, WINDOW_SURFACE, type ConsentOutcome, type ConsentRequest } from './consent'
import { DeckControl, type Budgets } from './control'
import { createLiveSurface, type LiveSurfaceDeps } from './live-surface'
import { SERVER_NAME, startDeckControlServer, stopDeckControlServer, type DeckControlEndpoint } from './server'
import type { ToolSpec } from './catalogue'
import type { DeckSurface } from './surface'
import { MAX_TOURS_KEPT, TourStage } from './tour-stage'
import { tourTool } from './tour-tool'

/* -------------------------------------------------------------- constants -- */

export const CONSENT_REQUEST_CHANNEL = 'deck-control:consent-request'
export const CONSENT_SETTLED_CHANNEL = 'deck-control:consent-settled'
export const ACTION_CHANNEL = 'deck-control:action'
/**
 * A validated tour, pushed to the one window that can play it.
 *
 * Sent rather than broadcast, unlike `consent-settled` above, and the asymmetry
 * is deliberate: a dialog that timed out has to be able to close itself in a
 * window that has since been replaced, whereas a tour is a thing happening on
 * *a* screen and a second window playing the same one would be two tours.
 */
export const TOUR_CHANNEL = 'deck-control:tour'

/**
 * The copilot's folder, asked of the module that owns it.
 *
 * `copilot-home.ts` defines the layout `COPILOT-DESIGN.md` specifies and
 * creates it; this module writes into two of its directories. Composing the
 * same paths here instead would be a second definition of where the copilot
 * lives, and the day one of them moved, the log would keep being written to a
 * folder nothing reads.
 */
function paths(): ReturnType<typeof copilotPaths> {
  return copilotPaths(userDataDir())
}

/** `<userData>/copilot/log` — the directory holding `actions.jsonl`. */
export function actionLogDir(): string {
  return paths().log
}

/**
 * Where the copilot session is told to find this server.
 *
 * A file rather than an inline `--mcp-config '{…}'` string, because argv is
 * readable from outside the process on some platforms and a bearer token in a
 * command line is a token in everybody's process list. Written through
 * `remote/secret-file.ts` — 0600 on POSIX, an ACL naming this account alone on
 * Windows — and rewritten on every start, so a copy left behind by a previous
 * run holds a token that authenticates nothing.
 *
 * It lives *inside* the copilot's folder, which was once load-bearing — that
 * folder was the only place a jailed copilot could open a file from — and is now
 * simply the right place: it is the session's working directory, so the CLI
 * finds it without an absolute path, and it sits beside the other files a person
 * opens that folder to read. The one consequence for the settings pane, which
 * lists this folder's contents, is that this file must not be rendered — it
 * contains the token.
 */
export function mcpConfigPath(): string {
  return join(paths().root, 'deck-control.json')
}

/**
 * The same server, told to a caller nobody is watching.
 *
 * A routine run is a Claude CLI process like the copilot is, so it reaches
 * these tools the only way a CLI process can — over MCP — and it needs a config
 * file of its own for one reason: it must carry
 * {@link DeckControlEndpoint.unattendedToken} rather than the ordinary one, so
 * that every alter-tier call it makes is refused at the boundary instead of
 * hanging on a confirmation dialog at three in the morning.
 *
 * Two files rather than one file with a flag, because the difference between
 * them is a *secret* and not a setting. A single config whose caller chose its
 * own mode would be a boundary the caller could step over; two files means the
 * privilege travels with the bytes, and a routine that somehow read the other
 * file would be a routine that had read the copilot's folder, which is a
 * different and much louder problem.
 *
 * It sits beside the attended one and is written the same way, through
 * `remote/secret-file.ts`, and removed the same way at shutdown.
 */
export function unattendedMcpConfigPath(): string {
  return join(paths().root, 'deck-control-unattended.json')
}

/* ------------------------------------------------------------------ types -- */

/**
 * The second place a confirmation can be shown and answered.
 *
 * The renderer was the only approver for as long as the only caller was the
 * copilot at this machine. A connected device now runs a copilot of its own, and
 * `COPILOT-REMOTE.md` §4 settles that it may answer its own run's questions —
 * the second factor being the separate copilot connection rather than the
 * geography of the desk.
 *
 * An interface rather than an import, for the reason every seam in this codebase
 * is one: `remote/copilot-runs.ts` knows about sealed channels and Claude CLI
 * processes, this file knows about `ipcMain` and a log, and neither has any
 * business importing the other. It also means the fan-out is exercised with a
 * plain object literal in a test with no socket anywhere near it.
 *
 * Absent is the switch. A build with no remote layer — the headless daemon,
 * `scripts/remote-host.ts`, the public demo box — delivers to the window and
 * nowhere else, which is exactly what it did before this existed.
 */
export interface ConsentRelay {
  /**
   * Show this question on the surface that owns it. True when it was delivered.
   *
   * Called for **every** question, including ones a device cannot answer,
   * because the surface also has to update its watch-only pending list. What it
   * returns is only whether an *approver* saw it — a pending row is not an
   * approver, and a question delivered to nobody who can answer must resolve
   * `no-approver` rather than sit until it times out.
   */
  ask(request: ConsentRequest): boolean
  /** A question closed. Withdraw the dialog, saying where it was answered. */
  settled(id: string, outcome: ConsentOutcome): void
}

export interface DeckControlDeps extends LiveSurfaceDeps {
  /**
   * Where a confirmation goes besides the window. See {@link ConsentRelay}.
   *
   * Optional and unset in every test that predates it, so the default is the
   * behaviour this app has always had: one approver, the renderer.
   */
  remoteApprover?: ConsentRelay
  /**
   * Is this the window allowed to answer a confirmation?
   *
   * Required, and there is no default. A default of "yes" would let any
   * renderer in the process approve an alter call; a default of "no" would look
   * like a broken feature. Making it a required argument means the question is
   * answered at the wiring site, where the caller knows which window is the
   * app's own.
   */
  isApprover(contents: Electron.WebContents): boolean
  /** Push to the renderer. Pass the main process's own `send`. */
  broadcast(channel: string, ...args: unknown[]): void
  /** Fixed port and shortened timeouts, for tests. */
  port?: number
  consentTimeoutMs?: number
  budgets?: Partial<Budgets>
  /**
   * Tools another feature contributes, held to exactly the same rules.
   *
   * A second entrance for the same reason `extraTools` exists on
   * `DeckControlOptions` at all: a feature that wants to give the copilot a
   * capability reaches it *through* the dispatcher rather than beside it. The
   * tour tool below is a closure over a stage this module builds, so it is
   * added here; the browser tools are a closure over a drive `src/main/index.ts`
   * builds, so they arrive through this field.
   *
   * Appended to the built-ins, never replacing them, and duplicate ids are
   * refused by `DeckControl` itself — a contributed tool that shadowed
   * `settings.write` would be the stricter of the two disappearing silently.
   */
  extraTools?: readonly ToolSpec[]
  /** Replaces the real app surface. Tests only; production passes nothing. */
  surface?: DeckSurface
  /** Overrides the copilot log directory. Tests only. */
  logDir?: string
}

export interface DeckControlHandle {
  endpoint: DeckControlEndpoint
  control: DeckControl
  log: ActionLog
  consent: ConsentBroker
  /** Path of the config file a copilot session should be launched with. */
  configPath: string
  /**
   * Path of the config file a *routine run* should be launched with.
   *
   * Different bytes, different token, different consequences — see
   * {@link unattendedMcpConfigPath}. A caller that handed this one to the
   * pinned copilot would give a person at the keyboard an agent that refuses
   * every confirmation they could have answered; a caller that handed the other
   * one to a routine would give an unwatched process the right to ask for
   * things nobody is there to allow. Both are wrong in ways a type cannot
   * catch, which is why they are two named fields rather than one and a flag.
   */
  unattendedConfigPath: string
  /**
   * Driving mode's state: what is playing, and the record of what was shown.
   *
   * On the handle because `src/main/index.ts` may want to ask — a menu item that
   * ends a tour, a status line — and because a test needs a way to reach the
   * stage without going through a window. Nothing about it is optional: an
   * assembly always has one, and one with no window to play in simply refuses
   * every tour with `no-window`, which is the honest behaviour rather than a
   * missing feature.
   */
  tours: TourStage
  stop(): Promise<void>
}

/* --------------------------------------------------------------- assembly -- */

let registered = false

/** Test seam: forget that the channels were claimed. Not used in the app. */
export function resetDeckControlForTests(): void {
  registered = false
}

export async function registerDeckControlIpc(
  ipcMain: Electron.IpcMain,
  deps: DeckControlDeps,
): Promise<DeckControlHandle> {
  // `ipcMain.handle` throws on a duplicate channel, so a second call — a hot
  // reload, or two call sites that each think they own startup — would take the
  // app down before a window opened.
  if (registered) throw new Error('deck-control: registerDeckControlIpc was called twice')
  registered = true

  const log = new ActionLog({ dir: deps.logDir ?? actionLogDir() })
  const surface = deps.surface ?? createLiveSurface(deps)

  /*
   * Exactly one window may answer, and it has to say so first.
   *
   * Held as a single reference rather than a set: this app has one window, and
   * a set would let a second renderer answer a question it never saw. When the
   * approver is replaced by a *different* WebContents, everything outstanding
   * is refused — the window that was asked is gone, so the answer can no longer
   * be the answer to the question that was shown.
   */
  let approver: Electron.WebContents | null = null

  const consent = new ConsentBroker({
    /*
     * Delivered to both surfaces, and delivered to the device **first**.
     *
     * Both, because either can answer and the race is the design: first answer
     * wins, and the loser withdraws its dialog saying where the answer came
     * from. `respond()` already returns false for a settled id, so the race
     * needs no lock — it needs both surfaces to have been asked.
     *
     * The device first because the window's `send` is the one that can throw,
     * and an ordering where a broken renderer stopped a connected phone from
     * ever seeing a question would make the desktop a single point of failure
     * for a feature whose whole point is that the desktop is not in the room.
     *
     * `delivered` is an OR and not an AND. One surface is enough for the
     * question to be live; requiring both would refuse every question raised
     * while a phone happened to be in a lift.
     */
    ask: (request) => {
      let delivered = false
      if (deps.remoteApprover) {
        try {
          delivered = deps.remoteApprover.ask(request) === true
        } catch (error) {
          // A relay that throws is the same situation as no relay: nobody on
          // that side saw the question. It must not stop the window being told.
          console.error('[deck-control] could not reach a connected device:', error)
        }
      }
      const target = approver
      if (target === null || target.isDestroyed()) return delivered
      try {
        target.send(CONSENT_REQUEST_CHANNEL, request)
        return true
      } catch (error) {
        console.error('[deck-control] could not reach the approver window:', error)
        return delivered
      }
    },
    settled: (id, outcome: ConsentOutcome) => {
      // Told to the whole renderer rather than only the approver: a dialog that
      // timed out has to close itself, and by then the window may already have
      // been replaced.
      deps.broadcast(CONSENT_SETTLED_CHANNEL, { id, outcome })
      try {
        deps.remoteApprover?.settled(id, outcome)
      } catch (error) {
        // Same rule as the broker's own `settled` guard: by this point the
        // answer has already been delivered to whoever was waiting on it, and a
        // subscriber failing to redraw must not fail the call.
        console.error('[deck-control] could not tell a connected device a question closed:', error)
      }
    },
    ...(deps.consentTimeoutMs === undefined ? {} : { timeoutMs: deps.consentTimeoutMs }),
  })

  /*
   * Driving mode's half, built here for the same reason the consent broker is:
   * it needs the approver window, and the approver window is a fact this
   * function holds and nothing below it does.
   *
   * `send` returns false when there is nobody to play a tour in, which is what
   * makes `tour.play` able to answer "there is no window" rather than reporting
   * success for a tour nobody saw. `watch` is the other half of the same care:
   * a renderer that reloads mid-tour must not leave this process believing a
   * tour is still playing, because the driving gate would then refuse every
   * change the copilot made for the rest of the run.
   */
  const tours = new TourStage({
    dir: deps.logDir ?? actionLogDir(),
    window: {
      send: (record, validated) => {
        const target = approver
        if (target === null || target.isDestroyed()) return false
        try {
          target.send(TOUR_CHANNEL, { record, stops: validated.plan.stops })
          return true
        } catch (error) {
          console.error('[deck-control] could not hand the tour to the window:', error)
          return false
        }
      },
      watch: (onGone) => {
        const target = approver
        if (target === null || target.isDestroyed()) {
          onGone()
          return () => {}
        }
        /*
         * A reload is a navigation, and it is the case that matters most: the
         * playhead is renderer state, so a reload has already ended the tour on
         * screen whether this side knows it or not. `DRIVING-MODE.md` §8 is
         * emphatic that a tour must never survive one — "a tour that resumed
         * itself after a crash is a screen that starts moving on its own" — and
         * the way to honour that from here is to notice and close the record.
         */
        const gone = (): void => onGone()
        target.on('did-start-navigation', gone)
        target.once('destroyed', gone)
        return () => {
          if (target.isDestroyed()) return
          target.off('did-start-navigation', gone)
          target.off('destroyed', gone)
        }
      },
    },
  })

  const control = new DeckControl({
    surface,
    log,
    consent,
    // The one tool contributed through `extraTools` rather than declared in
    // `catalogue.ts`, because it is a closure over the stage above and
    // `buildCatalogue()` takes no arguments. It is not special in any other
    // way: same tier check, same precheck, same budgets, same log row.
    extraTools: [tourTool(tours), ...(deps.extraTools ?? [])],
    driving: () => tours.driving(),
    ...(deps.budgets === undefined ? {} : { budgets: deps.budgets }),
    onRow: (row: ActionRow) => deps.broadcast(ACTION_CHANNEL, row),
  })

  const endpoint = await startDeckControlServer({
    control,
    ...(deps.port === undefined ? {} : { port: deps.port }),
  })

  /*
   * The config is written after the server is listening, because it carries the
   * port and the token the server just minted — so a refusal here arrives with
   * a live socket already open, and leaving it open would be a control plane
   * nothing can reach and nothing will ever close. `registered` goes back too,
   * or the retry the caller might make would be refused as a double
   * registration rather than attempted.
   */
  let configs: { attended: string; unattended: string }
  try {
    configs = writeMcpConfig(endpoint)
  } catch (error) {
    await stopDeckControlServer()
    registered = false
    throw error
  }
  const configPath = configs.attended

  /* ------------------------------------------------------------ channels -- */

  ipcMain.handle('deck-control:status', () => ({
    running: true,
    port: endpoint.port,
    server: SERVER_NAME,
    tools: control.tools().map((spec) => ({ id: spec.id, tier: spec.tier, title: spec.title })),
    /*
     * What the tool surface costs the copilot in context, every turn.
     *
     * Reported rather than kept internal because it is a number that only grows
     * and nobody would ever go looking for it. A settings pane that can show
     * "11 tools, about 2,200 tokens on every question" makes the standing charge
     * visible to the person paying it — and to the next agent about to add a
     * twelfth. See `MAX_CATALOGUE_TOKENS`.
     */
    catalogue: control.cost(),
    pendingConfirmations: consent.list().length,
    copilotSessions: control.copilotSessions(),
    logFile: log.file,
    // Said out loud rather than left to look quiet. A log that stopped
    // recording because the disk is full is a very different state from a
    // copilot that has not been asked to do anything.
    logging: !log.broken,
    // Deliberately not the token, and not the config path either. A renderer
    // has no use for either, and a secret that reaches page code is one
    // screenshot from leaving.
  }))

  ipcMain.handle('deck-control:activity', (_event, count?: unknown) => {
    const want = typeof count === 'number' && Number.isFinite(count) ? Math.trunc(count) : 200
    return log.tail(Math.min(Math.max(want, 1), 2000))
  })

  ipcMain.handle('deck-control:consent-attach', (event) => {
    if (!deps.isApprover(event.sender)) {
      throw new Error('deck-control: this window may not answer confirmations')
    }
    if (approver !== null && approver !== event.sender) {
      // A different window is taking over. Whatever was on the old one can no
      // longer be answered honestly, so it is refused now rather than left to
      // be approved by somebody who never saw it.
      consent.approverGone()
    }
    approver = event.sender
    onWebContentsDestroyed(event.sender, 'deck-control', () => {
      if (approver !== event.sender) return
      approver = null
      consent.approverGone()
    })
    return consent.list()
  })

  ipcMain.handle('deck-control:consent-respond', (event, id: unknown, approved: unknown) => {
    /*
     * Two checks, and both are needed.
     *
     * `isApprover` is the standing rule — only the app's own window may answer
     * at all. The identity check is the live one: the window that answers has
     * to be the window the question was actually delivered to. Without it, a
     * second renderer that passes the standing rule could answer a dialog it
     * never displayed.
     */
    if (!deps.isApprover(event.sender) || event.sender !== approver) {
      throw new Error('deck-control: this window may not answer confirmations')
    }
    if (typeof id !== 'string' || id.length === 0) throw new Error('deck-control: a request id is required')
    // Anything other than a literal `true` is a no. A dialog that sent
    // `undefined` because of a wiring mistake must not read as approval.
    //
    // `WINDOW_SURFACE` is the desktop, which may answer *any* question including
    // one a connected device raised — see `ConsentRequest.origin`. That is not a
    // loophole in the ownership rule; it is the rule. Somebody at this machine
    // can already do by hand whatever they are approving.
    const accepted = consent.respond(id, approved === true, WINDOW_SURFACE)
    return { accepted }
  })

  /* ------------------------------------------------------------- driving -- */

  /**
   * Everything a window says about a tour, on one channel.
   *
   * One handler rather than three, because the three things a player has to say
   * — *I have it*, *here is where I am*, *it is over* — are the same fact at
   * three moments, and splitting them across channels would mean three places
   * to remember the approver check.
   *
   * That check is the same one the confirmation channels make and it matters for
   * the same reason: this writes an audit record, and a second renderer must not
   * be able to write into the account of what the *first* one showed somebody.
   */
  ipcMain.handle('deck-control:tour-report', (event, raw: unknown) => {
    if (!deps.isApprover(event.sender) || event.sender !== approver) {
      throw new Error('deck-control: this window may not report on a tour')
    }
    if (typeof raw !== 'object' || raw === null) throw new Error('deck-control: a tour report is required')
    const message = raw as { kind?: unknown; tourId?: unknown; record?: unknown }
    const tourId = typeof message.tourId === 'string' ? message.tourId : ''
    const update =
      typeof message.record === 'object' && message.record !== null
        ? (message.record as Record<string, unknown>)
        : {}
    switch (message.kind) {
      case 'started':
        return { accepted: tours.acknowledge(tourId) }
      case 'progress':
        return { accepted: tours.progress(tourId, update) !== null }
      case 'ended':
        return { accepted: tours.end(tourId, update) !== null }
      default:
        throw new Error(`deck-control: unknown tour report ${String(message.kind)}`)
    }
  })

  /** Past tours, newest first. What the recap card and the Settings list read. */
  ipcMain.handle('deck-control:tours', (_event, count?: unknown) => {
    const want = typeof count === 'number' && Number.isFinite(count) ? Math.trunc(count) : 10
    return tours.list(Math.min(Math.max(want, 1), MAX_TOURS_KEPT))
  })

  return {
    endpoint,
    control,
    log,
    consent,
    tours,
    configPath,
    unattendedConfigPath: configs.unattended,
    stop: async () => {
      // The broker first: every outstanding question is refused before anything
      // it might have been guarding is torn down.
      consent.stop()
      // Then the tour, so a shutdown mid-tour closes its record rather than
      // leaving one whose `endedAt` is null for ever — which would read, months
      // later, as a tour that is somehow still playing.
      tours.stop()
      await stopDeckControlServer()
      // Both tokens are dead the moment the server stops, but a file full of a
      // dead token invites somebody to wonder whether it still works.
      for (const path of [configs.attended, configs.unattended]) {
        try {
          rmSync(path, { force: true })
        } catch (error) {
          console.error('[deck-control] could not remove the MCP config:', error)
        }
      }
      registered = false
    },
  }
}

/* ------------------------------------------------------------ mcp config -- */

/**
 * The file a copilot session is launched with:
 *
 *     claude --mcp-config <path> --strict-mcp-config
 *
 * `--strict-mcp-config` is the caller's decision, not this file's, but it is
 * the right one for the copilot: it means the copilot's tool surface is exactly
 * the native Claude Code tools plus these, rather than that plus whatever MCP
 * servers the user happens to have configured for their own work. A copilot
 * whose powers depend on somebody's unrelated `~/.claude.json` is a copilot
 * whose action log cannot be reasoned about.
 */
export function mcpConfigFor(
  endpoint: DeckControlEndpoint,
  caller: 'attended' | 'unattended' = 'attended',
): string {
  return `${JSON.stringify(
    {
      mcpServers: {
        [SERVER_NAME]: {
          type: 'http',
          url: endpoint.url,
          headers: {
            Authorization: `Bearer ${caller === 'unattended' ? endpoint.unattendedToken : endpoint.token}`,
          },
        },
      },
    },
    null,
    2,
  )}\n`
}

/**
 * Put that file on disk, through the one writer that knows how to keep a secret.
 *
 * This used to be a `writeFileSync` with `{ mode: 0o600 }` and a `chmod`
 * afterwards, with a comment explaining that the second step was not redundant
 * because a mode argument only applies at creation. That reasoning was right and
 * the file it protected was the wrong one on Windows, where a mode is a
 * synthesised number rather than a permission: `stat` reports 0666 for any
 * read-write file whatever was asked for, `chmod` can express only the read-only
 * attribute, and who may open the file is decided by an NTFS ACL that neither
 * call touched. Measured on a real Windows 11 machine — a file written exactly
 * the old way under `%APPDATA%\Terminal Deck` comes back
 *
 *     NT AUTHORITY\SYSTEM:(I)(F)
 *     BUILTIN\Administrators:(I)(F)
 *     DESKTOP-…\<user>:(I)(F)
 *
 * every entry inherited from the user profile. A second *standard* account on
 * that PC cannot read it, because the profile directory itself grants no
 * `Users` or `Everyone` entry; a second *administrator* account reads it
 * directly, with no elevation prompt and nothing to notice afterwards.
 *
 * Which would have been an argument worth having, except that this repository
 * already had it and settled it: `remote/secret-file.ts` exists because five
 * other files in this app were in exactly that position, and it strips the
 * inherited entries with `icacls /inheritance:r /grant:r <user>:(F)` on the file
 * and on its folder. This file holds a **bearer token for a server that can
 * start sessions and run tools on this machine**, which is not a weaker secret
 * than the ones already going through that door — so it goes through the same
 * door, and `remote/secret-file.test.ts` lists this module among the writers it
 * sweeps so that a future `writeFileSync` here fails a test rather than a user.
 *
 * The atomicity comes along with it and is worth naming separately: the old
 * write was not atomic, so a crash mid-write left the copilot pointing at half
 * a JSON document, which the CLI reports as a broken MCP server rather than as
 * a torn file.
 *
 * **This throws when the file cannot be protected**, which on Windows means
 * `icacls` refused or could not run. That is the writer's deliberate direction
 * of failure — nothing is written, rather than a token written where the rest
 * of the machine can read it — and the caller in `src/main/index.ts` already
 * catches it and logs "failed to start, copilot tools disabled". So the cost of
 * that refusal is the copilot losing its tools, not the app losing its launch.
 */
function writeMcpConfig(endpoint: DeckControlEndpoint): { attended: string; unattended: string } {
  const attended = mcpConfigPath()
  const unattended = unattendedMcpConfigPath()
  // The directory is `writeSecretFile`'s first argument rather than a `mkdir`
  // here: it creates it 0700, and on Windows it is the folder's inheritable ACL
  // that makes the temp file protected from the instant it exists.
  writeSecretFile(paths().root, attended, mcpConfigFor(endpoint, 'attended'))
  writeSecretFile(paths().root, unattended, mcpConfigFor(endpoint, 'unattended'))
  return { attended, unattended }
}

export type { ActionRow } from './action-log'
export type { ConsentRequest, ConsentOutcome } from './consent'
export type { CallResult } from './control'
export { DeckControl } from './control'
export type { DeckSurface, SessionView, Tier } from './surface'

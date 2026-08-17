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
 * written 0600 and deleted at shutdown.
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

import { chmodSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { copilotPaths } from '../copilot-home'
import { userDataDir } from '../platform/paths'
import { onWebContentsDestroyed } from '../web-contents-teardown'
import { ActionLog, type ActionRow } from './action-log'
import { ConsentBroker, type ConsentOutcome } from './consent'
import { DeckControl, type Budgets } from './control'
import { createLiveSurface, type LiveSurfaceDeps } from './live-surface'
import { SERVER_NAME, startDeckControlServer, stopDeckControlServer, type DeckControlEndpoint } from './server'
import type { DeckSurface } from './surface'

/* -------------------------------------------------------------- constants -- */

export const CONSENT_REQUEST_CHANNEL = 'deck-control:consent-request'
export const CONSENT_SETTLED_CHANNEL = 'deck-control:consent-settled'
export const ACTION_CHANNEL = 'deck-control:action'

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
 * command line is a token in everybody's process list. Mode 0600 and rewritten
 * on every start, so a copy left behind by a previous run holds a token that
 * authenticates nothing.
 *
 * It lives *inside* the copilot's folder deliberately: that folder is what the
 * copilot session is confined to, so a config outside it would be a file the
 * CLI cannot open. The one consequence for the settings pane, which lists this
 * folder's contents, is that this file must not be rendered — it contains the
 * token.
 */
export function mcpConfigPath(): string {
  return join(paths().root, 'deck-control.json')
}

/* ------------------------------------------------------------------ types -- */

export interface DeckControlDeps extends LiveSurfaceDeps {
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
    ask: (request) => {
      const target = approver
      if (target === null || target.isDestroyed()) return false
      try {
        target.send(CONSENT_REQUEST_CHANNEL, request)
        return true
      } catch (error) {
        console.error('[deck-control] could not reach the approver window:', error)
        return false
      }
    },
    settled: (id, outcome: ConsentOutcome) => {
      // Told to the whole renderer rather than only the approver: a dialog that
      // timed out has to close itself, and by then the window may already have
      // been replaced.
      deps.broadcast(CONSENT_SETTLED_CHANNEL, { id, outcome })
    },
    ...(deps.consentTimeoutMs === undefined ? {} : { timeoutMs: deps.consentTimeoutMs }),
  })

  const control = new DeckControl({
    surface,
    log,
    consent,
    ...(deps.budgets === undefined ? {} : { budgets: deps.budgets }),
    onRow: (row: ActionRow) => deps.broadcast(ACTION_CHANNEL, row),
  })

  const endpoint = await startDeckControlServer({
    control,
    ...(deps.port === undefined ? {} : { port: deps.port }),
  })

  const configPath = writeMcpConfig(endpoint)

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
    const accepted = consent.respond(id, approved === true, 'window')
    return { accepted }
  })

  return {
    endpoint,
    control,
    log,
    consent,
    configPath,
    stop: async () => {
      // The broker first: every outstanding question is refused before anything
      // it might have been guarding is torn down.
      consent.stop()
      await stopDeckControlServer()
      // The token is dead the moment the server stops, but a file full of a
      // dead token invites somebody to wonder whether it still works.
      try {
        rmSync(configPath, { force: true })
      } catch (error) {
        console.error('[deck-control] could not remove the MCP config:', error)
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
export function mcpConfigFor(endpoint: DeckControlEndpoint): string {
  return `${JSON.stringify(
    {
      mcpServers: {
        [SERVER_NAME]: {
          type: 'http',
          url: endpoint.url,
          headers: { Authorization: `Bearer ${endpoint.token}` },
        },
      },
    },
    null,
    2,
  )}\n`
}

function writeMcpConfig(endpoint: DeckControlEndpoint): string {
  const path = mcpConfigPath()
  // 0700 to match `copilot-home.ts`, which owns this directory: on a shared
  // machine the folder holds the copilot's memory as well as this token.
  mkdirSync(paths().root, { recursive: true, mode: 0o700 })
  /*
   * Written 0600 in two steps, and the second one is not redundant.
   *
   * `writeFileSync`'s mode is applied at *creation*, and the file usually
   * already exists from the previous run — in which case the mode argument is
   * ignored entirely and the file keeps whatever permissions it had. An
   * explicit `chmod` afterwards is what makes 0600 true on the second and every
   * subsequent start rather than only the first.
   */
  writeFileSync(path, mcpConfigFor(endpoint), { encoding: 'utf8', mode: 0o600 })
  try {
    chmodSync(path, 0o600)
  } catch (error) {
    // Windows has no POSIX mode and answers this with a no-op or an EPERM
    // depending on the filesystem; neither is a reason to refuse to start.
    console.error('[deck-control] could not tighten the MCP config permissions:', error)
  }
  return path
}

export type { ActionRow } from './action-log'
export type { ConsentRequest, ConsentOutcome } from './consent'
export type { CallResult } from './control'
export { DeckControl } from './control'
export type { DeckSurface, SessionView, Tier } from './surface'

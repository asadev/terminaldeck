/**
 * The New session dialog, drawn by the native macOS window.
 *
 * When the native window says it draws `new-session` (its `native-screens`
 * list), the page stops mounting `NewSessionDialog` and instead hands the
 * native window what that dialog was given — the folder and machine the press
 * named, the machines, the servers, this computer's name, how many sessions
 * each folder has (for "Delete N sessions?"), and the dialog's remembered
 * choices from this page's own storage. The native dialog asks the engine for
 * everything else on the same channels the page dialog uses, and when the
 * person presses Start it comes back here and runs the *same* code the page
 * dialog's `onStart` runs: one act, one implementation, whichever window drew
 * the question.
 *
 *     page → native   { type: 'new-session', seq, …context, memory }
 *     native → page   window.tdNewSession.run(name, arg):
 *                       'start'          { request, machineId, memory? }
 *                       'server'         { serverId, serverName, path }
 *                       'remove-project' path
 *                       'close'
 *
 * Inside Electron nothing installs `tdNewSession`, so nothing changes.
 */

import { isNativeShell, postToNative, type NativeHost } from '../shared/native-shell'
import { START_MEMORY_KEY, type SpawnRequest } from './session-start'
import { isProviderId } from './preferences'

/** The id the native window lists in `native-screens` when it draws this dialog. */
export const NATIVE_NEW_SESSION_SCREEN = 'new-session'

export interface NativeNewSessionContext {
  projectPath: string | null
  machineId: string | null
  machines: ReadonlyArray<{ id: string; name: string; folders: readonly string[] }>
  hereName: string
  servers: ReadonlyArray<{ id: string; name: string }>
  /** Folder → sessions running in it, for the Remove confirmation. */
  liveSessions: Record<string, number>
}

export interface NativeNewSessionMessage extends NativeNewSessionContext {
  type: 'new-session'
  /** Which opening this is: the same number again only updates (servers arrive late). */
  seq: number
  /** The dialog's remembered per-folder choices (`session-start.defaults.v1`), as stored. */
  memory: string | null
}

export interface NativeNewSessionHandlers {
  start(request: SpawnRequest, machineId: string | null): void
  startOnServer(serverId: string, serverName: string, path: string | null): void
  removeProject(path: string): void
  close(): void
}

function storage(): Storage | null {
  try {
    return typeof localStorage === 'undefined' ? null : localStorage
  } catch {
    return null
  }
}

export function newSessionMessage(
  seq: number,
  context: NativeNewSessionContext,
  store: Storage | null = storage(),
): NativeNewSessionMessage {
  let memory: string | null = null
  try {
    memory = store?.getItem(START_MEMORY_KEY) ?? null
  } catch {
    memory = null
  }
  return { type: 'new-session', seq, ...context, memory }
}

/** Ask the native window to show the dialog (or update the one it shows). */
export function openNativeNewSession(message: NativeNewSessionMessage, host?: NativeHost): void {
  postToNative(message, host)
}

/** What the native dialog decided, checked field by field — a bad one is refused, never guessed. */
export function readSpawnRequest(raw: unknown): SpawnRequest | null {
  if (typeof raw !== 'object' || raw === null) return null
  const r = raw as Record<string, unknown>
  if (typeof r.cwd !== 'string' || r.cwd.trim() === '') return null
  if (!isProviderId(r.provider)) return null
  const int = (value: unknown, fallback: number): number =>
    typeof value === 'number' && Number.isInteger(value) && value > 0 ? value : fallback
  return {
    cwd: r.cwd,
    provider: r.provider,
    resume: r.resume === true,
    profileId: typeof r.profileId === 'string' && r.profileId !== '' ? r.profileId : null,
    cols: int(r.cols, 100),
    rows: int(r.rows, 30),
    firstPrompt: typeof r.firstPrompt === 'string' ? r.firstPrompt : '',
    title: typeof r.title === 'string' && r.title !== '' ? r.title : null,
  }
}

export interface NewSessionCommands {
  run(name: string, arg?: unknown): boolean
}

export function newSessionCommands(
  current: () => NativeNewSessionHandlers | null,
  store: () => Storage | null = storage,
): NewSessionCommands {
  return {
    run(name, arg) {
      const handlers = current()
      if (handlers === null) return false
      switch (name) {
        case 'start': {
          if (typeof arg !== 'object' || arg === null) return false
          const body = arg as { request?: unknown; machineId?: unknown; memory?: unknown }
          const request = readSpawnRequest(body.request)
          if (request === null) return false
          // "Remember these choices": the native dialog worked out the new map with
          // the same rule the page dialog uses; it is kept where that dialog keeps it.
          if (typeof body.memory === 'string') {
            try {
              store()?.setItem(START_MEMORY_KEY, body.memory)
            } catch {
              // A full or blocked storage only costs the pre-fill next time.
            }
          }
          const machineId = typeof body.machineId === 'string' && body.machineId !== '' ? body.machineId : null
          handlers.start(request, machineId)
          return true
        }
        case 'server': {
          if (typeof arg !== 'object' || arg === null) return false
          const body = arg as { serverId?: unknown; serverName?: unknown; path?: unknown }
          if (typeof body.serverId !== 'string' || body.serverId === '') return false
          handlers.startOnServer(
            body.serverId,
            typeof body.serverName === 'string' ? body.serverName : '',
            typeof body.path === 'string' && body.path !== '' ? body.path : null,
          )
          return true
        }
        case 'remove-project':
          if (typeof arg !== 'string' || arg === '') return false
          handlers.removeProject(arg)
          return true
        case 'close':
          handlers.close()
          return true
        default:
          return false
      }
    },
  }
}

/** Installs `window.tdNewSession` in the native shell only. Returns the undo. */
export function publishNewSessionCommands(
  current: () => NativeNewSessionHandlers | null,
  host: NativeHost & { tdNewSession?: unknown } = globalThis as NativeHost & { tdNewSession?: unknown },
): () => void {
  if (!isNativeShell(host)) return () => {}
  const commands = newSessionCommands(current)
  host.tdNewSession = commands
  return () => {
    if (host.tdNewSession === commands) host.tdNewSession = undefined
  }
}

/** Folder → how many of the given sessions run in it. */
export function liveSessionCounts(sessions: ReadonlyArray<{ projectPath: string }>): Record<string, number> {
  const counts: Record<string, number> = {}
  for (const session of sessions) {
    if (session.projectPath === '') continue
    counts[session.projectPath] = (counts[session.projectPath] ?? 0) + 1
  }
  return counts
}

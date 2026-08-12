/**
 * IPC surface for cost and context tracking.
 *
 * One-line wiring from the main process:
 *
 *     import { registerCostIpc } from './cost-ipc'
 *     registerCostIpc(ipcMain)
 *
 * Watchers are keyed by project path and shared between windows, so opening the
 * same project twice tails its transcripts once. They are torn down when the
 * last subscriber unsubscribes or its window goes away.
 */

import type { IpcMain, IpcMainInvokeEvent, WebContents } from 'electron'
import { extname, resolve, sep } from 'node:path'
import {
  addUsage,
  emptyUsage,
  formatTokens,
  formatUsd,
  mergeAggregates,
  priceFor,
  sumUsage,
  type ResolvedPrice,
  type TokenUsage,
} from './cost'
import {
  claudeConfigDir,
  DEFAULT_MAX_AGE_MS,
  DEFAULT_MAX_SESSIONS,
  listTranscripts,
  readTranscript,
  transcriptDir,
  TranscriptWatcher,
  type ProjectSummary,
  type SessionSummary,
  type TranscriptFile,
} from './transcript'

/** Channel the renderer listens on for live updates. */
export const COST_UPDATE_CHANNEL = 'cost:update'

interface Entry {
  watcher: TranscriptWatcher
  subscribers: Set<WebContents>
  /** Resolves once the initial scan has finished. */
  started: Promise<void>
}

const entries = new Map<string, Entry>()

/**
 * Normalise a project path into the key watchers are shared under.
 *
 * `/a/b` and `/a/b/` are the same project; keying on the raw string starts two
 * watchers over the same directory and leaks one of them, because `cost:unwatch`
 * can only ever match the spelling it was given.
 */
function projectKey(cwd: unknown): string {
  if (typeof cwd !== 'string' || cwd.trim().length === 0) {
    throw new Error('cost: a project path is required')
  }
  return resolve(cwd)
}

/**
 * Everything the renderer sends is untrusted input, including a path.
 *
 * `cost:session` reads whatever file it is handed and reports fields lifted out
 * of it, so an unchecked path is an arbitrary-file-read primitive reachable from
 * the renderer. Transcripts only ever live under `<config>/projects`, so anything
 * that escapes that root — `../`, an absolute path elsewhere — is refused.
 */
function assertTranscriptPath(path: unknown): string {
  if (typeof path !== 'string' || path.length === 0) {
    throw new Error('cost: a transcript path is required')
  }
  const resolved = resolve(path)
  const root = resolve(claudeConfigDir(), 'projects')
  if (!resolved.startsWith(root + sep) || extname(resolved) !== '.jsonl') {
    throw new Error(`cost: refusing to read outside the transcript store: ${path}`)
  }
  return resolved
}

function broadcast(entry: Entry, summary: ProjectSummary): void {
  for (const contents of entry.subscribers) {
    if (contents.isDestroyed()) {
      entry.subscribers.delete(contents)
      continue
    }
    try {
      contents.send(COST_UPDATE_CHANNEL, summary)
    } catch (err) {
      // A window can be torn down between the check above and the send. This
      // runs inside the watcher's debounce chain, so letting it throw would
      // reject that chain and drop the update for every *other* subscriber too.
      entry.subscribers.delete(contents)
      console.error('[cost] dropping a dead subscriber:', err)
    }
  }
}

function ensureWatcher(cwd: string): Entry {
  const existing = entries.get(cwd)
  if (existing) return existing

  const entry: Entry = {
    watcher: new TranscriptWatcher({
      cwd,
      onUpdate: (summary) => broadcast(entry, summary),
    }),
    subscribers: new Set(),
    // Replaced immediately below — `start()` can only be called once `entry`
    // exists, because its updates route through the subscriber set.
    started: Promise.resolve(),
  }
  entry.started = entry.watcher.start().catch((err: unknown) => {
    console.error('[cost] watcher failed to start for', cwd, err)
  })

  entries.set(cwd, entry)
  return entry
}

function release(cwd: string, contents: WebContents): void {
  const entry = entries.get(cwd)
  if (!entry) return
  entry.subscribers.delete(contents)
  if (entry.subscribers.size === 0) {
    entry.watcher.stop()
    entries.delete(cwd)
  }
}

function releaseAll(contents: WebContents): void {
  for (const cwd of [...entries.keys()]) release(cwd, contents)
}

/**
 * Register the cost/context IPC handlers.
 *
 * Channels:
 *  - `cost:project`  (cwd)            -> ProjectSummary   one-shot totals
 *  - `cost:session`  (transcriptPath) -> SessionSummary   one session's totals
 *  - `cost:sessions` (cwd)            -> TranscriptFile[] what's on disk
 *  - `cost:watch`    (cwd)            -> ProjectSummary   subscribe; pushes `cost:update`
 *  - `cost:unwatch`  (cwd)            -> void
 *  - `cost:pricing`  (modelId)        -> ResolvedPrice | null
 *  - `cost:format`   ({usd?, tokens?})-> formatted strings
 */
export function registerCostIpc(ipcMain: IpcMain): void {
  ipcMain.handle('cost:project', async (_e: IpcMainInvokeEvent, cwd: string) => {
    const key = projectKey(cwd)
    // Reuse a live watcher when one exists — it already has the numbers, and a
    // second full scan of the same directory would be pure waste.
    const entry = entries.get(key)
    if (entry) {
      await entry.started
      return entry.watcher.summary()
    }

    // Bounded the same way the watcher is. Reading *every* transcript a project
    // has ever produced is unbounded work on the main process — some of these
    // directories hold hundreds of files and hundreds of megabytes.
    const cutoff = Date.now() - DEFAULT_MAX_AGE_MS
    const files = (await listTranscripts(transcriptDir(key)))
      .filter((file) => file.modifiedAt >= cutoff)
      .slice(0, DEFAULT_MAX_SESSIONS)

    const summaries: SessionSummary[] = []
    for (const file of files) {
      summaries.push(await readTranscript(file.path))
    }
    return summarizeStandalone(key, summaries)
  })

  ipcMain.handle('cost:session', (_e: IpcMainInvokeEvent, transcriptPath: string) =>
    readTranscript(assertTranscriptPath(transcriptPath)),
  )

  ipcMain.handle(
    'cost:sessions',
    (_e: IpcMainInvokeEvent, cwd: string): Promise<TranscriptFile[]> =>
      listTranscripts(transcriptDir(projectKey(cwd))),
  )

  ipcMain.handle('cost:watch', async (event: IpcMainInvokeEvent, cwd: string) => {
    const entry = ensureWatcher(projectKey(cwd))
    const contents = event.sender
    if (!entry.subscribers.has(contents)) {
      entry.subscribers.add(contents)
      // A window can close before its scan finishes; drop its subscriptions so
      // the watcher can shut down instead of tailing for nobody.
      contents.once('destroyed', () => releaseAll(contents))
    }
    await entry.started
    return entry.watcher.summary()
  })

  ipcMain.handle('cost:unwatch', (event: IpcMainInvokeEvent, cwd: string) => {
    release(projectKey(cwd), event.sender)
  })

  ipcMain.handle(
    'cost:pricing',
    (_e: IpcMainInvokeEvent, model: string): ResolvedPrice | null => priceFor(model),
  )

  ipcMain.handle(
    'cost:format',
    (_e: IpcMainInvokeEvent, value: { usd?: number; tokens?: number }) => ({
      usd: typeof value.usd === 'number' ? formatUsd(value.usd) : undefined,
      tokens: typeof value.tokens === 'number' ? formatTokens(value.tokens) : undefined,
    }),
  )
}

/** Roll session summaries up into a project summary without a watcher. */
function summarizeStandalone(cwd: string, sessions: SessionSummary[]): ProjectSummary {
  const ordered = [...sessions]
    .filter((session) => session.requests > 0)
    .sort((a, b) => b.lastActivityAt - a.lastActivityAt)

  // Rebuild per-model totals so mixed-model projects price correctly, then let
  // the shared aggregator do the money.
  const byModel = new Map<string, TokenUsage>()
  let requests = 0
  for (const session of ordered) {
    requests += session.requests
    for (const [model, usage] of Object.entries(session.usageByModel)) {
      byModel.set(model, addUsage(byModel.get(model) ?? emptyUsage(), usage))
    }
  }

  return {
    cwd,
    transcriptDir: transcriptDir(cwd),
    sessions: ordered,
    usage: sumUsage(byModel.values()),
    // Sum the sessions' already-priced money — re-pricing the pooled tokens
    // would value historical work at today's rates.
    cost: mergeAggregates(ordered.map((session) => session.cost)),
    requests,
    activeSessionId: ordered[0]?.sessionId ?? null,
    scanning: false,
    updatedAt: Date.now(),
  }
}

/**
 * IPC surface for token and context tracking.
 *
 * The channels are still spelled `cost:*`. They carry no cost — see "why this
 * app shows no prices" at the bottom of `cost.ts` — and the names stay because
 * a channel name is a contract with the preload bridge and the renderer on the
 * other side of it, not a label anybody reads.
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
import { resolve } from 'node:path'
import { addUsage, emptyUsage, formatTokens, sumUsage, type TokenUsage } from './cost'
import {
  DEFAULT_MAX_AGE_MS,
  DEFAULT_MAX_SESSIONS,
  isTranscriptPath,
  listTranscripts,
  readTranscript,
  SCAN_FACTOR,
  transcriptDir,
  transcriptDirs,
  TranscriptWatcher,
  type ProjectSummary,
  type SessionSummary,
  type TranscriptFile,
} from './transcript'
import { onWebContentsDestroyed } from './web-contents-teardown'

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
 * the renderer. Anything that escapes the transcript stores — `../`, an absolute
 * path elsewhere — is refused.
 *
 * The membership test moved into `transcript.ts` when there stopped being one
 * store. A confined session writes under its own device home, so a path that is
 * a perfectly real transcript now lives outside `~/.claude` — and widening this
 * check by hand here, and again in `chat-transcript.ts`, is how two copies of
 * one rule drift apart. The copy that drifts *open* is the one nobody notices.
 */
function assertTranscriptPath(path: unknown): string {
  if (typeof path !== 'string' || path.length === 0) {
    throw new Error('cost: a transcript path is required')
  }
  if (!isTranscriptPath(path)) {
    throw new Error(`cost: refusing to read outside the transcript store: ${path}`)
  }
  return resolve(path)
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
 * Tell every live watcher to look for a store that was not there before.
 *
 * Called when a session starts, and it exists for exactly one case: a session a
 * paired device asked for. Those run confined, with a home of their own, and
 * their transcripts land in that home rather than in `~/.claude` — so the first
 * session a *new* device starts creates a store that every open cost pane is
 * already past having looked for.
 *
 * An event rather than a poll, and an event the app already has rather than a
 * new one: the app made that home itself, one function call earlier. The
 * alternative is waiting for the filesystem to mention it, which
 * `TranscriptWatcher.refresh` explains is measurably unreliable at the moment it
 * matters most.
 *
 * A no-op when nothing is being watched, which is the ordinary case — nobody has
 * the cost pane open on the folder a phone just picked.
 */
export function refreshCostWatchers(): void {
  for (const entry of entries.values()) {
    void entry.watcher.refresh().catch((err: unknown) => {
      // One project's re-read must not take the others down with it, and there
      // is nothing for a user to do about it — the numbers simply refresh on the
      // next change instead.
      console.error('[cost] could not refresh a watcher:', err)
    })
  }
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
 *  - `cost:format`   ({tokens?})      -> formatted strings
 *
 * Two channels were removed with the pricing: `cost:pricing`, which answered a
 * model's per-million rates, and the `usd` half of `cost:format`. Neither had a
 * caller — `cost:format`'s did not even type-check, passing a bare number where
 * the handler read `value.usd` — and a main process that keeps computing money
 * for a renderer that no longer draws it is arithmetic that can only go stale.
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
    // Every store, merged and then capped, for the reason `TranscriptWatcher`
    // gives at the same point: the cap is an answer about the project, so
    // applying it per directory would make the number depend on how many devices
    // had been paired.
    const all = (await Promise.all(transcriptDirs(key).map((dir) => listTranscripts(dir))))
      .flat()
      .sort((a, b) => b.modifiedAt - a.modifiedAt)
    const recent = all.filter((file) => file.modifiedAt >= cutoff)
    const candidates = recent.slice(0, DEFAULT_MAX_SESSIONS * SCAN_FACTOR)

    /*
     * Read until `DEFAULT_MAX_SESSIONS` transcripts have actually recorded
     * something, not until that many files have been opened.
     *
     * This is the same correction `TranscriptWatcher.drain` makes, and it has to
     * be made here as well because this is the path the Overview tile takes on a
     * folder with nothing running in it — `cost:project`, not `cost:watch`. With
     * the cap counted in files, the tile read "Nothing recorded yet" over the
     * folder this app is built in, whose 40 newest transcripts are all sessions
     * that were opened and closed without being given anything to do. The
     * measurements, and why the ceiling is what it is, are on `SCAN_FACTOR`.
     */
    const summaries: SessionSummary[] = []
    let carrying = 0
    let read = 0
    for (const file of candidates) {
      if (carrying >= DEFAULT_MAX_SESSIONS) break
      read += 1
      const summary = await readTranscript(file.path)
      summaries.push(summary)
      if (summary.requests > 0) carrying += 1
    }

    // Whatever was never opened — too old, past the ceiling, or beyond the point
    // the scan had found what it needed. `summarizeStandalone` turns the count
    // into the sentence the tile prints; see `ProjectSummary.truncated`.
    return summarizeStandalone(key, summaries, all.length - read)
  })

  ipcMain.handle('cost:session', (_e: IpcMainInvokeEvent, transcriptPath: string) =>
    readTranscript(assertTranscriptPath(transcriptPath)),
  )

  ipcMain.handle(
    'cost:sessions',
    async (_e: IpcMainInvokeEvent, cwd: string): Promise<TranscriptFile[]> => {
      const found = await Promise.all(
        transcriptDirs(projectKey(cwd)).map((dir) => listTranscripts(dir)),
      )
      // `listTranscripts` sorts each directory newest first; the merge has to
      // re-sort, or a device's sessions would all land after the owner's however
      // recent they are.
      return found.flat().sort((a, b) => b.modifiedAt - a.modifiedAt)
    },
  )

  ipcMain.handle('cost:watch', async (event: IpcMainInvokeEvent, cwd: string) => {
    const entry = ensureWatcher(projectKey(cwd))
    const contents = event.sender
    entry.subscribers.add(contents)
    // A window can close before its scan finishes; drop its subscriptions so
    // the watcher can shut down instead of tailing for nobody.
    //
    // Keyed per WebContents, not per entry. The old guard was
    // `if (!entry.subscribers.has(contents))`, which attaches a fresh
    // `destroyed` listener for every *project* a window watches; `releaseAll`
    // clears this contents out of all of them, so one registration is enough.
    onWebContentsDestroyed(contents, 'cost', () => releaseAll(contents))
    await entry.started
    return entry.watcher.summary()
  })

  ipcMain.handle('cost:unwatch', (event: IpcMainInvokeEvent, cwd: string) => {
    release(projectKey(cwd), event.sender)
  })

  ipcMain.handle('cost:format', (_e: IpcMainInvokeEvent, value: { tokens?: number }) => ({
    tokens: typeof value?.tokens === 'number' ? formatTokens(value.tokens) : undefined,
  }))
}

/**
 * Roll session summaries up into a project summary without a watcher.
 *
 * `unread` is how many of the folder's transcripts were never opened — by the
 * age cutoff, by the ceiling on how far back the scan looks, or because it had
 * already found as much work as it was asked for. It is passed in rather than
 * inferred because only the caller knows what it skipped, and the tile's
 * sentence turns on it: a total drawn from part of a folder may not be described
 * as *"every request your agents made"* in it.
 */
function summarizeStandalone(
  cwd: string,
  sessions: SessionSummary[],
  unread: number,
): ProjectSummary {
  const ordered = [...sessions]
    .filter((session) => session.requests > 0)
    .sort((a, b) => b.lastActivityAt - a.lastActivityAt)

  // Rebuild per-model totals so a mixed-model project reports each model's
  // share rather than one undifferentiated heap.
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
    usageByModel: Object.fromEntries(byModel),
    requests,
    activeSessionId: ordered[0]?.sessionId ?? null,
    scanning: false,
    truncated: unread > 0,
    updatedAt: Date.now(),
  }
}

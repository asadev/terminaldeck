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
import { formatTokens } from './cost'
import {
  DEFAULT_MAX_AGE_MS,
  DEFAULT_MAX_SESSIONS,
  isTranscriptPath,
  listTranscripts,
  readTranscript,
  SCAN_FACTOR,
  SessionAggregator,
  transcriptDir,
  transcriptDirs,
  TranscriptTail,
  TranscriptWatcher,
  type ProjectSummary,
  type TranscriptEvent,
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
     *
     * What the loop keeps is each transcript's *aggregator*, not the summary it
     * produces. A summary is already a total, and a project total cannot be
     * built by adding totals together — the same API request appears in more
     * than one of them. `summarizeStandalone` makes that argument in full; the
     * fold is the thing that has to survive this loop for it to be able to.
     *
     * Forty folds rather than forty totals is the memory a `TranscriptWatcher`
     * already holds for any folder it is tailing — one small entry per request,
     * measured at a few megabytes for the largest project on this machine — and
     * here it is transient: nothing keeps them once the summary below is built.
     */
    const opened: SessionAggregator[] = []
    let carrying = 0
    let read = 0
    for (const file of candidates) {
      if (carrying >= DEFAULT_MAX_SESSIONS) break
      read += 1
      const aggregator = await readAggregate(file.path)
      opened.push(aggregator)
      if (!aggregator.isEmpty) carrying += 1
    }

    // Whatever was never opened — too old, past the ceiling, or beyond the point
    // the scan had found what it needed. `summarizeStandalone` turns the count
    // into the sentence the tile prints; see `ProjectSummary.truncated`.
    return summarizeStandalone(key, opened, all.length - read)
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
 * Roll a folder's transcripts up into a project summary without a watcher.
 *
 * `unread` is how many of the folder's transcripts were never opened — by the
 * age cutoff, by the ceiling on how far back the scan looks, or because it had
 * already found as much work as it was asked for. It is passed in rather than
 * inferred because only the caller knows what it skipped, and the tile's
 * sentence turns on it: a total drawn from part of a folder may not be described
 * as *"every request your agents made"* in it.
 *
 * ## Why this takes aggregators rather than `SessionSummary[]`
 *
 * It used to take the summaries and add them up — `requests += session.requests`
 * and a plain fold over each session's `usageByModel`. That is correct only if
 * no two transcripts record the same request, and they do, routinely: resuming
 * or forking a conversation copies its history into a new `.jsonl`, so an
 * assistant turn from Monday is written again in every branch taken from it.
 * Each `SessionAggregator` de-duplicates correctly inside its own file and can
 * see no other, so adding the totals counted those turns once per copy.
 *
 * Measured on the largest project on this machine, 2026-08-18: 11,110 distinct
 * requests recorded 11,598 times across forty transcripts — 488 of them in more
 * than one file — reporting 5,331,624,956 tokens where 5,121,344,002 were
 * spent. A 4.1% over-count, 210 million tokens, printed underneath a sentence
 * that says each request is counted once. It is the figure Asad asked about:
 * *"3.2 billion tokens… I don't know if it is true or not."*
 *
 * `TranscriptWatcher.summary()` was fixed for this and this path was not, which
 * left the two channels answering different numbers about the same folder. This
 * is not the rarer of the two: a watcher exists only while some session in the
 * folder is live, so a dashboard looking at a project nobody is working in — the
 * ordinary case for the Overview tile — is answered from here every time.
 *
 * The **per-session** figures deliberately still do not change, for the reason
 * the watcher gives at the same point: a resumed conversation really did re-send
 * the history it inherited, and subtracting it there would make a session's own
 * tile disagree with its own transcript. It is only the *project* sum that must
 * not add one request to itself twice.
 */
function summarizeStandalone(
  cwd: string,
  transcripts: SessionAggregator[],
  unread: number,
): ProjectSummary {
  // Sorted once, newest first, and used for both answers below. The watcher
  // sorts twice — its sessions by `lastActivityAt`, its aggregators by
  // `activityAt` — which are the same number read off two objects. Doing it once
  // here makes it impossible for the order a duplicated request is attributed in
  // to drift from the order the sessions are listed in.
  const live = transcripts
    .filter((agg) => !agg.isEmpty)
    .sort((a, b) => b.activityAt - a.activityAt)
  const ordered = live.map((agg) => agg.summary())

  /*
   * The project total is folded by an aggregator of its own, fed one synthetic
   * event per distinct request.
   *
   * `TranscriptWatcher.summary()` writes this fold out by hand and the obvious
   * move was to copy it across. It cannot be copied faithfully: the bucketing
   * turns on `rateKey`, which is private to `transcript.ts` and gives fast mode
   * a column of its own, and on the `UNKNOWN_MODEL` sentinel for a request that
   * carries tokens but names no model. Those keys have to come out as the same
   * strings every session's own `usageByModel` uses, or the Overview tile's list
   * of models and a session's own would name two different sets of things — and
   * this file already carries a note, on `assertTranscriptPath`, about what
   * happens to a rule that gets written out twice.
   *
   * Feeding the requests back through `add` also means the de-duplication is not
   * re-implemented here: `add` keeps one entry per key and refuses a key it has
   * already counted, which is exactly the `seen` set the watcher maintains,
   * living in the code that decides what a key is. Newest transcript first, so a
   * request recorded in two files is attributed to the copy still being written
   * to — the one a person is most likely looking at.
   */
  // The constructor names the transcript an aggregator is folding, and this one
  // folds a folder rather than a file. Nothing reads the name: only `requests`,
  // `usage` and `usageByModel` are taken off its summary, and every other field
  // of `ProjectSummary` is built from the real sessions above.
  const project = new SessionAggregator(cwd)
  for (const agg of live) {
    const { keyed, anonymous } = agg.contributions()
    for (const [key, entry] of keyed) project.add(asProjectEvent(entry, key))
    // Nothing identifies these, so nothing can prove one is a copy of another.
    // Counting them is the conservative error — dropping them would silently
    // lose real spend — so they go in without a key and `add` counts each one.
    for (const entry of anonymous) project.add(asProjectEvent(entry))
  }
  const total = project.summary()

  return {
    cwd,
    transcriptDir: transcriptDir(cwd),
    sessions: ordered,
    usage: total.usage,
    usageByModel: total.usageByModel,
    requests: total.requests,
    activeSessionId: ordered[0]?.sessionId ?? null,
    scanning: false,
    truncated: unread > 0,
    updatedAt: Date.now(),
  }
}

/**
 * One request's contribution to a total, as `SessionAggregator` hands it over.
 *
 * Derived from the method rather than re-declared, because `transcript.ts` keeps
 * the interface to itself. Writing the shape out again here would be a second
 * declaration of a type with one authority, free to drift the moment a field is
 * added to it; derived, it cannot. Exporting `Contribution` from `transcript.ts`
 * and importing it is the tidier end state and is owed there, not here.
 */
type Contribution = ReturnType<SessionAggregator['contributions']>['anonymous'][number]

/**
 * One de-duplicated request, dressed back up as the event it was folded from.
 *
 * Four fields are real: the model, the speed, the usage, and the key that
 * identifies the request. `type` and `timestamp` are present because
 * `TranscriptEvent` requires them, and neither is read on this path — `add`
 * keys its work off `usage`, never off the line's type, and the project's clock
 * comes from the per-session summaries, which were folded from the real lines.
 *
 * `isSidechain: false` is the one field that states something not known. A
 * contribution does not record whether its request belonged to a sub-agent, so
 * it cannot be reconstructed from one, and it costs nothing here because
 * `ProjectSummary` has no `sidechainRequests` field for it to be wrong in. The
 * per-session count, which is the one that is drawn, still comes from the real
 * transcript.
 *
 * The key goes in as `messageId` whatever it originally was. `add` reads
 * `messageId ?? requestId ?? uuid`, so all three collapse into a single
 * namespace the moment they are compared — exactly as they already do in the
 * watcher's `seen` set, which is one flat `Set<string>` over the same three
 * sources.
 */
function asProjectEvent(contribution: Contribution, key?: string): TranscriptEvent {
  return {
    type: 'assistant',
    messageId: key,
    model: contribution.model,
    speed: contribution.speed,
    usage: contribution.usage,
    timestamp: 0,
    isSidechain: false,
  }
}

/**
 * Read a whole transcript and keep the fold, not only its total.
 *
 * `readTranscript` in `transcript.ts` is this function with a `.summary()` on
 * the end, and it stays the right call wherever the question is about one
 * conversation — `cost:session` above still uses it. What a summary cannot
 * answer is the question a *project* total has to ask: which requests were
 * these, so that one recorded in two transcripts is counted once. The answer
 * lives on the aggregator, behind `contributions()`, and a summary has already
 * thrown it away.
 *
 * The loop is a hand copy of `readTranscript`'s, and that is a debt rather than
 * a design. The honest shape is a `readAggregate` in `transcript.ts` with
 * `readTranscript` as its one-line wrapper, so there is one loop and one place
 * to get the easy part wrong — `reset`, where a rewritten transcript has to
 * discard everything folded from the bytes that are gone. It is written here
 * because this change is confined to this file; if that loop ever changes over
 * there, it has to change here too.
 */
async function readAggregate(path: string): Promise<SessionAggregator> {
  const tail = new TranscriptTail(path)
  const aggregator = new SessionAggregator(path)
  for (;;) {
    const { events, reset, more } = await tail.read()
    if (reset) aggregator.reset()
    for (const event of events) aggregator.add(event)
    if (!more) break
  }
  return aggregator
}

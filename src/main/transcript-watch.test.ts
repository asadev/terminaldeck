import { mkdtempSync, mkdirSync, appendFileSync, readFileSync, realpathSync, utimesSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { formatTokens, totalTokens } from './cost'
import { encodeProjectPath, TranscriptWatcher, type ProjectSummary } from './transcript'

/**
 * The ceilings these tests state for themselves, and why they are not one
 * number.
 *
 * `vitest.config.ts` raises the *default* timeout to 30 s on Windows, with a
 * measurement behind it: the runner shows roughly 25x scheduling variance on
 * unchanged code. An explicit third argument to `it()` overrides that default
 * outright — so every case in this file opted out of the allowance the config
 * exists to provide, using a number chosen on a Mac.
 *
 * That matters more here than almost anywhere else in the suite, because this
 * file is the file whose subject is *file watching*, and the two platforms do
 * not watch the same way. macOS gets FSEvents; Windows gets
 * ReadDirectoryChangesW, with different coalescing, different latency and a
 * different relationship to the antivirus scanner that opens every file the
 * moment it is written. The numbers below were tuned against FSEvents and were
 * never evidence about the other one.
 *
 * So the shape `readiness.test.ts` established is used: a named constant per
 * class of cost, POSIX side unchanged — that is where the work is done and a
 * tight ceiling there is what would notice a real slowdown — and a Windows side
 * with room over the observed variance. `vitest.config.ts` endorses exactly
 * this: "a test whose cost is genuinely structural still states its own ceiling
 * with its own reasoning."
 *
 * Nothing here claims an operation *should* take this long. A test that never
 * settles is still red, just later.
 */
const WATCH_MS = process.platform === 'win32' ? 30_000 : 10_000
const WATCH_SLOW_MS = process.platform === 'win32' ? 45_000 : 15_000
const WATCH_SLOWEST_MS = process.platform === 'win32' ? 60_000 : 20_000

/**
 * The ceiling on any one {@link until}, and it is deliberately below the
 * *smallest* budget any `it()` in this file states.
 *
 * Whichever of the two fires first is the failure you get to read, and until
 * today the wrong one always did: the helper's ceiling was thirty seconds and
 * every case here is given at most twenty, so the message it exists to print —
 * which condition, with the watcher's own numbers beside it — could never
 * appear on any platform. What appeared instead was
 * `Error: Test timed out in 20000ms`, which says nothing about what the watcher
 * did, and cost an hour on 2026-08-21 working out that the answer was "nothing:
 * the event was never delivered".
 *
 * Derived from `WATCH_MS` rather than written out, so a budget that moves takes
 * this with it. Almost nothing goes anywhere near it: every wait that is about a
 * number is now driven through `watcher.refresh()`, leaving a debounce and a
 * file read. The two that still wait on a filesystem notification — named in
 * {@link until} — are the ones this exists to speak for.
 */
const UNTIL_MS = WATCH_MS - (process.platform === 'win32' ? 5_000 : 2_000)

/**
 * A scratch config directory, spelled the way the OS will spell it back.
 *
 * `os.tmpdir()` is `/var/folders/…` on macOS, which is a symlink to
 * `/private/var/…`, and `C:\Users\RUNNER~1\AppData\Local\Temp` on a Windows
 * runner, which is an 8.3 short name. A file watcher reports the resolved path,
 * so handing it the unresolved one makes every event arrive under a name the
 * watcher's own bookkeeping does not recognise. Resolved once, here, rather
 * than debugged again per test.
 */
function scratch(prefix: string): string {
  return realpathSync(mkdtempSync(join(tmpdir(), prefix)))
}

/**
 * One device's confined home, built exactly the way the app builds it, and
 * returning the store the agent will write into.
 *
 * `prepareDeviceHome` in `confine/index.ts` is the real thing, and this mirrors
 * it rather than calling it so that a test fixture cannot quietly become a test
 * of itself. What matters here is the *order*: the home, its `tmp` — which is
 * the session's `TMPDIR` and must never be mistaken for a store — and the empty
 * `.claude/projects`, all before any transcript exists. That is what the app
 * does, and a fixture that made all four levels in one burst would be testing a
 * sequence that never happens.
 */
function deviceHome(root: string, key: string): string {
  mkdirSync(join(root, key, 'tmp'), { recursive: true })
  const store = join(root, key, '.claude')
  mkdirSync(join(store, 'projects'), { recursive: true })
  return store
}

function line(
  id: string,
  output: number,
  extra: { model?: string; timestamp?: string } = {},
): string {
  return `${JSON.stringify({
    type: 'assistant',
    uuid: `${id}-u`,
    requestId: `req_${id}`,
    timestamp: extra.timestamp ?? new Date().toISOString(),
    cwd: '/fake/project',
    sessionId: 'sess-live',
    isSidechain: false,
    message: {
      id,
      model: extra.model ?? 'claude-opus-5',
      role: 'assistant',
      usage: {
        input_tokens: 1,
        output_tokens: output,
        cache_creation_input_tokens: 1000,
        cache_read_input_tokens: 5000,
        cache_creation: { ephemeral_1h_input_tokens: 1000, ephemeral_5m_input_tokens: 0 },
      },
    },
  })}\n`
}

/**
 * A transcript that exists and records no request, byte-for-byte what the CLI
 * writes.
 *
 * Copied from `~/.claude/projects/-Users-apple-Projects-terminaldeck` on
 * 2026-08-18, where 94 of 104 files looked exactly like this: 256 bytes, four
 * metadata lines, no `usage` anywhere. One is written every time a session is
 * opened and closed without being given anything to do, which on a machine that
 * restores its sessions at launch is most of them.
 *
 * It matters that this is the real shape rather than an invented "empty file".
 * These lines carry no `timestamp`, so the aggregator that reads one has an
 * activity time of zero — which is the reason the defect below could hide in a
 * cap that sorts by activity.
 */
function shellTranscript(id: string): string {
  return (
    `${JSON.stringify({ type: 'ai-title', aiTitle: 'Update the terminal', sessionId: id })}\n` +
    `${JSON.stringify({ type: 'agent-name', agentName: 'Update the terminal', sessionId: id })}\n` +
    `${JSON.stringify({ type: 'mode', mode: 'normal', sessionId: id })}\n` +
    `${JSON.stringify({ type: 'permission-mode', permissionMode: 'bypassPermissions', sessionId: id })}\n`
  )
}

/**
 * Wait until the watcher itself reports something, rather than sleeping a span
 * and hoping.
 *
 * These tests drive a real `TranscriptWatcher` over a real directory, so every
 * append reaches it through an OS filesystem notification — and that
 * notification carries no latency guarantee. It usually lands in a few
 * milliseconds; on a machine running the whole suite in parallel it can take
 * hundreds. A fixed `sleep` therefore encodes a guess about machine speed into
 * a pass/fail, which is exactly what made the `maxSessions` case below fail
 * about one run in four: instrumenting the watcher showed the append event had
 * simply not been delivered yet when the assertions ran, so the file was never
 * enqueued and never read.
 *
 * Waiting on the condition makes the outcome depend on what the watcher did
 * rather than on how busy the machine was — a slow machine now gets the same
 * answer, just later. The ceiling is not a tuned timeout: it exists only so a
 * watcher that genuinely never fires reports a readable failure instead of
 * hanging until vitest kills the test.
 *
 * ## What it is *not* enough for, learned on 2026-08-21
 *
 * The paragraph above assumed the notification is slow. Twelve copies of this
 * file run at once say otherwise: it can be **missing**. An `add` for a file
 * created seconds after the watch was established went undelivered twice in ten
 * runs, and a `change` for a file the watcher already had open once in
 * thirty-six — no error logged, no fd limit anywhere near. A condition that is
 * never going to become true is not helped by a longer wait, and both cases in
 * this file that went red under that load went red exactly that way: each sat
 * out its whole budget waiting for an event that was not coming, and the runner
 * killed it before the thirty-second ceiling could say a word about what it had
 * been waiting for.
 *
 * So the appends are now put in front of the watcher by `watcher.refresh()`,
 * which re-reads the directory and cannot miss what is already on disk — the
 * same call `index.ts` makes from the hook that says a session has appeared.
 * What is left waiting on a real filesystem event is the two cases whose claim
 * is *about* the watch rather than about a number, and they keep the budget and
 * the readable message because for them a missing notification is the only way
 * to go red without anything being wrong:
 *
 *  - `notices a device that starts its first session while the pane is open`,
 *    whose second half says `refresh` started a watch rather than doing one
 *    read — driving that append through `refresh()` would prove the opposite of
 *    what it is for;
 *  - `counts only this project, not another folder the device worked in or its
 *    scratch`, whose second half says the *live* filter (`enqueueFromStore`,
 *    matching on the encoded directory name) drops another project's append.
 *    `refresh()` filters through `transcriptDirs` instead, which is a different
 *    piece of code and would leave that one untested.
 *
 * The wiring both depend on is pinned at source in `the live watch is wired`,
 * so a watch that is removed outright fails immediately rather than
 * intermittently.
 */
async function until(
  what: string,
  watcher: TranscriptWatcher,
  ready: (summary: ProjectSummary) => boolean,
  /*
   * See {@link UNTIL_MS}: the ceiling is not a tuned timeout, it is the point at
   * which this says what it was waiting for instead of leaving vitest to say
   * "timed out" about the whole test. It is therefore below the test's own
   * budget on purpose — a ceiling the runner reaches first is a ceiling that
   * never speaks.
   *
   * It was thirty seconds, raised from eight after a `macos-latest` release
   * build failed with "waited 8000ms for the third request … and it never
   * happened". Raising it fixed nothing, because the diagnosis in that sentence
   * was already right: the event *never* arrived. Waiting longer for something
   * that is not coming is the same bug with a longer fuse, and the appends that
   * could go missing are now driven through `refresh()` instead.
   */
  ceilingMs = UNTIL_MS,
): Promise<ProjectSummary> {
  const deadline = Date.now() + ceilingMs
  for (;;) {
    const summary = watcher.summary()
    if (ready(summary)) return summary
    if (Date.now() >= deadline) {
      throw new Error(
        `waited ${ceilingMs}ms for ${what} and it never happened; ` +
          `requests=${summary.requests} sessions=[${summary.sessions
            .map((s) => s.sessionId)
            .join(' ')}]`,
      )
    }
    await new Promise((r) => setTimeout(r, 10))
  }
}

/**
 * Wait for a report the watcher actually emitted, and hand it back.
 *
 * {@link until} reads `summary()`, which answers from whatever the watcher holds
 * *at that instant* — including halfway through a drain. That is fine for a
 * claim that only grows, like "three requests have been counted", and wrong for
 * any claim about the cap: `prune` runs at the *end* of a drain, so a poll that
 * lands between one file being consumed and the loop finishing sees every
 * transcript resident at once and a cap that has not been applied yet.
 *
 * Not hypothetical. The cap test below asked `summary()` whether the third
 * session had appeared and then asserted that only two were resident; with the
 * drain reading three files it caught the middle of one and failed with three,
 * five times in thirty-six loaded runs — a wrong answer about a state the
 * watcher never reported to anybody.
 *
 * `onUpdate` is what the app is wired to and it fires after the drain, so a
 * report taken from there is a state the watcher was willing to be judged on.
 */
async function emitted(
  what: string,
  updates: readonly ProjectSummary[],
  ready: (summary: ProjectSummary) => boolean,
  ceilingMs = UNTIL_MS,
): Promise<ProjectSummary> {
  const deadline = Date.now() + ceilingMs
  for (;;) {
    const found = updates.find((summary) => ready(summary))
    if (found) return found
    if (Date.now() >= deadline) {
      const last = updates[updates.length - 1]
      throw new Error(
        `waited ${ceilingMs}ms for ${what} and no report said so; ` +
          `${updates.length} report(s), last: requests=${last?.requests ?? 'none'} ` +
          `sessions=[${last?.sessions.map((session) => session.sessionId).join(' ') ?? ''}]`,
      )
    }
    await new Promise((r) => setTimeout(r, 10))
  }
}

describe('TranscriptWatcher against a live file', () => {
  it('picks up appends incrementally', async () => {
    const config = scratch('terminaldeck-cost-')
    const cwd = '/fake/project'
    const dir = join(config, 'projects', encodeProjectPath(cwd))
    mkdirSync(dir, { recursive: true })
    const file = join(dir, 'sess-live.jsonl')

    // Pre-existing history, present before the watcher starts.
    appendFileSync(file, line('m1', 1_000_000))

    const updates: ProjectSummary[] = []
    const watcher = new TranscriptWatcher({
      cwd,
      configDir: config,
      debounceMs: 50,
      onUpdate: (s) => updates.push(s),
    })
    await watcher.start()

    const afterScan = watcher.summary()
    console.log('after initial scan:', afterScan.requests, formatTokens(totalTokens(afterScan.usage)))
    expect(afterScan.requests).toBe(1)
    expect(afterScan.scanning).toBe(false)
    expect(afterScan.activeSessionId).toBe('sess-live')

    /*
     * Two more requests arrive while we watch, the second split across three
     * lines the way a real multi-block response is. Each is waited for
     * separately, which is also what makes them two distinct updates rather
     * than one coalesced batch.
     *
     * What is asserted here is the *tail* — that an append is read from where
     * the last read stopped and added to what was already counted — so the file
     * is put in front of the watcher by `refresh()` rather than by waiting for
     * the operating system to mention it. That is not tidiness. This exact case
     * failed a `macos-latest` release build with "waited 8000ms for the third
     * request … and it never happened", the ceiling was raised to thirty
     * seconds, and it failed again here under load with the same sentence: the
     * `change` event for a file the watcher already had open was not late, it
     * never arrived. Waiting longer for something that is not coming is the same
     * bug with a longer fuse. `refresh` re-reads the directory, which cannot
     * miss what is already on disk, and every byte of the incremental path below
     * it runs exactly as it does in the app.
     *
     * The live watch itself is still waited on by the two cases {@link until}
     * names, and pinned at source by `the live watch is wired`.
     */
    appendFileSync(file, line('m2', 1_000_000))
    await watcher.refresh()
    await until('the second request to be picked up', watcher, (s) => s.requests >= 2)

    appendFileSync(file, line('m3', 1_000_000))
    appendFileSync(file, line('m3', 1_000_000))
    appendFileSync(file, line('m3', 1_000_000))
    await watcher.refresh()
    const final = await until('the third request to be picked up', watcher, (s) => s.requests >= 3)
    console.log('after appends:', final.requests, formatTokens(totalTokens(final.usage)))
    console.log('updates emitted:', updates.length)
    console.log('session:', final.sessions[0]?.sessionId, 'ctx:', final.sessions[0]?.context)
    watcher.stop()

    expect(final.requests).toBe(3)
    expect(final.usage.output).toBe(3_000_000)
    expect(updates.length).toBeGreaterThan(1)
  }, WATCH_MS)

  it('reports a project total that equals the sum of its sessions', async () => {
    /*
     * Regression, and originally about money: the project total was computed by
     * pooling every session's raw tokens and re-pricing them at `Date.now()`,
     * so historical work was valued at today's rates and the headline
     * disagreed with the sessions listed underneath it.
     *
     * With no rates left there is nothing to re-price, and the equality is the
     * part that always mattered — a project is the sum of its sessions, in
     * every column, including the per-model split the tile names its models
     * from.
     */
    const config = scratch('terminaldeck-usage-sum-')
    const cwd = '/fake/project'
    const dir = join(config, 'projects', encodeProjectPath(cwd))
    mkdirSync(dir, { recursive: true })
    appendFileSync(
      join(dir, 'sess-old.jsonl'),
      line('m1', 1_000_000, { model: 'claude-sonnet-5', timestamp: '2026-10-01T10:00:00.000Z' }),
    )

    const watcher = new TranscriptWatcher({ cwd, configDir: config, debounceMs: 20, onUpdate: () => {} })
    await watcher.start()
    const summary = watcher.summary()
    watcher.stop()

    const sessionTotal = summary.sessions.reduce((sum, s) => sum + totalTokens(s.usage), 0)
    console.log('project:', totalTokens(summary.usage), 'sessions:', sessionTotal)
    expect(summary.sessions).toHaveLength(1)
    expect(totalTokens(summary.usage)).toBe(sessionTotal)
    expect(summary.usage.output).toBe(1_000_000)
    expect(summary.usageByModel['claude-sonnet-5'].output).toBe(1_000_000)
  }, WATCH_MS)

  it('caps how many sessions it keeps resident as new ones appear', async () => {
    // Regression: `maxSessions` was only applied to the initial scan, so a
    // watcher left running on a busy project accumulated a tail and an
    // aggregator — each holding every request id it had ever seen — forever.
    const config = scratch('terminaldeck-cost-cap-')
    const cwd = '/fake/project'
    const dir = join(config, 'projects', encodeProjectPath(cwd))
    mkdirSync(dir, { recursive: true })
    appendFileSync(join(dir, 'sess-a.jsonl'), line('a1', 10, { timestamp: '2026-08-11T10:00:00.000Z' }))
    appendFileSync(join(dir, 'sess-b.jsonl'), line('b1', 10, { timestamp: '2026-08-11T11:00:00.000Z' }))

    const updates: ProjectSummary[] = []
    const watcher = new TranscriptWatcher({
      cwd,
      configDir: config,
      debounceMs: 30,
      maxSessions: 2,
      onUpdate: (s) => updates.push(s),
    })
    await watcher.start()
    expect(watcher.summary().sessions).toHaveLength(2)

    /*
     * A third session starts while we are watching. `prune` runs at the end of
     * the same drain that reads the new file, so a *report* naming sess-c is one
     * the cap has already been applied to — which is why this waits on
     * {@link emitted} and not on `summary()`, whose answer mid-drain has all
     * three resident and is a state the watcher never reported.
     *
     * Driven through `refresh()` for the reason the device test below gives at
     * length, and it is not a convenience here either: this case failed under
     * full-suite load by waiting out its whole budget for an `add` event that
     * never came. Not late — missed, with no error logged to say why, on a watch
     * `start()` had already waited to hear was ready. `refresh`
     * reads the directory rather than waiting to be told about it, and it is
     * what `index.ts` calls from the hook that says a session has appeared, so
     * the test now drives the watcher the way the app does.
     */
    appendFileSync(join(dir, 'sess-c.jsonl'), line('c1', 10, { timestamp: '2026-08-11T12:00:00.000Z' }))
    await watcher.refresh()

    const summary = await emitted('the third session to be picked up', updates, (s) =>
      s.sessions.some((session) => session.sessionId === 'sess-c'),
    )
    watcher.stop()
    const ids = summary.sessions.map((s) => s.sessionId)
    console.log('resident sessions:', ids)
    expect(summary.sessions).toHaveLength(2)
    // The two most recently active survive; the oldest is dropped.
    expect(ids).toContain('sess-c')
    expect(ids).toContain('sess-b')
    expect(ids).not.toContain('sess-a')
  }, WATCH_MS)

  /**
   * The store a confined session writes to, which is not the owner's.
   *
   * A session started from a paired device runs with a `HOME` of its own — it
   * cannot read the account's — and the CLI follows `HOME`, so its transcript
   * lands under `<deviceHome>/.claude/projects/<encoded cwd>`. Measured with the
   * real CLI; `transcript.ts` records the run.
   *
   * These cases are on a real filesystem with a real chokidar for the same
   * reason the ones above are: the interesting behaviour is what the watcher
   * *notices*, and every version of this code looks correct when you call its
   * methods by hand.
   */
  it('counts a confined session, whose transcript is not in the profile store', async () => {
    const config = scratch('terminaldeck-cost-confined-')
    const homes = scratch('terminaldeck-device-homes-')
    const cwd = '/fake/project'

    // The owner's own session in this folder, in the ordinary place.
    const own = join(config, 'projects', encodeProjectPath(cwd))
    mkdirSync(own, { recursive: true })
    appendFileSync(join(own, 'sess-owner.jsonl'), line('o1', 1_000_000))

    // A device that has already run one here — this is what the app's own
    // `prepareDeviceHome` plus the CLI leave on disk.
    const device = join(deviceHome(homes, 'dev-a'), 'projects', encodeProjectPath(cwd))
    mkdirSync(device, { recursive: true })
    appendFileSync(join(device, 'sess-phone.jsonl'), line('p1', 1_000_000))

    const watcher = new TranscriptWatcher({
      cwd,
      configDir: config,
      deviceHomes: homes,
      debounceMs: 50,
      onUpdate: () => undefined,
    })
    await watcher.start()
    const afterScan = watcher.summary()
    console.log('confined scan:', afterScan.requests, afterScan.sessions.map((s) => s.sessionId))
    watcher.stop()

    // Both, in one project total. This is the regression: the phone's session
    // used to be invisible, so the cost pane showed the owner's spend as the
    // project's spend and the conversation was simply not there.
    expect(afterScan.sessions.map((s) => s.sessionId).sort()).toEqual(['sess-owner', 'sess-phone'])
    expect(afterScan.requests).toBe(2)
  }, WATCH_MS)

  it('notices a device that starts its first session while the pane is open', async () => {
    /*
     * A device pairs, starts its first session ever, and the cost pane for that
     * folder is already open. Nothing about that device's store existed when the
     * watcher started.
     *
     * Driven through `refresh()`, which is the path the app actually uses:
     * `index.ts` calls `refreshCostWatchers()` from the same hook that tells the
     * window a session appeared, because the app *made* that home a moment
     * earlier and does not need the filesystem to tell it. The `addDir` watch on
     * the device-homes root covers the same case when nothing told us, and it is
     * deliberately not what this asserts — measured on this Mac, a directory
     * created in the same tick that a watch became ready is delivered most of
     * the time and not always, and a user-visible number must not rest on that.
     */
    const config = scratch('terminaldeck-cost-newdev-')
    const homes = scratch('terminaldeck-device-homes-new-')
    const cwd = '/fake/project'
    mkdirSync(join(config, 'projects', encodeProjectPath(cwd)), { recursive: true })

    const watcher = new TranscriptWatcher({
      cwd,
      configDir: config,
      deviceHomes: homes,
      debounceMs: 50,
      onUpdate: () => undefined,
    })
    await watcher.start()
    expect(watcher.summary().requests).toBe(0)

    // The app makes the home, then spawns; the agent writes its first line some
    // time later. Both halves are what `refresh()` has to cope with.
    const store = deviceHome(homes, 'dev-late')
    const device = join(store, 'projects', encodeProjectPath(cwd))
    mkdirSync(device, { recursive: true })
    appendFileSync(join(device, 'sess-late.jsonl'), line('l1', 1_000_000))

    await watcher.refresh()
    const summary = await until('the new device session to appear', watcher, (s) => s.requests >= 1)
    console.log('late device:', summary.requests, summary.sessions.map((s) => s.sessionId))
    expect(summary.sessions.map((s) => s.sessionId)).toEqual(['sess-late'])

    /*
     * And it keeps tailing it, rather than reading it once on discovery. This is
     * the half that proves `refresh` started a *watch* and not just a read.
     *
     * One of the two waits in this file that still depend on a real filesystem
     * event, and deliberate: driving this append through `refresh()` as the rest
     * now do would re-list the directory and re-read the file, which is exactly
     * the behaviour this exists to rule out. It keeps its budget and its
     * message — see {@link until} — and a missing notification is the one way it
     * can go red without anything being wrong.
     */
    appendFileSync(join(device, 'sess-late.jsonl'), line('l2', 1_000_000))
    const grown = await until('the append to that session', watcher, (s) => s.requests >= 2)
    watcher.stop()
    expect(grown.sessions.map((s) => s.sessionId)).toEqual(['sess-late'])
  }, WATCH_SLOW_MS)

  it('counts only this project, not another folder the device worked in or its scratch', async () => {
    /*
     * A device's store holds one directory per folder that device has worked in,
     * and its home also holds its `TMPDIR` — the directory a confined session
     * writes to every time it runs `git commit`. Neither may reach this
     * project's numbers.
     *
     * Everything is on disk before the watcher starts, and then one append
     * arrives live. That is deliberate: whether a store that appears *later* is
     * noticed is a different claim, and the test above owns it. Asking one case
     * to prove both meant a failure could not say which half had broken.
     */
    const config = scratch('terminaldeck-cost-prune-')
    const homes = scratch('terminaldeck-device-homes-prune-')
    const cwd = '/fake/project'
    mkdirSync(join(config, 'projects', encodeProjectPath(cwd)), { recursive: true })

    const store = deviceHome(homes, 'dev-a')
    const other = join(store, 'projects', encodeProjectPath('/fake/elsewhere'))
    mkdirSync(other, { recursive: true })
    appendFileSync(join(other, 'sess-other.jsonl'), line('x1', 1_000_000))
    appendFileSync(join(homes, 'dev-a', 'tmp', 'sess-noise.jsonl'), line('x2', 1_000_000))

    const mine = join(store, 'projects', encodeProjectPath(cwd))
    mkdirSync(mine, { recursive: true })
    appendFileSync(join(mine, 'sess-mine.jsonl'), line('m1', 1_000_000))

    const watcher = new TranscriptWatcher({
      cwd,
      configDir: config,
      deviceHomes: homes,
      debounceMs: 50,
      onUpdate: () => undefined,
    })
    await watcher.start()
    const afterScan = watcher.summary()
    console.log('pruned scan:', afterScan.sessions.map((s) => s.sessionId))
    expect(afterScan.sessions.map((s) => s.sessionId)).toEqual(['sess-mine'])

    /*
     * And the live watch is filtered the same way: an append to the other
     * project must not arrive as this project's cost.
     *
     * The second of the two waits in this file that still depend on a real
     * filesystem event, and deliberate for the reason {@link until} gives: the
     * live path filters in `enqueueFromStore`, on the encoded directory name,
     * and `refresh()` would filter in `transcriptDirs` instead — proving the
     * claim about a different piece of code than the one it names.
     */
    appendFileSync(join(other, 'sess-other.jsonl'), line('x3', 1_000_000))
    appendFileSync(join(mine, 'sess-mine.jsonl'), line('m2', 1_000_000))
    const grown = await until('the append to this project', watcher, (s) => s.requests >= 2)
    watcher.stop()
    console.log('pruned live:', grown.requests, grown.sessions.map((s) => s.sessionId))
    expect(grown.sessions.map((s) => s.sessionId)).toEqual(['sess-mine'])
    expect(grown.requests).toBe(2)
  }, WATCH_SLOW_MS)

  /**
   * The project total counts one API request once, however many files hold it.
   *
   * The number Asad asked about: *"3.2 billion tokens… I don't know if it is
   * true or not."* It was true in kind — 97% of it is cache reads, re-read every
   * turn — and wrong in detail, because resuming or forking a conversation
   * copies its history into a new `.jsonl` and every aggregator de-duplicated
   * only within its own file.
   *
   * Measured on this machine's largest project the day this was written: 11,110
   * distinct requests recorded 11,598 times across forty transcripts, reporting
   * 5,331,624,956 tokens where 5,121,344,002 were spent. This is that, in
   * miniature: `m1` and `m2` are written to the original transcript and then
   * copied into the resumed one, which adds `m3` of its own.
   */
  it('counts a request once even when two transcripts both recorded it', async () => {
    const config = scratch('terminaldeck-fork-')
    const cwd = '/fake/project'
    const dir = join(config, 'projects', encodeProjectPath(cwd))
    mkdirSync(dir, { recursive: true })

    // The original conversation.
    appendFileSync(join(dir, 'sess-a.jsonl'), line('m1', 1000) + line('m2', 1000))
    // Resumed: the CLI copies the history it inherited, verbatim, then carries
    // on. `m1` and `m2` are now on disk twice.
    appendFileSync(
      join(dir, 'sess-b.jsonl'),
      line('m1', 1000) + line('m2', 1000) + line('m3', 1000),
    )

    const watcher = new TranscriptWatcher({ cwd, configDir: config, debounceMs: 20, onUpdate: () => {} })
    await watcher.start()
    const summary = await until('both transcripts to be read', watcher, (s) => s.sessions.length === 2)
    watcher.stop()

    // Three real requests, not five.
    expect(summary.requests).toBe(3)
    expect(summary.usage.output).toBe(3000)

    // And each session still reports its own honest total — a resumed
    // conversation really did re-send the history it inherited, so subtracting
    // it there would make a session's tile disagree with its own transcript.
    // It is only the project sum that must not add a request to itself twice.
    const perSession = summary.sessions.map((s) => s.requests).sort()
    expect(perSession).toEqual([2, 3])
  }, WATCH_SLOW_MS)

  /* ------------------------------------------------------------------------ *
   * The cap counts conversations, not files.
   *
   * Measured on 2026-08-18 against `~/Projects/terminaldeck`, the folder this
   * app is built in: 104 transcripts, of which **94 record no request at all**,
   * and the newest one that does is number **79** by modification time. With the
   * cap applied to the file list, all forty slots went to files describing
   * nothing and the Overview tile read "Nothing recorded yet" over three months
   * of work — no number at all, on the busiest folder on the machine.
   * ------------------------------------------------------------------------ */

  it('finds the work when every recent transcript recorded nothing', async () => {
    const config = scratch('terminaldeck-cost-shells-')
    const cwd = '/fake/project'
    const dir = join(config, 'projects', encodeProjectPath(cwd))
    mkdirSync(dir, { recursive: true })

    // Oldest first, so the two that carry work are the two the old cap could
    // never have reached. `utimesSync` rather than write order because the
    // ordering *is* the test and a filesystem's mtime granularity is not
    // something to leave to chance.
    appendFileSync(join(dir, 'sess-work-a.jsonl'), line('wa', 10, { timestamp: '2026-08-11T10:00:00.000Z' }))
    appendFileSync(join(dir, 'sess-work-b.jsonl'), line('wb', 20, { timestamp: '2026-08-11T10:05:00.000Z' }))
    const base = Date.now() / 1000
    utimesSync(join(dir, 'sess-work-a.jsonl'), base - 100, base - 100)
    utimesSync(join(dir, 'sess-work-b.jsonl'), base - 99, base - 99)
    for (let i = 0; i < 12; i += 1) {
      const path = join(dir, `sess-shell-${i}.jsonl`)
      appendFileSync(path, shellTranscript(`shell-${i}`))
      utimesSync(path, base - 10 + i, base - 10 + i)
    }

    const watcher = new TranscriptWatcher({
      cwd,
      configDir: config,
      debounceMs: 30,
      maxSessions: 2,
      onUpdate: () => {},
    })
    await watcher.start()
    const summary = watcher.summary()
    watcher.stop()

    // Two files carry a request each. Before this, the scan opened the two
    // newest files — both shells — and reported nothing.
    expect(summary.requests).toBe(2)
    expect(summary.sessions.map((s) => s.sessionId).sort()).toEqual(['sess-work-a', 'sess-work-b'])
    // Everything eligible was read, so the tile may still say "every request".
    expect(summary.truncated).toBe(false)
  }, WATCH_SLOWEST_MS)

  it('says so when it stopped looking before the folder ran out', async () => {
    const config = scratch('terminaldeck-cost-partial-')
    const cwd = '/fake/project'
    const dir = join(config, 'projects', encodeProjectPath(cwd))
    mkdirSync(dir, { recursive: true })
    appendFileSync(join(dir, 'sess-old.jsonl'), line('o1', 10, { timestamp: '2026-08-11T09:00:00.000Z' }))
    appendFileSync(join(dir, 'sess-new.jsonl'), line('n1', 10, { timestamp: '2026-08-11T10:00:00.000Z' }))
    const base = Date.now() / 1000
    utimesSync(join(dir, 'sess-old.jsonl'), base - 100, base - 100)
    utimesSync(join(dir, 'sess-new.jsonl'), base - 10, base - 10)

    const watcher = new TranscriptWatcher({
      cwd,
      configDir: config,
      debounceMs: 30,
      maxSessions: 1,
      onUpdate: () => {},
    })
    await watcher.start()
    const summary = watcher.summary()
    watcher.stop()

    expect(summary.requests).toBe(1)
    // The whole point of the flag: one request is not "every request your agents
    // made in this folder", and the tile has to be able to tell the difference.
    expect(summary.truncated).toBe(true)
  }, WATCH_SLOWEST_MS)

  it('does not let a transcript with no requests evict one that has some', async () => {
    // The empty-but-active case: a session given a prompt and killed before it
    // was answered writes a timestamped line and no usage. It sorts newest and
    // carries nothing, and it used to take a resident slot from the conversation
    // whose numbers are on screen.
    const config = scratch('terminaldeck-cost-evict-')
    const cwd = '/fake/project'
    const dir = join(config, 'projects', encodeProjectPath(cwd))
    mkdirSync(dir, { recursive: true })
    appendFileSync(join(dir, 'sess-real.jsonl'), line('r1', 10, { timestamp: '2026-08-11T10:00:00.000Z' }))

    const updates: ProjectSummary[] = []
    const watcher = new TranscriptWatcher({
      cwd,
      configDir: config,
      debounceMs: 30,
      maxSessions: 1,
      onUpdate: (s) => updates.push(s),
    })
    await watcher.start()
    expect(watcher.summary().requests).toBe(1)

    appendFileSync(
      join(dir, 'sess-abandoned.jsonl'),
      `${JSON.stringify({
        type: 'user',
        uuid: 'abandoned-u',
        timestamp: '2026-08-11T23:00:00.000Z',
        sessionId: 'sess-abandoned',
        cwd,
        message: { role: 'user', content: 'do the thing' },
      })}\n`,
    )

    /*
     * Told about the new transcript, rather than waiting to be told.
     *
     * This is the half that raced, and it raced against the operating system
     * rather than against a clock: under full-suite load the `add` event for a
     * file created a moment after the watch was established was simply never
     * delivered, and the test sat out its whole twenty seconds waiting for a
     * drain that had no reason to run. Waiting longer would not have helped —
     * nothing was coming. `refresh()` re-reads the directory, which cannot miss
     * a file that is already on disk, and it is the path the app itself uses
     * when it knows a session has started; the `add` event, if it does arrive,
     * finds the file already queued and changes nothing.
     *
     * `before` is read *after* that call, so the update this waits for can only
     * come from a drain that had the abandoned transcript in its queue: a drain
     * already in flight consumes it too, because `drainOnce` loops over the live
     * queue rather than a copy of it. Without that ordering an unrelated update
     * could satisfy the wait and the assertions below would pass without the
     * eviction ever having been possible — a test that looks like it works and
     * does not.
     *
     * And the update is what is waited on rather than the file existing: the
     * watcher emits at the end of the drain that reads the file, `prune` runs
     * inside that same drain, so an update after the queue means the cap has
     * already been applied.
     */
    await watcher.refresh()
    const before = updates.length
    await until('the abandoned transcript to be read', watcher, () => updates.length > before)
    const summary = watcher.summary()
    watcher.stop()
    expect(summary.requests).toBe(1)
    expect(summary.sessions.map((s) => s.sessionId)).toEqual(['sess-real'])
  }, WATCH_SLOWEST_MS)

  it('survives a project that has never been opened in Claude Code', async () => {
    const config = scratch('terminaldeck-cost-empty-')
    const updates: ProjectSummary[] = []
    const watcher = new TranscriptWatcher({
      cwd: '/nowhere/at/all',
      configDir: config,
      debounceMs: 20,
      onUpdate: (s) => updates.push(s),
    })
    await watcher.start()
    const summary = watcher.summary()
    console.log('empty project:', summary.requests, summary.sessions.length, summary.activeSessionId)
    watcher.stop()
    expect(summary.requests).toBe(0)
    expect(summary.sessions).toEqual([])
    expect(summary.activeSessionId).toBeNull()
    expect(summary.usageByModel).toEqual({})
    expect(totalTokens(summary.usage)).toBe(0)
  }, WATCH_MS)
})

describe('the live watch is wired', () => {
  it('subscribes to both stores and waits until it is really watching', () => {
    /*
     * A source-level pin, in the shape the `unread` case below already uses
     * here, and for a sharper version of the same reason: this claim cannot be
     * provoked on demand *and cannot be waited for either*.
     *
     * Measured on this Mac on 2026-08-21, running twelve copies of this file at
     * once to stand in for a full-suite release run: a `change` event for a file
     * the watcher already had open went missing once in thirty-six runs, and an
     * `add` event for a file created seconds after the watch was established
     * went missing twice in ten. No error was logged and no fd limit was near —
     * the notification simply never came. Every behavioural test in this file
     * that waited on one is therefore driven through `refresh()` instead, which
     * reads the directory rather than waiting to be told about it and is the
     * path the app itself uses when it knows a session has started.
     *
     * That leaves nobody asserting the watch exists, which is what this is for.
     * It is a weaker claim than "an append arrives" and it is an honest one: it
     * fails if the subscription is dropped, and it does not pretend to know
     * whether the operating system will deliver.
     */
    const source = readFileSync(new URL('./transcript.ts', import.meta.url), 'utf8')
    const code = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '')

    // The project's own directory: a new transcript and an append to one.
    expect(code, 'the project watch no longer queues new transcripts').toMatch(
      /watcher\.on\('add', \(path: string\) => this\.enqueue\(path\)\)/,
    )
    expect(code, 'the project watch no longer queues appends').toMatch(
      /watcher\.on\('change', \(path: string\) => this\.enqueue\(path\)\)/,
    )
    // And every paired device's store, filtered to this project by name.
    expect(code, 'the confined-store watch no longer queues anything').toMatch(
      /stores\.on\('(add|change)', \(path: string\) => this\.enqueueFromStore\(path\)\)/,
    )
    /*
     * And `start()` does not resolve until the watchers say they are watching.
     * Dropping this is how an append written a moment after `start()` returns
     * gets lost for good, which is the Windows CI failure the method's own
     * comment records.
     */
    expect(code, 'start() no longer waits for the watchers to be ready').toMatch(
      /each\.once\('ready', done\)/,
    )
  })
})

describe('what the cap counts as unread', () => {
  it('tallies only the files it never opened', () => {
    /*
     * A source-level pin, in the shape `wiring.test.ts` and `finish.test.ts`
     * already use here, because the failure it guards cannot be provoked on
     * demand: it needs a watcher event to arrive for a file the scan has already
     * finished with, and that arrival is the operating system's decision.
     *
     * It does arrive. On macOS FSEvents can deliver an event for a write made
     * moments before the watch was attached, and the initial-scan suppression
     * does not cover it, because a replayed event is a real event. The file goes
     * back in the queue, the cap is already met, and the branch below counted it
     * as a transcript whose requests are missing from the total — when they were
     * in the total, put there by the same scan a moment earlier.
     *
     * `unread` is not a statistic. It is what decides whether the overview may
     * say "every request your agents made in this folder", so a number inflated
     * this way makes an honest total describe itself as partial. It failed the
     * sibling test above about one run in three on a folder where nothing was
     * left unread at all.
     */
    const source = readFileSync(new URL('./transcript.ts', import.meta.url), 'utf8')
    const code = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '')
    expect(
      code,
      'the cap adds the whole queue to `unread` again — files it already read are counted as missing',
    ).not.toMatch(/this\.unread \+= this\.queue\.size/)
    expect(
      code,
      'the cap no longer skips files that already have an aggregator',
    ).toMatch(/for \(const path of this\.queue\) if \(!this\.aggregators\.has\(path\)\) this\.unread \+= 1/)
  })
})

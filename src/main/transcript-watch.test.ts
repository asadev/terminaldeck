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
 */
async function until(
  what: string,
  watcher: TranscriptWatcher,
  ready: (summary: ProjectSummary) => boolean,
  /*
   * Thirty seconds, raised from eight after a release build failed on a
   * `macos-latest` runner with "waited 8000ms for the third request … and it
   * never happened".
   *
   * Raising it weakens nothing, and this file already says why: the ceiling is
   * not a tuned timeout, it exists only so a watcher that *genuinely* never
   * fires reports a readable failure instead of hanging until vitest kills the
   * test. The loop waits on the condition, so a slow machine gets the same
   * answer, just later — and a hosted runner sharing a host with other jobs is
   * exactly the slow machine that sentence was written for. A watcher that is
   * actually broken still fails here, thirty seconds later, with the same
   * message.
   */
  ceilingMs = 30_000,
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

    // Two more requests arrive while we watch, the second split across three
    // lines the way a real multi-block response is. Each is waited for
    // separately, which is also what makes them two distinct updates rather
    // than one coalesced batch.
    appendFileSync(file, line('m2', 1_000_000))
    await until('the second request to be picked up', watcher, (s) => s.requests >= 2)

    appendFileSync(file, line('m3', 1_000_000))
    appendFileSync(file, line('m3', 1_000_000))
    appendFileSync(file, line('m3', 1_000_000))
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

    const watcher = new TranscriptWatcher({
      cwd,
      configDir: config,
      debounceMs: 30,
      maxSessions: 2,
      onUpdate: () => {},
    })
    await watcher.start()
    expect(watcher.summary().sessions).toHaveLength(2)

    // A third session starts while we are watching. `prune` runs at the end of
    // the same drain that reads the new file, so the moment sess-c is visible
    // the cap has already been applied — there is no window in which all three
    // are resident for this to race against.
    appendFileSync(join(dir, 'sess-c.jsonl'), line('c1', 10, { timestamp: '2026-08-11T12:00:00.000Z' }))

    const summary = await until('the third session to be picked up', watcher, (s) =>
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

    // And it keeps tailing it, rather than reading it once on discovery. This is
    // the half that proves `refresh` started a *watch* and not just a read.
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

    // And the live watch is filtered the same way: an append to the other
    // project must not arrive as this project's cost.
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
    const before = updates.length

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
     * Waited on rather than slept through, and waited on the watcher's own
     * report rather than on a file existing.
     *
     * The watcher emits at the end of the drain that reads the new file, and
     * `prune` runs inside that same drain — so an update arriving after the
     * append is proof that the cap has already been applied, and there is no
     * window in which both transcripts are resident for this to race against.
     */
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

import { appendFileSync, mkdirSync, mkdtempSync, realpathSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { IpcMain, WebContents } from 'electron'
import { afterEach, describe, expect, it } from 'vitest'
import { registerCostIpc } from './cost-ipc'
import { encodeProjectPath, type ProjectSummary } from './transcript'

/**
 * A scratch config directory, spelled the way the OS will spell it back.
 *
 * The same care `transcript-watch.test.ts` takes, for the same reason:
 * `os.tmpdir()` is `/var/folders/…` on macOS, a symlink to `/private/var/…`,
 * and an 8.3 short name on a Windows runner. The watched half of these tests
 * puts a real file watcher on this directory and a watcher reports the resolved
 * path, so handing it the unresolved one makes every event arrive under a name
 * its own bookkeeping does not recognise.
 */
function scratch(prefix: string): string {
  return realpathSync(mkdtempSync(join(tmpdir(), prefix)))
}

/**
 * One assistant line, the shape the CLI writes it.
 *
 * `id` is the request's identity and is what the de-duplication turns on — the
 * same `id` written into two files is one request that was recorded twice, not
 * two requests. Everything else is fixed so the arithmetic in the assertions
 * stays readable: one input token, `output` output tokens, and a cache pair
 * that exists only so the fold has more than one column to get right.
 *
 * Kept a copy of `transcript-watch.test.ts`'s helper rather than shared out of
 * it. These two files pin the same rule on the two different channels that
 * answer it, and a fixture they both imported would let one change quietly
 * rewrite what the other proves.
 */
function line(
  id: string,
  output: number,
  extra: { model?: string; timestamp?: string; speed?: 'fast' } = {},
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
        ...(extra.speed ? { speed: extra.speed } : {}),
      },
    },
  })}\n`
}

type IpcHandler = (event: unknown, ...args: unknown[]) => unknown

function fakeIpc() {
  const invoke = new Map<string, IpcHandler>()
  const ipcMain = {
    handle: (channel: string, fn: IpcHandler) => void invoke.set(channel, fn),
    on: () => undefined,
  } as unknown as IpcMain
  return { ipcMain, invoke }
}

/**
 * A window that is alive and listens to nothing.
 *
 * `cost:watch` registers a teardown against its sender and pushes updates to
 * it, so the object has to answer all three calls; nothing here reads what was
 * pushed, because every assertion asks the channel directly rather than waiting
 * for a broadcast.
 */
function fakeSender(): WebContents {
  return {
    id: 1,
    isDestroyed: () => false,
    send: () => undefined,
    once: () => undefined,
  } as unknown as WebContents
}

/**
 * A project whose history was resumed once, which is the shape the defect
 * needs: `m1` and `m2` written to the original transcript and then copied
 * verbatim into the resumed one, which adds `m3` of its own. Three real
 * requests recorded five times.
 *
 * The timestamps are explicit and the resumed transcript is the newer one. The
 * total is the same either way — the duplicated pair carries identical usage in
 * both files — but which copy a request is *attributed* to is decided by
 * activity order, and a fixture whose two files were written in the same
 * millisecond would make that order a coin toss.
 */
function forkedProject(config: string, cwd = '/fake/project'): void {
  const dir = join(config, 'projects', encodeProjectPath(cwd))
  mkdirSync(dir, { recursive: true })
  const at = (minutesAgo: number): string => new Date(Date.now() - minutesAgo * 60_000).toISOString()

  appendFileSync(
    join(dir, 'sess-a.jsonl'),
    line('m1', 1000, { timestamp: at(120) }) + line('m2', 1000, { timestamp: at(119) }),
  )
  appendFileSync(
    join(dir, 'sess-b.jsonl'),
    line('m1', 1000, { timestamp: at(60) }) +
      line('m2', 1000, { timestamp: at(59) }) +
      line('m3', 1000, { timestamp: at(58) }),
  )
}

/** Whatever `CLAUDE_CONFIG_DIR` was, put back after every case. */
const originalConfigDir = process.env.CLAUDE_CONFIG_DIR
afterEach(() => {
  if (originalConfigDir === undefined) delete process.env.CLAUDE_CONFIG_DIR
  else process.env.CLAUDE_CONFIG_DIR = originalConfigDir
})

describe('cost:project without a watcher', () => {
  /**
   * The one-shot channel must de-duplicate across transcripts exactly as the
   * watched one does.
   *
   * `TranscriptWatcher.summary()` was fixed for this and `summarizeStandalone`
   * was not, which mattered more than it sounds: a watcher exists only while
   * some session in the folder is live, so the Overview tile of a project
   * nobody is working in was answered entirely from the unfixed path. Measured
   * on the largest project on this machine the day this was written, 11,110
   * distinct requests were recorded 11,598 times across forty transcripts and
   * reported 5,331,624,956 tokens against 5,121,344,002 actually spent. This is
   * that, in miniature.
   */
  it('counts a request once even when two transcripts both recorded it', async () => {
    const config = scratch('terminaldeck-cost-fork-')
    process.env.CLAUDE_CONFIG_DIR = config
    forkedProject(config)

    const { ipcMain, invoke } = fakeIpc()
    registerCostIpc(ipcMain)
    const summary = (await invoke.get('cost:project')?.(null, '/fake/project')) as ProjectSummary

    // Three real requests, not five.
    expect(summary.requests).toBe(3)
    expect(summary.usage.output).toBe(3000)
    // Every column folds once, not only the one the headline is drawn from.
    expect(summary.usage.input).toBe(3)
    expect(summary.usage.cacheRead).toBe(15_000)

    // And each session still reports its own honest total — a resumed
    // conversation really did re-send the history it inherited, so subtracting
    // it there would make a session's tile disagree with its own transcript. It
    // is only the project sum that must not add a request to itself twice.
    expect(summary.sessions.map((s) => s.requests).sort()).toEqual([2, 3])

    // Newest first, and the newest is the resumed transcript — the copy still
    // being written to is the one a person is most likely looking at.
    expect(summary.sessions.map((s) => s.sessionId)).toEqual(['sess-b', 'sess-a'])
    expect(summary.activeSessionId).toBe('sess-b')
  })

  /**
   * The two channels answer the same question and must not answer it
   * differently.
   *
   * This is the assertion the defect would have failed on directly: for months
   * `cost:watch` said three and `cost:project` said five about the same folder,
   * and which number a person saw depended on whether anything happened to be
   * running in it. Pinning the *agreement* rather than only the arithmetic is
   * what stops the two drifting apart again — a future change to one fold now
   * has to be made in both, or this fails.
   */
  it('agrees with the watched channel about the same folder', async () => {
    const config = scratch('terminaldeck-cost-agree-')
    process.env.CLAUDE_CONFIG_DIR = config
    forkedProject(config)

    const { ipcMain, invoke } = fakeIpc()
    registerCostIpc(ipcMain)
    const standalone = (await invoke.get('cost:project')?.(null, '/fake/project')) as ProjectSummary

    const event = { sender: fakeSender() }
    try {
      /*
       * Polled rather than asserted once. `TranscriptWatcher.start()` enumerates
       * what is already on disk before it returns, so one call is normally
       * enough — but this puts a real OS file watcher on a real directory, and
       * `transcript-watch.test.ts` documents at length that such a run is at the
       * mercy of a notification with no latency guarantee. Re-invoking is free:
       * the second call finds the entry already made and returns its current
       * summary.
       */
      let watched = (await invoke.get('cost:watch')?.(event, '/fake/project')) as ProjectSummary
      const deadline = Date.now() + 10_000
      while (watched.sessions.length < 2 && Date.now() < deadline) {
        watched = (await invoke.get('cost:watch')?.(event, '/fake/project')) as ProjectSummary
      }

      expect(watched.requests).toBe(standalone.requests)
      expect(watched.usage).toEqual(standalone.usage)
      expect(watched.usageByModel).toEqual(standalone.usageByModel)
      expect(watched.sessions.map((s) => s.sessionId)).toEqual(
        standalone.sessions.map((s) => s.sessionId),
      )
      expect(watched.truncated).toBe(standalone.truncated)
    } finally {
      // The watcher holds an fs handle for as long as a subscriber does, and a
      // test that leaves one open keeps the whole file alive after its last
      // assertion.
      invoke.get('cost:unwatch')?.(event, '/fake/project')
    }
  }, 15_000)

  /**
   * The project's per-model keys have to be the strings a session's own
   * `usageByModel` uses, including the `-fast` column.
   *
   * That rule lives in `rateKey`, which is private to `transcript.ts`, and it
   * is the reason this fold is performed by a `SessionAggregator` rather than
   * by a hand copy of the watcher's arithmetic. A copy would have had to
   * re-spell the suffix rule and the `unknown` sentinel beside it, and the day
   * one of them changed the Overview tile's list of models and a session's own
   * would have started naming two different sets of things.
   */
  it('keeps fast mode in its own column and splits models the way a session does', async () => {
    const config = scratch('terminaldeck-cost-models-')
    process.env.CLAUDE_CONFIG_DIR = config
    const dir = join(config, 'projects', encodeProjectPath('/fake/project'))
    mkdirSync(dir, { recursive: true })
    appendFileSync(
      join(dir, 'sess-mixed.jsonl'),
      line('m1', 1000) +
        line('m2', 500, { model: 'claude-haiku-4-5' }) +
        line('m3', 250, { speed: 'fast' }),
    )

    const { ipcMain, invoke } = fakeIpc()
    registerCostIpc(ipcMain)
    const summary = (await invoke.get('cost:project')?.(null, '/fake/project')) as ProjectSummary

    expect(Object.keys(summary.usageByModel).sort()).toEqual([
      'claude-haiku-4-5',
      'claude-opus-5',
      'claude-opus-5-fast',
    ])
    expect(summary.usageByModel['claude-opus-5-fast']?.output).toBe(250)
    // The project's split is the session's split, key for key.
    expect(summary.usageByModel).toEqual(summary.sessions[0]?.usageByModel)
  })

  /**
   * A request with no id of any kind cannot be proven to be a copy of another,
   * so it is counted. Dropping it would silently lose real spend, which is the
   * one direction this total must never be wrong in — the whole point of the
   * change is that the number under it claims to be every request.
   */
  it('counts an unidentifiable request rather than assuming it is a duplicate', async () => {
    const config = scratch('terminaldeck-cost-anon-')
    process.env.CLAUDE_CONFIG_DIR = config
    const dir = join(config, 'projects', encodeProjectPath('/fake/project'))
    mkdirSync(dir, { recursive: true })

    // No `id`, no `requestId`, no `uuid` — the three sources a key comes from.
    const anonymous = `${JSON.stringify({
      type: 'assistant',
      timestamp: new Date().toISOString(),
      cwd: '/fake/project',
      isSidechain: false,
      message: { model: 'claude-opus-5', role: 'assistant', usage: { output_tokens: 7 } },
    })}\n`
    appendFileSync(join(dir, 'sess-a.jsonl'), anonymous + anonymous)

    const { ipcMain, invoke } = fakeIpc()
    registerCostIpc(ipcMain)
    const summary = (await invoke.get('cost:project')?.(null, '/fake/project')) as ProjectSummary

    expect(summary.requests).toBe(2)
    expect(summary.usage.output).toBe(14)
  })
})

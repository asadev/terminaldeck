import { mkdtempSync, mkdirSync, writeFileSync, rmSync, utimesSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import {
  blankContextReading,
  parseCodexContextLine,
  readContextWindow,
  MAX_TAIL_BYTES,
  TAIL_STEPS,
} from './context-window'
import { encodeProjectPath } from './transcript'

/**
 * How full the model's context window is, read off disk.
 *
 * This is the cheap half of the usage bar, and everything below is about the
 * ways a cheap read produces a *confidently wrong* number. The three that
 * actually happened on this machine are the three that get a test each: the
 * denominator that is not on the line, the last usage-bearing line that is all
 * zeros, and the folder whose newest twelve files are title stubs.
 *
 * The directories are real and temporary rather than mocked, because the thing
 * being tested is a file layout — Claude Code's `<configDir>/projects/<encoded
 * cwd>/<session>.jsonl` — and a mock of a file layout only ever proves that the
 * mock matches the code.
 *
 * ## The encoding, verified rather than assumed
 *
 * `encodeProjectPath` replaces every non-alphanumeric byte with `-`. That was
 * checked against this machine on 2026-08-19 rather than read out of the code:
 * of the 90 directories under `~/.claude/projects`, 79 hold a transcript that
 * records its own `cwd`, and for all 59 whose sessions ran locally the encoding
 * of that recorded `cwd` is exactly the directory name — spaces (`Mobile
 * Documents`), dots (`.claude`) and tildes (`com~apple~CloudDocs`) included. The
 * other 20 are `ssh-<uuid>` directories, which are remote sessions named a
 * different way entirely and are not a cwd encoding at all.
 */

const made: string[] = []

function store(): { configDir: string; project: (cwd: string) => string } {
  const configDir = mkdtempSync(join(tmpdir(), 'ctxwin-'))
  made.push(configDir)
  return {
    configDir,
    project(cwd: string): string {
      const dir = join(configDir, 'projects', encodeProjectPath(cwd))
      mkdirSync(dir, { recursive: true })
      return dir
    },
  }
}

afterEach(() => {
  while (made.length > 0) rmSync(made.pop() as string, { recursive: true, force: true })
})

const AT = '2026-08-19T13:48:22.481Z'

/** One assistant turn, in the shape Claude Code actually writes. */
function turn(over: Record<string, unknown> = {}): string {
  return JSON.stringify({
    type: 'assistant',
    timestamp: AT,
    message: {
      model: 'claude-opus-5',
      usage: { input_tokens: 2, cache_read_input_tokens: 75_511, cache_creation_input_tokens: 1703 },
    },
    ...over,
  })
}

describe('reading Claude Code’s transcript', () => {
  it('adds the three fields that make up a resident context', () => {
    /*
     * `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`,
     * which is what `promptTokens` in `cost.ts` already sums. The numbers here
     * are the ones this app read off its own live session while the feature was
     * being written: 2 + 75,511 + 1,703 = 77,216.
     */
    const { configDir, project } = store()
    const cwd = '/tmp/ctx-project'
    writeFileSync(join(project(cwd), 'a.jsonl'), `${turn()}\n`)

    return readContextWindow({ provider: 'claude', cwd, scope: { configDir, deviceHomes: null, homeScopes: [] } }).then(
      (reading) => {
        expect(reading.state).toBe('ok')
        expect(reading.tokens).toBe(77_216)
        expect(reading.model).toBe('claude-opus-5')
        expect(reading.reportedAt).toBe(Date.parse(AT))
      },
    )
  })

  it('ignores the interrupt lines whose usage block is all zeros', async () => {
    /*
     * `<synthetic>` lines are interrupts and API errors the CLI writes locally.
     * They are `type: "assistant"`, they carry a full `message.usage`, and every
     * number in it is zero. Thirteen transcripts on this machine *end* with one,
     * so taking the last usage-bearing line unconditionally reports an empty
     * context for a session holding seventy-seven thousand tokens.
     */
    const { configDir, project } = store()
    const cwd = '/tmp/ctx-synthetic'
    const zeros = JSON.stringify({
      type: 'assistant',
      timestamp: AT,
      message: {
        model: '<synthetic>',
        usage: { input_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
      },
    })
    writeFileSync(join(project(cwd), 'a.jsonl'), `${turn()}\n${zeros}\n`)

    const reading = await readContextWindow({
      provider: 'claude',
      cwd,
      scope: { configDir, deviceHomes: null, homeScopes: [] },
    })
    expect(reading.tokens).toBe(77_216)
  })

  it('ignores a sub-agent’s own context, which shares the file', async () => {
    // A Task runs in its own context and writes into the parent's transcript
    // with `isSidechain: true`. Its prompt size is not the main thread's.
    const { configDir, project } = store()
    const cwd = '/tmp/ctx-sidechain'
    const side = turn({
      isSidechain: true,
      message: {
        model: 'claude-opus-5',
        usage: { input_tokens: 900_000, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
      },
    })
    writeFileSync(join(project(cwd), 'a.jsonl'), `${turn()}\n${side}\n`)

    const reading = await readContextWindow({
      provider: 'claude',
      cwd,
      scope: { configDir, deviceHomes: null, homeScopes: [] },
    })
    expect(reading.tokens).toBe(77_216)
  })

  it('walks past the title stubs that are the newest files in a real folder', async () => {
    /*
     * Of 509 transcripts on this machine, 250 carry no `message.usage` anywhere
     * — many are 256-byte records holding an `ai-title` and nothing else, and
     * the twelve most recently modified files in
     * `~/.claude/projects/-Users-apple-Projects-terminaldeck` were eleven of
     * those plus a fragment. "Newest file in the folder" is not "the session's
     * transcript", and stopping at the first candidate reported "nothing yet"
     * about a folder holding real conversations.
     */
    const { configDir, project } = store()
    const cwd = '/tmp/ctx-stubs'
    const dir = project(cwd)
    writeFileSync(join(dir, 'real.jsonl'), `${turn()}\n`)
    for (let i = 0; i < 12; i += 1) {
      writeFileSync(join(dir, `stub-${i}.jsonl`), `${JSON.stringify({ type: 'ai-title', title: 'x' })}\n`)
    }

    const reading = await readContextWindow({
      provider: 'claude',
      cwd,
      scope: { configDir, deviceHomes: null, homeScopes: [] },
    })
    expect(reading.state).toBe('ok')
    expect(reading.tokens).toBe(77_216)
    expect(reading.source?.sessionId).toBe('real')
  })

  it('says the transcript was inferred, and counts the sessions it could be confused with', async () => {
    /*
     * Two terminals open in one folder is an ordinary Tuesday. A person reading
     * a stranger session's occupancy as their own, with nothing on screen
     * admitting the ambiguity, would have no way to catch it — so the choice
     * travels with the number.
     */
    const { configDir, project } = store()
    const cwd = '/tmp/ctx-rivals'
    const dir = project(cwd)
    writeFileSync(join(dir, 'one.jsonl'), `${turn()}\n`)
    writeFileSync(join(dir, 'two.jsonl'), `${turn()}\n`)

    const reading = await readContextWindow({
      provider: 'claude',
      cwd,
      scope: { configDir, deviceHomes: null, homeScopes: [] },
    })
    expect(reading.source?.chosen).toBe('inferred')
    expect(reading.source?.rivals).toBe(1)
    expect(reading.detail).toContain('may be the other one')
  })

  it('prefers the newest conversation over the newest file, which is the “7d ago” bug', async () => {
    /*
     * The exact failure Asad photographed on 2026-08-19: a panel reading
     * `Written 7d ago` about a session he had opened minutes earlier, in a
     * folder an agent was working in at that moment.
     *
     * Reproduced from his own machine rather than imagined. In
     * `~/.claude/projects/-Users-apple-ClaudeAsad`, the transcript this module
     * picked — `d4601913-…` — had an mtime ten minutes old and not one line
     * written after 12 August: Claude Code had rewritten the `last-prompt` and
     * `mode` records it keeps at the end of a transcript without a turn being
     * added. So the file was fresh and the conversation in it was 6.88 days
     * cold, and a reading taken from it was 106k tokens belonging to a week-old
     * session.
     *
     * The fixture is that shape exactly: a stale conversation whose file was
     * touched last, beside a live one whose file was touched a moment earlier.
     * Modification order alone picks the wrong one.
     */
    const { configDir, project } = store()
    const cwd = '/tmp/ctx-touched'
    const dir = project(cwd)
    const live = join(dir, 'live.jsonl')
    const touched = join(dir, 'touched.jsonl')
    writeFileSync(live, `${turn({ timestamp: AT })}\n`)
    writeFileSync(
      touched,
      `${turn({
        timestamp: new Date(Date.parse(AT) - 7 * 24 * 3_600_000).toISOString(),
        message: {
          model: 'claude-opus-5',
          usage: { input_tokens: 1, cache_read_input_tokens: 106_131, cache_creation_input_tokens: 0 },
        },
      })}\n`,
    )
    // The touch itself: the stale file is the most recently written of the two,
    // and nothing was appended to it. `utimesSync` is what Claude Code's rewrite
    // amounts to from this module's point of view.
    const now = Date.now() / 1000
    utimesSync(live, now - 60, now - 60)
    utimesSync(touched, now, now)

    const reading = await readContextWindow({
      provider: 'claude',
      cwd,
      scope: { configDir, deviceHomes: null, homeScopes: [] },
    })
    expect(reading.source?.sessionId).toBe('live')
    expect(reading.tokens).toBe(77_216)
    expect(reading.reportedAt).toBe(Date.parse(AT))
    // Still a guess, and still said to be one. What changed is which guess.
    expect(reading.source?.chosen).toBe('inferred')
    expect(reading.source?.rivals).toBe(1)
  })

  it('still falls back past the live window when nothing recent has a figure', async () => {
    /*
     * The walk this module has always done, and the reason the preference above
     * is a preference rather than a filter: 250 of the 509 transcripts on this
     * machine carry no usage line at all. A folder whose only *recent* files are
     * title stubs must still answer from the conversation behind them, however
     * long ago that conversation stopped — an old figure with its age on it is a
     * reading, and "nothing yet" for a folder full of conversations is not.
     */
    const { configDir, project } = store()
    const cwd = '/tmp/ctx-fallback'
    const dir = project(cwd)
    const old = join(dir, 'old.jsonl')
    const stub = join(dir, 'stub.jsonl')
    writeFileSync(old, `${turn()}\n`)
    writeFileSync(stub, `${JSON.stringify({ type: 'ai-title', title: 'x' })}\n`)
    const now = Date.now() / 1000
    utimesSync(old, now - 3 * 3600, now - 3 * 3600)
    utimesSync(stub, now, now)

    const reading = await readContextWindow({
      provider: 'claude',
      cwd,
      scope: { configDir, deviceHomes: null, homeScopes: [] },
    })
    expect(reading.state).toBe('ok')
    expect(reading.source?.sessionId).toBe('old')
  })

  it('labels the model under the name the rest of the app prints', async () => {
    /*
     * *"the way it is typing claude-opus star dash 5 … it's too messy"*. The
     * panel prints this instead of the id, and it comes from `labelModelId` —
     * the same table the model chip on the same bar reads through, so the two
     * cannot end up calling one session's model two different things.
     */
    const { configDir, project } = store()
    const cwd = '/tmp/ctx-label'
    writeFileSync(join(project(cwd), 'a.jsonl'), `${turn()}\n`)
    const reading = await readContextWindow({
      provider: 'claude',
      cwd,
      scope: { configDir, deviceHomes: null, homeScopes: [] },
    })
    expect(reading.model).toBe('claude-opus-5')
    expect(reading.modelLabel).toBe('Opus 5')
  })

  it('names the transcript when it is given one, and refuses a path outside the store', async () => {
    /*
     * The path can reach here from renderer code, so an unchecked one is an
     * arbitrary-file-read primitive. The membership test is `transcript.ts`'s,
     * reused rather than copied — the mistake that file records having made
     * three times.
     */
    const { configDir, project } = store()
    const cwd = '/tmp/ctx-named'
    const path = join(project(cwd), 'named.jsonl')
    writeFileSync(path, `${turn()}\n`)
    const scope = { configDir, deviceHomes: null, homeScopes: [] } as const

    const reading = await readContextWindow({ provider: 'claude', cwd, transcriptPath: path, scope })
    expect(reading.source?.chosen).toBe('named')
    expect(reading.source?.rivals).toBe(0)

    await expect(
      readContextWindow({ provider: 'claude', cwd, transcriptPath: '/etc/passwd.jsonl', scope }),
    ).rejects.toThrow(/refusing to read outside/)
  })

  it('answers “nothing yet” rather than zero for a folder with no turns in it', async () => {
    const { configDir, project } = store()
    const cwd = '/tmp/ctx-empty'
    project(cwd)
    const reading = await readContextWindow({
      provider: 'claude',
      cwd,
      scope: { configDir, deviceHomes: null, homeScopes: [] },
    })
    expect(reading.state).toBe('nothing-yet')
    expect(reading.tokens).toBeNull()
    expect(reading.percent).toBeNull()
  })
})

describe('the denominator', () => {
  it('is 1,000,000 for the models this machine actually runs', async () => {
    /*
     * `~/.claude/settings.json` here sets `opus[1m]`, and the CLI's own
     * `/context` printed `claude-opus-5[1m]` … `18.8k / 1m`. The transcript the
     * same CLI writes records the model *without* the tag — the tag appears zero
     * times in `message.model` across all 509 transcripts on this machine — so
     * the window comes from `CONTEXT_WINDOWS` in `cost.ts`, which maps the bare
     * id, and not from parsing the id for a `[1m]` that is not there.
     */
    const { configDir, project } = store()
    const cwd = '/tmp/ctx-window'
    writeFileSync(join(project(cwd), 'a.jsonl'), `${turn()}\n`)
    const reading = await readContextWindow({
      provider: 'claude',
      cwd,
      scope: { configDir, deviceHomes: null, homeScopes: [] },
    })
    expect(reading.window).toBe(1_000_000)
    expect(reading.percent).toBeCloseTo(7.72, 2)
    expect(reading.windowBasis).toBe('model')
  })

  it('gives a token count with no percentage when nothing on disk names a model', async () => {
    /*
     * The refusal this module is built around. A percentage over an invented
     * denominator is a false statement; a token count with no percentage is a
     * true one. The live session in `~/ClaudeAsad` reached 999,876 tokens on
     * lines whose recorded model was bare — against a 200k default that draws as
     * 500%.
     */
    const { configDir, project } = store()
    const cwd = '/tmp/ctx-nomodel'
    const nameless = JSON.stringify({
      type: 'assistant',
      timestamp: AT,
      message: { usage: { input_tokens: 100, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 } },
    })
    writeFileSync(join(project(cwd), 'a.jsonl'), `${nameless}\n`)
    const reading = await readContextWindow({
      provider: 'claude',
      cwd,
      scope: { configDir, deviceHomes: null, homeScopes: [] },
    })
    // No model means no line this module will read at all, so the honest answer
    // is "nothing yet" rather than a figure with an invented window under it.
    expect(reading.percent).toBeNull()
    expect(reading.window).toBeNull()
  })
})

describe('the bounded read', () => {
  it('never reads a whole file, however large', () => {
    /*
     * The largest transcript on this machine is 154 MB and five exceed 50 MB. A
     * dropdown that opens on a keystroke cannot read one. The steps are measured
     * against the real distance from end-of-file to the last usage line across
     * all 261 transcripts here that have one: 3.5 KB median, 45 KB at p99, 552
     * KB at the worst.
     */
    expect(TAIL_STEPS[0]).toBe(256 * 1024)
    expect(MAX_TAIL_BYTES).toBe(8 * 1024 * 1024)
    expect([...TAIL_STEPS].sort((a, b) => a - b)).toEqual([...TAIL_STEPS])
  })

  it('finds the answer when it is behind a megabyte of tool output', async () => {
    const { configDir, project } = store()
    const cwd = '/tmp/ctx-big'
    const filler = `${JSON.stringify({ type: 'user', text: 'x'.repeat(4096) })}\n`.repeat(300)
    writeFileSync(join(project(cwd), 'a.jsonl'), `${turn()}\n${filler}`)
    const reading = await readContextWindow({
      provider: 'claude',
      cwd,
      scope: { configDir, deviceHomes: null, homeScopes: [] },
    })
    expect(reading.tokens).toBe(77_216)
  })
})

describe('the other agents', () => {
  it('reads Codex’s resident context, not its running total', () => {
    /*
     * Both traps in one record, verified by watching the numbers move across a
     * real session. `total_token_usage` accumulates over the whole session — it
     * ran to 60,285,342 in the rollout this was read from, which against the
     * stated 258,400 window is 23,000%. And `input_tokens` already *contains*
     * `cached_input_tokens`, so adding them the way Claude's fields must be
     * added nearly doubles the figure.
     */
    const line = JSON.stringify({
      timestamp: AT,
      payload: {
        type: 'token_count',
        info: {
          total_token_usage: { total_tokens: 60_285_342 },
          last_token_usage: { input_tokens: 214_679, cached_input_tokens: 12_160, total_tokens: 215_266 },
          model_context_window: 258_400,
        },
      },
    })
    const parsed = parseCodexContextLine(line, 0)
    expect(parsed?.tokens).toBe(214_679)
    expect(parsed?.window).toBe(258_400)
    // `info` is null on most `token_count` events — the event carries rate
    // limits too — so a null one is an ordinary line to skip.
    expect(parseCodexContextLine(JSON.stringify({ payload: { type: 'token_count', info: null } }), 0)).toBeNull()
  })

  it('says Gemini never writes one, rather than showing a zero', async () => {
    /*
     * Checked on this machine rather than assumed: `~/.gemini` holds nine
     * session files under `~/.gemini/tmp/<project>/chats/`, and a search across
     * the whole directory for `usageMetadata`, `promptTokenCount` or
     * `totalTokenCount` matches only two plugins' documentation. A
     * case-insensitive search for any key containing "token" across the nine
     * session files matches nothing at all.
     *
     * So the answer is a sentence, not a number and not a blank: a zero claims
     * the context is empty, and a reader who finds the figure silently missing
     * on one tab learns only that the feature is unreliable.
     */
    const reading = await readContextWindow({ provider: 'gemini', cwd: '/tmp/whatever' })
    expect(reading.state).toBe('not-reported')
    expect(reading.tokens).toBeNull()
    expect(reading.detail).toContain('Gemini does not record')

    const shell = await readContextWindow({ provider: 'shell', cwd: '/tmp/whatever' })
    expect(shell.state).toBe('not-reported')
    expect(shell.detail).toContain('plain shell')
  })

  it('has one shape for an empty reading, so a second file cannot invent another', () => {
    const blank = blankContextReading(null, 'not-reported', 'Nothing to read.', 12)
    expect(blank).toMatchObject({
      provider: null,
      tokens: null,
      window: null,
      percent: null,
      windowBasis: null,
      source: null,
      reportedAt: 0,
      observedAt: 12,
    })
  })
})

/**
 * Two sessions in one folder, told apart because this app named them.
 *
 * The defect Asad recorded on 2026-08-19, in his own words:
 *
 *   > *"it is showing context window now 44 … but here it is showing 61 which is
 *   > correct, but it is showing same context window for your session too — so
 *   > all the sessions show same context window, so this is a problem"*
 *
 * Both tabs were reading one file, because a session had no identity anything
 * could look up afterwards: the app spawned `claude` with no id, the CLI invented
 * one, and the only way back to a transcript was "the most recently written one
 * in this folder". That is a single answer, so every session in the folder got it.
 *
 * `claude --session-id <uuid>` is the other end of it, verified against Claude
 * Code 2.1.235 on this machine — a run with a generated id wrote exactly
 * `<configDir>/projects/<encoded cwd>/<that uuid>.jsonl`. `host-core.ts` now
 * generates one per session it starts fresh, and these are the two properties
 * that has to buy.
 */
describe('naming the conversation instead of inferring it', () => {
  it('gives two sessions in one folder two different figures', async () => {
    const { configDir, project } = store()
    const cwd = '/tmp/ctx-two-sessions'
    const dir = project(cwd)
    const scope = { configDir, deviceHomes: null, homeScopes: [] } as const

    // One small conversation and one large one, in the same folder, written in
    // that order — so the inference would answer with the *second* for both.
    writeFileSync(
      join(dir, 'aaaaaaaa-0000-4000-8000-000000000001.jsonl'),
      `${turn({ message: { model: 'claude-opus-5', usage: { input_tokens: 1_000, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 } } })}\n`,
    )
    writeFileSync(
      join(dir, 'aaaaaaaa-0000-4000-8000-000000000002.jsonl'),
      `${turn({ message: { model: 'claude-opus-5', usage: { input_tokens: 9_000, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 } } })}\n`,
    )

    const first = await readContextWindow({
      provider: 'claude',
      cwd,
      agentSessionId: 'aaaaaaaa-0000-4000-8000-000000000001',
      scope,
    })
    const second = await readContextWindow({
      provider: 'claude',
      cwd,
      agentSessionId: 'aaaaaaaa-0000-4000-8000-000000000002',
      scope,
    })

    expect(first.tokens).toBe(1_000)
    expect(second.tokens).toBe(9_000)
    // And each says it was named rather than picked, with no rival count — the
    // ambiguity the inference has to confess to does not exist here.
    expect(first.source?.chosen).toBe('named')
    expect(first.source?.rivals).toBe(0)
    expect(second.source?.chosen).toBe('named')

    // The inference, for contrast: one answer for the whole folder, and it is
    // the one both tabs used to show.
    const inferred = await readContextWindow({ provider: 'claude', cwd, scope })
    expect(inferred.source?.chosen).toBe('inferred')
  })

  it('says this session has written nothing rather than reading the neighbour', async () => {
    /*
     * The moment the old behaviour would come straight back if a missing named
     * file fell through to inference — a second tab opened in a busy folder,
     * which is exactly when somebody has two of them on screen to compare.
     */
    const { configDir, project } = store()
    const cwd = '/tmp/ctx-named-quiet'
    writeFileSync(join(project(cwd), 'bbbbbbbb-0000-4000-8000-000000000001.jsonl'), `${turn()}\n`)

    const reading = await readContextWindow({
      provider: 'claude',
      cwd,
      agentSessionId: 'cccccccc-0000-4000-8000-000000000002',
      scope: { configDir, deviceHomes: null, homeScopes: [] },
    })
    expect(reading.state).toBe('nothing-yet')
    expect(reading.tokens).toBeNull()
    expect(reading.detail).toContain('This session has not written a reply yet')
  })

  it('looks for the named conversation in the store its account writes to', async () => {
    /*
     * A confined session runs with a `HOME` of its own and writes under
     * `<deviceHome>/.claude/projects`, not under the account's directory. The
     * named lookup asks `transcriptDirs` for the store list rather than composing
     * one path, so it covers that without the caller having heard of
     * confinement — the class of miss `transcript.ts` records having shipped once.
     */
    const first = store()
    const second = store()
    const cwd = '/tmp/ctx-two-stores'
    second.project(cwd)
    writeFileSync(join(second.project(cwd), 'dddddddd-0000-4000-8000-000000000003.jsonl'), `${turn()}\n`)

    const reading = await readContextWindow({
      provider: 'claude',
      cwd,
      agentSessionId: 'dddddddd-0000-4000-8000-000000000003',
      // The account's own store first, the second one standing in for a device
      // home — `configDirs` returns them in that order.
      scope: { configDir: first.configDir, deviceHomes: null, homeScopes: [] },
    })
    // Not found under the account's store, and this build looks no further than
    // the scope it was given, so the honest answer is the named "nothing yet".
    expect(reading.state).toBe('nothing-yet')

    const found = await readContextWindow({
      provider: 'claude',
      cwd,
      agentSessionId: 'dddddddd-0000-4000-8000-000000000003',
      scope: { configDir: second.configDir, deviceHomes: null, homeScopes: [] },
    })
    expect(found.tokens).toBe(77_216)
    expect(found.source?.chosen).toBe('named')
  })
})

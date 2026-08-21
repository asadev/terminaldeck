import { describe, expect, it } from 'vitest'
import {
  attributeServerTranscript,
  parseSurvey,
  serverSkew,
  surveyScript,
  ServerChatSession,
  SERVER_CHAT_TAIL_BYTES,
  type ServerChatAccess,
} from './chat'

/**
 * The conversation belonging to a terminal on a server.
 *
 * ## Why these are exercised and not scanned
 *
 * Everything here is a *rule* — which file belongs to which shell, what happens
 * when two shells could both claim one, what a second read answers — and each of
 * them has a known-wrong version that is easy to write and impossible to see in
 * a screenshot. The local equivalent shipped two of those wrong versions before
 * `session-transcript.ts` was rewritten, and the reports read *"chat view is
 * showing something else"* rather than anything a developer could act on.
 *
 * So the far end is faked at the two calls it actually makes — one script, and
 * byte ranges — and the rest is the real code: the real attribution, the real
 * `ChatReader`, the real `ChatCollapser`.
 */

/* ------------------------------------------------------------------ the far end -- */

/** One JSONL line of a conversation, in the shape Claude Code writes. */
function said(role: 'user' | 'assistant', at: string, text: string, id: string): string {
  return role === 'user'
    ? `${JSON.stringify({ type: 'user', uuid: id, timestamp: at, message: { content: text } })}\n`
    : `${JSON.stringify({
        type: 'assistant',
        uuid: id,
        timestamp: at,
        message: { id, content: [{ type: 'text', text }] },
      })}\n`
}

/**
 * A server with some files on it and a clock of its own.
 *
 * `skewMs` is the whole reason this is a class rather than two closures: a
 * server whose clock is minutes out from this one is the case that silently
 * attributes the wrong conversation, and it cannot be exercised without a fake
 * that can *be* minutes out.
 */
class FakeServer implements ServerChatAccess {
  readonly files = new Map<string, string>()
  scripts = 0
  reads = 0

  constructor(
    private readonly now: () => number,
    private readonly skewMs = 0,
  ) {}

  /** The `startedAt` the survey will report for a file, read out of its first line. */
  private firstTimestamp(body: string): string | null {
    const match = /"timestamp":"([^"]*)"/.exec(body.split('\n')[0] ?? '')
    return match?.[1] ?? null
  }

  async runScript(): Promise<{ stdout: string; code: number | null }> {
    this.scripts += 1
    const lines = [`now\t${Math.trunc((this.now() + this.skewMs) / 1000)}`]
    for (const [path, body] of this.files) {
      const at = this.firstTimestamp(body)
      if (at !== null) lines.push(`file\t${at}\t${path}`)
    }
    return { stdout: `${lines.join('\n')}\n`, code: 0 }
  }

  async readFileRange(
    _serverId: string,
    path: string,
    from: number,
    length: number,
  ): Promise<{ bytes: Buffer; size: number }> {
    this.reads += 1
    const whole = Buffer.from(this.files.get(path) ?? '', 'utf8')
    return { bytes: whole.subarray(from, from + length), size: whole.length }
  }
}

/** Server time for a transcript line, given a skew. */
function stampAt(ms: number): string {
  return new Date(ms).toISOString()
}

/* ------------------------------------------------------------------- the script -- */

describe('the one question put to the server', () => {
  it('reads the leftmost timestamp on a line, and stops at the first line that has one', () => {
    const script = surveyScript(3)
    /*
     * `match()` and not a `sed` with a greedy wildcard. A transcript line can
     * carry a nested timestamp inside a tool result, and a `sed` expression that
     * skips forward with a wildcard answers with the *last* timestamp on the
     * line — a different minute belonging to a different turn.
     */
    expect(script).toContain('match($0,/"timestamp":"[^"]*"/)')
    expect(script).toContain('substr($0,RSTART+13,RLENGTH-14)')
    expect(script).toContain('exit')
  })

  it('looks back further than the shell is old, and still looks when -mmin is refused', () => {
    // Whole minutes, rounded against us, and two clocks aligned only to the
    // nearest second: a filter exactly as old as the shell drops the file that
    // matters. And a `find` without `-mmin` — busybox, an old BSD — must fall
    // back to looking at everything rather than answering nothing.
    expect(surveyScript(3)).toContain('-mmin -5')
    expect(surveyScript(0)).toContain('-mmin -2')
    expect(surveyScript(3)).toContain("if [ -z \"$FILES\" ]; then")
  })

  it('looks in the sign-in’s own home and assembles no path of its own', () => {
    const script = surveyScript(1)
    expect(script).toContain('"${HOME:-.}/.claude/projects"')
    expect(script).not.toContain('/home/')
  })
})

describe('reading what came back', () => {
  it('keeps a path with a tab in it whole', () => {
    // A folder on somebody's server is allowed to have a tab in its name.
    // Splitting on every tab turns that path into two and then fails to open
    // either, with nothing on screen saying why.
    const survey = parseSurvey(
      'now\t1000\nfile\t2026-08-21T10:00:00.000Z\t/home/a/od\td/x.jsonl\n',
      0,
    )
    expect(survey.transcripts).toEqual([
      { path: '/home/a/od\td/x.jsonl', startedAt: Date.parse('2026-08-21T10:00:00.000Z') },
    ])
    expect(survey.serverNow).toBe(1_000_000)
  })

  it('drops a line whose timestamp will not parse rather than dating it zero', () => {
    // A zero sorts before every shell that has ever opened, so it would be
    // claimed by the first one to ask.
    const survey = parseSurvey('now\t2\nfile\tnot-a-date\t/x.jsonl\nfile\t\t/y.jsonl\n', 0)
    expect(survey.transcripts).toEqual([])
  })

  it('falls back to this computer’s clock when the server did not answer with one', () => {
    expect(parseSurvey('file\t2026-08-21T10:00:00.000Z\t/x.jsonl\n', 4_242).serverNow).toBe(4_242)
  })

  it('measures the offset in the direction that claims fewer conversations', () => {
    // The round trip is inside the answer, so the offset is at most one round
    // trip too large and never too small — which pushes the shell's opening
    // moment later in server time, and a later opening moment can only ever
    // rule conversations out.
    expect(serverSkew({ serverNow: 5_000, transcripts: [] }, 1_000)).toBe(4_000)
  })
})

/* --------------------------------------------------------------- the attribution -- */

describe('which conversation belongs to which terminal', () => {
  const at = (iso: string): number => Date.parse(iso)

  it('will not claim a conversation that began before the shell opened', () => {
    const verdict = attributeServerTranscript(
      [{ path: '/old.jsonl', startedAt: at('2026-08-21T09:00:00Z') }],
      at('2026-08-21T10:00:00Z'),
    )
    expect(verdict).toEqual({ kind: 'none' })
  })

  it('takes the newest of the conversations it can claim, not the first', () => {
    // A shell writes more than one conversation over its life: `/clear` starts a
    // fresh one under a new name in the same terminal, and the pane exists to
    // show the one the terminal beside it is showing.
    const verdict = attributeServerTranscript(
      [
        { path: '/first.jsonl', startedAt: at('2026-08-21T10:01:00Z') },
        { path: '/second.jsonl', startedAt: at('2026-08-21T10:20:00Z') },
      ],
      at('2026-08-21T10:00:00Z'),
    )
    expect(verdict).toEqual({
      kind: 'choice',
      path: '/second.jsonl',
      startedAt: at('2026-08-21T10:20:00Z'),
    })
  })

  it('refuses to guess when a second terminal on the same server could have written it', () => {
    /*
     * The bug this whole rule exists for, with a server underneath it. Two
     * shells opened before either had been typed into have identical candidate
     * sets, so "the earliest conversation that began after this shell" hands
     * **both** of them the same file — one pane reads the other's words while
     * its own terminal, two keystrokes away, shows something else.
     */
    const verdict = attributeServerTranscript(
      [{ path: '/one.jsonl', startedAt: at('2026-08-21T10:05:00Z') }],
      at('2026-08-21T10:00:00Z'),
      [at('2026-08-21T10:00:30Z')],
    )
    expect(verdict).toEqual({ kind: 'ambiguous', candidates: 1, competing: 1 })
  })

  it('claims one that began before the next shell did', () => {
    const verdict = attributeServerTranscript(
      [{ path: '/mine.jsonl', startedAt: at('2026-08-21T10:00:10Z') }],
      at('2026-08-21T10:00:00Z'),
      [at('2026-08-21T10:00:30Z')],
    )
    expect(verdict).toEqual({
      kind: 'choice',
      path: '/mine.jsonl',
      startedAt: at('2026-08-21T10:00:10Z'),
    })
  })

  it('treats a tie between two shells as undecidable rather than as a win', () => {
    // Two shells stamped with the same millisecond genuinely cannot be told
    // apart, and reading a tie as "the other one had not started yet" hands this
    // shell a conversation with an equal claim on it.
    const opened = at('2026-08-21T10:00:00Z')
    expect(
      attributeServerTranscript([{ path: '/x.jsonl', startedAt: opened + 5 }], opened, [opened]),
    ).toMatchObject({ kind: 'ambiguous' })
  })

  it('allows a conversation begun a moment before the shell was believed to open', () => {
    // `date` answers whole seconds and the round trip is not instant, so the
    // opening moment converted into server time is good to about a second.
    // Without slack, a `claude` started the instant a terminal opened is ruled
    // out of its own session.
    const opened = at('2026-08-21T10:00:00Z')
    expect(
      attributeServerTranscript([{ path: '/x.jsonl', startedAt: opened - 900 }], opened),
    ).toMatchObject({ kind: 'choice', path: '/x.jsonl' })
  })
})

/* ------------------------------------------------------------------ the reading -- */

describe('a shell’s conversation, read over the wire', () => {
  const OPENED = Date.parse('2026-08-21T10:00:00Z')

  function sessionOn(
    server: FakeServer,
    clock: { now: number },
    others: readonly number[] = [],
  ): ServerChatSession {
    return new ServerChatSession(server, 'srv', OPENED, () => others, () => clock.now)
  }

  it('folds the far transcript with the same collapser the local view uses', async () => {
    const clock = { now: OPENED + 60_000 }
    const server = new FakeServer(() => clock.now)
    server.files.set(
      '/home/me/.claude/projects/p/live.jsonl',
      said('user', stampAt(OPENED + 1_000), 'build it', 'u1') +
        said('assistant', stampAt(OPENED + 2_000), 'Starting.', 'a1') +
        said('assistant', stampAt(OPENED + 3_000), 'Done.', 'a2'),
    )

    const update = await sessionOn(server, clock).load()
    expect(update.found).toBe(true)
    expect(update.transcriptPath).toBe('/home/me/.claude/projects/p/live.jsonl')
    // Two bubbles, not three: consecutive agent text is one turn, which is the
    // whole reason the collapser is shared rather than reimplemented here.
    expect(update.messages.map((one) => one.role)).toEqual(['you', 'agent'])
    expect(update.messages[1].text).toBe('Starting.\n\nDone.')
    expect(update.startedMidFile).toBe(false)
  })

  it('answers only what was appended on the next read', async () => {
    const clock = { now: OPENED + 60_000 }
    const server = new FakeServer(() => clock.now)
    const path = '/p/live.jsonl'
    server.files.set(path, said('user', stampAt(OPENED + 1_000), 'first', 'u1'))

    const session = sessionOn(server, clock)
    await session.load()
    server.files.set(
      path,
      `${server.files.get(path)}${said('assistant', stampAt(OPENED + 2_000), 'reply', 'a1')}`,
    )
    clock.now += 1_000
    const tail = await session.tail()
    expect(tail.messages.map((one) => one.text)).toEqual(['reply'])
    expect(tail.reset).toBe(false)
  })

  it('says so when it entered a large transcript late', async () => {
    /*
     * There is no equivalent cap locally and the difference is the wire: a
     * transcript reaches 154 MB on this machine and most of that weight is tool
     * results the chat view discards. Reading one whole is a disk read here and
     * the entire file over SSH there.
     *
     * The promise is not that it reads everything — it is that it never shows a
     * fragment as if it were the whole conversation.
     */
    const clock = { now: OPENED + 60_000 }
    const server = new FakeServer(() => clock.now)
    const filler = said('user', stampAt(OPENED + 1_000), 'x'.repeat(SERVER_CHAT_TAIL_BYTES), 'u1')
    server.files.set('/p/big.jsonl', filler + said('assistant', stampAt(OPENED + 2_000), 'late', 'a1'))

    const update = await sessionOn(server, clock).load()
    expect(update.startedMidFile).toBe(true)
    expect(update.messages.map((one) => one.text)).toEqual(['late'])
  })

  it('says it cannot tell rather than showing one of two terminals the other’s words', async () => {
    const clock = { now: OPENED + 60_000 }
    const server = new FakeServer(() => clock.now)
    server.files.set('/p/one.jsonl', said('user', stampAt(OPENED + 5_000), 'hello', 'u1'))

    const update = await sessionOn(server, clock, [OPENED + 500]).load()
    // Not `found: false`, which is the sentence for "there is no conversation".
    expect(update.unattributable).toEqual({ candidates: 1, competing: 1 })
    expect(update.messages).toEqual([])
  })

  it('is not fooled by a server whose clock is minutes out from this one', async () => {
    /*
     * The transcript's timestamp is written by the server's clock and the
     * opening moment was taken by this one. Compared directly, a server ten
     * minutes ahead makes every conversation look like it began long after the
     * shell — and one ten minutes behind rules out every conversation the shell
     * actually had.
     */
    const clock = { now: OPENED + 60_000 }
    const ahead = new FakeServer(() => clock.now, 10 * 60_000)
    ahead.files.set(
      '/p/live.jsonl',
      // Written by the server's clock: ten minutes ahead of this computer's.
      said('user', stampAt(OPENED + 10 * 60_000 + 1_000), 'hello', 'u1'),
    )
    const forward = await sessionOn(ahead, clock).load()
    expect(forward.messages.map((one) => one.text)).toEqual(['hello'])

    const behind = new FakeServer(() => clock.now, -10 * 60_000)
    behind.files.set(
      '/p/live.jsonl',
      said('user', stampAt(OPENED - 10 * 60_000 + 1_000), 'hello', 'u1'),
    )
    const backward = await sessionOn(behind, clock).load()
    expect(backward.messages.map((one) => one.text)).toEqual(['hello'])
  })

  it('re-asks which file this is, so a `/clear` does not leave the pane on a dead one', async () => {
    /*
     * `/clear` starts a *new* conversation under a new name in the same
     * terminal, and so does quitting the CLI and running it again. A pane bound
     * once showed the finished conversation for the rest of the session's life
     * while the terminal beside it showed the live one — a real defect in the
     * local view, and there is no reason for the far one to relearn it.
     */
    const clock = { now: OPENED + 60_000 }
    const server = new FakeServer(() => clock.now)
    server.files.set('/p/first.jsonl', said('user', stampAt(OPENED + 1_000), 'before', 'u1'))

    const session = sessionOn(server, clock)
    await session.load()
    server.files.set('/p/second.jsonl', said('user', stampAt(OPENED + 30_000), 'after', 'u2'))
    // Past the re-look window, which is deliberately not every append: the
    // answer changes when somebody runs `/clear`, not while a reply streams.
    clock.now += 20_000
    const tail = await session.tail()
    expect(tail.transcriptPath).toBe('/p/second.jsonl')
    expect(tail.reset).toBe(true)
    expect(tail.messages.map((one) => one.text)).toEqual(['after'])
  })

  it('keeps looking, but not on every read, while the shell has said nothing yet', async () => {
    /*
     * The state a person is waiting out: a shell is open, the first message has
     * not been typed, and the pane should fill in when it lands. Faster than the
     * bound interval and still not every read — each survey is a `find` and an
     * `awk` per recent transcript on a machine somebody else is using.
     */
    const clock = { now: OPENED + 60_000 }
    const server = new FakeServer(() => clock.now)
    const session = sessionOn(server, clock)
    const empty = await session.load()
    expect(empty.found).toBe(false)

    const afterLoad = server.scripts
    await session.tail()
    expect(server.scripts, 'a survey per read').toBe(afterLoad)

    clock.now += 6_000
    server.files.set('/p/live.jsonl', said('user', stampAt(OPENED + 61_000), 'at last', 'u1'))
    const found = await session.tail()
    expect(found.messages.map((one) => one.text)).toEqual(['at last'])
  })

  it('does not re-survey the server on every read', async () => {
    // One script and one `awk` per recent transcript is not a thing to do three
    // times a second for the whole of a long reply.
    const clock = { now: OPENED + 60_000 }
    const server = new FakeServer(() => clock.now)
    server.files.set('/p/live.jsonl', said('user', stampAt(OPENED + 1_000), 'hello', 'u1'))

    const session = sessionOn(server, clock)
    await session.load()
    const afterLoad = server.scripts
    await session.tail()
    await session.tail()
    expect(server.scripts).toBe(afterLoad)
  })

  it('reports nothing found when the shell has no conversation at all', async () => {
    const clock = { now: OPENED + 60_000 }
    const update = await sessionOn(new FakeServer(() => clock.now), clock).load()
    expect(update.found).toBe(false)
    expect(update.unattributable).toBeUndefined()
    expect(update.messages).toEqual([])
  })
})

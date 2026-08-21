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

/* --------------------------------------------------------------- the pushing -- */

/**
 * A conversation that arrives instead of being asked for.
 *
 * ## What was wrong with the version that worked
 *
 * Nothing a screenshot would show, which is why it needs a test. The pane asked
 * for the same transcript every three seconds — twelve hundred round trips an
 * hour over somebody's SSH link, almost all of them answering "nothing new", and
 * still up to three seconds late when there was something. His standing rule is
 * one sentence: *"events, not polling — they make the system heavier."*
 *
 * So there are two events and neither of them is a timer, and the pair is what
 * these exercise:
 *
 *  1. **The file grew** — a `tail -f` running on that server, on the channel
 *     `connection.ts` opens for a command that is not expected to finish.
 *  2. **The file changed identity** — `/clear` starts a *new* transcript, the
 *     old one simply stops growing, and no `tail` on earth reports that. The
 *     event that does exist is the terminal's own output, which this app already
 *     receives because it is drawing it two views away.
 *
 * And a third thing, which is the one a live view is not allowed to get wrong:
 * when neither event is available the pane must **say** it is on a timer rather
 * than look identical to one that is current.
 */
describe('a conversation that pushes', () => {
  const OPENED = Date.parse('2026-08-21T10:00:00Z')

  /** A `tail -f` the test can make grow, refuse, or die. */
  class FakeFollow {
    bytes: ((chunk: Buffer) => void)[] = []
    ends: ((why: { code: number | null; stderr: string }) => void)[] = []
    closes = 0

    onBytes(listener: (chunk: Buffer) => void): () => void {
      this.bytes.push(listener)
      return () => undefined
    }

    onEnd(listener: (why: { code: number | null; stderr: string }) => void): () => void {
      this.ends.push(listener)
      return () => undefined
    }

    close(): void {
      this.closes += 1
    }

    /** What the far end printing looks like from here. Bytes are discarded. */
    grew(): void {
      for (const listener of this.bytes) listener(Buffer.from('{}\n', 'utf8'))
    }

    died(stderr = 'tail: unrecognized option'): void {
      for (const listener of this.ends) listener({ code: 1, stderr })
    }
  }

  /** The far end, plus a channel it may or may not agree to open. */
  class FollowingServer extends FakeServer {
    followed: (readonly string[])[] = []
    streams: FakeFollow[] = []
    refuse = false

    async follow(_serverId: string, argv: readonly string[]): Promise<FakeFollow> {
      this.followed.push(argv)
      if (this.refuse) throw new Error('no such command')
      const stream = new FakeFollow()
      this.streams.push(stream)
      return stream
    }
  }

  function sessionOn(server: ServerChatAccess, clock: { now: number }): ServerChatSession {
    return new ServerChatSession(server, 'srv', OPENED, () => [], () => clock.now)
  }

  /** One turn of the event loop, so an `await`ed follow has settled. */
  const settle = (): Promise<void> => new Promise((resolve) => setImmediate(resolve))

  it('follows the bound transcript and says the pane is live', async () => {
    const clock = { now: OPENED + 60_000 }
    const server = new FollowingServer(() => clock.now)
    server.files.set('/p/live.jsonl', said('user', stampAt(OPENED + 1_000), 'hello', 'u1'))

    const session = sessionOn(server, clock)
    session.watch(() => undefined)
    const update = await session.load()

    expect(update.found).toBe(true)
    /*
     * `-n 0`, not `-c +N`. POSIX specifies the leading `+` and several real
     * `tail`s do not implement it — busybox reads `-c +5000` as *"the last 5000
     * bytes"*, with no error and no complaint, and this side would splice those
     * bytes into the file at the wrong offset and turn every line after them
     * into garbage. `-n 0 -f` cannot be misread into producing bytes, and the
     * bytes it does produce are thrown away: what this channel carries is the
     * *fact* that the file grew.
     */
    expect(server.followed).toEqual([['tail', '-n', '0', '-f', '/p/live.jsonl']])
    expect(update.feed).toBe('live')
  })

  it('tells the window the moment the channel is open, before anything is pushed', async () => {
    // `tail -n 0 -f` starts at the file's end as it is when the command runs,
    // and this side's offset is where the last read got to — a round trip
    // earlier. Anything appended in between is in neither, and would sit unread
    // until the next append happened along.
    const clock = { now: OPENED + 60_000 }
    const server = new FollowingServer(() => clock.now)
    server.files.set('/p/live.jsonl', said('user', stampAt(OPENED + 1_000), 'hello', 'u1'))

    const told: string[] = []
    const session = sessionOn(server, clock)
    session.watch((feed) => told.push(feed))
    await session.load()
    expect(told).toEqual(['live'])
  })

  it('keeps the timer, and says so, on a server whose tail will not follow', async () => {
    const clock = { now: OPENED + 60_000 }
    const server = new FollowingServer(() => clock.now)
    server.refuse = true
    server.files.set('/p/live.jsonl', said('user', stampAt(OPENED + 1_000), 'hello', 'u1'))

    const session = sessionOn(server, clock)
    session.watch(() => undefined)
    const update = await session.load()
    // Found the conversation, could not stream it, and says which — the whole
    // point of the field. A pane that claimed `live` here would be a control
    // that appears to work and does not.
    expect(update.found).toBe(true)
    expect(update.feed).toBe('polled')
  })

  it('falls back and tells the window when the tail dies later', async () => {
    const clock = { now: OPENED + 60_000 }
    const server = new FollowingServer(() => clock.now)
    server.files.set('/p/live.jsonl', said('user', stampAt(OPENED + 1_000), 'hello', 'u1'))

    const told: string[] = []
    const session = sessionOn(server, clock)
    session.watch((feed) => told.push(feed))
    await session.load()
    server.streams[0].died()
    // Not silence: a pane that was told `live` and then hears nothing is a pane
    // sitting on a conversation that has stopped moving, with no timer running
    // because it was told it did not need one.
    expect(told).toEqual(['live', 'polled'])
    expect((await session.tail()).feed).toBe('polled')
    // One attempt per file, not one per read: a `tail` that answered
    // `unrecognized option` will answer it again in three seconds, and retrying
    // would open and tear down a channel on somebody's server on every read —
    // a busier version of the polling this is here to remove.
    expect(server.followed).toHaveLength(1)
  })

  it('does not ask the server anything at all while nothing is pushed', async () => {
    // The measurement the whole change is for. Before it, three reads and a
    // survey every three seconds for as long as the pane was open.
    const clock = { now: OPENED + 60_000 }
    const server = new FollowingServer(() => clock.now)
    server.files.set('/p/live.jsonl', said('user', stampAt(OPENED + 1_000), 'hello', 'u1'))

    const session = sessionOn(server, clock)
    session.watch(() => undefined)
    await session.load()
    const scripts = server.scripts
    const reads = server.reads
    clock.now += 600_000
    await settle()
    expect(server.scripts, 'ten quiet minutes').toBe(scripts)
    expect(server.reads).toBe(reads)
  })

  it('moves the tail to the new file when /clear rebinds the conversation', async () => {
    const clock = { now: OPENED + 60_000 }
    const server = new FollowingServer(() => clock.now)
    server.files.set('/p/first.jsonl', said('user', stampAt(OPENED + 1_000), 'hello', 'u1'))

    const session = sessionOn(server, clock)
    session.watch(() => undefined)
    await session.load()
    expect(server.followed).toHaveLength(1)

    // `/clear`: a *new* file, and the old one simply stops growing.
    server.files.set('/p/second.jsonl', said('user', stampAt(OPENED + 40_000), 'again', 'u2'))
    clock.now += 20_000
    const after = await session.tail()

    expect(after.transcriptPath).toBe('/p/second.jsonl')
    expect(after.reset, 'the view replaces rather than appends').toBe(true)
    expect(server.followed[1]).toEqual(['tail', '-n', '0', '-f', '/p/second.jsonl'])
    // And the channel on the finished conversation was hung up rather than left
    // running on somebody's server delivering nothing forever.
    expect(server.streams[0].closes).toBe(1)
  })

  it('asks again when the terminal prints, and not on every byte of it', async () => {
    /*
     * The pty is the only event there is for *which* file this is. `/clear`
     * starts a new transcript and no `tail` reports that; what does exist is
     * that somebody typed into this shell, and a shell prints. So the bytes
     * already arriving for the terminal view are the signal — and an idle
     * terminal asks that server nothing at all.
     *
     * Rate-limited to the window `resolve` uses, because a survey is a `find`
     * and an `awk` per recent transcript on a machine somebody else is using,
     * and a streaming reply would otherwise ask for one on every chunk.
     */
    const clock = { now: OPENED + 60_000 }
    const server = new FollowingServer(() => clock.now)
    server.files.set('/p/live.jsonl', said('user', stampAt(OPENED + 1_000), 'hello', 'u1'))

    const told: string[] = []
    const session = sessionOn(server, clock)
    session.watch((feed) => told.push(feed))
    await session.load()
    told.length = 0

    for (let i = 0; i < 500; i += 1) session.nudge()
    expect(told, 'five hundred chunks of a streaming reply').toHaveLength(1)

    clock.now += 16_000
    session.nudge()
    expect(told).toHaveLength(2)
  })

  it('asks sooner while no conversation has been found yet', async () => {
    // The state a person is waiting out: they have opened a shell and are about
    // to type the first message, and the pane should fill in when it lands.
    const clock = { now: OPENED + 60_000 }
    const server = new FollowingServer(() => clock.now)

    const told: string[] = []
    const session = sessionOn(server, clock)
    session.watch((feed) => told.push(feed))
    const update = await session.load()
    expect(update.found).toBe(false)
    // Nothing to follow, so nothing was asked to follow it — and the pane is
    // told it is on a timer rather than left claiming a stream that is not there.
    expect(server.followed).toEqual([])
    expect(update.feed).toBe('polled')

    told.length = 0
    session.nudge()
    clock.now += 5_100
    session.nudge()
    expect(told).toHaveLength(2)
  })

  it('hangs up the far end when the pane closes, and stops pushing', async () => {
    const clock = { now: OPENED + 60_000 }
    const server = new FollowingServer(() => clock.now)
    server.files.set('/p/live.jsonl', said('user', stampAt(OPENED + 1_000), 'hello', 'u1'))

    const told: string[] = []
    const session = sessionOn(server, clock)
    session.watch((feed) => told.push(feed))
    await session.load()
    told.length = 0

    session.close()
    expect(server.streams[0].closes).toBe(1)
    // One last telling on the way out — that the stream has gone — and then
    // nothing. See the case below for why that one matters.
    expect(told).toEqual(['polled'])
    told.length = 0
    server.streams[0].grew()
    clock.now += 60_000
    session.nudge()
    expect(told, 'a closed pane is not pushed to').toEqual([])
    // Still readable: the transcript is lying on that server and a pane on a
    // terminal that exited can still show what was said in it.
    expect((await session.tail()).feed).toBe('polled')
  })

  it('hangs up the far end while nobody is looking, and reads to the end on return', async () => {
    /*
     * A pane that is mounted but off screen has always cost nothing. That
     * promise needs keeping out loud now that the far end can talk first: a
     * `tail -f` sends a transcript's appends whether or not this side reads
     * them, and a long tool result on a background tab is real traffic on
     * somebody's server for something nobody can see.
     */
    const clock = { now: OPENED + 60_000 }
    const server = new FollowingServer(() => clock.now)
    const path = '/p/live.jsonl'
    server.files.set(path, said('user', stampAt(OPENED + 1_000), 'hello', 'u1'))

    const told: string[] = []
    const session = sessionOn(server, clock)
    session.watch((feed) => told.push(feed))
    await session.load()

    session.setWatched(false)
    expect(server.streams[0].closes).toBe(1)
    expect((await session.tail()).feed).toBe('polled')

    // Written while nobody was watching, so nothing pushed and nothing was read.
    server.files.set(
      path,
      `${server.files.get(path)}${said('assistant', stampAt(OPENED + 70_000), 'while you were away', 'a1')}`,
    )
    told.length = 0

    session.setWatched(true)
    await settle()
    // Told the moment the channel is back — which is also the catch-up, because
    // the read that follows walks the file to the end.
    expect(told).toEqual(['live'])
    const back = await session.tail()
    expect(back.messages.map((one) => one.text)).toContain('while you were away')
    expect(back.feed).toBe('live')
    // The reader survived it: coming back is one read, not the whole tail window
    // across the link again.
    expect(back.reset).toBe(false)
  })

  it('stops claiming to be live when the terminal it belongs to goes', async () => {
    /*
     * A shell whose far end went away keeps its tab and its scrollback, so its
     * chat pane is still on screen — still reading "Live", and still holding its
     * own timer off because it was told it did not need one. A sentence that
     * says a dead terminal is streaming is the exact defect this round is
     * against.
     */
    const clock = { now: OPENED + 60_000 }
    const server = new FollowingServer(() => clock.now)
    server.files.set('/p/live.jsonl', said('user', stampAt(OPENED + 1_000), 'hello', 'u1'))

    const told: string[] = []
    const session = sessionOn(server, clock)
    session.watch((feed) => told.push(feed))
    await session.load()
    told.length = 0

    session.close()
    expect(told, 'the window was never told the stream had gone').toEqual(['polled'])
  })

  it('never lets two reads share one offset', async () => {
    /*
     * `ChatReader` advances a byte offset after each read, so two overlapping
     * reads both start from the same place, both fetch the same range and both
     * add its length — the offset ends up a chunk past where it should be and a
     * paragraph is skipped. The dedupe set hides the duplicate half of that;
     * nothing hides the missing half.
     *
     * It was a narrow window while the only callers were a load and a timer. It
     * stops being narrow the moment the far end can talk first, because a push
     * arriving while the pane is still loading is the ordinary case for a
     * conversation being written right now.
     */
    const clock = { now: OPENED + 60_000 }
    const server = new FollowingServer(() => clock.now)
    const lines = [
      said('user', stampAt(OPENED + 1_000), 'one', 'u1'),
      said('assistant', stampAt(OPENED + 2_000), 'two', 'a1'),
      said('assistant', stampAt(OPENED + 3_000), 'three', 'a2'),
    ]
    server.files.set('/p/live.jsonl', lines.join(''))

    const session = sessionOn(server, clock)
    session.watch(() => undefined)
    const [load, tail] = await Promise.all([session.load(), session.tail()])
    const seen = [...load.messages, ...tail.messages].map((one) => one.text).join('\n')
    expect(seen).toContain('one')
    expect(seen).toContain('two\n\nthree')
  })

  it('says it is on a timer when this build cannot follow anything', async () => {
    // `follow` is optional on the seam, and a build without it is the build this
    // app had yesterday. It must keep the timer, not lose the pane.
    const clock = { now: OPENED + 60_000 }
    const server = new FakeServer(() => clock.now)
    server.files.set('/p/live.jsonl', said('user', stampAt(OPENED + 1_000), 'hello', 'u1'))

    const session = sessionOn(server, clock)
    session.watch(() => undefined)
    const update = await session.load()
    expect(update.found).toBe(true)
    expect(update.feed).toBe('polled')
  })
})

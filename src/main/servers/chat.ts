/**
 * The conversation belonging to a terminal on a server.
 *
 * ## What was missing, and what it cost
 *
 * Chat mode reads the agent's own transcript file. For a session on this Mac
 * that file is beside the session; for a session on a **paired machine** the far
 * copy of this app reads it and the collapsed bubbles travel over the relay. For
 * a terminal on a **server** neither of those is true: a server does not run
 * this app, there is a pty over SSH and nothing at the far end that reads a
 * filesystem for a conversation. So the mode switch refused chat with a sentence
 * saying exactly that, which was honest and was still a hole — a `claude`
 * running in that terminal is writing a transcript the whole time, four hundred
 * milliseconds away, and the app was declining to look at it.
 *
 * This module looks. It is two questions and neither of them is a guess:
 *
 *  1. **Which file is this shell's conversation?**  {@link surveyScript}
 *     asks the server, once, for every transcript under `$HOME/.claude/projects`
 *     that has been written to since the shell opened, together with the
 *     timestamp on each one's own first line. {@link attributeServerTranscript}
 *     then applies the rule `renderer/session-transcript.ts` already applies
 *     locally, and applies it for the same reason.
 *  2. **What has been added to it since last time?**  A {@link ChatReader} — the
 *     same class the local chat view uses, with the same dedupe set and the same
 *     collapser — pointed at a {@link ChatBytes} that reads byte ranges over
 *     SFTP instead of out of `node:fs`. Nothing about how a transcript becomes
 *     bubbles is written twice.
 *
 * ## Birth times do not survive the crossing, and first lines do
 *
 * The local attribution rests on a transcript file's **birth time**: a
 * conversation that began before a tab opened cannot be that tab's. Over SSH
 * there is no portable way to ask for one — `stat -c %W` is GNU-only, answers
 * `0` on most ext4 mounts, and SFTP's attribute set has no creation time at all.
 *
 * The transcript says it itself. Every line carries an ISO `timestamp`, and the
 * first one in the file is when the conversation began — resuming *appends*
 * rather than starting a new file, verified on this machine where a transcript
 * born on 1 June was still being appended to on 13 August. So the first line's
 * timestamp is the same fact the birth time was standing in for, read from the
 * only witness that travels.
 *
 * ## Two clocks
 *
 * That timestamp is written by the **server's** clock and the moment the shell
 * opened was taken by **this** one, and comparing them directly is how a server
 * whose clock is four minutes out silently attributes the wrong conversation.
 * The survey therefore answers the server's own `date` in the same round trip,
 * and {@link serverSkew} turns the two into an offset that is applied to the
 * shell's opening moment before anything is compared. Measured rather than
 * assumed, once per read, which is the only honest way to compare two clocks
 * neither of which this app sets.
 */

import { ChatReader, type ChatBytes, type ChatMessage } from '../chat-transcript'

/* ------------------------------------------------------------ what is out there -- */

/** One transcript on a server, as the survey reports it. */
export interface ServerTranscript {
  /** The absolute path on the server. */
  path: string
  /**
   * Epoch ms of the first timestamped line in the file — when the conversation
   * began — **on the server's clock**.
   */
  startedAt: number
}

/** Everything one survey round trip answered. */
export interface TranscriptSurvey {
  /** The server's own idea of now, epoch ms, at the moment the script ran. */
  serverNow: number
  transcripts: ServerTranscript[]
}

/**
 * Which conversation belongs to a shell, or why that cannot be said.
 *
 * Three answers rather than two, exactly as `attributeTranscript` has three:
 * *nothing yet* and *cannot tell* want different words on screen and only one of
 * them is fixed by waiting. A pane that draws "nothing yet" over a busy terminal
 * is telling somebody staring at a reply that their session has said nothing.
 */
export type ServerTranscriptVerdict =
  | { kind: 'none' }
  | { kind: 'choice'; path: string; startedAt: number }
  | { kind: 'ambiguous'; candidates: number; competing: number }

/* ------------------------------------------------------------------- the survey -- */

/**
 * How far back the survey looks, beyond the age of the shell itself.
 *
 * `find -mmin` takes whole minutes and rounds against us, and the two clocks are
 * only aligned to the nearest second. Two extra minutes costs a handful of files
 * in the listing and removes a class of "the app cannot find a conversation that
 * is right there" that would be maddening to diagnose.
 */
const SURVEY_SLACK_MINUTES = 2

/**
 * The most files one survey will open.
 *
 * A cap rather than a belief about how many there are: a project this app has
 * been used on all week has hundreds of transcripts, and the fallback branch
 * below drops the time filter entirely on a server whose `find` does not have
 * `-mmin`. One `awk` per file is cheap; ten thousand of them is a minute of
 * somebody's server.
 */
const SURVEY_MAX_FILES = 400

/**
 * The script the server runs, once, per resolution.
 *
 * `sh`, not `bash` — plenty of real servers have neither bash nor GNU
 * coreutils; Alpine ships `ash` and the smallest containers ship `busybox`.
 * Everything below is POSIX apart from `find -mmin`, which is checked rather
 * than assumed: when it fails the listing falls back to every transcript, which
 * is slower and still correct.
 *
 * The `awk` is the whole trick and is worth reading closely. `match()` finds the
 * **leftmost** occurrence, so `"timestamp":"…"` inside a nested tool result
 * later on the line cannot win over the line's own; `RSTART+13` steps past
 * `"timestamp":"` and `RLENGTH-14` drops that prefix and the closing quote; and
 * `exit` stops at the first line that has one, so this reads the head of a file
 * rather than a file. A `sed` with `.*` would have been greedy and taken the
 * last timestamp on the line, which is a different conversation's minute on a
 * line that replays one.
 *
 * `$HOME/.claude/projects` and nowhere else. A confined session on *this*
 * machine writes under a device home of its own — `transcript.ts` knows the
 * several places to look here — but nothing this app installs on a server
 * confines anything, so the sign-in's own home is the whole of it. A server
 * where somebody has set `CLAUDE_CONFIG_DIR` is not covered and will report no
 * conversation, which is the honest failure: no file was found, rather than
 * somebody else's file offered as this one's.
 */
export function surveyScript(sinceMinutes: number): string {
  const minutes = Math.max(1, Math.ceil(sinceMinutes) + SURVEY_SLACK_MINUTES)
  return `
set -u
printf 'now\\t%s\\n' "$(date -u +%s)"
D="\${HOME:-.}/.claude/projects"
[ -d "$D" ] || exit 0
FILES=$(find "$D" -type f -name '*.jsonl' -mmin -${minutes} 2>/dev/null)
if [ -z "$FILES" ]; then
  FILES=$(find "$D" -type f -name '*.jsonl' 2>/dev/null)
fi
printf '%s\\n' "$FILES" | (
  n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n+1))
    [ "$n" -le ${SURVEY_MAX_FILES} ] || break
    t=$(awk 'match($0,/"timestamp":"[^"]*"/){print substr($0,RSTART+13,RLENGTH-14); exit}' "$f" 2>/dev/null)
    [ -n "$t" ] || continue
    printf 'file\\t%s\\t%s\\n' "$t" "$f"
  done
)
`
}

/**
 * Read the survey's answer.
 *
 * Tab-separated, and the path is *the rest of the line* rather than the third
 * field: a folder on somebody's server is allowed to have a tab in its name, and
 * splitting on every tab would turn that path into two and then fail to open
 * either. A line whose timestamp will not parse is dropped rather than being
 * given a zero, because a zero sorts before every shell that has ever opened and
 * would be claimed by the first one to ask.
 */
export function parseSurvey(stdout: string, at: number): TranscriptSurvey {
  let serverNow = at
  const transcripts: ServerTranscript[] = []
  for (const line of stdout.split('\n')) {
    if (line.startsWith('now\t')) {
      const seconds = Number(line.slice(4).trim())
      if (Number.isFinite(seconds) && seconds > 0) serverNow = Math.trunc(seconds) * 1000
      continue
    }
    if (!line.startsWith('file\t')) continue
    const rest = line.slice(5)
    const tab = rest.indexOf('\t')
    if (tab <= 0) continue
    const startedAt = Date.parse(rest.slice(0, tab))
    const path = rest.slice(tab + 1)
    if (!Number.isFinite(startedAt) || path === '') continue
    transcripts.push({ path, startedAt })
  }
  return { serverNow, transcripts }
}

/**
 * How far ahead of this computer the server's clock is, in ms.
 *
 * `askedAt` is `Date.now()` from immediately before the round trip, so the
 * answer carries the whole latency of it as error — the offset is at most one
 * round trip too large and never too small. That direction is deliberate: it
 * pushes the shell's opening moment *later* in server time, which can only ever
 * make this side claim fewer conversations, never a stranger's.
 */
export function serverSkew(survey: TranscriptSurvey, askedAt: number): number {
  return survey.serverNow - askedAt
}

/**
 * Slack on the opening moment, in ms.
 *
 * `date +%s` answers whole seconds and the round trip is not instant, so the
 * shell's opening moment converted into server time is good to about a second.
 * Without this, a `claude` started the instant a terminal opened writes a first
 * line stamped a fraction *before* the shell is believed to have opened, and its
 * conversation is ruled out of its own session.
 *
 * Applied to the lower bound only. The upper bound — the next shell on the same
 * server — is left exact, because widening that one would let this shell claim a
 * conversation the next one has an equal claim to, which is the failure the
 * whole rule exists to prevent.
 */
const OPENED_SLACK_MS = 2000

/**
 * Which of those transcripts is this shell's.
 *
 * The rule is `attributeTranscript`'s, restated over first-line timestamps
 * instead of birth times, and the paragraph that argues for it is in
 * `renderer/session-transcript.ts` — worth reading before changing anything
 * here, because both of its two known-wrong shapes are easy to write again:
 *
 *  - *"the earliest conversation that began after this shell"* claims another
 *    shell's conversation whenever two are open on one server, and claims it for
 *    **both** of them.
 *  - *"the newest conversation in the folder"* is the original bug in its
 *    purest form: it is whatever anybody, in any terminal, typed most recently.
 *
 * So a conversation is this shell's only when nothing else could have written
 * it: it began after this shell opened, and before the next shell on this server
 * did. Among those, the **newest**, because `/clear` starts a fresh conversation
 * in the same terminal and the pane exists to show the one the terminal beside
 * it is showing.
 *
 * `others` is every *other* shell this window has open on the same server, live
 * or exited — an exited shell's transcript is still lying there and still is not
 * this one's. All times are the server's; see {@link serverSkew}.
 */
export function attributeServerTranscript(
  transcripts: readonly ServerTranscript[],
  openedAt: number,
  others: readonly number[] = [],
): ServerTranscriptVerdict {
  const since = openedAt - OPENED_SLACK_MS
  const candidates = transcripts.filter((file) => file.startedAt >= since)
  if (candidates.length === 0) return { kind: 'none' }

  /*
   * The first moment another shell on this server could have started writing.
   *
   * `>=`, not `>`. Two shells opened in the same millisecond genuinely cannot be
   * told apart, and treating a tie as "the other one had not started yet" would
   * hand this one a conversation with an equal claim on it.
   */
  let nextStart = Number.POSITIVE_INFINITY
  for (const start of others) {
    if (start >= openedAt && start < nextStart) nextStart = start
  }

  const exclusive = candidates.filter((file) => file.startedAt < nextStart)
  if (exclusive.length === 0) {
    return {
      kind: 'ambiguous',
      candidates: candidates.length,
      competing: others.filter((start) => start >= openedAt).length,
    }
  }
  const own = [...exclusive].sort((a, b) => b.startedAt - a.startedAt)[0]
  return { kind: 'choice', path: own.path, startedAt: own.startedAt }
}

/* ------------------------------------------------------------------ the reading -- */

/**
 * The most of a transcript that is read on first open, in bytes.
 *
 * There is no equivalent cap locally, and the difference is the wire. A
 * transcript reaches 154 MB on this machine, and most of that weight is tool
 * results — the very lines the chat view throws away. Reading one from byte zero
 * costs a disk read here and costs *the whole file over SSH* there, which is
 * minutes of somebody's link to render the paragraph on the end of it.
 *
 * So a large one is entered late, and the pane **says so** rather than quietly
 * showing a conversation that starts mid-sentence — `session-replay.ts` makes
 * the same promise about the same kind of read. Four megabytes of JSONL is a
 * long conversation once the tool results in it are discarded, and tailing from
 * there is exact: every byte appended afterwards is read.
 */
export const SERVER_CHAT_TAIL_BYTES = 4 * 1024 * 1024

/**
 * What one read of a server's transcript answers.
 *
 * Deliberately the same shape `chat:load` and `chat:tail` answer with, plus the
 * two facts only a far reading has: whether it started mid-file, and whether the
 * conversation could be attributed at all. The renderer folds both into the
 * empty states `ChatView` already draws.
 */
export interface ServerChatUpdate {
  transcriptPath: string
  sessionId: string
  cwd: string
  messages: ChatMessage[]
  reset: boolean
  cursor: number
  found: boolean
  complete: boolean
  updatedAt: number
  /** True when the front of the file was skipped. See {@link SERVER_CHAT_TAIL_BYTES}. */
  startedMidFile: boolean
  /**
   * Set when several conversations could be this shell's and nothing can say
   * which — never folded into `found: false`, which means something different.
   */
  unattributable?: { candidates: number; competing: number }
}

/** What a reader needs from the far end. Two calls, both on the open connection. */
export interface ServerChatAccess {
  /** One `sh` script, one round trip. `ServerConnections.runScript`. */
  runScript(serverId: string, script: string): Promise<{ stdout: string; code: number | null }>
  /** A byte range out of one file. `ServerConnections.readFileRange`. */
  readFileRange(
    serverId: string,
    path: string,
    from: number,
    length: number,
  ): Promise<{ bytes: Buffer; size: number }>
}

/**
 * The byte source a {@link ChatReader} needs, over one server's SFTP channel.
 *
 * A zero-length range is how the size is asked for: `readFileRange` stats the
 * file and only then reads, so asking for no bytes is a `stat` and nothing else.
 * That keeps one call shape for both halves rather than a second verb whose
 * error handling would have to be got right separately.
 */
function bytesOn(access: ServerChatAccess, serverId: string): ChatBytes {
  return {
    async size(path) {
      return (await access.readFileRange(serverId, path, 0, 0)).size
    },
    async read(path, from, length) {
      return (await access.readFileRange(serverId, path, from, length)).bytes
    },
  }
}

/**
 * How often the binding is re-asked once there is one.
 *
 * The same shape of decision `ChatView`'s own re-attribution timer makes, and
 * for the same reason: the answer changes when somebody runs `/clear`, which is
 * a thing a person does a few times a day, and re-asking on every append would
 * be a `find` and an `awk` per recent transcript on somebody's server for the
 * whole of a long reply.
 */
const RESOLVE_EVERY_MS = 15_000

/**
 * And how often while there is not.
 *
 * Faster, because this is the state a person is *waiting out*: they have opened
 * a shell, they are about to type the first message, and the pane should fill in
 * when it lands rather than up to fifteen seconds later. Still not every read —
 * the pane asks about three times as often as this, and each survey is work on a
 * machine somebody else is using.
 *
 * `WAIT_MS` in `session-transcript.ts` is the same number for the same reason,
 * against a directory listing on this computer.
 */
const LOOK_AGAIN_MS = 5_000

/**
 * One shell's conversation, held open across reads.
 *
 * Holds the attribution as well as the reader, and re-asks it: a shell that runs
 * `/clear`, or quits the agent and starts it again, begins a *new* conversation
 * under a new name in the same terminal, and a pane bound once would show the
 * dead one for the rest of the session's life. That was a real defect in the
 * local view before `useSessionTranscript` was made to keep looking, and there
 * is no reason for the far one to relearn it.
 */
export class ServerChatSession {
  private reader: ChatReader | null = null
  /**
   * A different conversation from the one the last read answered about.
   *
   * Its own flag rather than something a caller could infer, because the reader
   * itself cannot: a fresh reader over a fresh file reads from byte zero and has
   * nothing to call a reset, so a `/clear` would arrive at the view as an
   * *append* and the new conversation would be merged onto the end of the
   * finished one. Consumed by the next read, which is what tells the view to
   * replace rather than append.
   */
  private rebound = false
  private startedMidFile = false
  private lastLookAt = 0
  private verdict: ServerTranscriptVerdict = { kind: 'none' }

  constructor(
    private readonly access: ServerChatAccess,
    private readonly serverId: string,
    /** When this window opened the shell, on **this** computer's clock. */
    private readonly openedAt: number,
    /** When this window opened every *other* shell on the same server. */
    private readonly others: () => readonly number[],
    private readonly now: () => number = Date.now,
  ) {}

  /**
   * Ask the server which file this is, again.
   *
   * Rate-limited, because it is a `find` and one `awk` per recent transcript and
   * the answer changes when somebody runs `/clear` — not when a reply streams.
   * The reader is only thrown away when the answer actually *moves*, so a
   * re-survey that confirms the binding costs one round trip and no re-reading.
   */
  private async resolve(force: boolean): Promise<ChatReader | null> {
    const at = this.now()
    const every = this.reader === null ? LOOK_AGAIN_MS : RESOLVE_EVERY_MS
    if (!force && at - this.lastLookAt < every) return this.reader
    const askedAt = this.now()
    const ageMinutes = Math.max(0, (askedAt - this.openedAt) / 60_000)
    const result = await this.access.runScript(this.serverId, surveyScript(ageMinutes))
    const survey = parseSurvey(result.stdout, askedAt)
    const skew = serverSkew(survey, askedAt)
    this.lastLookAt = this.now()
    this.verdict = attributeServerTranscript(
      survey.transcripts,
      this.openedAt + skew,
      this.others().map((start) => start + skew),
    )
    const path = this.verdict.kind === 'choice' ? this.verdict.path : null
    if (path === null) {
      this.reader = null
      this.startedMidFile = false
      return null
    }
    if (this.reader !== null && this.reader.path === path) return this.reader
    // A different conversation: a fresh reader, entered late when the file is
    // large enough that reading it whole would be minutes of somebody's link.
    const { size } = await this.access.readFileRange(this.serverId, path, 0, 0)
    const from = size > SERVER_CHAT_TAIL_BYTES ? size - SERVER_CHAT_TAIL_BYTES : 0
    this.startedMidFile = from > 0
    this.reader = new ChatReader(path, undefined, from, bytesOn(this.access, this.serverId))
    this.rebound = true
    return this.reader
  }

  /**
   * The whole conversation this shell can be shown.
   *
   * Deliberately *not* "throw the reader away and read the file again". The
   * pane is unmounted whenever somebody switches the session back to its
   * terminal, so this is called every time a person flips between the two views
   * — and re-reading from scratch would be the tail window across an SSH link
   * on every flip. The reader is kept when it is already bound to the same
   * conversation and only the bytes appended since are fetched; what makes this
   * a *load* rather than a tail is the answer, which is everything it holds.
   *
   * `resolve(true)` still re-asks which file this is, because that is the
   * question a person flipping views is most likely to have changed the answer
   * to — they went away, ran `/clear`, and came back.
   */
  async load(): Promise<ServerChatUpdate> {
    const reader = await this.resolve(true)
    this.rebound = false
    if (reader === null) return this.empty()
    await reader.readAll()
    // Always a replacement: the caller asked for the conversation, not for what
    // has changed since a read it did not make.
    return this.update([...reader.conversation], true)
  }

  /** Only what has been appended since the last read. */
  async tail(): Promise<ServerChatUpdate> {
    const first = this.reader === null
    const reader = await this.resolve(false)
    const rebound = this.rebound
    this.rebound = false
    if (reader === null) return this.empty()
    const { messages, reset } = await reader.readAll()
    // A tail against a conversation this session has not read before is a first
    // read: send all of it, flagged so the view replaces rather than appends.
    // That is also what happens the moment a `/clear` rolls the shell into a new
    // transcript, which is precisely when it matters.
    if (first || rebound || reset) return this.update([...reader.conversation], true)
    return this.update(messages, false)
  }

  private empty(): ServerChatUpdate {
    return {
      transcriptPath: '',
      sessionId: '',
      cwd: '',
      messages: [],
      reset: false,
      cursor: 0,
      // False means *no conversation for this shell was read*, which is what
      // "nothing yet" is drawn from. An ambiguous answer is a different
      // sentence and carries its own field rather than borrowing this one — the
      // view reads `unattributable` first and never reaches this.
      found: false,
      complete: true,
      updatedAt: this.now(),
      startedMidFile: false,
      ...(this.verdict.kind === 'ambiguous'
        ? {
            unattributable: {
              candidates: this.verdict.candidates,
              competing: this.verdict.competing,
            },
          }
        : {}),
    }
  }

  private update(messages: ChatMessage[], reset: boolean): ServerChatUpdate {
    const reader = this.reader
    return {
      transcriptPath: reader?.path ?? '',
      sessionId: reader?.sessionId ?? '',
      cwd: reader?.cwd ?? '',
      messages,
      reset,
      cursor: reader?.position ?? 0,
      found: true,
      complete: true,
      updatedAt: this.now(),
      startedMidFile: this.startedMidFile,
    }
  }
}


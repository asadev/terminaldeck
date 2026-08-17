/**
 * Which of a folder's conversations belongs to *this* session.
 *
 * ## The defect this exists for, and how it was found
 *
 * `newestChatTranscript(cwd)` answers "the transcript this folder's chat view
 * should open", and it is exactly right for that: a folder has one live
 * conversation and the chat view shows it. Every tool here used it, and for a
 * fleet that is wrong in a way that is worse than being unable to answer.
 *
 * It was found by asking a real copilot, running against this real machine,
 * *"anything stuck? which of my sessions needs me?"* — and reading what it said
 * back:
 *
 * > `sessions.transcript` looks like it resolves the transcript by **cwd, not
 * > session id**. All four copilot session ids returned `transcriptPath:
 * > …/7a579dec-….jsonl` — my own live conversation … I genuinely cannot tell
 * > you what three of them are doing: the tool handed me my own transcript
 * > instead of theirs.
 *
 * Four sessions in one folder, four identical answers, one of them the
 * copilot's own conversation. That is the fleet case — the case this whole tool
 * surface exists for — and every capability built on it inherits the error:
 * `sessions.result` would report one session's spend four times, and
 * `progress.ts` would call four sessions stuck because one of them was.
 *
 * ## What can and cannot be known
 *
 * Terminal Deck's session id and the CLI's session id are different things, and
 * nothing links them: the CLI names its transcript after its own id, which this
 * app never learns. A `SessionStart` hook carries it — `hooks.ts` installs the
 * hooks and `EVENT_STATUS` maps the events — but nothing in this repository
 * reads them, so there is no id to join on today. Whoever wires that listener
 * makes this module a two-line lookup and should delete most of it.
 *
 * Until then, there is one fact that genuinely narrows it, and
 * `TranscriptFile.createdAt` already carries it with the measurement attached:
 * **a conversation that began before a tab opened cannot be that tab's**,
 * because resuming appends to an existing file rather than starting a new one —
 * verified on this machine against a transcript born on 1 June and still being
 * written to on 13 August.
 *
 * So: a session that started fresh owns a transcript born at about the moment
 * it started. That is usually decisive even with four sessions in one folder,
 * because four tabs are not opened in the same second.
 *
 * ## And when it is not decisive, it says so
 *
 * The rule this module refuses to break is that it never silently hands back
 * somebody else's conversation. Every answer carries how it was arrived at:
 *
 * | `basis`             | Means                                                     |
 * |---------------------|-----------------------------------------------------------|
 * | `only-one`          | One conversation in the folder. It is this session's.     |
 * | `started-together`  | One began within a couple of minutes of this session.     |
 * | `newest`            | Several are plausible; this is the most recent. A guess.  |
 * | `none`              | Nothing here can be this session's. Not "no problems".    |
 *
 * `none` is the important one and it is new behaviour: a fresh session in a
 * folder full of older conversations previously got the newest of them and
 * presented it as its own. Now it gets nothing, and the caller says the session
 * has not written a transcript yet — which is the truth.
 */

import type { ProviderId, SessionMeta } from '../../shared/types'

/** One conversation file in a folder, as the surface reports it. */
export interface TranscriptChoice {
  path: string
  /** The CLI's own session id — the filename. Never Terminal Deck's. */
  sessionId: string
  /** File birth time, falling back to mtime where the filesystem has none. */
  createdAt: number
  modifiedAt: number
  bytes: number
}

export type MatchBasis = 'only-one' | 'started-together' | 'nearest-start' | 'newest' | 'none'

/** A live session in the folder, as much of it as the matching needs. */
export interface FolderSession {
  id: string
  createdAt: number
  resumed?: boolean
  provider?: ProviderId
}

/**
 * Providers whose sessions write one of these files at all.
 *
 * The files being matched live under `~/.claude/projects` and are written by
 * the Claude CLI. A shell writes nothing; Codex and Gemini keep their own
 * stores elsewhere, which this app reads through `codex-usage.ts` and not
 * through here. So a conversation in this folder can only belong to a `claude`
 * session, and handing one to any other kind of session is not a close call
 * that went the wrong way — it is an answer that cannot be right.
 *
 * This is not hypothetical tidying. Running the copilot against a real fleet on
 * this machine produced exactly it: a folder held a Claude conversation from a
 * session that had since ended and one live `shell` session, the shell was the
 * only live session so the `only-one` rule handed it that conversation, and the
 * copilot then told the user — in a report full of otherwise correct evidence —
 * that their shell session had been given a brief it never received and had
 * spent 780,000 tokens. Every number in that sentence was real and belonged to
 * somebody else.
 */
const TRANSCRIPT_PROVIDERS: readonly ProviderId[] = ['claude']

/**
 * Can this session own one of these files?
 *
 * Absent provider means yes, deliberately. `SessionMeta` always carries one, but
 * the parameter is optional so that a caller with less information than the app
 * has still gets the old behaviour rather than silently getting nothing —
 * refusing on a missing field would turn "we did not say" into "certainly not",
 * which is the wrong direction for a match that is otherwise good.
 */
function writesTranscripts(provider: ProviderId | undefined): boolean {
  return provider === undefined || TRANSCRIPT_PROVIDERS.includes(provider)
}

export interface TranscriptMatch {
  path: string | null
  basis: MatchBasis
  /**
   * True when another live session shares this folder and could own this file.
   *
   * Separate from `basis` on purpose. `started-together` with two other
   * sessions in the folder is a good answer that could still be wrong, and a
   * caller summarising it should say so; `only-one` with two other sessions is
   * not ambiguous at all, because there is only one conversation to go round.
   */
  ambiguous: boolean
  /** The other live sessions in this folder. The reason for `ambiguous`. */
  otherSessions: string[]
  /** One sentence for a tool result, or null when there is nothing to warn about. */
  note: string | null
}

/**
 * How far apart a session's start and its transcript's birth may be.
 *
 * Two minutes. The CLI opens its transcript within a second or two of the pty
 * starting, and the slack is for a cold start on a busy machine — measured here
 * at up to six seconds for a first launch — plus filesystem timestamp
 * granularity. Wide enough that a real match is never missed; narrow enough
 * that two tabs opened a few minutes apart do not both qualify.
 */
export const START_TOLERANCE_MS = 120_000

export function matchTranscript(
  session: Pick<SessionMeta, 'id' | 'createdAt' | 'resumed'> & { provider?: ProviderId },
  files: readonly TranscriptChoice[],
  sessionsInFolder: readonly FolderSession[],
  toleranceMs = START_TOLERANCE_MS,
): TranscriptMatch {
  /*
   * The other sessions that could actually own one of these files.
   *
   * Not "the other sessions in this folder", which is what this was and is what
   * made it wrong. `otherSessions` is documented as *the reason for
   * `ambiguous`*, and a session that never writes a transcript is not a reason
   * to doubt anything: a Claude session sharing a folder with three shells has
   * an unambiguous conversation, and reporting it as ambiguous would teach the
   * reader to discount a warning that is usually wrong.
   */
  const others = sessionsInFolder
    .filter((other) => other.id !== session.id && writesTranscripts(other.provider))
    .map((other) => other.id)

  /*
   * A session of a kind that never writes one of these files owns none of them.
   *
   * Checked first, before the file list is even looked at, because no amount of
   * good evidence about *which* conversation this is can rescue an answer that
   * is wrong about *whether* there is one. See {@link TRANSCRIPT_PROVIDERS} for
   * the report this produced on a real fleet before the check existed.
   *
   * The note says what kind of thing is missing rather than "none found", so a
   * caller reporting it can say "a shell keeps no transcript" instead of
   * implying the session has been quiet.
   */
  if (!writesTranscripts(session.provider)) {
    return {
      path: null,
      basis: 'none',
      ambiguous: false,
      otherSessions: others,
      note: `A ${session.provider ?? 'session'} session writes no transcript, so nothing in this folder is its conversation.`,
    }
  }


  /*
   * An empty file is not a conversation.
   *
   * The CLI opens a transcript before it has a turn to put in it, so a
   * zero-byte file is a session that started and has said nothing.
   * `newestConversation` in `transcript.ts` makes the same exclusion for the
   * same reason, and the restore path has always had to: sending `--continue`
   * at an empty transcript kills the tab.
   */
  const conversations = files.filter((file) => file.bytes > 0)
  if (conversations.length === 0) {
    return { path: null, basis: 'none', ambiguous: false, otherSessions: others, note: null }
  }

  /*
   * One live session in this folder, so whatever is here is its.
   *
   * This branch is where the whole question stops being interesting, and it is
   * the ordinary case: one tab, one folder, one conversation. The birth-time
   * rule below is not applied, deliberately — a lone session in a folder with
   * an older conversation in it almost certainly resumed it or is about to, and
   * refusing to name it would make the common case worse to serve the rare one.
   *
   * It is checked *before* the file count and not after, and that ordering was
   * wrong once: `conversations.length === 1` used to short-circuit here, so five
   * sessions sharing a folder with one conversation each got told it was
   * theirs — which is the original defect surviving inside its own fix, and it
   * was visible the moment the fix was run against the real machine.
   */
  if (others.length === 0) {
    const newest = newestFile(conversations)
    return {
      path: newest.path,
      basis: conversations.length === 1 ? 'only-one' : 'newest',
      ambiguous: false,
      otherSessions: [],
      note:
        conversations.length === 1
          ? null
          : 'Several conversations in this folder; this is the most recent, and no other session is running here.',
    }
  }

  /*
   * A resumed session appends to a file that already existed, so the birth-time
   * rule below says nothing about it — every candidate was born before it
   * started, which is exactly what resuming means. There is no honest way to
   * pick, so it takes the most recently written one and says it is a guess.
   */
  if (session.resumed === true) {
    return newestOf(conversations, others, 'it was resumed, so its conversation began before it did')
  }

  const born = conversations.filter(
    (file) =>
      file.createdAt >= session.createdAt - toleranceMs &&
      file.createdAt <= session.createdAt + toleranceMs,
  )

  if (born.length === 0) {
    /*
     * Every conversation here began before this session did, and it did not
     * resume any of them. None of them is its.
     *
     * This is the answer that used to be a lie. Handing back the newest file
     * made a session that has said nothing look like whichever session had
     * spoken most recently — and in the fleet case that was usually the
     * copilot's own conversation being reported back as somebody else's.
     */
    return {
      path: null,
      basis: 'none',
      ambiguous: false,
      otherSessions: others,
      note: 'Every conversation in this folder began before this session started, so none of them is its. It has not written one yet.',
    }
  }

  /*
   * Each conversation gets exactly one owner, and every session works it out
   * the same way.
   *
   * This is the part that had to change after the second real run. Two sessions
   * started 104 seconds apart — inside the tolerance either way — so both saw
   * both files as "born together", both fell through to "take the newest", and
   * both were handed the *same* 88 KB transcript. The 966-byte file, which was
   * plainly the older session's, was claimed by nobody. Everything downstream
   * inherited it: `sessions.result` reported 9 requests and 306,575 tokens for
   * each of them, and only one session had spent anything. The copilot caught
   * it by reading the file sizes and saying so.
   *
   * A per-session "take the newest" cannot fix that, because the defect is that
   * two answers are computed independently and nothing makes them agree. So the
   * rule is stated over the *pair* instead: a conversation belongs to the
   * session whose start is nearest its birth. That is decided identically no
   * matter which session is asking, so two sessions can never claim one file,
   * and a file whose nearest session is somebody else is not offered here at
   * all.
   *
   * A resumed session is left out of the claiming entirely: its conversation
   * began long before it did, so "nearest start" says nothing about it, and
   * letting it compete would let it take a fresh session's file.
   */
  const claimants = sessionsInFolder.filter((other) => other.resumed !== true)
  const mine = born.filter((file) => nearestSession(file, claimants)?.id === session.id)

  if (mine.length === 0) {
    return {
      path: null,
      basis: 'none',
      ambiguous: false,
      otherSessions: others,
      note: `Every conversation in this folder began nearer to another session's start than to this one's, so none of them is its.`,
    }
  }

  if (mine.length === 1) {
    return {
      path: mine[0].path,
      basis: 'started-together',
      ambiguous: others.length > 0,
      otherSessions: others,
      note:
        others.length === 0
          ? null
          : `${others.length} other session${others.length === 1 ? '' : 's'} share this folder; this file is the one that began nearest to when this session did.`,
    }
  }

  const nearest = mine.reduce((best, file) =>
    Math.abs(file.createdAt - session.createdAt) < Math.abs(best.createdAt - session.createdAt)
      ? file
      : best,
  )
  return {
    path: nearest.path,
    basis: 'nearest-start',
    ambiguous: true,
    otherSessions: others,
    note: `${mine.length} conversations here began nearest to this session; this is the closest of them. Treat what it says as possibly another session's.`,
  }
}

/**
 * The session a conversation most plausibly belongs to.
 *
 * Ties break on the session id so that the answer does not depend on the order
 * the caller happened to list them in — two sessions created in the same
 * millisecond is unlikely and a non-deterministic attribution is worse than an
 * arbitrary one, because it would change between two calls that read the same
 * disk.
 */
function nearestSession(
  file: TranscriptChoice,
  sessions: readonly FolderSession[],
): FolderSession | null {
  let best: FolderSession | null = null
  let bestGap = Number.POSITIVE_INFINITY
  for (const candidate of sessions) {
    const gap = Math.abs(file.createdAt - candidate.createdAt)
    if (gap < bestGap || (gap === bestGap && best !== null && candidate.id < best.id)) {
      best = candidate
      bestGap = gap
    }
  }
  return best
}

function newestFile(files: readonly TranscriptChoice[]): TranscriptChoice {
  return files.reduce((best, file) => (file.modifiedAt > best.modifiedAt ? file : best))
}

function newestOf(
  files: readonly TranscriptChoice[],
  others: string[],
  why: string,
): TranscriptMatch {
  const newest = newestFile(files)
  return {
    path: newest.path,
    basis: 'newest',
    ambiguous: true,
    otherSessions: others,
    note: `This is the most recently written conversation in the folder rather than certainly this session's — ${why}. Treat what it says as possibly another session's.`,
  }
}

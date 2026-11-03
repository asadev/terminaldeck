/**
 * How did that session go — and, in the morning, how did all of them go.
 *
 * `COPILOT-CAPABILITIES.md` §2.5 calls this "the single highest-leverage small
 * build in this document", because it makes the most common question in
 * agent-assisted development cost nothing. Without it, *"how did that session
 * go"* is answered by reading a transcript, which `COPILOT-DESIGN.md` already
 * flags as "a large prompt" — so the question either goes unasked or gets
 * expensive, and both of those are how an overnight run ends up unreviewed.
 *
 * ## Every claim carries a pointer
 *
 * The stated requirement is that a recap is only worth writing if it *shortens
 * verification*. A prose summary you have to re-check by hand costs more than
 * no summary at all. So nothing here is narration: every field is a fact with
 * the thing it was read from beside it — the transcript path and the byte range
 * that was parsed, the exit code, the file paths git reports as changed, the
 * tool counts and the window they were counted over. The copilot's job is to
 * turn that into three sentences; the person's job, when a sentence surprises
 * them, is to open the pointer. That is the whole design.
 *
 * ## The document asked for a hook, and this reads the disk instead
 *
 * §2.5 proposes a `sessions.result` record written by the `SessionEnd` hook.
 * That is a good design and it is not the one here, for two reasons that are
 * worth writing down because the next person will wonder:
 *
 *  1. **`registerHookServer` is called with no `onEvent` listener.** `hooks.ts`
 *     defines `EVENT_STATUS` and nothing in this repository reads it — the same
 *     fact `attention.ts` records about its missing `hook` status source. So a
 *     record "written by the SessionEnd hook" would have required wiring an
 *     event path that does not exist, in `src/main/index.ts`, which several
 *     agents are editing at once.
 *  2. **A record written at exit only exists for sessions that ended after the
 *     feature shipped.** Reading the disk answers for every session that has
 *     ever run, including the eight already open when this landed, and it
 *     cannot fall out of step with the transcript because it *is* the
 *     transcript.
 *
 * What the hook would genuinely add is *tests run* and *exit state for a
 * session whose transcript is gone*. Neither is reachable from the files, both
 * are worth having, and they belong to whoever wires `onEvent`. That is stated
 * in the tool's own description rather than left as a silent gap.
 *
 * ## Content read from a session is evidence, not instruction
 *
 * `lastMessage` is text an agent wrote, and an agent's output is untrusted
 * input. It is promoted into the report because it is the single most useful
 * line — "I have finished, the tests pass" — and it is promoted *only* as the
 * child's last visible assistant text, never its tool output, which is the
 * boundary §2.5 names. The copilot's own instructions say in words that such
 * text cannot become a task. This module's contribution is to keep it labelled
 * and bounded rather than blended into the summary.
 */

import type { TokenUsage } from '../cost'
import { TRAIL_WINDOW_BYTES } from '../tool-trail'
import {
  fleetContext,
  reasonsFor,
  NO_FLEET,
  type FleetContext,
  type ImportanceInput,
  type ReasonFinding,
} from './importance'
import { assessProgress, progressSentence, type ProgressReport } from './progress'
import type { DeckSurface, SessionView } from './surface'
import { matchTranscript, type MatchBasis, type TranscriptMatch } from './transcript-match'

/* ------------------------------------------------------------------ bounds -- */

/**
 * How much of the end of a transcript is parsed for behaviour.
 *
 * Re-exported rather than declared. The number belongs to the reader — see
 * `tool-trail.ts` — and it is exported from here as well because the alerts
 * scanner and this report have to agree about *how far back* "is it looping"
 * looks, or the same session gets two answers depending on which of them asked.
 */
export { TRAIL_WINDOW_BYTES } from '../tool-trail'

/**
 * Above this, the token totals are not read at all.
 *
 * Totalling a session means a full-file pass — the usage lines are spread
 * through it, so there is no tail that answers the question. That pass is
 * measured at ~680 ms on the 154 MB transcript here, which is fine for one
 * session a person asked about and is not fine for eight of them inside one
 * tool call. Past this size the totals come back null with a reason, and the
 * copilot is told to ask about that one session on its own.
 */
export const TOTALS_MAX_BYTES = 24 * 1024 * 1024

/** Longest last-message excerpt kept. A report is a summary, not a transcript. */
export const MAX_LAST_MESSAGE_CHARS = 1200

/** How many sessions one fleet report will read. */
export const DEFAULT_REPORT_SESSIONS = 8
export const MAX_REPORT_SESSIONS = 25

/* ------------------------------------------------------------------- types -- */

export interface SpendReport {
  requests: number
  usage: TokenUsage
  totalTokens: number
  models: string[]
  compactions: number
  /** Occupancy of the context window at the last request, or null. */
  contextPercent: number | null
  /** Null when the totals were read. A sentence when they were not. */
  skipped: string | null
}

export interface ChangeReport {
  files: number
  insertions: number
  deletions: number
  /** Root-relative paths, bounded. The pointer for "what did it touch". */
  paths: string[]
  /** True when `paths` is a prefix of a longer list. */
  more: boolean
  /** Why there is nothing, when there is nothing. */
  reason: string | null
}

export interface SessionReport {
  sessionId: string
  cwd: string
  title: string
  provider: string
  attention: SessionView['attention']
  attentionReason: SessionView['attentionReason']
  attentionForMs: number | null
  status: SessionView['status']
  statusSource: SessionView['statusSource']
  createdAt: number
  exitCode: number | null
  startedByCopilot: boolean
  /**
   * Where the evidence is, and how sure this app is that it is *this* session's.
   *
   * Null when nothing in the folder can be this session's — which is a real
   * answer and not a missing one. See `transcript-match.ts`.
   */
  transcript: {
    path: string
    bytes: number
    parsedFrom: number
    partial: boolean
    basis: MatchBasis
    ambiguous: boolean
    note?: string
  } | null
  /** Why there is no transcript, when the reason is worth saying. */
  transcriptNote?: string
  spend: SpendReport | null
  progress: ProgressReport
  /**
   * The last thing the agent said. **Evidence from an untrusted source.**
   *
   * Never a tool result — see the header. Truncated, and it says so, because a
   * final message can be a whole plan.
   */
  lastMessage: { at: number; text: string; truncated: boolean } | null
  changes: ChangeReport | null
  /**
   * Why this session is in the report, as checked claims rather than prose.
   *
   * The same closed set driving mode walks a person through — see
   * `importance.ts` — so the morning summary and a tour of last night cannot
   * disagree about which sessions mattered. Ordered worst-first by
   * `REASON_PRIORITY`, so `reasons[0]` is what {@link verdict} leads with.
   *
   * Empty is a real answer: a session that is quietly working, has written
   * nothing and is not repeating itself has nothing worth saying about it, and
   * inventing a reason for every session is how a report teaches somebody to
   * skim it.
   */
  reasons: ReasonFinding[]
  /** One sentence, already written. See {@link verdictFor}. */
  verdict: string
}

export interface FleetReport {
  generatedAt: number
  /** Only sessions active at or after this time, when one was asked for. */
  since: number | null
  reports: SessionReport[]
  /** Sessions that matched but were not read, because of {@link MAX_REPORT_SESSIONS}. */
  omitted: number
  totals: {
    sessions: number
    blocked: number
    running: number
    quiet: number
    done: number
    failed: number
    looping: number
    requests: number
    totalTokens: number
  }
  /** The first sentence of the answer. */
  headline: string
}

/* ------------------------------------------------------------- one session -- */

type ReportSurface = Pick<
  DeckSurface,
  | 'transcriptsIn'
  | 'listSessions'
  | 'transcriptBytes'
  | 'readTranscriptFrom'
  | 'readToolTrail'
  | 'transcriptTotals'
  | 'gitChanges'
  | 'fileModifiedAt'
>

/**
 * The conversation that is actually this session's.
 *
 * Not the folder's newest one. `transcript-match.ts` has the account of why
 * that distinction is load-bearing here rather than in the chat view: four
 * sessions in one folder were each reported with a fourth session's spend, its
 * tool trail and its last message, and the report read as four confident
 * answers rather than as one answer given four times.
 */
export async function transcriptFor(
  surface: ReportSurface,
  session: Pick<SessionView, 'id' | 'cwd' | 'createdAt' | 'resumed' | 'provider'>,
): Promise<TranscriptMatch> {
  const files = await surface.transcriptsIn(session.cwd)
  /*
   * Every live session in the folder — when each started, and what kind it is.
   *
   * The matching assigns each conversation to exactly one session, and it cannot
   * do that without knowing when the others began. The provider is the second
   * half of the same question and was missing at first, with a cost: a shell
   * shares the folder, writes no transcript, and was still counted both as a
   * candidate owner and as a reason to call somebody else's match ambiguous.
   */
  const here = surface
    .listSessions()
    .filter((meta) => meta.cwd === session.cwd)
    .map((meta) => ({
      id: meta.id,
      createdAt: meta.createdAt,
      provider: meta.provider,
      ...(meta.resumed === undefined ? {} : { resumed: meta.resumed }),
    }))
  return matchTranscript(session, files, here)
}

export async function reportOnSession(
  surface: ReportSurface,
  session: SessionView,
  options: { withChanges?: boolean; fleet?: FleetContext } = {},
): Promise<SessionReport> {
  const match = await transcriptFor(surface, session)
  const path = match.path
  const bytes = path === null ? 0 : await surface.transcriptBytes(path)

  const trail = path === null ? null : await surface.readToolTrail(path, TRAIL_WINDOW_BYTES)
  const progress = assessProgress(trail)
  const spend = path === null ? null : await spendOf(surface, path, bytes)
  const lastMessage = path === null ? null : await lastAgentMessage(surface, path, bytes)
  const changes = options.withChanges === false ? null : await changesIn(surface, session)

  const report: SessionReport = {
    sessionId: session.id,
    cwd: session.cwd,
    title: session.title,
    provider: session.provider,
    attention: session.attention,
    attentionReason: session.attentionReason,
    attentionForMs: session.attentionForMs,
    status: session.status,
    statusSource: session.statusSource,
    createdAt: session.createdAt,
    exitCode: session.exitCode,
    startedByCopilot: session.startedByCopilot,
    transcript:
      path === null
        ? null
        : {
            path,
            bytes,
            parsedFrom: trail?.fromByte ?? 0,
            partial: trail?.partial ?? false,
            /*
             * How this file was decided to be this session's, and whether
             * anything else in the folder could own it.
             *
             * Carried into the report rather than resolved silently, because
             * every number below it — the spend, the tool trail, the last
             * message — is only about this session if this field says so.
             */
            basis: match.basis,
            ambiguous: match.ambiguous,
            ...(match.note === null ? {} : { note: match.note }),
          },
    /** Set when nothing in the folder is this session's. See `transcript-match.ts`. */
    ...(path === null && match.note !== null ? { transcriptNote: match.note } : {}),
    spend,
    progress,
    lastMessage,
    changes,
    reasons: [],
    verdict: '',
  }
  return {
    ...report,
    reasons: reasonsFor(importanceOf(report), options.fleet ?? NO_FLEET),
    verdict: verdictFor(report),
  }
}

/**
 * A finished report, in the shape `importance.ts` checks claims against.
 *
 * A translation and nothing else — no field is computed here that is not
 * already on the report. It exists because `importance.ts` deliberately does
 * not take a `SessionReport`: the tour's plan validator has a session and a
 * handful of numbers rather than a whole report, and typing the parameter as
 * the report would force it to build one it does not need.
 */
export function importanceOf(report: SessionReport): ImportanceInput {
  return {
    attention: report.attention,
    attentionReason: report.attentionReason,
    exitCode: report.exitCode,
    progress: report.progress,
    totalTokens: report.spend?.totalTokens ?? null,
    changedFiles: report.changes?.files ?? 0,
    /*
     * Trimmed, and only when it was not cut short.
     *
     * `question-asked` is decided by a `?` at the end of the text, and a
     * truncated message ends in an ellipsis — so passing the truncated form
     * would silently make every long message un-questionable. Passing null for
     * it instead says "this app cannot tell", which is the honest answer and
     * the same one it gives when there is no message at all.
     */
    lastMessage:
      report.lastMessage === null || report.lastMessage.truncated ? null : report.lastMessage.text.trim(),
  }
}

async function spendOf(
  surface: ReportSurface,
  path: string,
  bytes: number,
): Promise<SpendReport | null> {
  if (bytes > TOTALS_MAX_BYTES) {
    return {
      requests: 0,
      usage: { input: 0, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0 },
      totalTokens: 0,
      models: [],
      compactions: 0,
      contextPercent: null,
      skipped: `This transcript is ${Math.round(bytes / 1_000_000)} MB, which is too large to total inside a fleet report. Ask about this session on its own.`,
    }
  }
  const totals = await surface.transcriptTotals(path)
  if (totals === null) return null
  const usage = totals.usage
  return {
    requests: totals.requests,
    usage,
    // Prompt and output together — the same figure the inspector ranks on.
    totalTokens:
      usage.input + usage.output + usage.cacheWrite5m + usage.cacheWrite1h + usage.cacheRead,
    models: totals.models,
    compactions: totals.compactions,
    contextPercent: totals.context === null ? null : Math.round(totals.context.percent),
    skipped: null,
  }
}

/**
 * The agent's last visible message, bounded.
 *
 * Read from a small window at the end of the file rather than from the whole
 * of it: the last message is by definition at the end, and a full read to find
 * one string is the cost this module exists to avoid. 256 KB is the same
 * default `sessions.transcript` uses, and it holds far more than one message.
 */
async function lastAgentMessage(
  surface: ReportSurface,
  path: string,
  bytes: number,
): Promise<SessionReport['lastMessage']> {
  const from = Math.max(0, bytes - 256 * 1024)
  const messages = await surface.readTranscriptFrom(path, from)
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index]
    if (message.role !== 'agent') continue
    const text = message.text.trim()
    if (text === '') continue
    const cut = text.length > MAX_LAST_MESSAGE_CHARS
    return {
      at: message.at,
      text: cut ? `${text.slice(0, MAX_LAST_MESSAGE_CHARS)}…` : text,
      truncated: cut,
    }
  }
  return null
}

/** Longest list of changed paths a report carries. */
const MAX_CHANGE_PATHS = 20

async function changesIn(surface: ReportSurface, session: SessionView): Promise<ChangeReport | null> {
  const changes = await surface.gitChanges(session.cwd)
  if (!changes.repo) return { files: 0, insertions: 0, deletions: 0, paths: [], more: false, reason: changes.reason }
  let insertions = 0
  let deletions = 0
  for (const file of changes.files) {
    insertions += file.insertions ?? 0
    deletions += file.deletions ?? 0
  }
  return {
    files: changes.files.length,
    insertions,
    deletions,
    paths: changes.files.slice(0, MAX_CHANGE_PATHS).map((file) => file.path),
    more: changes.files.length > MAX_CHANGE_PATHS,
    reason: null,
  }
}

/**
 * One sentence per session, leading with whatever is worth acting on.
 *
 * The ordering is the same claim `attention.ts` makes: a person is blocking one
 * of these, so that is the first thing said, whatever else is true about it. A
 * failed exit is next because it is over and cannot be un-failed. Looping is
 * third because it is money being spent right now. Everything else is a status
 * line.
 */
export function verdictFor(report: SessionReport): string {
  const where = report.title || report.cwd
  if (report.attention === 'blocked') {
    const waited = report.attentionForMs === null ? '' : ` for ${minutes(report.attentionForMs)}`
    return `Blocked on you${waited} — ${where}.`
  }
  if (report.exitCode !== null && report.exitCode !== 0) {
    return `Exited ${report.exitCode} — ${where}.`
  }
  if (report.progress.verdict === 'looping') {
    return `${progressSentence(report.progress)} — ${where}.`
  }
  if (report.attention === 'done') {
    const wrote =
      report.changes === null || report.changes.files === 0
        ? 'nothing changed on disk'
        : `${report.changes.files} file${report.changes.files === 1 ? '' : 's'} changed`
    return `Finished — ${wrote}, ${where}.`
  }
  if (report.attention === 'running') return `Working — ${where}.`
  return `Quiet — ${where}.`
}

function minutes(ms: number): string {
  const total = Math.round(ms / 60_000)
  if (total < 60) return `${total} min`
  const hours = Math.floor(total / 60)
  const rest = total % 60
  return rest === 0 ? `${hours}h` : `${hours}h ${rest}m`
}

/* ------------------------------------------------------------- the fleet -- */

/**
 * The overnight report: every session that was active in the window, ranked.
 *
 * Ranked by `byAttention` — the caller sorts before handing them over — so the
 * first report is the one that needs somebody. `since` is what makes it an
 * *overnight* report rather than a dump: "everything that ran since I last
 * looked" is the actual question, and a session that has been idle for three
 * days is not part of the answer.
 */
export async function reportOnFleet(
  surface: ReportSurface,
  sessions: readonly SessionView[],
  options: { since?: number | null; limit?: number; now: number },
): Promise<FleetReport> {
  const since = options.since ?? null
  const matching =
    since === null
      ? [...sessions]
      : sessions.filter((session) => activeAt(session) >= since)

  const limit = Math.min(Math.max(Math.trunc(options.limit ?? DEFAULT_REPORT_SESSIONS), 1), MAX_REPORT_SESSIONS)
  const chosen = matching.slice(0, limit)

  const read: SessionReport[] = []
  for (const session of chosen) {
    // Sequential rather than `Promise.all`, deliberately. Each report is a
    // handful of file reads and a `git status`, and eight of those in parallel
    // is eight git processes and eight multi-megabyte reads competing with the
    // window the person is looking at. This runs on the main process.
    read.push(await reportOnSession(surface, session))
  }

  /*
   * A second pass for the one reason that is a comparison rather than a fact.
   *
   * `expensive` means "far above its peers", so it cannot be decided while the
   * peers are still being read — the first session in the list has no fleet
   * behind it yet. The reasons are recomputed once the median exists, which
   * costs nothing: `reasonsFor` is pure and reads no file, so this is arithmetic
   * over numbers that are already in hand rather than a second look at disk.
   *
   * Doing it this way rather than pre-scanning for totals keeps a single read
   * path. A pre-scan would mean two passes over the same transcripts, and the
   * measurements at the top of this file are the reason that is not free.
   */
  const context = fleetContext(read.map((report) => report.spend?.totalTokens ?? null))
  const reports = read.map((report) => ({
    ...report,
    reasons: reasonsFor(importanceOf(report), context),
  }))

  const totals = {
    sessions: reports.length,
    blocked: reports.filter((report) => report.attention === 'blocked').length,
    running: reports.filter((report) => report.attention === 'running').length,
    quiet: reports.filter((report) => report.attention === 'quiet').length,
    done: reports.filter((report) => report.attention === 'done').length,
    failed: reports.filter((report) => report.exitCode !== null && report.exitCode !== 0).length,
    looping: reports.filter((report) => report.progress.verdict === 'looping').length,
    requests: reports.reduce((sum, report) => sum + (report.spend?.requests ?? 0), 0),
    totalTokens: reports.reduce((sum, report) => sum + (report.spend?.totalTokens ?? 0), 0),
  }

  return {
    generatedAt: options.now,
    since,
    reports,
    omitted: matching.length - chosen.length,
    totals,
    headline: headlineFor(totals),
  }
}

/**
 * The last moment a session was doing anything, for the `since` filter.
 *
 * `statusSince` when there is one, else `createdAt`. An exited session has no
 * `statusSince` — the live-status map drops it on exit — so a session that ran
 * and died overnight is matched on when it *started*, which is the only time
 * this app still holds for it and is close enough for "since I last looked".
 */
function activeAt(session: SessionView): number {
  return Math.max(session.statusSince, session.createdAt)
}

function headlineFor(totals: FleetReport['totals']): string {
  if (totals.sessions === 0) return 'Nothing has run in that window.'
  const parts: string[] = []
  if (totals.blocked > 0) parts.push(`${totals.blocked} waiting on you`)
  if (totals.failed > 0) parts.push(`${totals.failed} failed`)
  if (totals.looping > 0) parts.push(`${totals.looping} looking stuck`)
  if (totals.running > 0) parts.push(`${totals.running} still working`)
  /*
   * A failed session is also a finished one, and it must be counted once.
   *
   * `done` and `failed` overlap by construction — `attention.ts` puts a
   * non-zero exit in `done` deliberately, because nothing a person does will
   * un-end it — so a headline that added them would report three sessions as
   * four. Subtracting here rather than narrowing `totals` keeps both raw
   * numbers available to the copilot, which needs them separately.
   */
  const cleanlyDone = Math.max(0, totals.done - totals.failed)
  if (cleanlyDone > 0) parts.push(`${cleanlyDone} finished`)
  if (parts.length === 0) parts.push(`${totals.sessions} quiet`)
  return `${totals.sessions} session${totals.sessions === 1 ? '' : 's'}: ${parts.join(', ')}.`
}

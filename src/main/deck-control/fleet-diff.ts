/**
 * What has actually changed, and which agent changed it.
 *
 * `COPILOT-CAPABILITIES.md` §2.4 puts this above almost everything else for one
 * reason, and it is the one point every 2026 retrospective agrees on:
 * *verification, not generation, is the bottleneck*. A feature that produces
 * more agent output without producing more **reviewable** output makes the
 * problem worse. The diff is the reviewable unit — reading a transcript to work
 * out what an agent changed is the slow path, and it is the path everybody is
 * on today.
 *
 * The diff-first review surface is the near-universal architecture in this
 * field. What none of them have is an agent you can *talk to* about the diff,
 * and what this app has that none of them do is that it owns the sessions as
 * well as the repository — so the diff can be attributed.
 *
 * ## How attribution is done, and why it is not a guess
 *
 * The obvious design — snapshot `git status` when a session starts and diff
 * against it later — was the one the capability document proposed, and it needs
 * a hook into the one function that starts sessions. This does something
 * cheaper that is strictly more informative and needs no new plumbing at all:
 * it compares each changed file's **mtime** against each session's `createdAt`.
 *
 * A file written at 09:41 cannot have been written by a session that started at
 * 09:55. So for every changed file the candidate set is *the sessions in this
 * repository that were already running when the file was last written*, and
 * that set is frequently a single session even when three are open — because
 * they did not all start at the same moment. Where it is not a single session,
 * this says "one of these two" rather than choosing, which is the honest answer
 * and the one the capability document asks for in those words: two sessions in
 * one worktree genuinely cannot be told apart.
 *
 * Three things it does not claim, stated because the failure of an attribution
 * feature is over-claiming:
 *
 *  - **A change with no candidate is yours.** A file last written before any
 *    running session started was written by the person, by a session that has
 *    since gone, or by a build. It is reported as unattributed, not blamed on
 *    the oldest session that happens to still be open.
 *  - **mtime is when the file was last touched, not when the interesting change
 *    happened.** A session that edits a file at 09:00 and a formatter that
 *    rewrites it at 09:30 leave one mtime, and it points at the formatter.
 *  - **A deleted file has no mtime.** It is listed, with no candidates and a
 *    stated reason, rather than dropped — a deletion is the change most worth
 *    reviewing.
 *
 * ## The bounds, and reporting which one bit
 *
 * The same discipline `sessions.transcript` already uses: three ceilings, and
 * the result says which one it hit. A diff is the one payload in this whole
 * surface with no natural size — a lockfile regeneration is half a megabyte of
 * unified diff, and a model that receives it has been handed a bill rather than
 * an answer.
 */

import { join } from 'node:path'
import type { ChangedFile, DeckSurface, RepoChanges, SessionView } from './surface'

/* ------------------------------------------------------------------ bounds -- */

/**
 * How many changed files carry their diff text.
 *
 * Every changed file is *listed* — the list is the shape of the change and it
 * is cheap — but only the first few carry the diff itself. Twenty-five is the
 * point at which a review stops being a review: past that, the useful next step
 * is to name a path and look at one file, which is what the `path` argument is
 * for.
 */
export const DEFAULT_MAX_FILES = 25
export const MAX_FILES = 100

/** Longest diff kept for one file before it is cut in the middle. */
export const MAX_FILE_DIFF_CHARS = 12_000

/**
 * Total diff text in one result.
 *
 * Sized against the catalogue's own reasoning about standing cost: 60,000
 * characters is roughly 17,000 tokens, which is a large but survivable single
 * answer, and it is an order of magnitude below what an unbounded diff of a
 * dependency upgrade would be.
 */
export const MAX_TOTAL_DIFF_CHARS = 60_000

/* ------------------------------------------------------------------- types -- */

/** Which sessions could have written a file, and which one it probably was. */
export interface Attribution {
  /** Session ids that were already running when the file was last written. */
  candidates: string[]
  /** The single candidate, when there is exactly one. Null otherwise. */
  sessionId: string | null
  /** Epoch ms the file was last written, or null when it could not be read. */
  modifiedAt: number | null
  /** Why there is no candidate, when there is none. Null otherwise. */
  reason: string | null
}

export interface DiffFile extends ChangedFile {
  /** Unified diff, or null when it was not fetched. */
  diff: string | null
  /** True when `diff` was cut to {@link MAX_FILE_DIFF_CHARS}. */
  diffTruncated: boolean
  /** Why the diff is null: a bound, or the file being binary. Null when it is there. */
  omitted: 'binary' | 'file-limit' | 'byte-limit' | 'empty' | null
  attribution: Attribution
}

export interface FolderDiff {
  cwd: string
  repo: boolean
  root: string | null
  branch: string | null
  ahead: number
  behind: number
  /** Every changed file, whether or not its diff came with it. */
  files: DiffFile[]
  changedFiles: number
  /** How many of them carry diff text. */
  withDiff: number
  diffChars: number
  /** Which ceiling stopped it, or `none`. See the header. */
  bound: 'none' | 'file-limit' | 'byte-limit'
  /** The sessions running in this folder, newest first. */
  sessions: Array<Pick<SessionView, 'id' | 'title' | 'provider' | 'attention' | 'createdAt' | 'startedByCopilot'>>
  /** One sentence about who changed what. Already written for a person. */
  attributionNote: string
  /** Why there is nothing, when `repo` is false. */
  reason: string | null
}

export interface DiffRequest {
  cwd: string
  /** One file, root-relative. Omit for everything that changed. */
  path?: string | null
  maxFiles?: number
}

/* -------------------------------------------------------------- the gather -- */

export async function collectFolderDiff(
  surface: Pick<DeckSurface, 'gitChanges' | 'fileDiff' | 'fileModifiedAt'>,
  sessions: readonly SessionView[],
  request: DiffRequest,
): Promise<FolderDiff> {
  const changes = await surface.gitChanges(request.cwd)
  const here = sessionsIn(sessions, request.cwd, changes)

  if (!changes.repo) {
    return {
      cwd: request.cwd,
      repo: false,
      root: null,
      branch: null,
      ahead: 0,
      behind: 0,
      files: [],
      changedFiles: 0,
      withDiff: 0,
      diffChars: 0,
      bound: 'none',
      sessions: here.map(describeSession),
      attributionNote: 'This folder is not a git repository, so there is nothing to diff.',
      reason: changes.reason,
    }
  }

  const wanted =
    request.path === undefined || request.path === null
      ? changes.files
      : changes.files.filter((file) => file.path === request.path)

  const maxFiles = clamp(request.maxFiles ?? DEFAULT_MAX_FILES, 1, MAX_FILES)
  const files: DiffFile[] = []
  let diffChars = 0
  let bound: FolderDiff['bound'] = 'none'
  let withDiff = 0

  for (const [index, file] of wanted.entries()) {
    const attribution = await attribute(surface, changes.root, file, here)

    /*
     * Every changed file is listed; only some carry text.
     *
     * The list is the shape of the change — eleven files across four
     * directories is an answer on its own — and it costs almost nothing. The
     * text is what has no ceiling, so the two are bounded separately and the
     * reason a particular file has no text is written on that file rather than
     * left for the reader to infer from a count.
     */
    if (file.binary) {
      files.push({ ...file, diff: null, diffTruncated: false, omitted: 'binary', attribution })
      continue
    }
    if (index >= maxFiles) {
      bound = 'file-limit'
      files.push({ ...file, diff: null, diffTruncated: false, omitted: 'file-limit', attribution })
      continue
    }
    if (diffChars >= MAX_TOTAL_DIFF_CHARS) {
      bound = 'byte-limit'
      files.push({ ...file, diff: null, diffTruncated: false, omitted: 'byte-limit', attribution })
      continue
    }

    const raw = await surface.fileDiff(request.cwd, file.path, {
      staged: file.group === 'staged',
      untracked: file.group === 'untracked',
    })
    if (raw === '') {
      files.push({ ...file, diff: null, diffTruncated: false, omitted: 'empty', attribution })
      continue
    }

    const room = Math.min(MAX_FILE_DIFF_CHARS, MAX_TOTAL_DIFF_CHARS - diffChars)
    const cut = raw.length > room
    const text = cut ? raw.slice(0, room) : raw
    if (cut) bound = bound === 'file-limit' ? bound : 'byte-limit'
    diffChars += text.length
    withDiff += 1
    files.push({ ...file, diff: text, diffTruncated: cut, omitted: null, attribution })
  }

  return {
    cwd: request.cwd,
    repo: true,
    root: changes.root,
    branch: changes.branch,
    ahead: changes.ahead,
    behind: changes.behind,
    files,
    changedFiles: wanted.length,
    withDiff,
    diffChars,
    bound,
    sessions: here.map(describeSession),
    attributionNote: noteFor(files, here),
    reason: null,
  }
}

/* ------------------------------------------------------------- attribution -- */

/**
 * Sessions whose working directory is inside this repository.
 *
 * Matched against the repository *root* rather than against the requested
 * folder, because a session started in `packages/web` and a diff asked for at
 * the repository root are the same working tree — and a session that edited
 * `packages/web/src/App.tsx` is the obvious candidate for that change however
 * the question was phrased. The prefix check is a plain path comparison with a
 * separator on the end, so `/repo-two` is not a match for `/repo`.
 */
function sessionsIn(
  sessions: readonly SessionView[],
  cwd: string,
  changes: RepoChanges,
): SessionView[] {
  const root = changes.repo && changes.root !== null ? changes.root : cwd
  return sessions
    .filter((session) => session.cwd === root || session.cwd.startsWith(`${root}/`) || session.cwd === cwd)
    .sort((a, b) => b.createdAt - a.createdAt)
}

async function attribute(
  surface: Pick<DeckSurface, 'fileModifiedAt'>,
  root: string | null,
  file: ChangedFile,
  sessions: readonly SessionView[],
): Promise<Attribution> {
  if (root === null) {
    return { candidates: [], sessionId: null, modifiedAt: null, reason: 'No repository root.' }
  }
  const modifiedAt = await surface.fileModifiedAt(join(root, file.path))
  if (modifiedAt === null) {
    return {
      candidates: [],
      sessionId: null,
      modifiedAt: null,
      reason:
        file.kind === 'deleted'
          ? 'The file is gone, so there is no time on it to compare against.'
          : 'That file could not be read, so nothing can be said about when it changed.',
    }
  }

  /*
   * A session can only have written a file it was alive for.
   *
   * `createdAt` is the one time this app has for every session and it is exact.
   * The comparison is deliberately one-sided — started before the write — and
   * not "and had not exited yet", because a session's exit time is dropped from
   * the live status map the moment it exits (see `AttentionInput.statusSince`),
   * so the closing half of the interval is genuinely not known. One-sided
   * over-includes, which is the safe direction: it can leave two candidates
   * where the truth was one, and it can never point at a session that had not
   * started.
   */
  const candidates = sessions
    .filter((session) => session.createdAt <= modifiedAt)
    .map((session) => session.id)

  return {
    candidates,
    sessionId: candidates.length === 1 ? candidates[0] : null,
    modifiedAt,
    reason:
      candidates.length === 0
        ? 'Written before any session in this folder started, so it is yours or an older one.'
        : null,
  }
}

function describeSession(session: SessionView): FolderDiff['sessions'][number] {
  return {
    id: session.id,
    title: session.title,
    provider: session.provider,
    attention: session.attention,
    createdAt: session.createdAt,
    startedByCopilot: session.startedByCopilot,
  }
}

/**
 * The sentence a person actually reads.
 *
 * Written here rather than left to the model, for the reason `attention.ts`
 * gives about its own buckets: the interesting distinction — *this file is
 * definitely that session's* versus *it is one of these two* — is a fact this
 * module computed and a fact the model would have to re-derive from an array of
 * ids and a set of timestamps.
 */
function noteFor(files: readonly DiffFile[], sessions: readonly SessionView[]): string {
  if (files.length === 0) return 'Nothing has changed in this folder.'
  if (sessions.length === 0) {
    return 'No session is running in this folder, so these changes are yours or an earlier one.'
  }
  const certain = files.filter((file) => file.attribution.sessionId !== null).length
  const shared = files.filter((file) => file.attribution.candidates.length > 1).length
  const unattributed = files.length - certain - shared
  const parts: string[] = []
  if (certain > 0) parts.push(`${certain} traceable to one session`)
  if (shared > 0) parts.push(`${shared} that could be any of ${sessions.length} sessions here`)
  if (unattributed > 0) parts.push(`${unattributed} written before any of them started`)
  return `${files.length} changed file${files.length === 1 ? '' : 's'}: ${parts.join(', ')}.`
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(Math.max(Math.trunc(value), min), max)
}

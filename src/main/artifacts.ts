/**
 * What the agent actually produced in a project.
 *
 * ## What an artifact is here, and why it is not something grander
 *
 * The word "artifacts" invites invention — generated images, reports, build
 * output, "documents". This module enumerates exactly one thing, because it is
 * the only thing the app can *know*: **a file an agent wrote or edited in this
 * project**, taken from the tool calls its own transcript recorded.
 *
 * A transcript line for an assistant turn carries a `message.content` array,
 * and a `tool_use` block in it carries the tool's name and the arguments it was
 * called with. Two of those tools name a file and say what went into it, and
 * both were verified against the real transcripts on this machine — 175 files,
 * 3,190 matching calls:
 *
 *     Write  919 calls   { file_path, content }
 *     Edit  2271 calls   { file_path, old_string, new_string, replace_all }
 *
 * A third, `NotebookEdit` ({ notebook_path, new_source, edit_mode }), appears
 * in no transcript here; it is read anyway because its schema is a fact of the
 * current tool set rather than a guess, and a notebook cell rewrite is the same
 * event wearing different field names.
 *
 * `MultiEdit` is deliberately **absent**. It is not in the current tool set and
 * not in a single transcript on this machine, so its shape would be invented,
 * and an invented shape produces either nothing or something wrong. Adding it
 * is one entry in {@link TOOL_SHAPES} the day somebody sees one.
 *
 * Everything else an agent does — a `Bash` line that happens to redirect into a
 * file, an image some MCP server saved — is *not* enumerable from what is
 * recorded. `Bash` records a command string, not its effects, and guessing at
 * `>` and `tee` inside a shell command would produce a list that is confidently
 * wrong. Those are left out, and the page says what it is showing.
 *
 * ## Why the transcript and not `git status`
 *
 * `git status` knows what changed; it does not know *who* changed it. A page
 * whose job is reviewing an agent's work has to separate the agent's edits from
 * your own, and only the transcript can. Source control already answers the
 * other question, on its own page.
 *
 * Wiring:
 *
 *     import { registerArtifactsIpc } from './artifacts'
 *     registerArtifactsIpc(ipcMain)
 */

import { readdir, stat } from 'node:fs/promises'
import { basename, join, relative, resolve, sep } from 'node:path'
import type { IpcMain, IpcMainInvokeEvent } from 'electron'
import { isWithinRoot } from './fs-tree'
import { isAbortError, streamLines } from './session-search'
import {
  configDirs,
  encodeProjectPath,
  homeScopeFor,
  listTranscripts,
  transcriptDirs,
  type HomeScope,
  type TranscriptFile,
  type TranscriptScope,
} from './transcript'
import { onWebContentsDestroyed } from './web-contents-teardown'

export const ARTIFACTS_LIST_CHANNEL = 'artifacts:list'
export const ARTIFACTS_CHANGES_CHANNEL = 'artifacts:changes'
export const ARTIFACTS_CANCEL_CHANNEL = 'artifacts:cancel'

/* -------------------------------------------------------------------------- */
/* Limits                                                                      */
/* -------------------------------------------------------------------------- */

/** Transcripts read per request, newest first. */
export const DEFAULT_MAX_SESSIONS = 40
export const MAX_MAX_SESSIONS = 400

/** Files listed. A long agent run touches hundreds, not thousands. */
export const DEFAULT_MAX_ARTIFACTS = 400
export const MAX_MAX_ARTIFACTS = 2000

/** Transcripts older than this are not opened at all. */
export const DEFAULT_MAX_AGE_MS = 90 * 24 * 60 * 60 * 1000

/** Wall-clock ceiling. Past it the scan stops and reports `truncated`. */
export const DEFAULT_TIME_BUDGET_MS = 8_000

/** Lines between wall-clock checks inside one transcript. */
export const DEADLINE_CHECK_LINES = 512

/** Changes returned for one file, newest first. */
export const DEFAULT_MAX_CHANGES = 60

/**
 * Characters kept per side of one recorded change.
 *
 * A `Write` of a 400 kB file is one string in one transcript line, and sending
 * every one of them to the renderer would put megabytes through the bridge for
 * a pane that shows the first screenful. The clip is reported, never hidden.
 */
export const MAX_CHANGE_CHARS = 24_000

/** Files stat-ed on disk per request, so a huge list cannot storm the syscall table. */
const MAX_DISK_CHECKS = 600

/* -------------------------------------------------------------------------- */
/* Reading tool calls out of a transcript                                      */
/* -------------------------------------------------------------------------- */

export type ArtifactAction = 'write' | 'edit'

/**
 * Where each recognised tool keeps the file it touched and the text involved.
 *
 * A table rather than a `switch` because the honesty of this module is exactly
 * the contents of this table: every entry is a shape somebody has seen, and
 * adding one is the whole cost of supporting another tool.
 */
interface ToolShape {
  /** Input key holding the absolute path. */
  pathKey: string
  action: ArtifactAction
  /** Input key holding the text that was replaced, if the tool records one. */
  beforeKey?: string
  /** Input key holding the text that ended up in the file. */
  afterKey: string
}

export const TOOL_SHAPES: Readonly<Record<string, ToolShape>> = {
  Write: { pathKey: 'file_path', action: 'write', afterKey: 'content' },
  Edit: {
    pathKey: 'file_path',
    action: 'edit',
    beforeKey: 'old_string',
    afterKey: 'new_string',
  },
  NotebookEdit: { pathKey: 'notebook_path', action: 'edit', afterKey: 'new_source' },
}

/**
 * Cheap gate before `JSON.parse`.
 *
 * The lines that matter are assistant turns carrying a `tool_use` block that
 * names a file, and those are also the *expensive* lines to parse — a single
 * `Write` line can be half a megabyte. Rejecting everything else on a substring
 * test is what keeps a scan of a project's whole history to a few seconds.
 */
export function mayCarryFileWrite(line: string): boolean {
  if (!line.includes('"tool_use"')) return false
  return line.includes('"file_path"') || line.includes('"notebook_path"')
}

export interface ToolTouch {
  /** Absolute path exactly as the tool call recorded it. */
  path: string
  action: ArtifactAction
  /** Epoch ms from the line's timestamp, or 0 when it carries none. */
  at: number
  /** Text the edit replaced. Empty for a write, and for tools that record none. */
  before: string
  /** Text that ended up in the file — the content written, or the replacement. */
  after: string
  /** `Edit`'s `replace_all`, which is why one call can change many lines. */
  replaceAll: boolean
  /** The tool's own name, so the UI can say what did this rather than guess. */
  tool: string
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function text(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

/**
 * Absolute in the shape a *transcript* records, which is not the same question
 * as `path.isAbsolute` on the machine reading it.
 *
 * A transcript written on Windows and read on a Mac — the relay makes that an
 * ordinary case — carries `C:\src\app.ts`, which `isAbsolute` on posix calls
 * relative and would then quietly resolve against the project root. Both
 * spellings are recognised here so a foreign path is dropped as outside the
 * project rather than invented as inside it.
 */
export function isRecordedAbsolute(path: string): boolean {
  return path.startsWith('/') || /^[A-Za-z]:[\\/]/.test(path)
}

/**
 * Every file-touching tool call on one JSONL line.
 *
 * Returns an array because one assistant turn genuinely emits several: the
 * parallel-edit pattern puts four `Edit` blocks in one `content` array, and
 * reading only the first would under-count every busy turn.
 */
export function parseToolTouches(line: string): ToolTouch[] {
  let raw: unknown
  try {
    raw = JSON.parse(line)
  } catch {
    // Transcripts are appended to live, so a torn final line is normal.
    return []
  }
  if (!isRecord(raw)) return []
  // A sub-agent's turns are recorded on the same file with `isSidechain`, and
  // they are kept: a file written by a sub-agent is still a file this project's
  // agent produced, and dropping them would hide most of a parallel run.
  const message = isRecord(raw.message) ? raw.message : undefined
  const content = message?.content
  if (!Array.isArray(content)) return []

  const at = typeof raw.timestamp === 'string' ? Date.parse(raw.timestamp) || 0 : 0
  const touches: ToolTouch[] = []

  for (const block of content) {
    if (!isRecord(block) || block.type !== 'tool_use') continue
    const name = typeof block.name === 'string' ? block.name : ''
    const shape = TOOL_SHAPES[name]
    if (!shape) continue
    const input = isRecord(block.input) ? block.input : undefined
    if (!input) continue
    const path = text(input[shape.pathKey])
    // A relative path would have to be resolved against the session's cwd,
    // which is not the project root for a sub-agent that changed directory.
    // Every real call records an absolute one; the rest are dropped rather
    // than resolved against a guess.
    if (!isRecordedAbsolute(path)) continue
    touches.push({
      path,
      action: shape.action,
      at,
      before: shape.beforeKey ? text(input[shape.beforeKey]) : '',
      after: text(input[shape.afterKey]),
      replaceAll: input.replace_all === true,
      tool: name,
    })
  }

  return touches
}

/* -------------------------------------------------------------------------- */
/* Scanning                                                                    */
/* -------------------------------------------------------------------------- */

/**
 * Which transcripts to read.
 *
 * `project` is this project's own transcript directory — the sessions Terminal
 * Deck itself starts, which run with the project as their cwd.
 *
 * `all` reads every transcript on the machine and keeps the tool calls that
 * landed inside this project. That is not a nicety, it is the case that made
 * this module look broken: measured here, `/Users/apple/Projects/terminaldeck`
 * has 16 transcripts of its own containing **zero** file writes, while 193 real
 * Write/Edit calls into that same folder are recorded under
 * `-Users-apple-ClaudeAsad`, because the agent that made them was launched from
 * a parent workspace and reached in. An orchestrator working across repositories
 * is the normal shape of a multi-agent run, and a page that could not see it
 * would report "nothing" about a folder somebody had just spent a night in.
 *
 * It costs more — every project's history rather than one project's — so it is
 * the widened scope rather than the default, and the session cap keeps it to
 * the most recently written transcripts, which is where recent work is.
 */
export type ArtifactScope = 'project' | 'all'

export interface ScanOptions {
  configDir?: string
  deviceHomes?: string | null
  /**
   * Stores that answer for one folder only. Defaults to whatever was installed.
   *
   * Carried through rather than left to the module default because this scan
   * has a wide mode, and the wide mode is the one that has to respect it. See
   * {@link allTranscriptDirs}.
   */
  homeScopes?: readonly HomeScope[]
  scope?: ArtifactScope
  maxSessions?: number
  maxAgeMs?: number
  timeBudgetMs?: number
  signal?: AbortSignal
  /** Injected in tests so the budget can be proven to bite deterministically. */
  clock?: () => number
}

class ScanAborted extends Error {
  constructor() {
    super('artifact scan aborted')
    this.name = 'AbortError'
  }
}

function clamp(value: number | undefined, fallback: number, max: number): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) return fallback
  return Math.min(Math.floor(value), max)
}

/**
 * Every transcript directory under a config store.
 *
 * The directory name is a lossy one-way encoding of a project path, so this
 * enumerates directories rather than trying to decode a name back into a path —
 * the same reasoning `session-search.ts` records for its own all-projects scan.
 * Which project a transcript belongs to does not matter here anyway: what
 * matters is where its tool calls wrote, and that is in the calls themselves.
 */
async function allTranscriptDirs(configDir: string, scope: TranscriptScope): Promise<string[]> {
  /*
   * Unless the store belongs to one folder, in which case that one folder is
   * all it may be enumerated for.
   *
   * The copilot's home is a store like any other and it is the only directory
   * on the machine the copilot may write to. Under `scope: 'all'` this function
   * is what decides which transcripts get their tool calls read — and the reader
   * below attributes a `Write` by the path *recorded in the call*, not by the
   * directory the transcript sits in. So handing over a scoped store whole would
   * let the copilot list files it never wrote, in a repository it cannot even
   * open, on the panel a person uses to review what their agents did.
   *
   * `transcript.ts` has the argument. A scoped home legitimately holds exactly
   * one project directory, so nothing real is dropped here.
   */
  const owned = homeScopeFor(configDir, scope)
  if (owned !== undefined) {
    return [join(configDir, 'projects', encodeProjectPath(owned.folder))]
  }
  let names: string[]
  try {
    names = await readdir(join(configDir, 'projects'))
  } catch {
    return []
  }
  return names.map((name) => join(configDir, 'projects', name)).sort()
}

/** Every transcript to read for a project, newest first, across every config store. */
export async function projectTranscripts(
  cwd: string,
  options: ScanOptions = {},
): Promise<TranscriptFile[]> {
  const scope: TranscriptScope = {
    configDir: options.configDir,
    deviceHomes: options.deviceHomes,
    ...(options.homeScopes === undefined ? {} : { homeScopes: options.homeScopes }),
  }
  const dirs =
    options.scope === 'all'
      ? (await Promise.all(configDirs(scope).map((dir) => allTranscriptDirs(dir, scope)))).flat()
      : transcriptDirs(cwd, scope)

  const files: TranscriptFile[] = []
  for (const dir of dirs) files.push(...(await listTranscripts(dir)))
  return files.sort((a, b) => b.modifiedAt - a.modifiedAt)
}

/**
 * A path recorded by a tool call, as a project-relative POSIX path — or null
 * when it points outside the project.
 *
 * Deliberately `resolve` and not `realpath`: this runs for every touch on every
 * line, a `realpath` each would be thousands of syscalls, and the comparison
 * only has to answer "is this in the folder we are showing". The cost is that a
 * project reached through a symlinked prefix (`/tmp` vs `/private/tmp` on
 * macOS) reads as outside, which is the safe direction to be wrong in — a file
 * is left out of a list rather than a stranger's file shown in it.
 */
export function relativeToRoot(root: string, recorded: string): string | null {
  const abs = resolve(recorded)
  if (!isWithinRoot(root, abs)) return null
  const rel = relative(resolve(root), abs)
  // `isWithinRoot` counts the root itself as inside it, and the root is a
  // directory rather than an artifact.
  if (rel === '') return null
  return sep === '/' ? rel : rel.split(sep).join('/')
}

/**
 * Walk a project's transcripts, handing every file-touching tool call to
 * `onTouch` with the session it came from.
 *
 * The one traversal both public calls share. Returning `false` from `onTouch`
 * is not a thing it can do — filtering is the caller's business, and making the
 * walk understand two kinds of filter is how it would grow a third.
 */
async function scanTranscripts(
  cwd: string,
  onTouch: (touch: ToolTouch, file: TranscriptFile) => void,
  options: ScanOptions = {},
): Promise<{ sessionsScanned: number; truncated: boolean; cancelled: boolean }> {
  const clock = options.clock ?? Date.now
  const deadline = clock() + clamp(options.timeBudgetMs, DEFAULT_TIME_BUDGET_MS, 120_000)
  const maxSessions = clamp(options.maxSessions, DEFAULT_MAX_SESSIONS, MAX_MAX_SESSIONS)
  const maxAge = options.maxAgeMs === 0 ? 0 : clamp(options.maxAgeMs, DEFAULT_MAX_AGE_MS, Number.MAX_SAFE_INTEGER)
  const cutoff = maxAge > 0 ? Date.now() - maxAge : 0

  const root = resolve(cwd)
  let sessionsScanned = 0
  let truncated = false
  let cancelled = false

  try {
    const all = (await projectTranscripts(root, options)).filter((file) => file.modifiedAt >= cutoff)
    const files = all.slice(0, maxSessions)
    truncated = all.length > files.length

    for (const file of files) {
      if (options.signal?.aborted) throw new ScanAborted()
      if (clock() > deadline) {
        truncated = true
        break
      }

      let lines = 0
      let timedOut = false
      for await (const line of streamLines(file.path, options.signal)) {
        lines += 1
        // Checked inside the file as well as between files: one transcript on
        // this machine is 154 MB, and a budget that only bites between files
        // would let a single one run to completion however long it took.
        if (lines % DEADLINE_CHECK_LINES === 0 && clock() > deadline) {
          timedOut = true
          break
        }
        if (!mayCarryFileWrite(line)) continue
        for (const touch of parseToolTouches(line)) {
          onTouch({ ...touch, at: touch.at > 0 ? touch.at : file.modifiedAt }, file)
        }
      }

      sessionsScanned += 1
      if (timedOut) {
        truncated = true
        break
      }
    }
  } catch (error) {
    if (!isAbortError(error)) throw error
    cancelled = true
  }

  return { sessionsScanned, truncated, cancelled }
}

/* -------------------------------------------------------------------------- */
/* The list                                                                    */
/* -------------------------------------------------------------------------- */

export interface Artifact {
  /** POSIX path relative to the project root — what the Files page opens. */
  relPath: string
  /** Just the filename, so the renderer does not re-split the path per row. */
  name: string
  firstAt: number
  lastAt: number
  writes: number
  edits: number
  /** Characters the most recent change put into the file, as recorded. */
  lastChars: number
  /** The tool behind the most recent change. */
  lastTool: string
  /** Sessions that touched this file, most recent first. */
  sessionIds: string[]
  /** Null when the file is no longer on disk — deleted, moved or never kept. */
  onDisk: { bytes: number; modifiedAt: number } | null
}

export interface ArtifactSession {
  sessionId: string
  /** Most recent touch in this session. */
  at: number
  /** Files this session wrote or edited inside the project. */
  files: number
}

export interface ArtifactList {
  root: string
  /** Which transcripts this answer came from, so the page cannot mislabel it. */
  scope: ArtifactScope
  artifacts: Artifact[]
  /** Sessions that produced at least one artifact, most recent first. */
  sessions: ArtifactSession[]
  sessionsScanned: number
  /** Tool calls that named a file outside the project — counted, not listed. */
  outsideProject: number
  /** A cap or the time budget cut the scan short. */
  truncated: boolean
  cancelled: boolean
  tookMs: number
}

export interface ListArtifactsOptions extends ScanOptions {
  maxArtifacts?: number
  /** Skips the disk check. Tests use it; nothing else should. */
  skipDiskCheck?: boolean
}

interface Building {
  relPath: string
  firstAt: number
  lastAt: number
  writes: number
  edits: number
  lastChars: number
  lastTool: string
  sessions: Map<string, number>
}

export async function listArtifacts(
  cwd: string,
  options: ListArtifactsOptions = {},
): Promise<ArtifactList> {
  const started = Date.now()
  const root = resolve(cwd)
  const maxArtifacts = clamp(options.maxArtifacts, DEFAULT_MAX_ARTIFACTS, MAX_MAX_ARTIFACTS)

  const byPath = new Map<string, Building>()
  const sessions = new Map<string, { at: number; files: Set<string> }>()
  let outsideProject = 0

  const outcome = await scanTranscripts(
    root,
    (touch, file) => {
      const relPath = relativeToRoot(root, touch.path)
      if (relPath === null) {
        outsideProject += 1
        return
      }

      let entry = byPath.get(relPath)
      if (!entry) {
        entry = {
          relPath,
          firstAt: touch.at,
          lastAt: 0,
          writes: 0,
          edits: 0,
          lastChars: 0,
          lastTool: touch.tool,
          sessions: new Map(),
        }
        byPath.set(relPath, entry)
      }

      if (touch.action === 'write') entry.writes += 1
      else entry.edits += 1
      if (touch.at < entry.firstAt || entry.firstAt === 0) entry.firstAt = touch.at
      // Transcripts are appended in order, but two *files* are merged here, so
      // "most recent" has to be decided by the timestamp rather than by arrival.
      if (touch.at >= entry.lastAt) {
        entry.lastAt = touch.at
        entry.lastChars = touch.after.length
        entry.lastTool = touch.tool
      }

      const seenAt = entry.sessions.get(file.sessionId) ?? 0
      if (touch.at > seenAt) entry.sessions.set(file.sessionId, touch.at)

      const session = sessions.get(file.sessionId) ?? { at: 0, files: new Set<string>() }
      session.files.add(relPath)
      if (touch.at > session.at) session.at = touch.at
      sessions.set(file.sessionId, session)
    },
    options,
  )

  const ordered = [...byPath.values()].sort((a, b) => b.lastAt - a.lastAt)
  const kept = ordered.slice(0, maxArtifacts)

  const artifacts: Artifact[] = kept.map((entry) => ({
    relPath: entry.relPath,
    name: basename(entry.relPath),
    firstAt: entry.firstAt,
    lastAt: entry.lastAt,
    writes: entry.writes,
    edits: entry.edits,
    lastChars: entry.lastChars,
    lastTool: entry.lastTool,
    sessionIds: [...entry.sessions.entries()].sort((a, b) => b[1] - a[1]).map(([id]) => id),
    onDisk: null,
  }))

  // The disk check is what makes the list honest about the present: an agent
  // writes a scratch file and deletes it two turns later, and a row that offers
  // to open it would be offering a read error.
  if (options.skipDiskCheck !== true) {
    const checked = artifacts.slice(0, MAX_DISK_CHECKS)
    await Promise.all(
      checked.map(async (artifact) => {
        try {
          const info = await stat(resolve(root, artifact.relPath))
          if (info.isFile()) artifact.onDisk = { bytes: info.size, modifiedAt: info.mtimeMs }
        } catch {
          // Gone, or unreadable. Either way it is not something to open.
        }
      }),
    )
  }

  return {
    root,
    scope: options.scope === 'all' ? 'all' : 'project',
    artifacts,
    sessions: [...sessions.entries()]
      .map(([sessionId, value]) => ({ sessionId, at: value.at, files: value.files.size }))
      .sort((a, b) => b.at - a.at),
    sessionsScanned: outcome.sessionsScanned,
    outsideProject,
    truncated: outcome.truncated || ordered.length > kept.length,
    cancelled: outcome.cancelled,
    tookMs: Date.now() - started,
  }
}

/* -------------------------------------------------------------------------- */
/* One file's history                                                          */
/* -------------------------------------------------------------------------- */

export interface ArtifactChange {
  at: number
  sessionId: string
  action: ArtifactAction
  tool: string
  /** What this call replaced. Empty on a write, which replaces the whole file. */
  before: string
  /** What this call put in. */
  after: string
  replaceAll: boolean
  /** Either side was longer than {@link MAX_CHANGE_CHARS} and was cut. */
  clipped: boolean
}

export interface ArtifactHistory {
  root: string
  relPath: string
  /** Most recent first — the order somebody reviewing reads in. */
  changes: ArtifactChange[]
  /** Changes found before the cap trimmed the list. */
  totalChanges: number
  truncated: boolean
  cancelled: boolean
  tookMs: number
}

export interface ArtifactHistoryOptions extends ScanOptions {
  maxChanges?: number
}

function clip(value: string): { text: string; clipped: boolean } {
  if (value.length <= MAX_CHANGE_CHARS) return { text: value, clipped: false }
  return { text: value.slice(0, MAX_CHANGE_CHARS), clipped: true }
}

export async function artifactHistory(
  cwd: string,
  relPath: string,
  options: ArtifactHistoryOptions = {},
): Promise<ArtifactHistory> {
  const started = Date.now()
  const root = resolve(cwd)
  const target = relativeToRoot(root, resolve(root, relPath))
  const maxChanges = clamp(options.maxChanges, DEFAULT_MAX_CHANGES, 500)

  const changes: ArtifactChange[] = []
  let totalChanges = 0

  const outcome =
    target === null
      ? { sessionsScanned: 0, truncated: false, cancelled: false }
      : await scanTranscripts(
          root,
          (touch, file) => {
            if (relativeToRoot(root, touch.path) !== target) return
            totalChanges += 1
            const before = clip(touch.before)
            const after = clip(touch.after)
            changes.push({
              at: touch.at,
              sessionId: file.sessionId,
              action: touch.action,
              tool: touch.tool,
              before: before.text,
              after: after.text,
              replaceAll: touch.replaceAll,
              clipped: before.clipped || after.clipped,
            })
            // Trimmed as it grows rather than at the end: a file rewritten two
            // hundred times would otherwise hold two hundred file bodies in
            // memory before anything threw any of them away.
            if (changes.length > maxChanges * 2) {
              changes.sort((a, b) => b.at - a.at)
              changes.length = maxChanges
            }
          },
          options,
        )

  changes.sort((a, b) => b.at - a.at)
  const truncated = outcome.truncated || changes.length > maxChanges
  if (changes.length > maxChanges) changes.length = maxChanges

  return {
    root,
    relPath: target ?? relPath,
    changes,
    totalChanges,
    truncated,
    cancelled: outcome.cancelled,
    tookMs: Date.now() - started,
  }
}

/* -------------------------------------------------------------------------- */
/* IPC                                                                         */
/* -------------------------------------------------------------------------- */

export interface ArtifactsListRequest {
  cwd: string
  scope?: ArtifactScope
  maxSessions?: number
  maxArtifacts?: number
}

export interface ArtifactsChangesRequest {
  cwd: string
  relPath: string
  scope?: ArtifactScope
  maxChanges?: number
}

export type ArtifactsListResponse =
  | ({ ok: true } & ArtifactList)
  | { ok: false; error: 'cancelled' | 'invalid-project' | 'failed'; message: string }

export type ArtifactsChangesResponse =
  | ({ ok: true } & ArtifactHistory)
  | { ok: false; error: 'cancelled' | 'invalid-project' | 'failed'; message: string }

/**
 * A project path from the renderer is untrusted. It is never opened directly —
 * it is hashed into a transcript directory name — but the disk check does read
 * `<root>/<relPath>`, so both halves are pinned: the root has to be a real
 * absolute path, and every relative path is proven to stay inside it by
 * `relativeToRoot` before anything touches it.
 */
function projectPath(cwd: unknown): string {
  if (typeof cwd !== 'string' || cwd.trim().length === 0) {
    throw new Error('artifacts: a project path is required')
  }
  const resolved = resolve(cwd)
  if (resolved === sep) throw new Error('artifacts: refusing to scan the filesystem root')
  return resolved
}

/**
 * One scan per window **per channel**, and the reason that second half is in
 * bold.
 *
 * A newer request replacing an older one is right: the user has moved to
 * another project, or toggled the scope, and two passes over the same history
 * only slow each other down. What was wrong was the key. This was a
 * `Map<senderId, AbortController>`, so *any* request from a window aborted
 * *any* other request from that window — and the Artifacts page makes two,
 * on two different channels, about two different things.
 *
 * The page's own effects fire them in that order on every scope toggle and
 * every project switch: the list effect starts `artifacts:list`, and the
 * history effect, running in the same commit and still seeing the previous
 * selection, immediately starts `artifacts:changes` — which aborted the list
 * it had nothing to do with. The list handler then answered
 * `{ ok: false, error: 'cancelled' }`, a shape the panel silently ignored, and
 * the page sat on *"Reading this project’s history…"* for the rest of the
 * session with an empty list under it. Reproducible every time by pressing
 * "Every session".
 *
 * Keying on the channel as well means a list only ever cancels a list. The two
 * scans do overlap now, which is what the page was always asking for, and both
 * are bounded by the same time budget they always were.
 *
 * Exported so it can be tested without a filesystem: the bookkeeping is the
 * whole of the bug, and it is not observable through a scan of a real project.
 */
export class ScanSlots {
  private readonly slots = new Map<string, AbortController>()

  // The two halves are joined with a NUL, which cannot occur in either of
  // them, so no two different (sender, channel) pairs can collide on one key.
  // Spelled as an escape, never as the byte: a single literal NUL makes
  // `file`(1) call this source file `data` and makes `grep`(1) treat it as
  // binary, at which point every search of this file silently returns nothing.
  private static key(senderId: number, channel: string): string {
    return `${senderId}\u0000${channel}`
  }

  /** Start a scan, retiring the previous one **on the same channel** only. */
  begin(senderId: number, channel: string): AbortController {
    const key = ScanSlots.key(senderId, channel)
    this.slots.get(key)?.abort()
    const controller = new AbortController()
    this.slots.set(key, controller)
    return controller
  }

  /** Forget a finished scan, unless a newer one has already taken its place. */
  end(senderId: number, channel: string, controller: AbortController): void {
    const key = ScanSlots.key(senderId, channel)
    if (this.slots.get(key) === controller) this.slots.delete(key)
  }

  /** The window has gone. Everything it asked for stops. */
  cancelAll(senderId: number): void {
    const prefix = `${senderId}\u0000`
    for (const [key, controller] of [...this.slots]) {
      if (!key.startsWith(prefix)) continue
      controller.abort()
      this.slots.delete(key)
    }
  }

  /** How many scans are running. Tests read this; nothing else does. */
  get size(): number {
    return this.slots.size
  }
}

/**
 * Register the artifact channels.
 *
 *  - `artifacts:list`    (ArtifactsListRequest)    -> ArtifactsListResponse
 *  - `artifacts:changes` (ArtifactsChangesRequest) -> ArtifactsChangesResponse
 *  - `artifacts:cancel`  ()                        -> void
 */
export function registerArtifactsIpc(ipcMain: IpcMain): void {
  const inFlight = new ScanSlots()

  const begin = (event: IpcMainInvokeEvent, channel: string): AbortController => {
    const senderId = event.sender.id
    const controller = inFlight.begin(senderId, channel)
    // A closed window must not leave a scan of every transcript running for
    // nobody. Keyed, so registering on every request is correct rather than a
    // leak — see `web-contents-teardown.ts`.
    onWebContentsDestroyed(event.sender, 'artifacts', () => inFlight.cancelAll(senderId))
    return controller
  }

  const end = (event: IpcMainInvokeEvent, channel: string, controller: AbortController): void => {
    inFlight.end(event.sender.id, channel, controller)
  }

  ipcMain.handle(
    ARTIFACTS_LIST_CHANNEL,
    async (event: IpcMainInvokeEvent, request: unknown): Promise<ArtifactsListResponse> => {
      const payload = (request ?? {}) as Partial<ArtifactsListRequest>
      let cwd: string
      try {
        cwd = projectPath(payload.cwd)
      } catch (error) {
        return {
          ok: false,
          error: 'invalid-project',
          message: error instanceof Error ? error.message : 'Invalid project path.',
        }
      }

      const controller = begin(event, ARTIFACTS_LIST_CHANNEL)
      try {
        const result = await listArtifacts(cwd, {
          scope: payload.scope === 'all' ? 'all' : 'project',
          maxSessions: payload.maxSessions,
          maxArtifacts: payload.maxArtifacts,
          signal: controller.signal,
        })
        if (result.cancelled) return { ok: false, error: 'cancelled', message: 'Scan cancelled.' }
        return { ok: true, ...result }
      } catch (error) {
        if (isAbortError(error)) return { ok: false, error: 'cancelled', message: 'Scan cancelled.' }
        console.error('[artifacts] list failed:', error)
        return { ok: false, error: 'failed', message: 'Could not read this project’s history.' }
      } finally {
        end(event, ARTIFACTS_LIST_CHANNEL, controller)
      }
    },
  )

  ipcMain.handle(
    ARTIFACTS_CHANGES_CHANNEL,
    async (event: IpcMainInvokeEvent, request: unknown): Promise<ArtifactsChangesResponse> => {
      const payload = (request ?? {}) as Partial<ArtifactsChangesRequest>
      let cwd: string
      try {
        cwd = projectPath(payload.cwd)
      } catch (error) {
        return {
          ok: false,
          error: 'invalid-project',
          message: error instanceof Error ? error.message : 'Invalid project path.',
        }
      }
      if (typeof payload.relPath !== 'string' || payload.relPath === '') {
        return { ok: false, error: 'invalid-project', message: 'A file is required.' }
      }

      const controller = begin(event, ARTIFACTS_CHANGES_CHANNEL)
      try {
        const result = await artifactHistory(cwd, payload.relPath, {
          scope: payload.scope === 'all' ? 'all' : 'project',
          maxChanges: payload.maxChanges,
          signal: controller.signal,
        })
        if (result.cancelled) return { ok: false, error: 'cancelled', message: 'Scan cancelled.' }
        return { ok: true, ...result }
      } catch (error) {
        if (isAbortError(error)) return { ok: false, error: 'cancelled', message: 'Scan cancelled.' }
        console.error('[artifacts] changes failed:', error)
        return { ok: false, error: 'failed', message: 'Could not read this file’s history.' }
      } finally {
        end(event, ARTIFACTS_CHANGES_CHANNEL, controller)
      }
    },
  )

  // The page leaving, or the window closing: everything this sender asked for
  // stops, on every channel.
  ipcMain.handle(ARTIFACTS_CANCEL_CHANNEL, (event: IpcMainInvokeEvent): void => {
    inFlight.cancelAll(event.sender.id)
  })
}

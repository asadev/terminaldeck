import { execFile } from 'node:child_process'
import type { Dirent } from 'node:fs'
import { readdir, stat } from 'node:fs/promises'
import { homedir } from 'node:os'
import { isAbsolute, join, parse as parsePath, resolve, sep } from 'node:path'
import type { IpcMain, IpcMainInvokeEvent } from 'electron'

/**
 * Candidate file enumeration for quick open.
 *
 * The renderer asks once per project and ranks locally on every keystroke —
 * round-tripping to the main process per character would put IPC latency in
 * front of every letter typed. That makes this module's job "produce a good,
 * bounded list quickly", not "search".
 *
 * `git ls-files` is tried first because it already knows what the project
 * considers noise: build output, caches, anything in .gitignore. The directory
 * walk is the fallback for folders that are not repositories, and for machines
 * where git is not on the packaged app's PATH.
 *
 * Deliberately holds no reference to `electron` at runtime — only its types —
 * so the logic here stays unit-testable outside an Electron process.
 */

export const FILE_SEARCH_CHANNEL = 'search:files'
export const FILE_SEARCH_CANCEL_CHANNEL = 'search:cancel'
export const FILE_SEARCH_INVALIDATE_CHANNEL = 'search:invalidate'

/**
 * Directories that are never worth walking. `.git` and `node_modules` are the
 * ones that matter — either can outnumber the real project by a hundred to one.
 */
export const DEFAULT_IGNORED_DIRS: readonly string[] = [
  '.git',
  '.hg',
  '.svn',
  'node_modules',
  'bower_components',
  '.venv',
  'venv',
  '__pycache__',
  '.mypy_cache',
  '.pytest_cache',
  '.tox',
  'dist',
  'build',
  'out',
  'target',
  'coverage',
  '.next',
  '.nuxt',
  '.svelte-kit',
  '.turbo',
  '.parcel-cache',
  '.cache',
  '.gradle',
  '.idea',
  'DerivedData',
  'Pods',
  '.terraform',
  '.serverless',
  '.yarn',
  '.pnpm-store',
]

const DEFAULT_LIMIT = 10_000
const MAX_LIMIT = 50_000
const DEFAULT_MAX_DEPTH = 12
/** Directories read in parallel. Enough to hide syscall latency, not enough
 *  to exhaust the file-descriptor table on a large monorepo. */
const READ_CONCURRENCY = 12
const GIT_TIMEOUT_MS = 8_000
const GIT_MAX_BUFFER = 32 * 1024 * 1024
/** A project's file list barely moves between keystrokes; re-walking it on
 *  every palette open would be pure waste. */
const CACHE_TTL_MS = 30_000

export interface FileSearchOptions {
  /** Hard ceiling on returned paths. Defaults to 10,000. */
  limit?: number
  /** Aborts the walk, and kills the `git ls-files` child if one is running. */
  signal?: AbortSignal
  /** Directory names to skip on top of the defaults. */
  ignoreDirs?: readonly string[]
  /** How deep the fallback walk goes. Defaults to 12. */
  maxDepth?: number
  /** Skip the git fast path. Only used by tests. */
  disableGit?: boolean
}

export interface FileList {
  /** Absolute, resolved project root. */
  root: string
  /** Project-relative paths, forward slashes on every platform. */
  files: string[]
  /** True when the limit or the depth cut the list short. */
  truncated: boolean
  source: 'git' | 'walk'
  tookMs: number
}

export type FileSearchResponse =
  | ({ ok: true } & FileList)
  | { ok: false; error: 'cancelled' | 'invalid-root' | 'failed' }

export interface FileSearchRequest {
  root: string
  /** Ignore the cached list and enumerate again. */
  refresh?: boolean
  limit?: number
}

/** Thrown by the walk when its signal fires. Named so callers can recognise it
 *  the same way they recognise an aborted child process. */
class SearchAbortedError extends Error {
  constructor() {
    super('file search aborted')
    this.name = 'AbortError'
  }
}

export function isAbortError(error: unknown): boolean {
  return error instanceof Error && error.name === 'AbortError'
}

function throwIfAborted(signal: AbortSignal | undefined): void {
  if (signal?.aborted) throw new SearchAbortedError()
}

/** Project-relative paths are always reported with forward slashes, so the
 *  renderer's path handling does not need a platform branch. */
export function toPosix(path: string): string {
  return sep === '/' ? path : path.split(sep).join('/')
}

/**
 * `git ls-files -z` emits NUL-separated paths. NUL rather than newline because
 * a newline is a legal character in a filename and would split one path in two.
 */
export function parseGitFileList(stdout: string): string[] {
  const seen = new Set<string>()
  for (const entry of stdout.split('\0')) {
    if (entry !== '') seen.add(entry)
  }
  return [...seen]
}

/** True when any directory on the way to this file is one we skip. */
export function isIgnoredPath(relativePath: string, ignored: ReadonlySet<string>): boolean {
  const segments = relativePath.split('/')
  for (let i = 0; i < segments.length - 1; i++) {
    if (ignored.has(segments[i])) return true
  }
  return false
}

/**
 * Refuses roots that would enumerate far more than a project: the filesystem
 * root, a drive root, and the home directory itself. Not a security boundary
 * on its own — pass `isAllowedRoot` to `registerSearchIpc` for that — but it
 * stops an obvious foot-gun before it spawns a million-file walk.
 */
export function isPlausibleProjectRoot(root: string): boolean {
  if (root === '' || !isAbsolute(root)) return false
  const resolved = resolve(root)
  if (resolved === parsePath(resolved).root) return false
  if (resolved === resolve(homedir())) return false
  return true
}

function clampLimit(limit: number | undefined): number {
  if (typeof limit !== 'number' || !Number.isFinite(limit)) return DEFAULT_LIMIT
  return Math.max(1, Math.min(MAX_LIMIT, Math.floor(limit)))
}

function runGit(args: readonly string[], cwd: string, signal?: AbortSignal): Promise<string> {
  return new Promise((done, fail) => {
    execFile(
      'git',
      [...args],
      {
        cwd,
        signal,
        encoding: 'utf8',
        timeout: GIT_TIMEOUT_MS,
        maxBuffer: GIT_MAX_BUFFER,
        windowsHide: true,
      },
      (error, stdout) => {
        if (error) fail(error)
        else done(stdout)
      },
    )
  })
}

async function listWithGit(root: string, signal: AbortSignal | undefined): Promise<string[] | null> {
  try {
    const stdout = await runGit(
      ['ls-files', '--cached', '--others', '--exclude-standard', '-z'],
      root,
      signal,
    )
    return parseGitFileList(stdout)
  } catch (error) {
    // Cancellation is the caller's business; everything else — not a repo, git
    // missing, timed out — just means the walk takes over.
    if (isAbortError(error)) throw error
    return null
  }
}

async function readDirectory(dir: string): Promise<Dirent[]> {
  try {
    return await readdir(dir, { withFileTypes: true })
  } catch {
    // Unreadable directory (permissions, or it vanished mid-walk). One bad
    // folder must not abort enumeration of the rest of the project.
    return []
  }
}

interface QueuedDir {
  absolute: string
  relative: string
  depth: number
}

/**
 * Breadth-first directory walk. Breadth-first specifically because the list is
 * capped: when a project overruns the limit, the files nearest the root are
 * the ones a person is most likely to be looking for, and a depth-first walk
 * would spend the whole budget inside the first subtree it entered.
 */
export async function walkProjectFiles(
  root: string,
  options: FileSearchOptions = {},
): Promise<{ files: string[]; truncated: boolean }> {
  const limit = clampLimit(options.limit)
  const maxDepth = options.maxDepth ?? DEFAULT_MAX_DEPTH
  const ignored = new Set([...DEFAULT_IGNORED_DIRS, ...(options.ignoreDirs ?? [])])
  const files: string[] = []
  let truncated = false
  let queue: QueuedDir[] = [{ absolute: root, relative: '', depth: 0 }]

  while (queue.length > 0) {
    throwIfAborted(options.signal)
    if (files.length >= limit) {
      truncated = true
      break
    }

    const batch = queue.splice(0, READ_CONCURRENCY)
    const read = await Promise.all(
      batch.map(async (dir) => ({ dir, entries: await readDirectory(dir.absolute) })),
    )
    const deeper: QueuedDir[] = []

    for (const { dir, entries } of read) {
      for (const entry of entries) {
        if (files.length >= limit) {
          truncated = true
          break
        }
        // Symlinks are skipped outright. A link pointing back up the tree
        // turns the walk into an infinite loop, and resolving every one to
        // find out costs a stat per entry.
        if (entry.isSymbolicLink()) continue

        const relative = dir.relative === '' ? entry.name : `${dir.relative}/${entry.name}`
        if (entry.isDirectory()) {
          if (ignored.has(entry.name)) continue
          if (dir.depth >= maxDepth) {
            truncated = true
            continue
          }
          deeper.push({
            absolute: join(dir.absolute, entry.name),
            relative,
            depth: dir.depth + 1,
          })
        } else if (entry.isFile()) {
          files.push(relative)
        }
      }
    }

    // Appended, not prepended — this is what keeps the walk breadth-first.
    queue = queue.concat(deeper)
  }

  if (queue.length > 0) truncated = true
  return { files, truncated }
}

/** Enumerate a project: git if it can, a bounded walk if it cannot. */
export async function listProjectFiles(
  root: string,
  options: FileSearchOptions = {},
): Promise<FileList> {
  const started = Date.now()
  const resolved = resolve(root)
  const limit = clampLimit(options.limit)
  const ignored = new Set([...DEFAULT_IGNORED_DIRS, ...(options.ignoreDirs ?? [])])

  if (options.disableGit !== true) {
    const tracked = await listWithGit(resolved, options.signal)
    if (tracked) {
      throwIfAborted(options.signal)
      const kept = tracked.filter((file) => !isIgnoredPath(file, ignored))
      return {
        root: resolved,
        files: kept.slice(0, limit),
        truncated: kept.length > limit,
        source: 'git',
        tookMs: Date.now() - started,
      }
    }
  }

  const walked = await walkProjectFiles(resolved, { ...options, limit })
  return {
    root: resolved,
    files: walked.files.map(toPosix),
    truncated: walked.truncated,
    source: 'walk',
    tookMs: Date.now() - started,
  }
}

interface CacheEntry {
  at: number
  /** The cap this list was produced under. A list that was cut short for a
   *  small request must not be handed to a later one that asked for more. */
  limit: number
  list: FileList
}

/**
 * One entry can hold up to MAX_LIMIT paths — tens of megabytes of strings for
 * a monorepo. Without a cap, every root the renderer ever asks about stays
 * resident for the life of the process, and expired entries are never even
 * looked at again, so nothing would ever free them.
 */
const MAX_CACHED_ROOTS = 8

const cache = new Map<string, CacheEntry>()

/** Drop a cached list — call after an operation that changes the file set. */
export function invalidateFileList(root?: string): void {
  if (root === undefined) cache.clear()
  else cache.delete(resolve(root))
}

function readCache(root: string, limit: number): FileList | null {
  const entry = cache.get(root)
  if (!entry) return null
  if (Date.now() - entry.at >= CACHE_TTL_MS) {
    cache.delete(root)
    return null
  }
  // Only a *truncated* list is short because of its cap; a complete one is
  // complete whatever limit produced it.
  if (entry.list.truncated && entry.limit < limit) return null
  // Map iteration is insertion order, so re-inserting marks this entry as the
  // most recently used and leaves the coldest one first.
  cache.delete(root)
  cache.set(root, entry)
  return entry.list
}

function writeCache(root: string, limit: number, list: FileList): void {
  const now = Date.now()
  for (const [key, entry] of [...cache]) {
    if (now - entry.at >= CACHE_TTL_MS) cache.delete(key)
  }
  cache.delete(root)
  cache.set(root, { at: now, limit, list })
  while (cache.size > MAX_CACHED_ROOTS) {
    const coldest = cache.keys().next()
    if (coldest.done) break
    cache.delete(coldest.value)
  }
}

async function isDirectory(path: string): Promise<boolean> {
  try {
    return (await stat(path)).isDirectory()
  } catch {
    return false
  }
}

export interface RegisterSearchOptions {
  /**
   * Gate on which folders the renderer may enumerate. Pass the app's known
   * project list — a renderer that has been compromised should not be able to
   * turn quick open into a filesystem crawler.
   */
  isAllowedRoot?(root: string): boolean
  /** Overrides the default per-request cap. */
  limit?: number
}

/**
 * Wire the file-search channels.
 *
 * ```ts
 * registerSearchIpc(ipcMain, {
 *   isAllowedRoot: (root) => store().getProjects().some((p) => p.path === root),
 * })
 * ```
 *
 * A second request from the same window cancels the first: the user has moved
 * on, and two concurrent walks of the same tree only slow each other down.
 */
export function registerSearchIpc(ipcMain: IpcMain, options: RegisterSearchOptions = {}): void {
  const inFlight = new Map<number, AbortController>()
  /** Senders already wired for teardown — one listener each, not one per request. */
  const watched = new Set<number>()

  const cancelFor = (senderId: number): void => {
    inFlight.get(senderId)?.abort()
    inFlight.delete(senderId)
  }

  ipcMain.handle(
    FILE_SEARCH_CHANNEL,
    async (event: IpcMainInvokeEvent, request: unknown): Promise<FileSearchResponse> => {
      const payload = request as Partial<FileSearchRequest> | undefined
      const rawRoot = payload?.root
      if (typeof rawRoot !== 'string' || rawRoot === '') return { ok: false, error: 'invalid-root' }

      const root = resolve(rawRoot)
      if (!isPlausibleProjectRoot(root)) return { ok: false, error: 'invalid-root' }
      if (options.isAllowedRoot && !options.isAllowedRoot(root)) {
        return { ok: false, error: 'invalid-root' }
      }
      if (!(await isDirectory(root))) return { ok: false, error: 'invalid-root' }

      const senderId = event.sender.id
      const limit = clampLimit(payload?.limit ?? options.limit)
      if (payload?.refresh !== true) {
        const cached = readCache(root, limit)
        if (cached) return { ok: true, ...cached }
      }

      cancelFor(senderId)
      const controller = new AbortController()
      inFlight.set(senderId, controller)
      // A closed window must not leave a walk running against a dead sender.
      if (!watched.has(senderId)) {
        watched.add(senderId)
        event.sender.once('destroyed', () => {
          cancelFor(senderId)
          watched.delete(senderId)
        })
      }

      try {
        const list = await listProjectFiles(root, { signal: controller.signal, limit })
        writeCache(root, limit, list)
        return { ok: true, ...list }
      } catch (error) {
        if (isAbortError(error)) return { ok: false, error: 'cancelled' }
        console.error('[file-search] enumeration failed:', error)
        return { ok: false, error: 'failed' }
      } finally {
        if (inFlight.get(senderId) === controller) inFlight.delete(senderId)
      }
    },
  )

  ipcMain.handle(FILE_SEARCH_CANCEL_CHANNEL, (event: IpcMainInvokeEvent): void => {
    cancelFor(event.sender.id)
  })

  ipcMain.handle(FILE_SEARCH_INVALIDATE_CHANNEL, (_event: IpcMainInvokeEvent, root?: unknown): void => {
    invalidateFileList(typeof root === 'string' ? root : undefined)
  })
}

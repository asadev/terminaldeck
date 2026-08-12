/**
 * `.pawlignore` — one list of what this app should not look at, shared by the
 * file tree, quick open and the watchers.
 *
 * The pattern engine is not written here. `fs-tree.ts` already has one, and it
 * is tested case-by-case against real `git check-ignore` output, which is the
 * only definition of "gitignore semantics" that actually counts. A second
 * implementation would be a second set of edge cases to get wrong. picomatch
 * is available and deliberately unused: it is a glob matcher, not a gitignore
 * matcher — no negation, no directory-only rules, no last-match-wins — so it
 * would only cover the easy half.
 *
 * What this module adds is everything around the matcher: finding the files,
 * caching the compiled result until they change, merging `.gitignore` with
 * `.pawlignore` in the right order, explaining *which* rule hid something, and
 * handing consumers filters in the shape each of them needs.
 *
 * Ordering matters and is the reason both files are merged here rather than
 * separately: rules are evaluated last-match-wins, so `.pawlignore` is
 * appended after `.gitignore` and can re-include something git hides —
 * `!dist/preview.html` in `.pawlignore` works even though `.gitignore` has
 * `dist/`. The reverse would make `.pawlignore` unable to override anything.
 */

import { constants } from 'node:fs'
import { open, stat, type FileHandle } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import type { IpcMain, IpcMainInvokeEvent } from 'electron'
import {
  createIgnoreMatcher,
  isAlwaysIgnored,
  parseIgnoreFile,
  type IgnoreMatcher,
  type IgnoreRule,
} from './fs-tree'

/* ---------------------------------------------------------------- types -- */

export const PAWLIGNORE_FILE = '.pawlignore'
export const GITIGNORE_FILE = '.gitignore'

/** Later files win, so `.pawlignore` can negate a `.gitignore` rule. */
export const IGNORE_FILE_ORDER: readonly string[] = [GITIGNORE_FILE, PAWLIGNORE_FILE]

/**
 * A hand-written ignore file is a few hundred bytes. Anything past this is a
 * generated or corrupt file, and compiling it would mean one regex per line
 * evaluated against every path in the tree.
 */
export const MAX_IGNORE_BYTES = 256 * 1024

/** A rule plus which file it came from, so an explanation can name the file. */
export interface TaggedRule {
  rule: IgnoreRule
  /** File name, e.g. `.pawlignore`. */
  file: string
  /** 1-based line number within that file. */
  line: number
}

export interface IgnoreSource {
  file: string
  path: string
  present: boolean
  ruleCount: number
  /** Set when the file exists but was too large to use. */
  skipped: 'too-large' | null
}

export interface ProjectIgnore {
  /** Absolute, resolved project root. */
  root: string
  /** `(relPath, isDir) => hidden`, the shape `fs-tree.listDirectory` uses. */
  matches: IgnoreMatcher
  rules: TaggedRule[]
  sources: IgnoreSource[]
}

export interface IgnoreOptions {
  /** Merge `.gitignore` in first. On by default — the tree already does this. */
  includeGitignore?: boolean
}

/* -------------------------------------------------------------- loading -- */

async function readIgnoreFile(
  root: string,
  file: string,
): Promise<{ source: IgnoreSource; rules: TaggedRule[] }> {
  const path = join(root, file)
  const absent: IgnoreSource = { file, path, present: false, ruleCount: 0, skipped: null }
  const tooLarge: IgnoreSource = { file, path, present: true, ruleCount: 0, skipped: 'too-large' }

  let text: string
  let handle: FileHandle | undefined
  try {
    // One handle for both the size check and the read. `stat` then `readFile`
    // reopens the path, and between the two the file can grow — the size that
    // passed the cap is then not the size that gets allocated.
    //
    // Opened non-blocking because `open` on a FIFO waits for a writer, and a
    // `.pawlignore` that is a named pipe would otherwise hang this promise for
    // good, taking the file tree and quick open down with it. O_NONBLOCK is
    // POSIX-only; on Windows it is undefined and the flag falls away.
    handle = await open(path, constants.O_RDONLY | (constants.O_NONBLOCK ?? 0))
    const info = await handle.stat()
    // Regular files only. A pipe or device has no size worth trusting and
    // reading one is how a walk ends up blocked on something that never ends.
    if (!info.isFile()) return { source: absent, rules: [] }
    if (info.size > MAX_IGNORE_BYTES) return { source: tooLarge, rules: [] }

    // One byte past the cap, so a file that grew after the check is detected
    // rather than read: this is the only place an ignore file's own size gets
    // to decide how much memory this process allocates.
    const buffer = Buffer.allocUnsafe(Math.min(info.size, MAX_IGNORE_BYTES) + 1)
    let filled = 0
    while (filled < buffer.length) {
      const { bytesRead } = await handle.read(buffer, filled, buffer.length - filled, filled)
      if (bytesRead === 0) break
      filled += bytesRead
    }
    if (filled > MAX_IGNORE_BYTES) return { source: tooLarge, rules: [] }
    text = buffer.subarray(0, filled).toString('utf8')
  } catch {
    // Absent is the common case, not an error.
    return { source: absent, rules: [] }
  } finally {
    // A handle left open on every read would exhaust the process's descriptors
    // long before the ignore rules ever became the problem.
    await handle?.close().catch(() => {})
  }

  // Parsed line by line rather than through parseIgnoreFile in one go, because
  // an explanation is worthless without the line number it came from.
  const rules: TaggedRule[] = []
  const lines = text.split(/\r?\n/)
  for (let i = 0; i < lines.length; i++) {
    const [rule] = parseIgnoreFile(lines[i])
    if (rule) rules.push({ rule, file, line: i + 1 })
  }

  return {
    source: { file, path, present: true, ruleCount: rules.length, skipped: null },
    rules,
  }
}

/** Read and compile a project's ignore files. Uncached — see `ignoreFor`. */
export async function loadProjectIgnore(
  root: string,
  options: IgnoreOptions = {},
): Promise<ProjectIgnore> {
  const resolved = resolve(root)
  const files =
    options.includeGitignore === false ? [PAWLIGNORE_FILE] : [...IGNORE_FILE_ORDER]

  const loaded = await Promise.all(files.map((file) => readIgnoreFile(resolved, file)))
  // Concatenated in file order — the whole point of the ordering is that a
  // later file's negation beats an earlier file's exclusion.
  const rules = loaded.flatMap((entry) => entry.rules)

  return {
    root: resolved,
    matches: createIgnoreMatcher(rules.map((tagged) => tagged.rule)),
    rules,
    sources: loaded.map((entry) => entry.source),
  }
}

/* ---------------------------------------------------------------- cache -- */

interface CacheEntry {
  ignore: ProjectIgnore
  /** mtime + size of every ignore file; an edit changes it. */
  stamp: string
}

/**
 * Compiled rule sets kept at once, evicted least-recently-used.
 *
 * A window that has opened a hundred projects should not still be holding a
 * hundred compiled regex sets, and the IPC guard that decides which roots are
 * legal is optional — an unbounded map keyed by caller-supplied paths is a
 * memory leak with a remote trigger.
 */
export const MAX_CACHED_PROJECTS = 64

/**
 * Keyed by root *and* option, because the two variants compile different rules.
 * A single slot per root meant a caller asking for `.pawlignore` alone and one
 * asking for the merged list evicted each other on every call.
 */
function cacheKey(root: string, includeGitignore: boolean): string {
  return `${includeGitignore ? 'g' : '-'}:${root}`
}

const cache = new Map<string, CacheEntry>()

/** Loads in progress, so concurrent callers share one compile. */
const inFlight = new Map<string, Promise<ProjectIgnore>>()

async function ignoreStamp(root: string, files: readonly string[]): Promise<string> {
  const parts = await Promise.all(
    files.map(async (file) => {
      try {
        const info = await stat(join(root, file))
        return `${file}:${info.mtimeMs}:${info.size}`
      } catch {
        // Distinct from any real stamp, so creating the file invalidates too.
        return `${file}:-`
      }
    }),
  )
  return parts.join('|')
}

/**
 * The shared entry point. Compiles once per project and recompiles only when
 * an ignore file's mtime or size changes, so the tree can call it on every
 * directory expand and quick open on every enumeration.
 */
export async function ignoreFor(root: string, options: IgnoreOptions = {}): Promise<ProjectIgnore> {
  const resolved = resolve(root)
  const includeGitignore = options.includeGitignore !== false
  const files = includeGitignore ? IGNORE_FILE_ORDER : [PAWLIGNORE_FILE]
  const stamp = await ignoreStamp(resolved, files)
  const key = cacheKey(resolved, includeGitignore)

  const cached = cache.get(key)
  if (cached && cached.stamp === stamp) {
    // Re-insert to mark it as recently used: a Map iterates in insertion order,
    // which is what makes the eviction below evict the right entry.
    cache.delete(key)
    cache.set(key, cached)
    return cached.ignore
  }

  // A tree expanding several directories at once used to start one full read
  // and compile per call. Sharing is keyed by the stamp as well, so an edit
  // mid-flight starts a fresh load instead of joining the stale one.
  const flightKey = `${key}|${stamp}`
  const pending = inFlight.get(flightKey)
  if (pending) return pending

  const load = loadProjectIgnore(resolved, options)
    .then((ignore) => {
      cache.set(key, { ignore, stamp })
      while (cache.size > MAX_CACHED_PROJECTS) {
        const oldest = cache.keys().next()
        if (oldest.done) break
        cache.delete(oldest.value)
      }
      return ignore
    })
    .finally(() => {
      inFlight.delete(flightKey)
    })

  inFlight.set(flightKey, load)
  return load
}

/** Drop compiled rules. Call after writing an ignore file from inside the app. */
export function invalidateIgnoreCache(root?: string): void {
  if (root === undefined) {
    cache.clear()
    return
  }
  // Both variants: dropping only the merged one left a stale `.pawlignore`-only
  // matcher behind for whichever consumer asked for that shape.
  const resolved = resolve(root)
  cache.delete(cacheKey(resolved, true))
  cache.delete(cacheKey(resolved, false))
}

/* ------------------------------------------------------------- explain -- */

export interface IgnoreExplanation {
  relPath: string
  ignored: boolean
  /** The rule that settled it, or null when nothing matched. */
  rule: { source: string; file: string; line: number; negated: boolean } | null
  /**
   * Set when an ancestor directory is what is really excluded. Git cannot
   * re-include a file whose parent is ignored, and this is the only way to
   * explain why a `!` rule the user just wrote had no effect.
   */
  viaAncestor: string | null
  /** `node_modules` and `.git` are hidden by the app, not by any rule. */
  alwaysIgnored: boolean
}

/**
 * Which rule decided a path, mirroring `createIgnoreMatcher`'s walk.
 *
 * Kept in step with that matcher by test, not by hope: `explain().ignored`
 * is asserted to equal `matches()` across the whole case table.
 */
export function explainPath(
  ignore: ProjectIgnore,
  relPath: string,
  isDir: boolean,
): IgnoreExplanation {
  const base: IgnoreExplanation = {
    relPath,
    ignored: false,
    rule: null,
    viaAncestor: null,
    alwaysIgnored: false,
  }

  const segments = relPath.split('/').filter((segment) => segment !== '')
  if (segments.length === 0) return base
  if (segments.some((segment) => isAlwaysIgnored(segment))) {
    return { ...base, ignored: true, alwaysIgnored: true }
  }

  for (let i = 0; i < segments.length; i++) {
    const last = i === segments.length - 1
    const prefix = segments.slice(0, i + 1).join('/')
    // Everything above the final segment is a directory by definition.
    const asDir = last ? isDir : true

    let ignored = false
    let deciding: TaggedRule | null = null
    for (const tagged of ignore.rules) {
      if (tagged.rule.dirOnly && !asDir) continue
      if (tagged.rule.re.test(prefix)) {
        ignored = !tagged.rule.negated
        deciding = tagged
      }
    }

    const rule = deciding
      ? {
          source: deciding.rule.source,
          file: deciding.file,
          line: deciding.line,
          negated: deciding.rule.negated,
        }
      : null

    if (last) return { ...base, ignored, rule }
    if (ignored) return { ...base, ignored: true, rule, viaAncestor: prefix }
  }

  return base
}

/* ------------------------------------------------------------- consumers -- */

export interface WalkFilters {
  /** True when a directory should not be descended into. */
  skipDir(relDir: string): boolean
  /** True when a file belongs in the results. */
  keepFile(relPath: string): boolean
}

/**
 * The shape a directory walk wants. `file-search.ts` decides per directory
 * whether to queue it and per file whether to keep it, and calling `matches`
 * with the right `isDir` at each point is easy to get backwards.
 */
export function createWalkFilters(ignore: ProjectIgnore): WalkFilters {
  return {
    skipDir: (relDir) => relDir !== '' && ignore.matches(relDir, true),
    keepFile: (relPath) => !ignore.matches(relPath, false),
  }
}

/**
 * Drop ignored paths from a list of files, e.g. the output of `git ls-files`.
 *
 * Used for the git fast path in quick open: git already applied `.gitignore`,
 * but it has never heard of `.pawlignore`, so tracked files matching a
 * `.pawlignore` rule come back and have to be filtered here.
 */
export async function filterIgnoredFiles(
  root: string,
  files: readonly string[],
  options: IgnoreOptions = {},
): Promise<string[]> {
  const ignore = await ignoreFor(root, options)
  return files.filter((file) => !ignore.matches(file, false))
}

/* ------------------------------------------------------------------ ipc -- */

export interface RegisterIgnoreOptions {
  /**
   * Gate on which roots may be read, as `registerSearchIpc` takes. Without it
   * a compromised renderer could read any `.gitignore` on the disk to probe
   * for paths.
   */
  isAllowedRoot?(root: string): boolean
}

function requireString(value: unknown, label: string): string {
  if (typeof value !== 'string') throw new TypeError(`${label} must be a string`)
  return value
}

export interface IgnoreOverview {
  root: string
  sources: IgnoreSource[]
  ruleCount: number
}

/**
 * Wire the ignore channels. Call once from `registerIpc()`:
 * `registerPawlignoreIpc(ipcMain, { isAllowedRoot })`.
 *
 * Channels:
 * - `pawlignore:overview` (root) → {@link IgnoreOverview}
 * - `pawlignore:explain` (root, relPath, isDir) → {@link IgnoreExplanation}
 * - `pawlignore:filter` (root, paths) → kept paths
 * - `pawlignore:invalidate` (root?) → void
 */
export function registerPawlignoreIpc(
  ipcMain: IpcMain,
  options: RegisterIgnoreOptions = {},
): void {
  const guard = (root: string): string => {
    const resolved = resolve(root)
    if (options.isAllowedRoot && !options.isAllowedRoot(resolved)) {
      throw new Error('that folder is not an open project')
    }
    return resolved
  }

  ipcMain.handle(
    'pawlignore:overview',
    async (_e: IpcMainInvokeEvent, root: unknown): Promise<IgnoreOverview> => {
      const ignore = await ignoreFor(guard(requireString(root, 'root')))
      return { root: ignore.root, sources: ignore.sources, ruleCount: ignore.rules.length }
    },
  )

  ipcMain.handle(
    'pawlignore:explain',
    async (_e: IpcMainInvokeEvent, root: unknown, relPath: unknown, isDir: unknown) => {
      const ignore = await ignoreFor(guard(requireString(root, 'root')))
      return explainPath(ignore, requireString(relPath, 'relPath'), isDir === true)
    },
  )

  ipcMain.handle(
    'pawlignore:filter',
    async (_e: IpcMainInvokeEvent, root: unknown, paths: unknown): Promise<string[]> => {
      if (!Array.isArray(paths)) throw new TypeError('paths must be an array')
      const files = paths.filter((entry): entry is string => typeof entry === 'string')
      return filterIgnoredFiles(guard(requireString(root, 'root')), files)
    },
  )

  ipcMain.handle('pawlignore:invalidate', (_e: IpcMainInvokeEvent, root: unknown) => {
    invalidateIgnoreCache(typeof root === 'string' ? root : undefined)
  })
}

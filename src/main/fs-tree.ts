import { lstat, readdir, readFile, realpath, stat } from 'node:fs/promises'
import { isAbsolute, join, relative, resolve, sep } from 'node:path'
import type { IpcMain, IpcMainInvokeEvent } from 'electron'

/* ---------------------------------------------------------------- types -- */

/** One row of a directory listing. Never recursive — the tree loads a level at a time. */
export interface FsEntry {
  name: string
  /** POSIX-separated path relative to the project root. '' is the root itself. */
  relPath: string
  kind: 'dir' | 'file'
  symlink: boolean
  /**
   * We refuse to open this entry: a link that leaves the project root or points
   * back into its own ancestry, a broken link, or a pipe/socket/device.
   */
  blocked: boolean
}

export interface DirListing {
  relPath: string
  entries: FsEntry[]
  /** More than MAX_ENTRIES children exist; the rest were dropped. */
  truncated: boolean
}

export interface ListOptions {
  /** Include entries an ignore file would hide. node_modules/.git stay hidden. */
  showIgnored?: boolean
}

export type FileRead =
  | { kind: 'text'; relPath: string; text: string; bytes: number; lines: number }
  | { kind: 'binary'; relPath: string; bytes: number }
  | { kind: 'too-large'; relPath: string; bytes: number; limit: number }

/** Above this the viewer refuses rather than freezing the renderer on a blob. */
export const MAX_FILE_BYTES = 2 * 1024 * 1024

/** A generated folder can hold hundreds of thousands of files; the tree cannot. */
export const MAX_ENTRIES = 2000

/** Hidden whatever the ignore files say — never worth the IO or the noise. */
const ALWAYS_IGNORED = new Set(['node_modules', '.git'])

/** Not overridable by an ignore rule, a negation, or the showIgnored option. */
export function isAlwaysIgnored(name: string): boolean {
  return ALWAYS_IGNORED.has(name)
}

const IGNORE_FILES = ['.gitignore', '.deckignore']

const BINARY_SNIFF_BYTES = 8192

/* ------------------------------------------------------- ignore matcher -- */

export interface IgnoreRule {
  /** The original line, kept so a surprising match can be traced back. */
  source: string
  negated: boolean
  dirOnly: boolean
  re: RegExp
}

export type IgnoreMatcher = (relPath: string, isDir: boolean) => boolean

function escapeLiteral(ch: string): string {
  return /[.*+?^${}()|[\]\\/]/.test(ch) ? `\\${ch}` : ch
}

/** Index of the `]` closing the class opened at `start`, or -1 if unterminated. */
function findClassEnd(pattern: string, start: number): number {
  let i = start + 1
  if (pattern[i] === '!' || pattern[i] === '^') i++
  if (pattern[i] === ']') i++ // a `]` in first position is a literal
  for (; i < pattern.length; i++) {
    if (pattern[i] === '\\') i++
    else if (pattern[i] === ']') return i
  }
  return -1
}

function compileClass(body: string): string {
  let out = '['
  let i = 0
  if (body[0] === '!' || body[0] === '^') {
    out += '^'
    i = 1
  }
  for (; i < body.length; i++) {
    const ch = body[i]
    if (ch === '\\') {
      out += `\\${body[++i] ?? '\\'}`
      continue
    }
    out += ch === ']' || ch === '^' ? `\\${ch}` : ch
  }
  // Wildcards never cross a path separator, so neither may a character class.
  return `(?!/)${out}]`
}

function patternToRegExp(pattern: string, anchored: boolean): RegExp {
  // Unanchored patterns match a whole segment at any depth, which is what
  // `(?:^|/)` buys: `build` hits `build` and `src/build` but not `mybuild`.
  let out = anchored ? '^' : '(?:^|/)'
  let i = 0

  while (i < pattern.length) {
    const ch = pattern[i]

    if (ch === '\\') {
      const next = pattern[i + 1]
      out += next === undefined ? '\\\\' : escapeLiteral(next)
      i += 2
      continue
    }

    if (ch === '*') {
      if (pattern[i + 1] === '*') {
        let j = i + 2
        while (pattern[j] === '*') j++
        if (pattern[j] === '/') {
          // `a/**/b` also matches `a/b`, per gitignore.
          out += '(?:.*/)?'
          i = j + 1
        } else {
          out += '.*'
          i = j
        }
        continue
      }
      out += '[^/]*'
      i++
      continue
    }

    if (ch === '?') {
      out += '[^/]'
      i++
      continue
    }

    if (ch === '[') {
      const end = findClassEnd(pattern, i)
      if (end === -1) {
        out += '\\['
        i++
        continue
      }
      out += compileClass(pattern.slice(i + 1, end))
      i = end + 1
      continue
    }

    out += escapeLiteral(ch)
    i++
  }

  return new RegExp(`${out}$`)
}

/** Compile one .gitignore line. Returns null for blanks and comments. */
export function compileIgnorePattern(line: string): IgnoreRule | null {
  // Trailing whitespace is insignificant unless escaped.
  let pattern = line.replace(/(?<!\\)\s+$/, '')
  if (pattern === '' || pattern.startsWith('#')) return null

  let negated = false
  if (pattern.startsWith('!')) {
    negated = true
    pattern = pattern.slice(1)
  } else if (pattern.startsWith('\\#') || pattern.startsWith('\\!')) {
    pattern = pattern.slice(1)
  }

  let dirOnly = false
  if (pattern.endsWith('/')) {
    dirOnly = true
    pattern = pattern.slice(0, -1)
  }
  if (pattern === '') return null

  // A slash anywhere else pins the pattern to the root of the ignore file.
  const anchored = pattern.includes('/')
  if (pattern.startsWith('/')) pattern = pattern.slice(1)
  if (pattern === '') return null

  return { source: line, negated, dirOnly, re: patternToRegExp(pattern, anchored) }
}

export function parseIgnoreFile(text: string): IgnoreRule[] {
  const rules: IgnoreRule[] = []
  for (const line of text.split(/\r?\n/)) {
    const rule = compileIgnorePattern(line)
    if (rule) rules.push(rule)
  }
  return rules
}

/** Last matching rule wins, exactly as git resolves competing patterns. */
function evaluate(rules: IgnoreRule[], path: string, isDir: boolean): boolean {
  let ignored = false
  for (const rule of rules) {
    if (rule.dirOnly && !isDir) continue
    if (rule.re.test(path)) ignored = !rule.negated
  }
  return ignored
}

export function createIgnoreMatcher(rules: IgnoreRule[]): IgnoreMatcher {
  return (relPath, isDir) => {
    const segments = relPath.split('/').filter((s) => s !== '')
    if (segments.length === 0) return false
    if (segments.some((s) => ALWAYS_IGNORED.has(s))) return true

    for (let i = 0; i < segments.length; i++) {
      const last = i === segments.length - 1
      const hit = evaluate(rules, segments.slice(0, i + 1).join('/'), last ? isDir : true)
      if (last) return hit
      // Nothing under an excluded directory can be re-included by a later
      // negation, so an ignored ancestor settles it without reading deeper.
      if (hit) return true
    }
    return false
  }
}

/* ------------------------------------------------------ traversal guard -- */

export class PathEscapeError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'PathEscapeError'
  }
}

/** True when `target` is `root` itself or lives somewhere beneath it. */
export function isWithinRoot(root: string, target: string): boolean {
  const rel = relative(resolve(root), resolve(target))
  if (rel === '') return true
  return rel !== '..' && !rel.startsWith(`..${sep}`) && !isAbsolute(rel)
}

/**
 * Resolve a renderer-supplied relative path against the project root, or throw.
 * The renderer is not trusted: `../../.ssh/id_rsa` and absolute paths are how a
 * compromised page would read the whole disk through our IPC.
 */
export function safeJoin(root: string, relPath: string): string {
  if (relPath.includes('\0')) throw new PathEscapeError('path contains a null byte')
  if (isAbsolute(relPath)) {
    throw new PathEscapeError(`expected a path relative to the project root, got ${relPath}`)
  }
  const abs = resolve(root, relPath)
  if (!isWithinRoot(root, abs)) {
    throw new PathEscapeError(`refusing to read outside the project root: ${relPath}`)
  }
  return abs
}

/**
 * A symlinked directory that resolves to itself or to one of its own ancestors
 * expands forever — `ln -s .. loop` is enough to hang a naive tree.
 */
export function createsLoop(containerRealPath: string, targetRealPath: string): boolean {
  return isWithinRoot(targetRealPath, containerRealPath)
}

/* ------------------------------------------------------- ignore loading -- */

interface IgnoreCacheEntry {
  matcher: IgnoreMatcher
  stamp: string
}

const ignoreCache = new Map<string, IgnoreCacheEntry>()

/** mtime + size of every ignore file, so an edit invalidates the cache. */
async function ignoreStamp(root: string): Promise<string> {
  const parts = await Promise.all(
    IGNORE_FILES.map(async (name) => {
      try {
        const info = await stat(join(root, name))
        return `${name}:${info.mtimeMs}:${info.size}`
      } catch {
        return `${name}:-`
      }
    }),
  )
  return parts.join('|')
}

/** Root-level ignore files only — nested .gitignore files are not consulted. */
async function ignoreMatcherFor(root: string): Promise<IgnoreMatcher> {
  const stamp = await ignoreStamp(root)
  const cached = ignoreCache.get(root)
  if (cached && cached.stamp === stamp) return cached.matcher

  const rules: IgnoreRule[] = []
  for (const name of IGNORE_FILES) {
    try {
      rules.push(...parseIgnoreFile(await readFile(join(root, name), 'utf8')))
    } catch {
      /* absent is the common case */
    }
  }

  const matcher = createIgnoreMatcher(rules)
  ignoreCache.set(root, { matcher, stamp })
  return matcher
}

/* ---------------------------------------------------------- directories -- */

/** Directories first, then natural-order names so file2 sorts before file10. */
export function compareEntries(a: FsEntry, b: FsEntry): number {
  if (a.kind !== b.kind) return a.kind === 'dir' ? -1 : 1
  return a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: 'base' })
}

/** Read a single directory level. Cheap enough to call on every expand. */
export async function listDirectory(
  root: string,
  relDir = '',
  options: ListOptions = {},
): Promise<DirListing> {
  const rootReal = await realpath(resolve(root))
  const dirReal = await realpath(safeJoin(rootReal, relDir))
  // The path was inside the root; its resolved target must be too, or a
  // symlink already crossed the fence on an earlier level.
  if (!isWithinRoot(rootReal, dirReal)) {
    throw new PathEscapeError(`refusing to read outside the project root: ${relDir}`)
  }

  const ignores = await ignoreMatcherFor(rootReal)
  const dirents = await readdir(dirReal, { withFileTypes: true })
  const entries: FsEntry[] = []

  for (const dirent of dirents) {
    // Checked before anything else so showIgnored cannot resurrect them.
    if (isAlwaysIgnored(dirent.name)) continue

    const relPath = relDir === '' ? dirent.name : `${relDir}/${dirent.name}`
    const symlink = dirent.isSymbolicLink()
    let kind: 'dir' | 'file' = dirent.isDirectory() ? 'dir' : 'file'
    let blocked = false

    if (symlink) {
      const abs = join(dirReal, dirent.name)
      try {
        const targetReal = await realpath(abs)
        kind = (await stat(abs)).isDirectory() ? 'dir' : 'file'
        blocked =
          !isWithinRoot(rootReal, targetReal) ||
          (kind === 'dir' && createsLoop(dirReal, targetReal))
      } catch {
        // Broken link: show it, but never try to open it.
        kind = 'file'
        blocked = true
      }
    } else if (!dirent.isDirectory() && !dirent.isFile()) {
      // Sockets, FIFOs and devices list fine but must never be read.
      blocked = true
    }

    if (!options.showIgnored && ignores(relPath, kind === 'dir')) continue
    entries.push({ name: dirent.name, relPath, kind, symlink, blocked })
  }

  entries.sort(compareEntries)
  const truncated = entries.length > MAX_ENTRIES
  if (truncated) entries.length = MAX_ENTRIES

  return { relPath: relDir, entries, truncated }
}

/* ---------------------------------------------------------------- files -- */

/** A NUL in the first few KB is the same heuristic git uses to call a file binary. */
export function looksBinary(buf: Uint8Array): boolean {
  const end = Math.min(buf.length, BINARY_SNIFF_BYTES)
  for (let i = 0; i < end; i++) {
    if (buf[i] === 0) return true
  }
  return false
}

/** Lines as an editor counts them: a trailing newline ends the last one. */
export function countLines(text: string): number {
  if (text === '') return 0
  let lines = 1
  for (let i = 0; i < text.length; i++) {
    if (text.charCodeAt(i) === 10) lines++
  }
  return text.endsWith('\n') ? lines - 1 : lines
}

export async function readTextFile(root: string, relPath: string): Promise<FileRead> {
  const rootReal = await realpath(resolve(root))
  const abs = await realpath(safeJoin(rootReal, relPath))
  if (!isWithinRoot(rootReal, abs)) {
    throw new PathEscapeError(`refusing to read outside the project root: ${relPath}`)
  }

  const info = await lstat(abs)
  // Reading a FIFO or a character device blocks until something writes to it,
  // which would wedge the IPC handler for good.
  if (!info.isFile()) throw new Error(`not a readable file: ${relPath}`)

  // Size is checked before a single byte is read, so a huge file is refused
  // instantly instead of stalling the UI while it loads.
  if (info.size > MAX_FILE_BYTES) {
    return { kind: 'too-large', relPath, bytes: info.size, limit: MAX_FILE_BYTES }
  }

  const buf = await readFile(abs)
  if (looksBinary(buf)) return { kind: 'binary', relPath, bytes: buf.byteLength }

  const text = buf.toString('utf8')
  return { kind: 'text', relPath, text, bytes: buf.byteLength, lines: countLines(text) }
}

/* ------------------------------------------------------------------ ipc -- */

function requireString(value: unknown, label: string): string {
  if (typeof value !== 'string') throw new TypeError(`${label} must be a string`)
  return value
}

/**
 * Wire the file-tree channels into the main process. Call once, from
 * `registerIpc()`: `registerFsIpc(ipcMain)`.
 *
 * Channels:
 * - `fs:list` (root, relDir, options?) → {@link DirListing}
 * - `fs:read` (root, relPath) → {@link FileRead}
 *
 * Both reject when the path would leave `root`; the renderer shows the message.
 */
export function registerFsIpc(ipcMain: IpcMain): void {
  ipcMain.handle(
    'fs:list',
    (_e: IpcMainInvokeEvent, root: unknown, relDir: unknown, options: unknown) => {
      const showIgnored =
        typeof options === 'object' &&
        options !== null &&
        (options as ListOptions).showIgnored === true
      return listDirectory(requireString(root, 'root'), requireString(relDir ?? '', 'relDir'), {
        showIgnored,
      })
    },
  )

  ipcMain.handle('fs:read', (_e: IpcMainInvokeEvent, root: unknown, relPath: unknown) =>
    readTextFile(requireString(root, 'root'), requireString(relPath, 'relPath')),
  )
}

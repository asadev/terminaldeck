import { execFile } from 'node:child_process'
import { stat } from 'node:fs/promises'
import { isAbsolute, join, relative, resolve, sep } from 'node:path'
import { promisify } from 'node:util'
import type { IpcMain, WebContents } from 'electron'
import { loginPath } from './providers'

const run = promisify(execFile)

/* ------------------------------------------------------------------ types -- */

/** Which of the four lists in the panel an entry belongs to. */
export type GitFileGroup = 'staged' | 'unstaged' | 'untracked' | 'conflicted'

export type GitChangeKind =
  | 'added'
  | 'modified'
  | 'deleted'
  | 'renamed'
  | 'copied'
  | 'typechange'
  | 'untracked'
  | 'conflicted'
  | 'unknown'

export interface GitFile {
  /**
   * Path relative to the repository root — porcelain formats always report
   * root-relative paths, never paths relative to the invoking directory.
   */
  path: string
  /** Previous path, set only on the staged side of a rename or copy. */
  origPath: string | null
  group: GitFileGroup
  /** The letter git prints: M A D R C T ? — or the two-letter XY for conflicts. */
  code: string
  kind: GitChangeKind
  /** Rename/copy similarity percentage, when git reported one. */
  score: number | null
  /** Null until a numstat pass fills it in; untracked entries stay null. */
  insertions: number | null
  deletions: number | null
  binary: boolean
}

export interface GitBranch {
  /** Null when HEAD is detached. */
  name: string | null
  detached: boolean
  /** Full commit oid — null on an unborn branch. Truncate for display. */
  oid: string | null
  upstream: string | null
  ahead: number
  behind: number
}

export interface GitRepoStatus {
  repo: true
  cwd: string
  /** Absolute path of the repository root, which may sit above `cwd`. */
  root: string
  branch: GitBranch
  staged: GitFile[]
  unstaged: GitFile[]
  untracked: GitFile[]
  conflicted: GitFile[]
  clean: boolean
}

export type GitUnavailableReason = 'not-a-repo' | 'git-missing' | 'no-such-folder' | 'error'

export interface GitNotRepo {
  repo: false
  cwd: string
  reason: GitUnavailableReason
  message: string
}

/**
 * Discriminated on `repo`, so a caller cannot read `branch` off a folder that
 * has no repository — the "not a repo" case is a value, never a thrown error.
 */
export type GitStatusResult = GitRepoStatus | GitNotRepo

export interface ParsedStatus {
  branch: GitBranch
  staged: GitFile[]
  unstaged: GitFile[]
  untracked: GitFile[]
  conflicted: GitFile[]
}

export interface GitDiffStat {
  path: string
  origPath: string | null
  insertions: number
  deletions: number
  binary: boolean
}

export interface DiffOptions {
  /** Diff the index against HEAD instead of the working tree against the index. */
  staged?: boolean
  /** The file is untracked, so it has to be diffed against /dev/null. */
  untracked?: boolean
}

/* ----------------------------------------------------------------- parsing -- */

const KIND_BY_CODE: Record<string, GitChangeKind> = {
  A: 'added',
  M: 'modified',
  D: 'deleted',
  R: 'renamed',
  C: 'copied',
  T: 'typechange',
  U: 'conflicted',
  '?': 'untracked',
}

function emptyBranch(): GitBranch {
  return { name: null, detached: false, oid: null, upstream: null, ahead: 0, behind: 0 }
}

function makeFile(
  path: string,
  group: GitFileGroup,
  code: string,
  origPath: string | null = null,
  score: number | null = null,
): GitFile {
  return {
    path,
    origPath,
    group,
    code,
    kind: group === 'conflicted' ? 'conflicted' : (KIND_BY_CODE[code] ?? 'unknown'),
    score,
    insertions: null,
    deletions: null,
    binary: false,
  }
}

function applyHeader(record: string, branch: GitBranch): void {
  const parts = record.split(' ')
  const value = parts.slice(2).join(' ')
  switch (parts[1]) {
    case 'branch.oid':
      branch.oid = value === '(initial)' ? null : value
      break
    case 'branch.head':
      branch.detached = value === '(detached)'
      branch.name = branch.detached ? null : value
      break
    case 'branch.upstream':
      branch.upstream = value
      break
    case 'branch.ab': {
      const match = /^\+(\d+) -(\d+)$/.exec(value)
      if (match) {
        branch.ahead = Number(match[1])
        branch.behind = Number(match[2])
      }
      break
    }
    default:
      break
  }
}

/**
 * Parse `git status --porcelain=v2 --branch -z`.
 *
 * v2 is used rather than v1 because v1 is ambiguous: it pads status letters
 * with spaces that are indistinguishable from a leading space in a filename,
 * and it renders renames as `old -> new` inside a single field, which breaks
 * on any path containing " -> ". v2 gives one record per entry with fixed
 * leading fields, and `-z` removes the C-quoting of odd filenames entirely.
 *
 * Pure and synchronous — no git process needed to test it.
 */
export function parsePorcelainV2(output: string): ParsedStatus {
  const records = output.split('\0')
  const branch = emptyBranch()
  const staged: GitFile[] = []
  const unstaged: GitFile[] = []
  const untracked: GitFile[] = []
  const conflicted: GitFile[] = []

  for (let i = 0; i < records.length; i++) {
    const record = records[i]
    if (!record) continue

    const tag = record[0]

    if (tag === '#') {
      applyHeader(record, branch)
      continue
    }
    if (tag === '?') {
      untracked.push(makeFile(record.slice(2), 'untracked', '?'))
      continue
    }
    // `!` entries only appear with --ignored, which this module never asks for.
    if (tag === '!') continue

    const parts = record.split(' ')
    const xy = parts[1] ?? '..'
    const x = xy[0] ?? '.'
    const y = xy[1] ?? '.'

    if (tag === 'u') {
      // Unmerged entries carry three extra mode and three extra oid fields.
      // The whole XY pair is kept: DU and UD mean very different things.
      conflicted.push(makeFile(parts.slice(10).join(' '), 'conflicted', xy))
      continue
    }

    if (tag === '1') {
      const path = parts.slice(8).join(' ')
      // A file can be both staged and dirty (XY = "MM"), in which case it
      // belongs in both lists — same as what `git status` prints.
      if (x !== '.') staged.push(makeFile(path, 'staged', x))
      if (y !== '.') unstaged.push(makeFile(path, 'unstaged', y))
      continue
    }

    if (tag === '2') {
      // Under -z the original path is its own NUL-separated record rather than
      // a tab-separated suffix, so it is consumed from the stream here.
      const origPath = records[i + 1] ?? ''
      i += 1

      const score = Number.parseInt((parts[8] ?? '').slice(1), 10)
      const path = parts.slice(9).join(' ')
      // The rename lives in the index; the working-tree side of an "RM" is
      // just a modification of the new path, so it carries no origPath.
      if (x !== '.') {
        staged.push(makeFile(path, 'staged', x, origPath, Number.isNaN(score) ? null : score))
      }
      if (y !== '.') unstaged.push(makeFile(path, 'unstaged', y))
    }
  }

  return { branch, staged, unstaged, untracked, conflicted }
}

/**
 * Parse `git diff --numstat -z`.
 *
 * Ordinary entries are `<added>\t<deleted>\t<path>` in one record. Renames
 * leave the path field empty and emit the old and new paths as the two
 * following records. Binary files report `-` for both counts.
 */
export function parseNumstat(output: string): GitDiffStat[] {
  const records = output.split('\0')
  const stats: GitDiffStat[] = []

  for (let i = 0; i < records.length; i++) {
    const record = records[i]
    if (!record) continue

    const fields = record.split('\t')
    if (fields.length < 3) continue

    const added = fields[0] ?? ''
    const deleted = fields[1] ?? ''
    // Rejoined because -z paths are literal and may themselves contain a tab.
    let path = fields.slice(2).join('\t')
    let origPath: string | null = null

    if (path === '') {
      origPath = records[i + 1] ?? ''
      path = records[i + 2] ?? ''
      i += 2
    }

    const binary = added === '-' || deleted === '-'
    stats.push({
      path,
      origPath,
      insertions: binary ? 0 : (Number.parseInt(added, 10) || 0),
      deletions: binary ? 0 : (Number.parseInt(deleted, 10) || 0),
      binary,
    })
  }

  return stats
}

/** Fold numstat counts into the matching status entries, in place. */
export function applyStats(files: GitFile[], stats: GitDiffStat[]): void {
  const byPath = new Map(stats.map((s) => [s.path, s]))
  for (const file of files) {
    const found = byPath.get(file.path)
    if (!found) continue
    file.insertions = found.insertions
    file.deletions = found.deletions
    file.binary = found.binary
  }
}

/* ------------------------------------------------------------- git process -- */

const GIT_TIMEOUT_MS = 8000
/** A status listing in a very large repo comfortably exceeds the 1 MB default. */
const MAX_BUFFER = 16 * 1024 * 1024

interface ExecFailure {
  code?: string | number
  stderr?: string
  stdout?: string
  message?: string
}

async function git(cwd: string, args: string[]): Promise<string> {
  const PATH = await loginPath()
  const { stdout } = await run('git', args, {
    cwd,
    timeout: GIT_TIMEOUT_MS,
    maxBuffer: MAX_BUFFER,
    windowsHide: true,
    env: {
      ...process.env,
      PATH,
      // Never take index.lock for a read: this module polls in the background
      // and must not lose a race with the agent's own git commands.
      GIT_OPTIONAL_LOCKS: '0',
      // Porcelain output is stable, but error text is localised — pin it so
      // the "not a repository" check below works in any locale.
      LC_ALL: 'C',
    },
  })
  return stdout
}

function notRepo(cwd: string, reason: GitUnavailableReason, message: string): GitNotRepo {
  return { repo: false, cwd, reason, message }
}

function classifyFailure(cwd: string, error: unknown): GitNotRepo {
  const failure = error as ExecFailure
  const text = (failure?.stderr || failure?.message || '').trim()
  if (failure?.code === 'ENOENT') {
    return notRepo(cwd, 'git-missing', 'git is not installed, or not on the login PATH')
  }
  if (/not a git repository|detected dubious ownership/i.test(text)) {
    return notRepo(cwd, 'not-a-repo', text)
  }
  return notRepo(cwd, 'error', text || 'git failed')
}

/** Absolute path of the `.git` directory, resolving worktrees and submodules. */
export async function findGitDir(cwd: string): Promise<string | null> {
  try {
    return (await git(cwd, ['rev-parse', '--absolute-git-dir'])).trim() || null
  } catch {
    return null
  }
}

/**
 * Full status for one project folder. Never throws: a missing folder, a folder
 * with no repository and a missing git binary all come back as a typed
 * `repo: false` result the UI can render directly.
 */
export async function readGitStatus(cwd: string): Promise<GitStatusResult> {
  if (typeof cwd !== 'string' || !isAbsolute(cwd)) {
    return notRepo(String(cwd), 'no-such-folder', 'Project path must be absolute')
  }

  // Checked up front so that an ENOENT from execFile below can only ever mean
  // "no git binary", never "no such working directory".
  try {
    const info = await stat(cwd)
    if (!info.isDirectory()) return notRepo(cwd, 'no-such-folder', 'Not a folder')
  } catch {
    return notRepo(cwd, 'no-such-folder', 'Folder does not exist')
  }

  let root: string
  try {
    root = (await git(cwd, ['rev-parse', '--show-toplevel'])).trim() || cwd
  } catch (error) {
    return classifyFailure(cwd, error)
  }

  try {
    const [statusOut, worktreeOut, indexOut] = await Promise.all([
      // --untracked-files is left at the default "normal": "all" expands every
      // file inside an untracked folder, which turns a fresh clone with an
      // unignored build directory into tens of thousands of rows.
      git(cwd, ['status', '--porcelain=v2', '--branch', '-z']),
      git(cwd, ['diff', '--numstat', '-z', '--no-ext-diff']),
      git(cwd, ['diff', '--numstat', '-z', '--no-ext-diff', '--cached']),
    ])

    const parsed = parsePorcelainV2(statusOut)
    applyStats(parsed.unstaged, parseNumstat(worktreeOut))
    applyStats(parsed.staged, parseNumstat(indexOut))

    return {
      repo: true,
      cwd,
      root,
      branch: parsed.branch,
      staged: parsed.staged,
      unstaged: parsed.unstaged,
      untracked: parsed.untracked,
      conflicted: parsed.conflicted,
      clean:
        parsed.staged.length === 0 &&
        parsed.unstaged.length === 0 &&
        parsed.untracked.length === 0 &&
        parsed.conflicted.length === 0,
    }
  } catch (error) {
    return classifyFailure(cwd, error)
  }
}

/**
 * Confine a caller-supplied path to the repository and return it in the
 * normalised, root-relative form git expects — or null if it escapes.
 *
 * This is a security boundary, not a tidiness helper. Diff paths arrive over
 * IPC from the renderer, and the untracked branch below shells out to
 * `git diff --no-index`, which is not a repository operation at all: it reads
 * whatever two paths it is handed. Without this check, `../../../../.ssh/id_rsa`
 * or a plain absolute path turns the diff channel into an arbitrary-file read
 * for anything that gets script execution in the renderer.
 */
export function repoRelative(root: string, path: string): string | null {
  if (typeof path !== 'string' || path === '' || path.includes('\0')) return null
  // An absolute path is never something git reported: porcelain output is
  // always root-relative, so this can only be a caller reaching outside.
  if (isAbsolute(path)) return null
  const rel = relative(root, resolve(root, path))
  // '' is the root itself, '..'-prefixed is outside it, and `relative` returns
  // an absolute path when the two sit on different Windows drives.
  if (rel === '' || rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) return null
  return rel
}

/**
 * Unified diff for a single file, as text. Returns '' rather than throwing so
 * a click on a vanished file cannot take the panel down.
 */
export async function readFileDiff(
  cwd: string,
  path: string,
  options: DiffOptions = {},
): Promise<string> {
  if (!isAbsolute(cwd) || path === '') return ''

  let root: string
  try {
    root = (await git(cwd, ['rev-parse', '--show-toplevel'])).trim() || cwd
  } catch {
    return ''
  }

  // Every path git reported is root-relative, so running from the root means
  // no pathspec gymnastics and no ambiguity for files under a subdirectory.
  // --no-ext-diff matters: a user's configured difftool would otherwise try to
  // open a GUI from inside the main process and hang the call.
  const safe = repoRelative(root, path)
  if (!safe) return ''

  if (options.untracked) {
    try {
      // --no-index implies --exit-code, so "there is a difference" arrives as a
      // rejection with the diff sitting in stdout.
      return await git(root, [
        'diff',
        '--no-color',
        '--no-ext-diff',
        '--no-index',
        '--',
        '/dev/null',
        safe,
      ])
    } catch (error) {
      const failure = error as ExecFailure
      return typeof failure?.stdout === 'string' ? failure.stdout : ''
    }
  }

  const args = ['diff', '--no-color', '--no-ext-diff']
  if (options.staged) args.push('--cached')
  args.push('--', safe)

  try {
    return await git(root, args)
  } catch {
    return ''
  }
}

/* ---------------------------------------------------------------- watching -- */

/** Channel the main process pushes fresh status on: (cwd, GitStatusResult). */
export const GIT_STATUS_CHANGED = 'git:status-changed'

const POLL_MS = 1000
/**
 * Editing a file in the working tree touches nothing under .git, so the mtime
 * probe alone would never notice an unstaged edit. A cheap poll catches
 * commits, checkouts and staging within a second; this slower full run is the
 * backstop that catches everything else.
 */
const FULL_REFRESH_MS = 4000

interface Watch {
  cwd: string
  target: WebContents
  gitDir: string | null
  timer: NodeJS.Timeout | null
  /** mtimes of .git/HEAD and .git/index, as seen after the last full run. */
  signature: string
  /** Last payload sent, so an unchanged repo produces no IPC traffic. */
  payload: string
  lastFullRun: number
  stopped: boolean
  /**
   * How many mounted panels asked for this (webContents, cwd) pair. The key
   * cannot distinguish two panels showing the same folder in one window, so
   * without a count the first unmount would stop the poller the second is
   * still relying on and freeze it on stale status.
   */
  refs: number
}

const watches = new Map<string, Watch>()
const teardownBound = new Set<number>()

function watchKey(target: WebContents, cwd: string): string {
  return `${target.id}\x00${cwd}`
}

async function signatureOf(gitDir: string | null): Promise<string> {
  if (!gitDir) return ''
  const parts = await Promise.all(
    ['HEAD', 'index'].map(async (name) => {
      try {
        const info = await stat(join(gitDir, name))
        return `${info.mtimeMs}:${info.size}`
      } catch {
        return '-'
      }
    }),
  )
  return parts.join('|')
}

function stopWatch(watch: Watch): void {
  watch.stopped = true
  if (watch.timer) clearTimeout(watch.timer)
  watch.timer = null
}

async function emit(watch: Watch): Promise<void> {
  const result = await readGitStatus(watch.cwd)
  watch.lastFullRun = Date.now()
  if (result.repo && !watch.gitDir) watch.gitDir = await findGitDir(watch.cwd)

  // Re-stat *after* the run: `git status` refreshes the index stat-cache and
  // may rewrite .git/index itself, which would otherwise read as a change on
  // the next tick and pin the poller to a permanent full run.
  watch.signature = await signatureOf(watch.gitDir)

  const payload = JSON.stringify(result)
  if (payload === watch.payload) return
  watch.payload = payload
  if (!watch.target.isDestroyed()) watch.target.send(GIT_STATUS_CHANGED, watch.cwd, result)
}

async function tick(watch: Watch): Promise<void> {
  if (watch.stopped) return
  try {
    if (watch.target.isDestroyed()) {
      stopWatch(watch)
      return
    }
    const signature = await signatureOf(watch.gitDir)
    const due = Date.now() - watch.lastFullRun >= FULL_REFRESH_MS
    if (signature !== watch.signature || due) await emit(watch)
  } catch {
    /* a transient fs or git error just means we try again on the next tick */
  } finally {
    // Re-armed rather than run on an interval, so a slow status on a huge repo
    // cannot stack overlapping git processes.
    if (!watch.stopped) watch.timer = setTimeout(() => void tick(watch), POLL_MS)
  }
}

function bindTeardown(target: WebContents): void {
  const id = target.id
  if (teardownBound.has(id)) return
  teardownBound.add(id)
  target.once('destroyed', () => {
    teardownBound.delete(id)
    for (const [key, watch] of watches) {
      if (watch.target !== target) continue
      stopWatch(watch)
      watches.delete(key)
    }
  })
}

async function startWatch(target: WebContents, cwd: string): Promise<GitStatusResult> {
  const key = watchKey(target, cwd)
  const existing = watches.get(key)
  if (existing && !existing.stopped) {
    // Already polling for this pair — join it rather than tearing down a live
    // poller another panel is reading, and answer with a fresh read.
    existing.refs += 1
    return readGitStatus(cwd)
  }
  if (existing) stopWatch(existing)

  const watch: Watch = {
    cwd,
    target,
    gitDir: null,
    timer: null,
    signature: '',
    payload: '',
    lastFullRun: 0,
    stopped: false,
    refs: 1,
  }
  watches.set(key, watch)
  bindTeardown(target)

  const first = await readGitStatus(cwd)
  watch.gitDir = first.repo ? await findGitDir(cwd) : null
  watch.lastFullRun = Date.now()
  watch.signature = await signatureOf(watch.gitDir)
  // Seeded so the first push only fires once something actually changes.
  watch.payload = JSON.stringify(first)
  // React StrictMode mounts, unmounts and remounts, so an unwatch can land
  // while this first read is still in flight — arming here would leave a timer
  // on a watch nobody holds a reference to any more.
  if (!watch.stopped) watch.timer = setTimeout(() => void tick(watch), POLL_MS)
  return first
}

/** Drop every poller — call on app quit so no timer outlives the window. */
export function stopAllGitWatches(): void {
  for (const watch of watches.values()) stopWatch(watch)
  watches.clear()
  teardownBound.clear()
}

/** Live poller count. Exported so tests can assert the watch bookkeeping. */
export function activeGitWatchCount(): number {
  return watches.size
}

/* --------------------------------------------------------------------- ipc -- */

/** IPC arguments arrive untrusted, so paths are validated rather than assumed. */
function asPath(value: unknown): string | null {
  return typeof value === 'string' && value.length > 0 && isAbsolute(value) ? value : null
}

/**
 * Wire the git channels. One call from the main process:
 *
 *   import { registerGitIpc } from './git'
 *   registerGitIpc(ipcMain)
 *
 * Channels:
 *  - `git:status`  (invoke, cwd)                  → GitStatusResult
 *  - `git:diff`    (invoke, cwd, path, options)   → unified diff text
 *  - `git:watch`   (invoke, cwd)                  → GitStatusResult, starts polling
 *  - `git:unwatch` (send,   cwd)                  → stops polling
 *  - `git:status-changed` (push, cwd, GitStatusResult)
 *
 * Pushes go to the webContents that subscribed, and stop on its own when that
 * webContents is destroyed — a window reload leaves no orphaned timer.
 */
export function registerGitIpc(ipcMain: IpcMain): void {
  ipcMain.handle('git:status', (_event, cwd: unknown): Promise<GitStatusResult> => {
    const path = asPath(cwd)
    return path
      ? readGitStatus(path)
      : Promise.resolve(notRepo(String(cwd), 'no-such-folder', 'Project path must be absolute'))
  })

  ipcMain.handle('git:diff', (_event, cwd: unknown, file: unknown, options: unknown) => {
    const path = asPath(cwd)
    if (!path || typeof file !== 'string') return Promise.resolve('')
    const opts = (typeof options === 'object' && options !== null ? options : {}) as DiffOptions
    return readFileDiff(path, file, { staged: !!opts.staged, untracked: !!opts.untracked })
  })

  ipcMain.handle('git:watch', (event, cwd: unknown): Promise<GitStatusResult> => {
    const path = asPath(cwd)
    return path
      ? startWatch(event.sender, path)
      : Promise.resolve(notRepo(String(cwd), 'no-such-folder', 'Project path must be absolute'))
  })

  ipcMain.on('git:unwatch', (event, cwd: unknown) => {
    const path = asPath(cwd)
    if (!path) return
    const key = watchKey(event.sender, path)
    const watch = watches.get(key)
    if (!watch) return
    watch.refs -= 1
    // Another panel on the same folder is still mounted — keep polling for it.
    if (watch.refs > 0) return
    stopWatch(watch)
    watches.delete(key)
  })
}

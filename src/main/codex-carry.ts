/**
 * Carrying a Codex conversation across an account switch.
 *
 * ## Why Codex is restarted and Claude Code is not
 *
 * Claude Code asks for its login again and again while it runs (see
 * `account-vault/switch-in-place.ts`), so a session can be handed another
 * account's login without being touched. Codex does not. Its `AuthManager`
 * (codex-rs, `login/src/auth/manager.rs`) loads `auth.json` once and says so in
 * as many words — *"External modifications to stored credentials will NOT be
 * observed until `reload()` is called explicitly"* — and the one place it
 * reloads on its own, a 401, reloads only *"if the account id matches the one
 * the current process is running as"*. A different account's file is the one
 * thing it is written to ignore. So a running Codex cannot change account; the
 * switch has to start it again.
 *
 * ## What this file does about the conversation
 *
 * Codex keeps each conversation as one rollout file inside the account's own
 * folder — `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<time>-<thread id>.jsonl`
 * — and `codex resume <thread id>` finds it there by its file name when its
 * index has no row for it (`find_thread_path_by_id_str_in_subdir`, falling back
 * to `find_thread_path_by_id_from_filenames`), then appends to that same file
 * (`open_rollout_for_append`). So the conversation follows the switch when its
 * file is put in the same place under the other account's folder and the new
 * process is started with `resume <thread id>`.
 *
 * **Copied, not linked.** The switch starts the new process before it stops
 * the old one, and Codex's lock against two writers on one conversation lives
 * inside each account's folder (`thread-writer-locks/`), so two accounts' locks
 * cannot see each other. A hard link would let both processes append to one
 * file for a moment; a copy cannot. The cost is anything the old process writes
 * in the seconds before it is stopped, which is the same thing a restart has
 * always cost.
 *
 * Measured against the Codex source, not against a running Codex: the binary
 * on this machine lives in the owner's own Codex folder, which nothing here
 * runs. `switch-resume` falls back to a fresh start if the resume does not take.
 */

import { closeSync, copyFileSync, existsSync, mkdirSync, openSync, readdirSync, readSync, realpathSync, statSync } from 'node:fs'
import { dirname, join, relative } from 'node:path'

/** One Codex conversation, found on disk. */
export interface CodexThread {
  /** The thread id `codex resume` takes. */
  id: string
  /** Its rollout file. */
  file: string
  /** That file's path under `<CODEX_HOME>/sessions`. */
  relative: string
}

const ROLLOUT = /^rollout-(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})-([0-9a-f-]{36})(?:_[0-9a-f-]{36})?\.jsonl$/

/** The start of a file: enough for a session's first line, which carries its instructions. */
function firstLine(file: string, limit = 1024 * 1024): string | null {
  let fd: number | null = null
  try {
    fd = openSync(file, 'r')
    const buffer = Buffer.alloc(limit)
    const read = readSync(fd, buffer, 0, limit, 0)
    const text = buffer.subarray(0, read).toString('utf8')
    const end = text.indexOf('\n')
    return end < 0 ? text : text.slice(0, end)
  } catch {
    return null
  } finally {
    if (fd !== null) closeSync(fd)
  }
}

function sameFolder(a: string, b: string): boolean {
  const real = (path: string): string => {
    try {
      return realpathSync(path)
    } catch {
      return path
    }
  }
  return a === b || real(a) === real(b)
}

/** The UTC days from `since` to `until`, as `YYYY/MM/DD` folder paths. */
function daysBetween(since: number, until: number): string[] {
  const out: string[] = []
  const day = new Date(since - 86_400_000)
  day.setUTCHours(0, 0, 0, 0)
  while (day.getTime() <= until) {
    const y = String(day.getUTCFullYear())
    const m = String(day.getUTCMonth() + 1).padStart(2, '0')
    const d = String(day.getUTCDate()).padStart(2, '0')
    out.push(join(y, m, d))
    day.setUTCDate(day.getUTCDate() + 1)
  }
  return out
}

/**
 * The conversation a running Codex session is in: the one rollout in its
 * account's folder that was started in this session's folder after the session
 * itself started. Null when there is none — nothing has been said yet, so
 * there is nothing to carry — and null when there is more than one, because a
 * guess here would continue somebody else's conversation under this tab.
 */
export function findCodexThread(input: {
  home: string
  cwd: string
  /** When the session started, in ms. */
  startedAt: number
  now?: number
  /** Thread ids other live sessions are known to be in. */
  claimed?: ReadonlySet<string>
}): CodexThread | null {
  const sessions = join(input.home, 'sessions')
  const now = input.now ?? Date.now()
  // Rollout names carry the time to the second, in UTC.
  const earliest = Math.floor(input.startedAt / 1000) * 1000 - 2_000
  const found = new Map<string, { file: string; at: number }>()
  for (const day of daysBetween(input.startedAt, now)) {
    let names: string[]
    try {
      names = readdirSync(join(sessions, day))
    } catch {
      continue
    }
    for (const name of names) {
      const match = ROLLOUT.exec(name)
      if (!match) continue
      const at = Date.UTC(
        Number(match[1]),
        Number(match[2]) - 1,
        Number(match[3]),
        Number(match[4]),
        Number(match[5]),
        Number(match[6]),
      )
      if (at < earliest) continue
      const file = join(sessions, day, name)
      const line = firstLine(file)
      if (line === null) continue
      let meta: { type?: unknown; payload?: { id?: unknown; cwd?: unknown } }
      try {
        meta = JSON.parse(line) as typeof meta
      } catch {
        continue
      }
      if (meta.type !== 'session_meta') continue
      const id = meta.payload?.id
      const cwd = meta.payload?.cwd
      if (typeof id !== 'string' || typeof cwd !== 'string') continue
      if (!sameFolder(cwd, input.cwd)) continue
      if (input.claimed?.has(id)) continue
      const held = found.get(id)
      if (held === undefined || at > held.at) found.set(id, { file, at })
    }
  }
  if (found.size !== 1) return null
  const [[id, { file }]] = [...found]
  return { id, file, relative: relative(sessions, file) }
}

/**
 * Put a conversation where the other account's Codex will find it: the same
 * file, at the same place under its own `sessions/`. Overwrites an older copy
 * left by an earlier switch — the copy being carried is the newest there is,
 * because it is the one the session has been writing to. Answers the path, or
 * null when it could not be put there (the switch then starts fresh).
 */
export function carryCodexThread(thread: CodexThread, targetHome: string): string | null {
  const target = join(targetHome, 'sessions', thread.relative)
  try {
    if (!existsSync(thread.file) || !statSync(thread.file).isFile()) return null
    mkdirSync(dirname(target), { recursive: true, mode: 0o700 })
    copyFileSync(thread.file, target)
    return target
  } catch {
    return null
  }
}

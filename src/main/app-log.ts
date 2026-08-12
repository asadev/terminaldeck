/**
 * The app log — a small rotating file under userData that main-process modules
 * can write to, and the Debug panel can read back.
 *
 * Three properties matter more than features here:
 *
 *  - It cannot grow without bound. A desktop app that runs for weeks writing
 *    into one file is a disk-filling bug waiting to happen, so the file is
 *    capped and rotated, and only one generation is kept by default.
 *  - It cannot throw. Logging sits on paths that must not fail — an exception
 *    out of `logger.error` during teardown would replace a real error with a
 *    confusing one. Every filesystem call here is wrapped, and a broken log is
 *    silently a no-op.
 *  - Nothing leaves the process unredacted. The file itself holds what was
 *    written, but `log:recent` runs every line through `redact` first, because
 *    the Debug panel is read over someone's shoulder and pasted into issues.
 *
 * Writes are synchronous appends. They are small, infrequent, and an async
 * queue would reorder lines relative to the events that produced them —
 * which is the one thing a log must not do.
 */

import { appendFileSync, existsSync, mkdirSync, renameSync, rmSync, statSync, readFileSync } from 'node:fs'
import { basename, join } from 'node:path'
import { app, shell, type IpcMain } from 'electron'
import { BRAND } from '../shared/brand'
import { redactLines } from './redact'

export type LogLevel = 'debug' | 'info' | 'warn' | 'error'

export interface LogEntry {
  at: number
  level: LogLevel
  /** Which module wrote it — `git`, `mcp`, `session`. */
  scope: string
  message: string
  data?: unknown
}

export interface AppLogOptions {
  dir: string
  fileName?: string
  /** Rotate once the file passes this. */
  maxBytes?: number
  /** How many rotated generations to keep. */
  keep?: number
  now?: () => number
}

export interface LogFileInfo {
  name: string
  bytes: number
}

export interface LogStatus {
  dir: string
  file: string
  bytes: number
  files: LogFileInfo[]
  maxBytes: number
  keep: number
}

/** 512 KB per generation, two generations — about 1.5 MB worst case. */
const DEFAULT_MAX_BYTES = 512 * 1024
const DEFAULT_KEEP = 2

/**
 * One line cannot be allowed to be the whole file. Anything longer is almost
 * always a serialised blob that a summary would have served better.
 */
const MAX_LINE = 4000

const LEVEL_WIDTH = 5

function stringify(data: unknown): string {
  if (data === undefined) return ''
  if (typeof data === 'string') return ` ${data}`
  try {
    return ` ${JSON.stringify(data)}`
  } catch {
    // A cycle or a BigInt — worth noting, not worth failing over.
    return ' [unserialisable]'
  }
}

/** `2026-08-12T09:12:33.123Z INFO  [git] status refreshed {"files":3}` */
export function formatLine(entry: LogEntry): string {
  const stamp = new Date(entry.at).toISOString()
  const level = entry.level.toUpperCase().padEnd(LEVEL_WIDTH)
  const scope = entry.scope ? `[${entry.scope}] ` : ''
  const line = `${stamp} ${level} ${scope}${entry.message}${stringify(entry.data)}`.replace(/\r?\n/g, ' ')
  return line.length > MAX_LINE ? `${line.slice(0, MAX_LINE)}… (truncated)` : line
}

export class AppLog {
  readonly dir: string
  readonly file: string
  private readonly fileName: string
  private readonly maxBytes: number
  private readonly keep: number
  private readonly now: () => number
  /** Tracked in memory so a stat is not needed on every write. */
  private bytes = 0
  private broken = false

  constructor(options: AppLogOptions) {
    this.dir = options.dir
    this.fileName = options.fileName ?? `${BRAND.id}.log`
    this.file = join(this.dir, this.fileName)
    this.maxBytes = Math.max(options.maxBytes ?? DEFAULT_MAX_BYTES, 4096)
    this.keep = Math.max(options.keep ?? DEFAULT_KEEP, 0)
    this.now = options.now ?? Date.now
    this.bytes = this.currentSize()
  }

  private currentSize(): number {
    try {
      return statSync(this.file).size
    } catch {
      return 0
    }
  }

  private generation(index: number): string {
    return join(this.dir, `${this.fileName}.${index}`)
  }

  /**
   * Shift generations down and start a new file. Failures are swallowed and
   * the log carries on appending — an oversized log beats a lost one.
   */
  private rotate(): void {
    try {
      if (this.keep === 0) {
        rmSync(this.file, { force: true })
      } else {
        rmSync(this.generation(this.keep), { force: true })
        for (let i = this.keep - 1; i >= 1; i -= 1) {
          if (existsSync(this.generation(i))) renameSync(this.generation(i), this.generation(i + 1))
        }
        if (existsSync(this.file)) renameSync(this.file, this.generation(1))
      }
      this.bytes = 0
    } catch {
      this.bytes = this.currentSize()
    }
  }

  write(level: LogLevel, scope: string, message: string, data?: unknown): void {
    if (this.broken) return
    const line = `${formatLine({ at: this.now(), level, scope, message, data })}\n`
    const size = Buffer.byteLength(line)
    try {
      mkdirSync(this.dir, { recursive: true })
      if (this.bytes + size > this.maxBytes) this.rotate()
      appendFileSync(this.file, line, 'utf8')
      this.bytes += size
    } catch {
      // Read-only volume, a full disk, a sandbox that will not let us write:
      // stop trying rather than throwing on every subsequent call.
      this.broken = true
    }
  }

  debug(scope: string, message: string, data?: unknown): void {
    this.write('debug', scope, message, data)
  }

  info(scope: string, message: string, data?: unknown): void {
    this.write('info', scope, message, data)
  }

  warn(scope: string, message: string, data?: unknown): void {
    this.write('warn', scope, message, data)
  }

  error(scope: string, message: string, data?: unknown): void {
    this.write('error', scope, message, data)
  }

  /**
   * The last `count` lines, oldest first.
   *
   * Walks back through the rotated generations until it has enough. A busy
   * session can rotate twice in a minute, and a tail that only read the live
   * file would show the last few seconds of a problem that started before it —
   * which is exactly the history the reader came for.
   */
  tail(count = 200): string[] {
    // `slice(-n)` is the trap here: `slice(-0)` and `slice(NaN)` both mean "the
    // whole array", so asking for no lines used to return *every* line of every
    // generation, and a negative count dropped the oldest few and returned the
    // rest. The bundle passes this straight through from the renderer, so an
    // out-of-range number turned "200 lines of log" into the entire log.
    const want = Number.isFinite(count) ? Math.floor(count) : 0
    if (want <= 0) return []

    let lines = this.readFileLines(this.file)
    for (let i = 1; i <= this.keep && lines.length < want; i += 1) {
      lines = [...this.readFileLines(this.generation(i)), ...lines]
    }
    return lines.slice(-want)
  }

  private readFileLines(path: string): string[] {
    try {
      return readFileSync(path, 'utf8').split('\n').filter((line) => line.length > 0)
    } catch {
      return []
    }
  }

  status(): LogStatus {
    const files: LogFileInfo[] = []
    const candidates = [this.file, ...Array.from({ length: this.keep }, (_, i) => this.generation(i + 1))]
    for (const path of candidates) {
      try {
        // `basename`, not `slice(dir.length + 1)`: a `dir` given with a trailing
        // separator makes `join` drop it, so the arithmetic ate a character and
        // the live log was reported as `awl.log`.
        files.push({ name: basename(path), bytes: statSync(path).size })
      } catch {
        /* not rotated that far yet */
      }
    }
    return {
      dir: this.dir,
      file: this.file,
      // The live file, not `files[0]` — when the live file is missing the first
      // entry is a rotated generation, and its size would be reported as the
      // current one's.
      bytes: this.currentSize(),
      files,
      maxBytes: this.maxBytes,
      keep: this.keep,
    }
  }

  /** Drop everything. Used by the Debug panel before reproducing a bug. */
  clear(): void {
    try {
      rmSync(this.file, { force: true })
      for (let i = 1; i <= this.keep; i += 1) rmSync(this.generation(i), { force: true })
      this.bytes = 0
      this.broken = false
    } catch {
      /* nothing to do — the next write will find out */
    }
  }
}

export function createAppLog(options: AppLogOptions): AppLog {
  return new AppLog(options)
}

let instance: AppLog | null = null

/**
 * The app's log. Constructed lazily because `app.getPath` is only valid once
 * the app is ready, and this module is imported at the top of main.
 */
export function appLog(): AppLog {
  if (!instance) instance = new AppLog({ dir: join(app.getPath('userData'), 'logs') })
  return instance
}

/** Test seam, and the way a different directory can be forced. */
export function setAppLog(log: AppLog | null): void {
  instance = log
}

/**
 * What modules import. A plain object rather than the class, so callers never
 * hold a reference from before the app was ready.
 */
export const logger = {
  debug: (scope: string, message: string, data?: unknown): void => appLog().debug(scope, message, data),
  info: (scope: string, message: string, data?: unknown): void => appLog().info(scope, message, data),
  warn: (scope: string, message: string, data?: unknown): void => appLog().warn(scope, message, data),
  error: (scope: string, message: string, data?: unknown): void => appLog().error(scope, message, data),
}

export function registerLogIpc(ipcMain: IpcMain): void {
  ipcMain.handle('log:recent', (_event, limit?: number) => {
    const log = appLog()
    const count = Math.min(Math.max(Number(limit) || 200, 1), 2000)
    // Redacted on the way out, not on the way in: the file is as trusted as
    // the rest of userData, but everything the panel shows can be screenshotted.
    return { file: redactLines([log.file])[0], lines: redactLines(log.tail(count)) }
  })

  ipcMain.handle('log:status', () => {
    const status = appLog().status()
    return { ...status, dir: redactLines([status.dir])[0], file: redactLines([status.file])[0] }
  })

  /** Opens the folder in the OS file manager. Returns '' on success. */
  ipcMain.handle('log:open-folder', async () => {
    const log = appLog()
    try {
      mkdirSync(log.dir, { recursive: true })
    } catch {
      /* openPath will report it */
    }
    return shell.openPath(log.dir)
  })

  ipcMain.handle('log:clear', () => {
    appLog().clear()
  })
}

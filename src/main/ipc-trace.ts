import { appendFileSync, mkdirSync, renameSync, rmSync, statSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { app, type IpcMain } from 'electron'

/**
 * Channels that fire on every frame of a resize or scroll. They are excluded by
 * name rather than by an allowlist because an allowlist is what made this file
 * useless the first time: it named the four panels that were broken that week,
 * so the log filled with `browser:bounds` and said nothing about the session
 * and project channels — the two that actually matter — when they went quiet.
 */
const NOISE = ['browser:bounds', 'browser:visible']

/** The setting that turns this on. Off is the default, and the shipped state. */
export const TRACE_SETTING = 'advanced.debugMode'

/**
 * Bytes before the log rolls over. Two generations are kept, so the trace costs
 * at most 8 MB and the previous session's tail survives a restart — which is
 * usually the half you want, because the interesting thing happened before you
 * went looking for it.
 */
export const MAX_TRACE_BYTES = 4 * 1024 * 1024

export function traceFilePath(): string {
  return join(app.getPath('userData'), 'ipc-trace.log')
}

/** The rolled-over generation, kept beside the live one. */
export function previousTraceFilePath(): string {
  return `${traceFilePath()}.1`
}

/**
 * Records every IPC call to a file, except the per-frame noise above — but only
 * while Debug mode is on.
 *
 * ## What this got wrong, and what each part of the fix is for
 *
 * A packaged v0.1.3 shipped a 12 MB `ipc-trace.log` in the user's application
 * support directory, growing at about 1.2 MB an hour, with Debug mode off. It
 * had three separate faults and they need three separate fixes:
 *
 *  1. **It wrote when nobody had asked.** Tracing every IPC call is a debugging
 *     tool; doing it unasked is a disk cost and a privacy surface — IPC
 *     arguments include project paths and search queries. It is now gated on
 *     `advanced.debugMode`, which is off by default.
 *
 *  2. **It never stopped growing.** There was no cap and no rotation, so the
 *     only bound was how long the app stayed open. Now it rolls at
 *     {@link MAX_TRACE_BYTES} and keeps one previous generation.
 *
 *  3. **Nothing told the user it existed.** It was not in Settings → Advanced →
 *     "Where things are kept", so a 12 MB file could not be found, understood
 *     or cleared by the person whose disk it was on. `configPaths()` now lists
 *     it.
 *
 * ## Why the wrapping is unconditional and only the writing is gated
 *
 * This runs during `registerIpc()`, before the handlers exist, because it works
 * by wrapping `ipcMain.on` and `ipcMain.handle` — it can only capture channels
 * registered after it. Gating the *wrapping* on the setting would therefore
 * mean tracing only takes effect after a restart, and a debugging aid you have
 * to relaunch the app to arm is one you reach for after the bug has gone. The
 * wrappers are two closures and a boolean check per call; the cost of leaving
 * them in is not measurable against an IPC round trip.
 *
 * So `enabled()` is consulted per write, and toggling Debug mode starts and
 * stops tracing immediately.
 *
 * `enabled` is passed in rather than read from `settings-extra` here, because
 * `settings-extra` has to import `traceFilePath` from this module to list the
 * file in "Where things are kept" — and a cycle between the two is not worth
 * paying for a default argument. `index.ts` imports both and wires them.
 */
export function traceIpc(
  ipcMain: IpcMain,
  options: { exclude?: string[]; enabled: () => boolean },
): void {
  const exclude = options.exclude ?? NOISE
  const { enabled } = options

  const file = traceFilePath()
  try {
    mkdirSync(dirname(file), { recursive: true })
  } catch {
    /* userData always exists in practice; a failure here must not block boot */
  }

  /** Bytes in the live file, so rotation does not `stat` on every line. */
  let size = sizeOf(file)
  /** Whether the "trace started" header has been written this run. */
  let announced = false
  /** Last answer from `enabled()`, to notice the moment it changes. */
  let was = enabled()

  if (!was) {
    // Clear what the previous build left behind. This is the 12 MB that shipped:
    // it was written without the user asking, it is this module's own debug
    // output rather than anything of theirs, and leaving it to sit on their disk
    // because the fix only applies going forward would fix nothing for anybody
    // who already has it.
    discard()
    size = 0
  }

  const write = (line: string): void => {
    const on = enabled()
    if (on !== was) {
      was = on
      // Turning it off mid-run leaves the file for reading — that is the point
      // of having traced — but stops adding to it, and re-arms the header so a
      // later session is visibly a separate one.
      if (!on) announced = false
    }
    if (!on) return

    if (!announced) {
      announced = true
      append(`--- trace started, all channels except: ${exclude.join(', ')} ---`)
    }
    append(line)
  }

  function append(line: string): void {
    const text = `${new Date().toISOString()} ${line}\n`
    try {
      if (size + text.length > MAX_TRACE_BYTES) rotate()
      appendFileSync(file, text)
      size += text.length
    } catch {
      /* tracing must never break the app it is tracing */
    }
  }

  function rotate(): void {
    try {
      renameSync(file, previousTraceFilePath())
    } catch {
      // Nothing to move, or the rename failed. Either way the live file must not
      // be allowed to keep growing, so drop it rather than skip the rotation.
      try {
        rmSync(file, { force: true })
      } catch {
        /* give up on bounding it this once rather than throwing out of an IPC call */
      }
    }
    size = 0
  }

  function discard(): void {
    for (const path of [file, previousTraceFilePath()]) {
      try {
        rmSync(path, { force: true })
      } catch {
        /* a locked or unwritable file is not worth failing boot over */
      }
    }
  }

  // `on` is wrapped too. Tracing only `handle` is what hid the bug this file
  // was written to find: browser:bounds and browser:visible are `on` channels,
  // so the trace showed no calls at all and made it look like the renderer was
  // never asking for them.
  const originalOn = ipcMain.on.bind(ipcMain)
  ipcMain.on = ((channel: string, listener: (...args: unknown[]) => void) => {
    if (exclude.includes(channel)) return originalOn(channel, listener)
    return originalOn(channel, (event: unknown, ...args: unknown[]) => {
      if (enabled()) write(`⇢ ${channel}(${summarize(args)})   [send]`)
      return listener(event, ...args)
    })
  }) as IpcMain['on']

  const original = ipcMain.handle.bind(ipcMain)
  ipcMain.handle = ((channel: string, listener: (...args: unknown[]) => unknown) => {
    if (exclude.includes(channel)) return original(channel, listener)

    return original(channel, async (event: unknown, ...args: unknown[]) => {
      const tracing = enabled()
      if (tracing) write(`→ ${channel}(${summarize(args)})`)
      try {
        const result = await (listener as (...a: unknown[]) => unknown)(event, ...args)
        if (tracing) write(`← ${channel} ok: ${JSON.stringify(result)?.slice(0, 300) ?? 'undefined'}`)
        return result
      } catch (error) {
        if (tracing) write(`✗ ${channel} THREW: ${String(error).slice(0, 300)}`)
        throw error
      }
    })
  }) as IpcMain['handle']
}

/**
 * Arguments are truncated: a bounds object is useful, a screenshot data URL
 * would fill the disk on its own.
 */
function summarize(args: unknown[]): string {
  return args.map((a) => JSON.stringify(a)?.slice(0, 200) ?? String(a)).join(', ')
}

function sizeOf(path: string): number {
  try {
    return statSync(path).size
  } catch {
    return 0
  }
}

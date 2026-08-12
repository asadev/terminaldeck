import { appendFileSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { app, type IpcMain } from 'electron'

/**
 * Records every IPC call on the given channel prefixes to a file.
 *
 * A packaged app has no visible console, so when a panel silently does nothing
 * there is no way to tell whether the renderer never called, the call threw, or
 * it succeeded and the result was wrong. This makes that difference readable
 * without asking the user to run anything from a terminal.
 */
export function traceIpc(ipcMain: IpcMain, prefixes: string[]): void {
  const file = join(app.getPath('userData'), 'ipc-trace.log')
  try {
    mkdirSync(dirname(file), { recursive: true })
  } catch {
    /* userData always exists in practice; a failure here must not block boot */
  }

  const write = (line: string): void => {
    try {
      appendFileSync(file, `${new Date().toISOString()} ${line}\n`)
    } catch {
      /* tracing must never break the app it is tracing */
    }
  }

  write(`--- trace started, watching: ${prefixes.join(', ')} ---`)

  // `on` is wrapped too. Tracing only `handle` is what hid the bug this file
  // was written to find: browser:bounds and browser:visible are `on` channels,
  // so the trace showed no calls at all and made it look like the renderer was
  // never asking for them.
  const originalOn = ipcMain.on.bind(ipcMain)
  ipcMain.on = ((channel: string, listener: (...args: unknown[]) => void) => {
    if (!prefixes.some((p) => channel.startsWith(p))) return originalOn(channel, listener)
    return originalOn(channel, (event: unknown, ...args: unknown[]) => {
      const shown = args.map((a) => JSON.stringify(a)?.slice(0, 200) ?? String(a)).join(', ')
      write(`⇢ ${channel}(${shown})   [send]`)
      return listener(event, ...args)
    })
  }) as IpcMain['on']

  const original = ipcMain.handle.bind(ipcMain)
  ipcMain.handle = ((channel: string, listener: (...args: unknown[]) => unknown) => {
    if (!prefixes.some((p) => channel.startsWith(p))) return original(channel, listener)

    return original(channel, async (event: unknown, ...args: unknown[]) => {
      // Arguments are truncated: a bounds object is useful, a screenshot
      // data URL would fill the disk.
      const shown = args.map((a) => JSON.stringify(a)?.slice(0, 200) ?? String(a)).join(', ')
      write(`→ ${channel}(${shown})`)
      try {
        const result = await (listener as (...a: unknown[]) => unknown)(event, ...args)
        write(`← ${channel} ok: ${JSON.stringify(result)?.slice(0, 300) ?? 'undefined'}`)
        return result
      } catch (error) {
        write(`✗ ${channel} THREW: ${String(error).slice(0, 300)}`)
        throw error
      }
    })
  }) as IpcMain['handle']
}

export function traceFilePath(): string {
  return join(app.getPath('userData'), 'ipc-trace.log')
}

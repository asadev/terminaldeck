import { EventEmitter } from 'node:events'
import { existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { IpcMain } from 'electron'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * `app.getPath('userData')` is the only thing this module wants from Electron,
 * and it has to answer a real directory because the module writes to it. A
 * per-test temp dir is swapped in through the mock.
 */
let userData = ''

vi.mock('electron', () => ({
  app: { getPath: (): string => userData },
}))

const { MAX_TRACE_BYTES, previousTraceFilePath, traceFilePath, traceIpc } = await import(
  './ipc-trace'
)

/** Enough of `ipcMain` for the wrappers to wrap. */
class FakeIpcMain extends EventEmitter {
  readonly handlers = new Map<string, (...args: unknown[]) => unknown>()

  handle(channel: string, listener: (...args: unknown[]) => unknown): void {
    this.handlers.set(channel, listener)
  }

  async invoke(channel: string, ...args: unknown[]): Promise<unknown> {
    return this.handlers.get(channel)?.({}, ...args)
  }
}

function fakeIpc(): { ipc: FakeIpcMain; asIpcMain: IpcMain } {
  const ipc = new FakeIpcMain()
  return { ipc, asIpcMain: ipc as unknown as IpcMain }
}

function traceText(): string {
  try {
    return readFileSync(traceFilePath(), 'utf8')
  } catch {
    return ''
  }
}

beforeEach(() => {
  userData = mkdtempSync(join(tmpdir(), 'terminaldeck-ipc-trace-'))
})

afterEach(() => {
  rmSync(userData, { recursive: true, force: true })
})

describe('tracing is off unless Debug mode is on', () => {
  it('writes nothing at all when disabled — not even a header', () => {
    const { ipc, asIpcMain } = fakeIpc()
    traceIpc(asIpcMain, { enabled: () => false })
    ipc.handle('session:create', () => 'ok')

    return ipc.invoke('session:create', { cwd: '/work' }).then(() => {
      // The shipped bug: 12 MB written with this setting off. Not "less", none.
      expect(existsSync(traceFilePath())).toBe(false)
    })
  })

  it('records the call when enabled', async () => {
    const { ipc, asIpcMain } = fakeIpc()
    traceIpc(asIpcMain, { enabled: () => true })
    ipc.handle('session:create', () => 'made it')

    await ipc.invoke('session:create', { cwd: '/work' })

    const text = traceText()
    expect(text).toContain('trace started')
    expect(text).toContain('→ session:create')
    expect(text).toContain('← session:create ok')
  })

  it('starts and stops with the setting, without a relaunch', async () => {
    let on = false
    const { ipc, asIpcMain } = fakeIpc()
    // The wrappers are installed once, at boot, before the setting can be read —
    // so the check has to happen per call or arming the trace would mean
    // quitting the app first, by which point the bug has gone.
    traceIpc(asIpcMain, { enabled: () => on })
    ipc.handle('a:one', () => 1)

    await ipc.invoke('a:one')
    expect(traceText()).toBe('')

    on = true
    await ipc.invoke('a:one')
    expect(traceText()).toContain('→ a:one')

    on = false
    const afterOff = traceText()
    await ipc.invoke('a:one')
    expect(traceText()).toBe(afterOff)
  })

  it('still calls the handler and still propagates its result and its throw', async () => {
    const { ipc, asIpcMain } = fakeIpc()
    traceIpc(asIpcMain, { enabled: () => false })
    ipc.handle('a:ok', () => 'value')
    ipc.handle('a:bad', () => {
      throw new Error('boom')
    })

    // Tracing must never change what the app does, in either state.
    await expect(ipc.invoke('a:ok')).resolves.toBe('value')
    await expect(ipc.invoke('a:bad')).rejects.toThrow('boom')
  })

  it('leaves excluded per-frame channels alone', async () => {
    const { ipc, asIpcMain } = fakeIpc()
    traceIpc(asIpcMain, { enabled: () => true, exclude: ['browser:bounds'] })
    ipc.handle('browser:bounds', () => undefined)
    ipc.handle('session:list', () => [])

    await ipc.invoke('browser:bounds', { x: 1 })
    await ipc.invoke('session:list')

    // Not a bare substring check: the header line names the exclusions, which
    // is the point of printing it, so only a *call* record counts as a leak.
    expect(traceText()).not.toContain('→ browser:bounds')
    expect(traceText()).toContain('→ session:list')
  })
})

describe('a trace left by an earlier build', () => {
  it('is cleared at boot when tracing is off', () => {
    writeFileSync(traceFilePath(), 'x'.repeat(12 * 1024 * 1024))
    writeFileSync(previousTraceFilePath(), 'older')

    const { asIpcMain } = fakeIpc()
    traceIpc(asIpcMain, { enabled: () => false })

    // v0.1.3 shipped 12 MB of this. Fixing it only for new installs would leave
    // every existing user carrying the file for ever.
    expect(existsSync(traceFilePath())).toBe(false)
    expect(existsSync(previousTraceFilePath())).toBe(false)
  })

  it('is kept when tracing is on, because it is what the user asked for', () => {
    writeFileSync(traceFilePath(), 'earlier session\n')

    const { asIpcMain } = fakeIpc()
    traceIpc(asIpcMain, { enabled: () => true })

    expect(traceText()).toContain('earlier session')
  })
})

describe('the file cannot grow without bound', () => {
  it('rolls over at the cap and keeps one previous generation', async () => {
    const { ipc, asIpcMain } = fakeIpc()
    traceIpc(asIpcMain, { enabled: () => true })
    // A big argument, truncated to 200 characters in the log — so the line
    // length is bounded and the number of calls needed is predictable.
    const chunk = 'y'.repeat(4000)
    ipc.handle('big:call', () => chunk)

    // Comfortably past the cap: ~300 bytes a call against a 4 MB ceiling would
    // take too long, so the file is primed near the limit first.
    writeFileSync(traceFilePath(), 'z'.repeat(MAX_TRACE_BYTES - 100))
    // Re-register so the module picks the primed size up.
    const second = fakeIpc()
    traceIpc(second.asIpcMain, { enabled: () => true })
    second.ipc.handle('big:call', () => chunk)
    for (let i = 0; i < 5; i++) await second.ipc.invoke('big:call', chunk)

    expect(statSync(traceFilePath()).size).toBeLessThan(MAX_TRACE_BYTES)
    expect(existsSync(previousTraceFilePath())).toBe(true)
    // The rolled-over copy is the one that was full.
    expect(statSync(previousTraceFilePath()).size).toBeGreaterThan(MAX_TRACE_BYTES - 1000)
  })

  it('never exceeds two generations', async () => {
    const { ipc, asIpcMain } = fakeIpc()
    traceIpc(asIpcMain, { enabled: () => true })
    ipc.handle('c', () => 'x')

    for (let round = 0; round < 3; round++) {
      writeFileSync(traceFilePath(), 'z'.repeat(MAX_TRACE_BYTES - 100))
      const next = fakeIpc()
      traceIpc(next.asIpcMain, { enabled: () => true })
      next.ipc.handle('c', () => 'x')
      for (let i = 0; i < 3; i++) await next.ipc.invoke('c')
    }

    const names = new Set(
      [traceFilePath(), previousTraceFilePath()].filter((p) => existsSync(p)),
    )
    expect(names.size).toBeLessThanOrEqual(2)
  })
})

describe('the file is disclosed to the user', () => {
  it('sits under userData where the settings list can name it', () => {
    mkdirSync(userData, { recursive: true })
    // "Where things are kept" lists it by this path; if it moved out of
    // userData the settings entry would point at nothing.
    expect(traceFilePath()).toBe(join(userData, 'ipc-trace.log'))
    expect(previousTraceFilePath()).toBe(`${join(userData, 'ipc-trace.log')}.1`)
  })
})

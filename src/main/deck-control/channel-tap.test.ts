import type { IpcMain } from 'electron'
import { describe, expect, it, vi } from 'vitest'
import { channelCall, createChannelTap, type ChannelListener, type TappableIpc } from './channel-tap'

/**
 * A stand-in for Electron's `ipcMain` that keeps what it was given, the way the
 * real one does, so a test can play the window's part and call a channel the
 * way the renderer would — through whatever the tap handed Electron.
 */
function fakeIpc(): TappableIpc & { window(channel: string, ...args: unknown[]): Promise<unknown> } {
  const electron = new Map<string, ChannelListener>()
  return {
    handle(channel, listener) {
      electron.set(channel, listener)
    },
    on(channel, listener) {
      electron.set(channel, listener)
    },
    async window(channel, ...args) {
      const listener = electron.get(channel)
      if (!listener) throw new Error(`nothing on ${channel}`)
      return await listener({ sender: 'the window' }, ...args)
    },
  }
}

describe('the channel tap', () => {
  it('fits the real ipcMain without a cast', () => {
    // A compile-time check as much as a runtime one: `index.ts` passes Electron's
    // own `ipcMain`, and a structural type that stopped accepting it would be a
    // wiring line that no longer compiles.
    const fits = (ipc: IpcMain): TappableIpc => ipc
    expect(typeof fits).toBe('function')
  })

  it('calls the same handler the window calls, with no event', async () => {
    const tap = createChannelTap()
    const ipc = fakeIpc()
    tap.attach(ipc)
    const seen: unknown[] = []
    ipc.handle('machines:rename', (event, id, name) => {
      seen.push(event)
      return { renamed: `${String(id)}=${String(name)}` }
    })
    expect(await tap.invoke('machines:rename', 'm1', 'Office')).toEqual({ renamed: 'm1=Office' })
    // The window still reaches it, through Electron, exactly as before.
    expect(await ipc.window('machines:rename', 'm2', 'Mac')).toEqual({ renamed: 'm2=Mac' })
    expect(seen).toEqual([null, { sender: 'the window' }])
  })

  it('reaches an `on` channel too', async () => {
    const tap = createChannelTap()
    const ipc = fakeIpc()
    tap.attach(ipc)
    const cleared = vi.fn()
    ipc.on('github:clear-cache', (_event, cwd) => cleared(cwd))
    await tap.invoke('github:clear-cache', '/repo')
    expect(cleared).toHaveBeenCalledWith('/repo')
  })

  it('names a channel nothing registered, rather than answering for it', async () => {
    const tap = createChannelTap()
    tap.attach(fakeIpc())
    await expect(tap.invoke('machines:nothing')).rejects.toThrow(/Nothing in this app answers "machines:nothing"/)
  })

  it('refuses to wrap the same ipcMain twice', () => {
    const tap = createChannelTap()
    const ipc = fakeIpc()
    tap.attach(ipc)
    expect(() => tap.attach(ipc)).toThrow(/already attached/)
  })

  it('reports every call once — the window’s and a tool’s — before the handler runs', async () => {
    const tap = createChannelTap()
    const ipc = fakeIpc()
    tap.attach(ipc)
    const order: string[] = []
    ipc.handle('machines:attach', () => {
      order.push('handler')
      return true
    })
    tap.onInvoke((channel, args) => order.push(`${channel}(${args.join(',')})`))
    await ipc.window('machines:attach', 'm1', 's1', 80, 24)
    await tap.invoke('machines:attach', 'm1', 's1', 120, 30)
    expect(order).toEqual(['machines:attach(m1,s1,80,24)', 'handler', 'machines:attach(m1,s1,120,30)', 'handler'])
  })

  it('keeps a throwing listener from costing the window its answer', async () => {
    const tap = createChannelTap()
    const ipc = fakeIpc()
    tap.attach(ipc)
    ipc.handle('machines:list', () => 'the list')
    const quiet = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    tap.onInvoke(() => {
      throw new Error('a broken listener')
    })
    expect(await ipc.window('machines:list')).toBe('the list')
    quiet.mockRestore()
  })

  it('hands pushes to whoever listens, and stops when asked', () => {
    const tap = createChannelTap()
    const heard: unknown[] = []
    const stop = tap.onPush('machines:output', (payload) => heard.push(payload))
    tap.pushed('machines:output', [{ data: 'a' }])
    stop()
    tap.pushed('machines:output', [{ data: 'b' }])
    expect(heard).toEqual([{ data: 'a' }])
  })

  it('waits for a push caused by the very call it wraps, even one in the same tick', async () => {
    const tap = createChannelTap()
    const next = tap.nextPush('machines:state', (payload) => (payload as { n: number }).n === 2, 1000, () => {
      // The push lands synchronously, inside the action — the race a
      // subscribe-after helper loses.
      tap.pushed('machines:state', [{ n: 1 }])
      tap.pushed('machines:state', [{ n: 2 }])
    })
    expect(await next).toEqual({ n: 2 })
  })

  it('answers null at the ceiling, and lets go of its listener', async () => {
    vi.useFakeTimers()
    try {
      const tap = createChannelTap()
      const next = tap.nextPush('machines:state', () => true, 500)
      vi.advanceTimersByTime(501)
      expect(await next).toBeNull()
      // Nothing left listening: a later push reaches no stale waiter.
      const heard: unknown[] = []
      tap.onPush('machines:state', (payload) => heard.push(payload))
      tap.pushed('machines:state', [1])
      expect(heard).toEqual([1])
    } finally {
      vi.useRealTimers()
    }
  })

  it('narrows to a typed call over a closed map', async () => {
    const tap = createChannelTap()
    const ipc = fakeIpc()
    tap.attach(ipc)
    ipc.handle('machines:ports', (_event, id) => id === 'm1')
    const call = channelCall<{ 'machines:ports': { args: [string]; result: boolean } }>(tap)
    expect(await call('machines:ports', 'm1')).toBe(true)
  })
})

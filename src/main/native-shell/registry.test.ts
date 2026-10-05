import { EventEmitter } from 'node:events'
import { describe, expect, it } from 'vitest'
import { isNativeShell, NATIVE_REFUSED_CHANNELS } from './mode'
import { createHandlerRegistry, isBridgeChannel, type IpcListener, type TappableIpcMain } from './registry'
import { createNativeSender, NATIVE_SENDER_ID } from './sender'
import { decodeFromWire, encodeForWire } from './wire'

/** Electron's `ipcMain` shape: an emitter, a private handler map, `handle` that refuses a second registration. */
function fakeIpcMain(): TappableIpcMain & EventEmitter & { _invokeHandlers: Map<string, IpcListener> } {
  const emitter = new EventEmitter()
  const handlers = new Map<string, IpcListener>()
  return Object.assign(emitter, {
    _invokeHandlers: handlers,
    handle(channel: string, listener: IpcListener) {
      if (handlers.has(channel)) throw new Error(`Attempted to register a second handler for '${channel}'`)
      handlers.set(channel, listener)
    },
    removeHandler(channel: string) {
      handlers.delete(channel)
    },
  })
}

describe('the handler registry', () => {
  it('calls the handler registered after the tap, with the event it is given', async () => {
    const ipcMain = fakeIpcMain()
    const registry = createHandlerRegistry()
    registry.tap(ipcMain)
    ipcMain.handle('sum', (event, a, b) => ({ who: (event as { sender: string }).sender, total: (a as number) + (b as number) }))
    expect(registry.has('sum')).toBe(true)
    await expect(registry.invoke('sum', { sender: 'me' }, [2, 3])).resolves.toEqual({ who: 'me', total: 5 })
  })

  it('keeps the outermost wrapper when a later layer wraps handle, as the trace and the channel tap do', async () => {
    const ipcMain = fakeIpcMain()
    const registry = createHandlerRegistry()
    registry.tap(ipcMain)
    const inner = ipcMain.handle.bind(ipcMain)
    const calls: string[] = []
    ipcMain.handle = (channel: string, listener: IpcListener) =>
      inner(channel, (event, ...args) => {
        calls.push(channel)
        return listener(event, ...args)
      })
    ipcMain.handle('traced', () => 'value')
    await expect(registry.invoke('traced', {}, [])).resolves.toBe('value')
    expect(calls).toEqual(['traced'])
  })

  it('forgets a removed handler, and leaves Electron to refuse a duplicate', async () => {
    const ipcMain = fakeIpcMain()
    const registry = createHandlerRegistry()
    registry.tap(ipcMain)
    ipcMain.handle('once', () => 1)
    expect(() => ipcMain.handle('once', () => 2)).toThrow(/second handler/)
    await expect(registry.invoke('once', {}, [])).resolves.toBe(1)
    ipcMain.removeHandler('once')
    expect(registry.has('once')).toBe(false)
    await expect(registry.invoke('once', {}, [])).rejects.toThrow("No handler registered for 'once'")
  })

  it('falls back to Electron’s own map for a handler registered before the tap', async () => {
    const ipcMain = fakeIpcMain()
    ipcMain.handle('early', (_event, x) => `early ${String(x)}`)
    const registry = createHandlerRegistry()
    registry.tap(ipcMain)
    await expect(registry.invoke('early', {}, ['bird'])).resolves.toBe('early bird')
    // The older Electron shape, which answered through the event.
    ipcMain._invokeHandlers.set('replies', (event) => {
      ;(event as { _reply(value: unknown): void })._reply('through the event')
    })
    await expect(registry.invoke('replies', {}, [])).resolves.toBe('through the event')
  })

  it('delivers a send to every on-listener, and says when nobody listens', () => {
    const ipcMain = fakeIpcMain()
    const registry = createHandlerRegistry()
    registry.tap(ipcMain)
    const heard: unknown[] = []
    ipcMain.on('typed', (_event: unknown, text: unknown) => heard.push(text))
    ipcMain.on('typed', (_event: unknown, text: unknown) => heard.push(`again ${String(text)}`))
    expect(registry.send('typed', {}, ['x'])).toBe(true)
    expect(heard).toEqual(['x', 'again x'])
    expect(registry.send('silent', {}, [])).toBe(false)
  })

  it('carries ordinary channel names and refuses Electron’s and the emitter’s own', () => {
    for (const ok of ['brand:get', 'session:write', 'debug:ipc-call', 'browser-view:claim', 'hoot-panel:pointer']) {
      expect(isBridgeChannel(ok), ok).toBe(true)
    }
    for (const bad of ['', 'error', 'newListener', 'removeListener', '-ipc-invoke', 'ELECTRON_BROWSER_X', 'a b', 'x'.repeat(201), 5, null]) {
      expect(isBridgeChannel(bad), String(bad)).toBe(false)
    }
  })
})

describe('the stand-in sender', () => {
  it('pushes through the bridge and answers what handlers read off a window', async () => {
    const pushed: unknown[] = []
    const session = { name: 'default' }
    const sender = createNativeSender({
      deliver: (channel, args) => {
        pushed.push([channel, ...args])
        return true
      },
      url: () => 'http://127.0.0.1:1/',
      session: () => session,
    })
    sender.send('usage:update', 's1', { tokens: 3 })
    expect(pushed).toEqual([['usage:update', 's1', { tokens: 3 }]])
    expect(sender.id).toBe(NATIVE_SENDER_ID)
    expect(sender.isDestroyed()).toBe(false)
    expect(sender.getOwnerBrowserWindow()).toBeNull()
    expect(sender.mainFrame).toBeNull()
    expect(sender.session).toBe(session)
    expect(sender.getURL()).toBe('http://127.0.0.1:1/')
    let destroyed = false
    sender.once('destroyed', () => (destroyed = true))
    expect(destroyed).toBe(false)
    await expect(sender.executeJavaScript('1')).rejects.toThrow(/native window/)
  })
})

describe('the mode switch', () => {
  it('is on only with the flag', () => {
    expect(isNativeShell(['/Electron', '/repo', '--native-shell', '--user-data-dir=/x'])).toBe(true)
    expect(isNativeShell(['/Electron', '/repo'])).toBe(false)
    expect(isNativeShell(['/Electron', '/repo', '--native-shell=1'])).toBe(false)
  })

  it('refuses the two channels that need a Chromium window, in plain words', () => {
    expect(Object.keys(NATIVE_REFUSED_CHANNELS).sort()).toEqual(['browser-view:claim', 'browser:create'])
    for (const sentence of Object.values(NATIVE_REFUSED_CHANNELS)) expect(sentence).toMatch(/native shell/)
  })
})

describe('the wire format', () => {
  it('round-trips bytes and leaves everything else as JSON', () => {
    const text = encodeForWire({ a: Buffer.from('x'), b: new Uint8Array([1, 2]), c: [undefined, 1], d: new Error('e'), e: 5n })
    expect(JSON.parse(text)).toEqual({
      a: { $bytes: 'eA==' },
      b: { $bytes: 'AQI=' },
      c: [null, 1],
      d: { name: 'Error', message: 'e' },
      e: '5',
    })
    const back = decodeFromWire(JSON.parse(text)) as { a: Buffer; b: Buffer }
    expect(Buffer.isBuffer(back.a) && back.a.toString()).toBe('x')
    expect([...back.b]).toEqual([1, 2])
  })

  it('does not let a body replace an object’s prototype', () => {
    const decoded = decodeFromWire(JSON.parse('{"__proto__":{"polluted":true},"ok":1}')) as Record<string, unknown>
    expect(decoded.ok).toBe(1)
    expect(decoded.polluted).toBeUndefined()
    expect(({} as Record<string, unknown>).polluted).toBeUndefined()
  })
})

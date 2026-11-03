import { describe, expect, it } from 'vitest'
import { BRIDGE_PATHS, createTransport, openEventStream, type EventSourceLike, type Transport } from './bridge'
import { createContextBridge, createIpcRenderer, type IpcListener } from './ipc-renderer'

/**
 * `ipcRenderer`, `contextBridge` and `webUtils` as the preload sees them in the
 * native window.
 *
 * The preload's listeners are all written `(_e, …payload) => cb(…payload)`, so
 * the one thing that must never slip is the first argument: a listener that got
 * the payload in the event's slot would hand every subscriber `undefined`, and
 * nothing would throw.
 */

function recordingTransport() {
  const calls: Array<[string, string, readonly unknown[]]> = []
  const transport: Transport = {
    invoke: (channel, args) => {
      calls.push(['invoke', channel, args])
      return Promise.resolve(`answer to ${channel}`)
    },
    send: (channel, args) => {
      calls.push(['send', channel, args])
    },
    sendSync: (channel, args) => {
      calls.push(['sendSync', channel, args])
      return 'sync answer'
    },
  }
  return { calls, transport }
}

describe('ipcRenderer: calls', () => {
  it('passes invoke, send and sendSync straight to the bridge with their arguments', async () => {
    const { calls, transport } = recordingTransport()
    const { ipcRenderer } = createIpcRenderer(transport)
    await expect(ipcRenderer.invoke('prefs:set', { theme: 'light' })).resolves.toBe('answer to prefs:set')
    expect(ipcRenderer.send('session:write', 's1', 'x')).toBeUndefined()
    expect(ipcRenderer.sendSync('x:sync')).toBe('sync answer')
    expect(calls).toEqual([
      ['invoke', 'prefs:set', [{ theme: 'light' }]],
      ['send', 'session:write', ['s1', 'x']],
      ['sendSync', 'x:sync', []],
    ])
  })
})

describe('ipcRenderer: listeners', () => {
  it('hands a listener the event stub first and the payload after it, on its own channel only', () => {
    const { ipcRenderer, dispatch } = createIpcRenderer(recordingTransport().transport)
    const heard: unknown[][] = []
    ipcRenderer.on('session:data', (event, ...args) => heard.push([event.sender === ipcRenderer, event.ports, ...args]))
    ipcRenderer.on('session:exit', () => heard.push(['wrong channel']))
    dispatch('session:data', ['s1', 'hello'])
    dispatch('nobody:listens', [1])
    expect(heard).toEqual([[true, [], 's1', 'hello']])
  })

  it('removes with off and removeListener, and on/off return ipcRenderer for chaining', () => {
    const { ipcRenderer, dispatch } = createIpcRenderer(recordingTransport().transport)
    let count = 0
    const listener: IpcListener = () => {
      count++
    }
    expect(ipcRenderer.on('a', listener)).toBe(ipcRenderer)
    dispatch('a', [])
    expect(ipcRenderer.off('a', listener)).toBe(ipcRenderer)
    dispatch('a', [])
    ipcRenderer.addListener('a', listener)
    ipcRenderer.removeListener('a', listener)
    dispatch('a', [])
    expect(count).toBe(1)
    expect(ipcRenderer.listenerCount('a')).toBe(0)
  })

  it('behaves like EventEmitter for duplicates: added twice, called twice, off takes one', () => {
    const { ipcRenderer, dispatch } = createIpcRenderer(recordingTransport().transport)
    let count = 0
    const listener: IpcListener = () => {
      count++
    }
    ipcRenderer.on('a', listener).on('a', listener)
    dispatch('a', [])
    expect(count).toBe(2)
    ipcRenderer.off('a', listener)
    dispatch('a', [])
    expect(count).toBe(3)
  })

  it('fires a once listener once, and lets it be removed by the function that was passed', () => {
    const { ipcRenderer, dispatch } = createIpcRenderer(recordingTransport().transport)
    const heard: unknown[] = []
    ipcRenderer.once('a', (_event, value) => heard.push(value))
    dispatch('a', [1])
    dispatch('a', [2])
    const never: IpcListener = () => heard.push('never')
    ipcRenderer.once('b', never)
    ipcRenderer.off('b', never)
    dispatch('b', [])
    expect(heard).toEqual([1])
  })

  it('clears one channel or all of them', () => {
    const { ipcRenderer, dispatch } = createIpcRenderer(recordingTransport().transport)
    const heard: string[] = []
    ipcRenderer.on('a', () => heard.push('a'))
    ipcRenderer.on('b', () => heard.push('b'))
    ipcRenderer.removeAllListeners('a')
    dispatch('a', [])
    dispatch('b', [])
    ipcRenderer.removeAllListeners()
    dispatch('b', [])
    expect(heard).toEqual(['b'])
  })

  it('delivers an event to the listeners present when it arrived, whatever they do to the list', () => {
    const { ipcRenderer, dispatch } = createIpcRenderer(recordingTransport().transport)
    const heard: string[] = []
    const second: IpcListener = () => heard.push('second')
    ipcRenderer.on('a', () => {
      heard.push('first')
      ipcRenderer.off('a', second)
      ipcRenderer.on('a', () => heard.push('added during'))
    })
    ipcRenderer.on('a', second)
    dispatch('a', [])
    expect(heard).toEqual(['first', 'second'])
  })

  it('does not let one throwing listener silence the others, and still reports the error', () => {
    const reported: unknown[] = []
    const { ipcRenderer, dispatch } = createIpcRenderer(recordingTransport().transport, (error) => reported.push(error))
    const heard: string[] = []
    ipcRenderer.on('a', () => {
      throw new Error('boom')
    })
    ipcRenderer.on('a', () => heard.push('still heard'))
    dispatch('a', [])
    expect(heard).toEqual(['still heard'])
    expect((reported[0] as Error).message).toBe('boom')
  })
})

describe('ipcRenderer over the real event stream', () => {
  it('routes an SSE message to the subscriber of its channel, as the preload subscribes', () => {
    const sources: Array<EventSourceLike & { url: string }> = []
    class FakeEventSource implements EventSourceLike {
      onopen = null
      onmessage: ((event: { data: string }) => void) | null = null
      onerror = null
      constructor(readonly url: string) {
        sources.push(this)
      }
      close() {}
    }
    const { ipcRenderer, dispatch } = createIpcRenderer(
      createTransport({ fetch: () => Promise.reject(new Error('unused')) }),
    )
    openEventStream({ EventSource: FakeEventSource, setTimeout: () => 0 }, dispatch)

    // `onPreferencesChanged` in `src/preload/index.ts`, verbatim in shape.
    const received: unknown[] = []
    const cb = (preferences: unknown) => received.push(preferences)
    const handler: IpcListener = (_e, preferences) => cb(preferences)
    ipcRenderer.on('prefs:changed', handler)
    const unsubscribe = () => ipcRenderer.off('prefs:changed', handler)

    expect(sources.map((source) => source.url)).toEqual([BRIDGE_PATHS.events])
    sources[0].onmessage?.({ data: JSON.stringify({ channel: 'prefs:changed', args: [{ theme: 'light' }] }) })
    sources[0].onmessage?.({ data: JSON.stringify({ channel: 'settings:changed', args: [{ x: 1 }] }) })
    unsubscribe()
    sources[0].onmessage?.({ data: JSON.stringify({ channel: 'prefs:changed', args: [{ theme: 'dark' }] }) })
    expect(received).toEqual([{ theme: 'light' }])
  })
})

describe('contextBridge', () => {
  it('puts the API on the window under its name', () => {
    const host: Record<string, unknown> = {}
    const api = { getBrand: () => Promise.resolve({ name: 'x' }) }
    createContextBridge(host).exposeInMainWorld('deck', api)
    expect(host.deck).toBe(api)
  })

  it('refuses to bind over a name the window already has, as Electron does', () => {
    const host: Record<string, unknown> = { deck: 'already here' }
    expect(() => createContextBridge(host).exposeInMainWorld('deck', {})).toThrow(/existing property/)
    expect(host.deck).toBe('already here')
  })
})

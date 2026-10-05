import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { request as httpRequest } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { COOKIE_NAME, startBridgeServer, type BridgeServer } from '../main/native-shell/bridge-server'
import { createTransport, decodeEvent } from './bridge'
import { createIpcRenderer, type IpcListener } from './ipc-renderer'

/**
 * Two windows on one session both print everything it writes.
 *
 * Each native window is its own page with its own event stream; each terminal
 * subscribes to `session:data` and keeps the frames for its session id. Proved
 * here end to end on the engine's real bridge (`main/native-shell/bridge-server.ts`):
 * two streams open, one push goes out, and each window's terminal — a separate
 * `ipcRenderer`, subscribed exactly as the preload's `onSessionData` subscribes
 * — hears it. One terminal per window, one session, both fed.
 */

const TOKEN = 'two-windows-token-0123456789abcdef0123456789'

let root: string | null = null
let server: BridgeServer | null = null

afterEach(async () => {
  await server?.close()
  server = null
  if (root !== null) rmSync(root, { recursive: true, force: true })
  root = null
})

/** One window: an event stream, decoded and dispatched to that window's own listeners. */
function openWindow(port: number): Promise<{
  on(listener: IpcListener): void
  close(): void
}> {
  const { ipcRenderer, dispatch } = createIpcRenderer(createTransport({ fetch: () => Promise.reject(new Error('unused')) }))
  return new Promise((resolve, reject) => {
    const req = httpRequest(
      { host: '127.0.0.1', port, path: '/__td/events', headers: { cookie: `${COOKIE_NAME}=${TOKEN}` } },
      (res) => {
        let buffered = ''
        res.on('data', (chunk: Buffer) => {
          buffered += chunk.toString('utf8')
          let end = buffered.indexOf('\n\n')
          while (end !== -1) {
            const frame = buffered.slice(0, end)
            buffered = buffered.slice(end + 2)
            if (frame.startsWith(': connected')) {
              resolve({
                on: (listener) => void ipcRenderer.on('session:data', listener),
                close: () => req.destroy(),
              })
            }
            const data = frame.split('\n').find((line) => line.startsWith('data: '))
            const event = data === undefined ? null : decodeEvent(data.slice('data: '.length))
            if (event) dispatch(event.channel, event.args)
            end = buffered.indexOf('\n\n')
          }
        })
      },
    )
    req.on('error', (error) => {
      if ((error as NodeJS.ErrnoException).code !== 'ECONNRESET') reject(error)
    })
    req.end()
  })
}

describe('two windows on one session', () => {
  it('both receive its output', async () => {
    root = mkdtempSync(join(tmpdir(), 'td-two-windows-'))
    const rendererDir = join(root, 'out', 'renderer')
    mkdirSync(rendererDir, { recursive: true })
    writeFileSync(join(rendererDir, 'index.html'), '<!doctype html><html><head></head><body></body></html>')
    server = await startBridgeServer({
      rendererDir,
      shimFile: join(root, 'out', 'native-web', 'shim.js'),
      token: TOKEN,
      invoke: async () => null,
      send: () => undefined,
    })

    const first = await openWindow(server.port)
    const second = await openWindow(server.port)
    const printed: Record<string, string[]> = { first: [], second: [] }
    // Each window's terminal, subscribed as the preload's `onSessionData` does
    // and keeping only its own session's output, as `TerminalView` does.
    const terminal = (into: string[]): IpcListener => (_event, id, data) => {
      if (id === 's1') into.push(String(data))
    }
    first.on(terminal(printed.first))
    second.on(terminal(printed.second))

    expect(server.clientCount()).toBe(2)
    expect(server.emit('session:data', ['s1', 'hello '])).toBe(true)
    expect(server.emit('session:data', ['s2', 'not this one'])).toBe(true)
    expect(server.emit('session:data', ['s1', 'world'])).toBe(true)

    await new Promise<void>((resolve, reject) => {
      const started = Date.now()
      const check = setInterval(() => {
        if (printed.first.length === 2 && printed.second.length === 2) {
          clearInterval(check)
          resolve()
        } else if (Date.now() - started > 3000) {
          clearInterval(check)
          reject(new Error(`only got ${JSON.stringify(printed)}`))
        }
      }, 5)
    })
    expect(printed.first).toEqual(['hello ', 'world'])
    expect(printed.second).toEqual(['hello ', 'world'])
    first.close()
    second.close()
  })
})

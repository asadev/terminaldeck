import { EventEmitter } from 'node:events'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { createServer, request as httpRequest, type IncomingHttpHeaders } from 'node:http'
import type { AddressInfo } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  COOKIE_NAME,
  failedLine,
  injectShim,
  readyLine,
  rememberedPort,
  startBridgeServer,
  staticPathFor,
  type BridgeServer,
  type BridgeServerOptions,
} from './bridge-server'
import { createHandlerRegistry, type IpcListener, type TappableIpcMain } from './registry'

/* ---------------------------------------------------------------- helpers -- */

interface Reply {
  status: number
  headers: IncomingHttpHeaders
  body: string
}

function send(
  port: number,
  options: { method?: string; path?: string; headers?: Record<string, string>; body?: string } = {},
): Promise<Reply> {
  return new Promise((resolve, reject) => {
    const req = httpRequest(
      { host: '127.0.0.1', port, method: options.method ?? 'GET', path: options.path ?? '/', headers: options.headers },
      (res) => {
        const chunks: Buffer[] = []
        res.on('data', (chunk: Buffer) => chunks.push(chunk))
        res.on('end', () => resolve({ status: res.statusCode ?? 0, headers: res.headers, body: Buffer.concat(chunks).toString('utf8') }))
      },
    )
    req.on('error', reject)
    if (options.body !== undefined) req.write(options.body)
    req.end()
  })
}

/** A fake `ipcMain`: an emitter with Electron's `handle` / `removeHandler` shape. */
function fakeIpcMain(): TappableIpcMain {
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

let root: string
let rendererDir: string
let shimFile: string
let server: BridgeServer | null = null
const TOKEN = 'test-token-0123456789abcdef0123456789abcdef'

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'td-bridge-'))
  rendererDir = join(root, 'out', 'renderer')
  mkdirSync(join(rendererDir, 'assets'), { recursive: true })
  writeFileSync(
    join(rendererDir, 'index.html'),
    '<!doctype html>\n<html lang="en">\n  <head>\n    <meta charset="UTF-8" />\n    <script type="module" crossorigin src="./assets/app.js"></script>\n  </head>\n  <body><div id="root"></div></body>\n</html>\n',
  )
  writeFileSync(join(rendererDir, 'assets', 'app.js'), 'console.log("app")\n')
  writeFileSync(join(root, 'out', 'secret.txt'), 'outside the renderer\n')
  symlinkSync(join(root, 'out', 'secret.txt'), join(rendererDir, 'assets', 'link.txt'))
  shimFile = join(root, 'out', 'native-web', 'shim.js')
})

afterEach(async () => {
  await server?.close()
  server = null
  rmSync(root, { recursive: true, force: true })
})

async function start(overrides: Partial<BridgeServerOptions> = {}): Promise<BridgeServer> {
  server = await startBridgeServer({
    rendererDir,
    shimFile,
    token: TOKEN,
    invoke: async () => null,
    send: () => undefined,
    ...overrides,
  })
  return server
}

const cookie = { cookie: `${COOKIE_NAME}=${TOKEN}` }

/* ------------------------------------------------------------------ tests -- */

describe('the ready line', () => {
  it('names a loopback address, a port and a token of at least 32 random bytes', async () => {
    const bridge = await startBridgeServer({ rendererDir, shimFile, invoke: async () => null, send: () => undefined })
    try {
      expect(readyLine(bridge.url)).toMatch(/^TD_NATIVE_READY http:\/\/127\.0\.0\.1:\d+\/\?t=[A-Za-z0-9_-]{43,}$/)
      expect(bridge.url).toBe(`http://127.0.0.1:${bridge.port}/?t=${bridge.token}`)
    } finally {
      await bridge.close()
    }
  })

  it('keeps a failure on one line', () => {
    expect(failedLine('the port\nwas taken\r\n')).toBe('TD_NATIVE_FAILED the port was taken')
    expect(failedLine('')).toBe('TD_NATIVE_FAILED unknown reason')
  })
})

describe('the port, kept per data folder', () => {
  it('serves on the remembered port again, with a fresh token', async () => {
    const portFile = join(root, 'native-shell-port')
    const first = await startBridgeServer({ rendererDir, shimFile, portFile, invoke: async () => null, send: () => undefined })
    const { port, token } = first
    await first.close()
    expect(readFileSync(portFile, 'utf8').trim()).toBe(String(port))
    const second = await startBridgeServer({ rendererDir, shimFile, portFile, invoke: async () => null, send: () => undefined })
    try {
      expect(second.port).toBe(port)
      expect(second.token).not.toBe(token)
    } finally {
      await second.close()
    }
  })

  it('takes another port when the remembered one is busy, and remembers that one', async () => {
    const holder = createServer()
    await new Promise<void>((resolve) => holder.listen(0, '127.0.0.1', () => resolve()))
    const busy = (holder.address() as AddressInfo).port
    const portFile = join(root, 'native-shell-port')
    writeFileSync(portFile, `${busy}\n`)
    const logged: string[] = []
    const bridge = await startBridgeServer({
      rendererDir,
      shimFile,
      portFile,
      invoke: async () => null,
      send: () => undefined,
      log: (message) => logged.push(message),
    })
    try {
      expect(bridge.port).not.toBe(busy)
      expect(readFileSync(portFile, 'utf8').trim()).toBe(String(bridge.port))
      expect(logged.join('\n')).toContain(`port ${busy} is taken`)
    } finally {
      await bridge.close()
      await new Promise<void>((resolve) => holder.close(() => resolve()))
    }
  })

  it('ignores a remembered value that is not a usable port', async () => {
    const portFile = join(root, 'native-shell-port')
    for (const junk of ['80', 'banana', '70000', '']) {
      writeFileSync(portFile, junk)
      expect(await rememberedPort(portFile)).toBeNull()
    }
    expect(await rememberedPort(join(root, 'absent'))).toBeNull()
  })
})

describe('who may ask', () => {
  it('serves the page for the token in the URL, sets the cookie, and loads the shim first', async () => {
    const { port } = await start()
    const reply = await send(port, { path: `/?t=${TOKEN}` })
    expect(reply.status).toBe(200)
    expect(reply.headers['set-cookie']).toEqual([`${COOKIE_NAME}=${TOKEN}; HttpOnly; SameSite=Strict; Path=/`])
    expect(reply.headers['content-type']).toBe('text/html; charset=utf-8')
    expect(reply.headers['content-security-policy']).toContain("script-src 'self'")
    const head = reply.body.slice(reply.body.indexOf('<head>'), reply.body.indexOf('</head>'))
    const firstScript = head.indexOf('<script')
    expect(head.slice(firstScript)).toMatch(/^<script src="\/__td\/shim\.js"><\/script>/)
    expect(head.indexOf('./assets/app.js')).toBeGreaterThan(firstScript)
  })

  it('refuses a request with no cookie and no token', async () => {
    const { port } = await start()
    expect((await send(port, { path: '/assets/app.js' })).status).toBe(403)
    expect((await send(port, { path: '/' })).status).toBe(403)
    expect((await send(port, { path: '/__td/events' })).status).toBe(403)
  })

  it('refuses a wrong token in the URL', async () => {
    const { port } = await start()
    expect((await send(port, { path: '/?t=nope' })).status).toBe(403)
  })

  it('refuses the right cookie under the wrong Host', async () => {
    const { port } = await start()
    const wrongHosts = ['localhost', `localhost:${port}`, `evil.example:${port}`, '127.0.0.1']
    for (const host of wrongHosts) {
      expect((await send(port, { path: '/assets/app.js', headers: { ...cookie, host } })).status).toBe(403)
    }
    expect((await send(port, { path: `/?t=${TOKEN}`, headers: { host: `rebound.example:${port}` } })).status).toBe(403)
  })

  it('refuses a foreign Origin, and a cross-site fetch, even with the cookie', async () => {
    const { port } = await start()
    const post = (headers: Record<string, string>) =>
      send(port, {
        method: 'POST',
        path: '/__td/invoke',
        headers: { ...cookie, 'content-type': 'application/json', ...headers },
        body: JSON.stringify({ channel: 'brand:get', args: [] }),
      })
    expect((await post({ origin: 'http://evil.example' })).status).toBe(403)
    expect((await post({ origin: 'null' })).status).toBe(403)
    expect((await post({ origin: `http://127.0.0.1:${port + 1}` })).status).toBe(403)
    expect((await post({ 'sec-fetch-site': 'cross-site' })).status).toBe(403)
    expect((await post({ origin: `http://127.0.0.1:${port}`, 'sec-fetch-site': 'same-origin' })).status).toBe(200)
  })

  it('accepts the token as a header instead of the cookie', async () => {
    const { port } = await start()
    expect((await send(port, { path: '/assets/app.js', headers: { 'x-td-token': TOKEN } })).status).toBe(200)
  })
})

describe('static files', () => {
  it('serves a file from the renderer with its content type', async () => {
    const { port } = await start()
    const reply = await send(port, { path: '/assets/app.js', headers: cookie })
    expect(reply.status).toBe(200)
    expect(reply.headers['content-type']).toBe('text/javascript; charset=utf-8')
    expect(reply.body).toBe('console.log("app")\n')
  })

  it('refuses every way out of the renderer folder', async () => {
    const { port } = await start()
    const attempts = [
      '/../secret.txt',
      '/assets/../../secret.txt',
      '/assets/%2e%2e/%2e%2e/secret.txt',
      '/assets/..%2f..%2fsecret.txt',
      '/assets/%2E%2E%5C..%5Csecret.txt',
      '/assets/link.txt',
      '/%00/etc/passwd',
      '/%E0%A4%A',
    ]
    for (const path of attempts) {
      const reply = await send(port, { path, headers: cookie })
      expect([403, 404], path).toContain(reply.status)
      expect(reply.body, path).not.toContain('outside the renderer')
    }
  })

  it('maps paths without escaping the root', () => {
    expect(staticPathFor('/r', '/assets/a.js')).toBe('/r/assets/a.js')
    expect(staticPathFor('/r', '/assets/../a.js')).toBeNull()
    expect(staticPathFor('/r', '/a%2F..%2F..%2Fb')).toBeNull()
    expect(staticPathFor('/r', '/a\\b')).toBeNull()
  })

  it('says plainly when the shim has not been built, and serves it once it has', async () => {
    const { port } = await start()
    const missing = await send(port, { path: '/__td/shim.js', headers: cookie })
    expect(missing.status).toBe(404)
    expect(missing.body).toContain('out/native-web/shim.js is missing')
    mkdirSync(join(root, 'out', 'native-web'), { recursive: true })
    writeFileSync(shimFile, 'window.__shim = true\n')
    const built = await send(port, { path: '/__td/shim.js', headers: cookie })
    expect(built.status).toBe(200)
    expect(built.headers['content-type']).toBe('text/javascript; charset=utf-8')
    expect(built.body).toBe('window.__shim = true\n')
  })

  it('puts nothing in a page with no head', () => {
    expect(injectShim('<html><body></body></html>')).toBeNull()
    expect(injectShim('<html><HEAD lang="x"><title>t</title></HEAD></html>')).toBe(
      '<html><HEAD lang="x">\n    <script src="/__td/shim.js"></script><title>t</title></HEAD></html>',
    )
  })
})

describe('calls', () => {
  function wired(): { ipcMain: TappableIpcMain; options: Partial<BridgeServerOptions> } {
    const ipcMain = fakeIpcMain()
    const registry = createHandlerRegistry()
    registry.tap(ipcMain)
    const sender = { id: 7 }
    return {
      ipcMain,
      options: {
        invoke: (channel, args) => registry.invoke(channel, { sender, senderFrame: null }, args),
        send: (channel, args) => {
          registry.send(channel, { sender, senderFrame: null }, args)
        },
      },
    }
  }

  const post = (port: number, path: string, body: unknown, headers: Record<string, string> = {}) =>
    send(port, {
      method: 'POST',
      path,
      headers: { ...cookie, 'content-type': 'application/json', ...headers },
      body: typeof body === 'string' ? body : JSON.stringify(body),
    })

  it('invokes the registered handler and answers with its value', async () => {
    const { ipcMain, options } = wired()
    let seen: unknown = null
    ipcMain.handle('echo:it', (event, ...args) => {
      seen = (event as { sender: { id: number } }).sender.id
      return { args, bytes: Buffer.from('hi'), when: undefined }
    })
    const { port } = await start(options)
    const reply = await post(port, '/__td/invoke', { channel: 'echo:it', args: [1, 'two', { $bytes: Buffer.from('in').toString('base64') }] })
    expect(reply.status).toBe(200)
    expect(JSON.parse(reply.body)).toEqual({
      ok: true,
      value: { args: [1, 'two', { $bytes: Buffer.from('in').toString('base64') }], bytes: { $bytes: Buffer.from('hi').toString('base64') } },
    })
    expect(seen).toBe(7)
  })

  it('answers a thrown error, and a channel nobody handles, as ok:false', async () => {
    const { ipcMain, options } = wired()
    ipcMain.handle('fails:always', async () => {
      throw new Error('it broke')
    })
    const { port } = await start(options)
    expect(JSON.parse((await post(port, '/__td/invoke', { channel: 'fails:always' })).body)).toEqual({ ok: false, error: 'it broke' })
    expect(JSON.parse((await post(port, '/__td/invoke', { channel: 'nobody:home', args: [] })).body)).toEqual({
      ok: false,
      error: "No handler registered for 'nobody:home'",
    })
  })

  it('refuses a body that is not JSON, not an object, too big, or names no channel', async () => {
    const { options } = wired()
    const { port } = await start({ ...options, maxBodyBytes: 64 })
    expect((await post(port, '/__td/invoke', '{"channel":"a"}', { 'content-type': 'text/plain' })).status).toBe(415)
    expect((await post(port, '/__td/invoke', 'not json')).status).toBe(400)
    expect((await post(port, '/__td/invoke', [1, 2])).status).toBe(400)
    expect((await post(port, '/__td/invoke', { channel: 'error' })).status).toBe(400)
    expect((await post(port, '/__td/invoke', { channel: 'a:b', args: 'x' })).status).toBe(400)
    expect((await post(port, '/__td/invoke', { channel: 'a:b', args: ['x'.repeat(200)] })).status).toBe(413)
  })

  it('delivers a send to the ipcMain.on listeners and answers 204', async () => {
    const { ipcMain, options } = wired()
    const heard: unknown[][] = []
    ;(ipcMain as unknown as EventEmitter).on('session:write', (event: { sender: { id: number } }, ...args: unknown[]) => {
      heard.push([event.sender.id, ...args])
    })
    const { port } = await start(options)
    const reply = await post(port, '/__td/send', { channel: 'session:write', args: ['s1', 'ls\r'] })
    expect(reply.status).toBe(204)
    expect(heard).toEqual([[7, 's1', 'ls\r']])
  })

  it('has no sendSync route, and says why', async () => {
    const { port } = await start()
    const reply = await post(port, '/__td/send-sync', { channel: 'a:b' })
    expect(reply.status).toBe(501)
    expect(JSON.parse(reply.body).error).toContain('sendSync')
  })
})

describe('the event stream', () => {
  it('delivers an emitted push as one data line, and counts the client', async () => {
    let clients = 0
    const bridge = await start({ onClient: () => clients++ })
    expect(bridge.emit('nobody:listening', [])).toBe(false)

    const received = await new Promise<string>((resolve, reject) => {
      const req = httpRequest(
        { host: '127.0.0.1', port: bridge.port, path: '/__td/events', headers: cookie },
        (res) => {
          expect(res.statusCode).toBe(200)
          expect(res.headers['content-type']).toBe('text/event-stream; charset=utf-8')
          let text = ''
          res.on('data', (chunk: Buffer) => {
            text += chunk.toString('utf8')
            if (text.includes(': connected')) {
              if (!text.includes('data:')) {
                expect(bridge.clientCount()).toBe(1)
                expect(bridge.emit('session:status', ['s1', { state: 'busy' }, Buffer.from([1, 2, 3])])).toBe(true)
              }
            }
            const line = text.split('\n').find((candidate) => candidate.startsWith('data: '))
            if (line !== undefined) {
              req.destroy()
              resolve(line)
            }
          })
        },
      )
      req.on('error', (error) => {
        if ((error as NodeJS.ErrnoException).code !== 'ECONNRESET') reject(error)
      })
      req.end()
    })

    expect(clients).toBe(1)
    expect(JSON.parse(received.slice('data: '.length))).toEqual({
      channel: 'session:status',
      args: ['s1', { state: 'busy' }, { $bytes: Buffer.from([1, 2, 3]).toString('base64') }],
    })
  })

  it('sends keep-alive comments on an idle stream', async () => {
    const bridge = await start({ keepAliveMs: 20 })
    const text = await new Promise<string>((resolve) => {
      const req = httpRequest({ host: '127.0.0.1', port: bridge.port, path: '/__td/events', headers: cookie }, (res) => {
        let buffer = ''
        res.on('data', (chunk: Buffer) => {
          buffer += chunk.toString('utf8')
          if (buffer.includes(': keep-alive')) {
            req.destroy()
            resolve(buffer)
          }
        })
      })
      req.on('error', () => undefined)
      req.end()
    })
    expect(text).toContain(': keep-alive\n\n')
  })
})

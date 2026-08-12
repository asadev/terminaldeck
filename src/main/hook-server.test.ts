import { createServer, request, type IncomingMessage } from 'node:http'
import { PassThrough } from 'node:stream'
import { afterEach, describe, expect, it } from 'vitest'
import {
  SESSION_HEADER,
  TOKEN_HEADER,
  currentHookEndpoint,
  onHookEvent,
  parseHookPath,
  readBody,
  startHookServer,
  stopHookServer,
  toHookEvent,
  type HookEndpoint,
  type HookEvent,
} from './hook-server'

/**
 * The endpoint is the one part of this feature that opens a socket, so the
 * tests are about what it refuses: a request without the token, a request with
 * a rebound Host, a path that is not a hook route. Each is driven over a real
 * loopback connection rather than by calling the handler directly — a check
 * that only holds when you call the function the right way is not a check.
 */

let live: HookEndpoint | null = null

afterEach(async () => {
  await stopHookServer()
  live = null
})

async function start(onEvent?: (event: HookEvent) => void): Promise<HookEndpoint> {
  live = await startHookServer(onEvent ? { onEvent } : {})
  return live
}

interface PostOptions {
  token?: string
  host?: string
  method?: string
  path?: string
  body?: string
  sessionId?: string
}

/**
 * Raw http.request rather than fetch: `Host` is a forbidden header for fetch,
 * which silently rewrites it — so the rebinding test would pass against a
 * server that had no Host check at all.
 */
function post(endpoint: HookEndpoint, options: PostOptions = {}): Promise<number> {
  const headers: Record<string, string> = { 'content-type': 'application/json' }
  headers[TOKEN_HEADER] = options.token ?? endpoint.token
  if (options.sessionId) headers[SESSION_HEADER] = options.sessionId
  if (options.host) headers.host = options.host

  return new Promise((resolve, reject) => {
    const req = request(
      {
        host: '127.0.0.1',
        port: endpoint.port,
        method: options.method ?? 'POST',
        path: options.path ?? '/hook/claude/Stop',
        headers,
      },
      (res) => {
        res.resume()
        res.on('end', () => resolve(res.statusCode ?? 0))
      },
    )
    req.on('error', reject)
    if ((options.method ?? 'POST') !== 'GET') req.write(options.body ?? '{}')
    req.end()
  })
}

/** Give the emit a tick to land before asserting on it. */
const settle = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 10))

describe('parseHookPath', () => {
  it('accepts only /hook/<provider>/<event>', () => {
    expect(parseHookPath('/hook/claude/Stop')).toEqual({ provider: 'claude', event: 'Stop' })
    expect(parseHookPath('/hook/claude/Stop?x=1')).toEqual({ provider: 'claude', event: 'Stop' })
    expect(parseHookPath('/hook/claude')).toBe(null)
    expect(parseHookPath('/hook/claude/Stop/extra')).toBe(null)
    expect(parseHookPath('/../../etc/passwd')).toBe(null)
    expect(parseHookPath(undefined)).toBe(null)
  })
})

describe('toHookEvent', () => {
  it('pulls the fields the app uses out of a real-shaped payload', () => {
    const event = toHookEvent(
      'claude',
      'PostToolUse',
      'pawl-session-1',
      JSON.stringify({
        session_id: 'abc-123',
        transcript_path: '/Users/a/.claude/projects/x.jsonl',
        cwd: '/Users/a/Projects/pawl',
        tool_name: 'Edit',
      }),
    )
    expect(event.cliSessionId).toBe('abc-123')
    expect(event.sessionId).toBe('pawl-session-1')
    expect(event.cwd).toBe('/Users/a/Projects/pawl')
    expect(event.toolName).toBe('Edit')
  })

  it('still reports the event when the body is not JSON', () => {
    const event = toHookEvent('codex', 'Stop', null, 'not json')
    expect(event.event).toBe('Stop')
    expect(event.payload).toEqual({})
    expect(event.cliSessionId).toBe(null)
  })
})

describe('readBody', () => {
  /** A stream that behaves like an IncomingMessage for the parts readBody uses. */
  function fakeRequest(): PassThrough & IncomingMessage {
    return new PassThrough() as unknown as PassThrough & IncomingMessage
  }

  it('resolves with the body it was given', async () => {
    const req = fakeRequest()
    const body = readBody(req)
    req.end('{"a":1}')
    await expect(body).resolves.toBe('{"a":1}')
  })

  /**
   * The failure this guards is a hang, not a wrong answer: the handler awaits
   * this promise while holding the socket the CLI is blocked on, so a close
   * that never settles it is a hook that never returns.
   */
  it('settles when the caller disappears mid-body', async () => {
    const req = fakeRequest()
    const body = readBody(req)
    req.write('{"hal')
    req.destroy()
    await expect(body).rejects.toThrow(/closed before/)
  })

  it('rejects a body over the cap without buffering the rest of it', async () => {
    const req = fakeRequest()
    const body = readBody(req)
    req.write('x'.repeat(1024 * 1024 + 1))
    await expect(body).rejects.toThrow(/too large/)
    // Still writable: the connection survives long enough to be told 413.
    expect(req.destroyed).toBe(false)
    req.end('x'.repeat(1024))
  })

  /**
   * A request can error after we have already answered it. If readBody had
   * unsubscribed on settling, that error would land on a stream with no
   * listener, and an unhandled stream error ends the main process.
   */
  it('absorbs an error that arrives after it has already settled', async () => {
    const req = fakeRequest()
    const body = readBody(req)
    req.end('{}')
    await expect(body).resolves.toBe('{}')

    expect(req.listenerCount('error')).toBeGreaterThan(0)
    expect(() => req.emit('error', new Error('late reset'))).not.toThrow()
  })
})

describe('the endpoint', () => {
  it('listens on loopback and reports its port', async () => {
    const endpoint = await start()
    expect(endpoint.port).toBeGreaterThan(0)
    expect(currentHookEndpoint()).toEqual(endpoint)
  })

  it('mints a fresh token every run', async () => {
    const first = (await start()).token
    await stopHookServer()
    const second = (await start()).token
    expect(second).not.toBe(first)
    expect(second).toMatch(/^[0-9a-f]{48}$/)
  })

  it('forgets the endpoint when stopped, so nothing can post into a dead run', async () => {
    await start()
    await stopHookServer()
    expect(currentHookEndpoint()).toBe(null)
  })

  it('accepts a tagged event and hands it to listeners', async () => {
    const seen: HookEvent[] = []
    const endpoint = await start((event) => seen.push(event))

    const status = await post(endpoint, {
      path: '/hook/claude/PostToolUse',
      sessionId: 'session-7',
      body: JSON.stringify({ session_id: 'cli-9', tool_name: 'Bash' }),
    })
    await settle()

    expect(status).toBe(204)
    expect(seen).toHaveLength(1)
    expect(seen[0]).toMatchObject({
      provider: 'claude',
      event: 'PostToolUse',
      sessionId: 'session-7',
      cliSessionId: 'cli-9',
      toolName: 'Bash',
    })
  })

  it('rejects a request with no token, a wrong token, or a token of another length', async () => {
    const seen: HookEvent[] = []
    const endpoint = await start((event) => seen.push(event))

    expect(await post(endpoint, { token: '' })).toBe(403)
    expect(await post(endpoint, { token: 'b'.repeat(endpoint.token.length) })).toBe(403)
    expect(await post(endpoint, { token: 'short' })).toBe(403)
    await settle()
    expect(seen).toHaveLength(0)
  })

  it('rejects a Host that is not loopback, which is what DNS rebinding produces', async () => {
    const endpoint = await start()
    expect(await post(endpoint, { host: 'evil.example.com' })).toBe(403)
  })

  it('rejects anything that is not a POST to a hook route', async () => {
    const endpoint = await start()
    expect(await post(endpoint, { method: 'GET' })).toBe(405)
    expect(await post(endpoint, { path: '/' })).toBe(404)
    expect(await post(endpoint, { path: '/hook/claude/Stop/extra' })).toBe(404)
  })

  it('keeps serving after a listener throws', async () => {
    const endpoint = await start(() => {
      throw new Error('subscriber is broken')
    })
    expect(await post(endpoint)).toBe(204)
    expect(await post(endpoint)).toBe(204)
  })

  /**
   * `startHookServer` awaits `listen`, so two callers arriving before it
   * resolved each used to build a server. The second overwrote the first in the
   * module state and the first stayed bound to its port for the life of the
   * process — invisible, unstoppable, and holding a socket that hooks from a
   * previous install could still reach.
   */
  it('gives two racing callers the same server, not two', async () => {
    const [first, second] = await Promise.all([startHookServer(), startHookServer()])
    expect(second.port).toBe(first.port)
    expect(second.token).toBe(first.token)

    await stopHookServer()

    // If a second server had been started, its port would still accept.
    const refused = await new Promise<string>((resolve) => {
      const req = request({ host: '127.0.0.1', port: first.port, method: 'POST', path: '/hook/a/b' })
      req.on('error', (error) => resolve((error as NodeJS.ErrnoException).code ?? 'error'))
      req.on('response', (res) => {
        res.resume()
        resolve(`answered:${res.statusCode}`)
      })
      req.end('{}')
    })
    expect(refused).toBe('ECONNREFUSED')
  })

  it('can still start after a failed bind', async () => {
    // Occupy a port, then ask the endpoint for that exact one.
    const blocker = createServer()
    const taken = await new Promise<number>((resolve) => {
      blocker.listen(0, '127.0.0.1', () => resolve((blocker.address() as { port: number }).port))
    })

    await expect(startHookServer({ port: taken })).rejects.toThrow()
    expect(currentHookEndpoint()).toBe(null)

    // The failed attempt must not have poisoned the module state.
    const endpoint = await startHookServer()
    expect(endpoint.port).toBeGreaterThan(0)

    await new Promise<void>((resolve) => blocker.close(() => resolve()))
  })

  it('answers an oversized body with 413 instead of dropping the connection', async () => {
    const seen: HookEvent[] = []
    const endpoint = await start((event) => seen.push(event))

    const outcome = await new Promise<string>((resolve) => {
      const req = request(
        {
          host: '127.0.0.1',
          port: endpoint.port,
          method: 'POST',
          path: '/hook/claude/Stop',
          headers: { [TOKEN_HEADER]: endpoint.token },
        },
        (res) => {
          res.resume()
          res.on('end', () => resolve(String(res.statusCode)))
        },
      )
      req.on('error', (error) => resolve(`error:${(error as NodeJS.ErrnoException).code}`))
      req.end('x'.repeat(2 * 1024 * 1024))
    })

    expect(outcome).toBe('413')
    await settle()
    // Nothing oversized reaches the app.
    expect(seen).toHaveLength(0)
    // And the endpoint is still serving.
    expect(await post(endpoint)).toBe(204)
  })

  it('lets a subscriber unsubscribe', async () => {
    const seen: HookEvent[] = []
    const endpoint = await start()
    const off = onHookEvent((event) => seen.push(event))

    await post(endpoint)
    await settle()
    off()
    await post(endpoint)
    await settle()

    expect(seen).toHaveLength(1)
  })
})

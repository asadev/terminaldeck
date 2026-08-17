import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { request, type IncomingMessage } from 'node:http'
import { createServer as createSocketServer } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { PassThrough } from 'node:stream'
import { afterEach, describe, expect, it } from 'vitest'
import { ownPorts, resetOwnPortsForTests } from './own-ports'
import {
  CONFIG_FILE,
  SESSION_HEADER,
  TOKEN_HEADER,
  currentHookEndpoint,
  hostIsLocal,
  onHookEvent,
  parseHookPath,
  readBody,
  SOCKET_FILE,
  startHookServer,
  stopHookServer,
  toHookEvent,
  type HookEndpoint,
  type HookEvent,
} from './hook-server'

/**
 * The endpoint is the one part of this feature that opens a socket, so the
 * tests are about what it refuses: a request without the token, a request that
 * addresses somebody else, a path that is not a hook route. Each is driven over
 * a real connection rather than by calling the handler directly — a check that
 * only holds when you call the function the right way is not a check.
 *
 * The address is a unix socket now, and the tests that matter most are the two
 * that pin *why*: the endpoint keeps the same address across a restart, and it
 * binds no TCP port at all. Both of those are the fix for hooks going stale on
 * every launch, and both are the kind of property that is quietly undone by a
 * later "let's just bind a port, it is simpler" change.
 */

let live: HookEndpoint | null = null
const dirs: string[] = []

/** A short-lived directory per test, so two tests never share a socket path. */
function scratch(): string {
  const dir = mkdtempSync(join(tmpdir(), 'td-hook-'))
  dirs.push(dir)
  return dir
}

afterEach(async () => {
  await stopHookServer()
  live = null
  while (dirs.length > 0) rmSync(dirs.pop() as string, { recursive: true, force: true })
})

async function start(onEvent?: (event: HookEvent) => void, dir = scratch()): Promise<HookEndpoint> {
  live = await startHookServer(onEvent ? { onEvent, dir } : { dir })
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
 * Raw http.request over the socket rather than fetch: `Host` is a forbidden
 * header for fetch, which silently rewrites it — so the Host test would pass
 * against a server that had no Host check at all. `fetch` also cannot address a
 * unix socket, which is itself one of the properties being relied on.
 */
function post(endpoint: HookEndpoint, options: PostOptions = {}): Promise<number> {
  const headers: Record<string, string> = { 'content-type': 'application/json' }
  headers[TOKEN_HEADER] = options.token ?? endpoint.token
  if (options.sessionId) headers[SESSION_HEADER] = options.sessionId
  if (options.host) headers.host = options.host

  return new Promise((resolve, reject) => {
    const req = request(
      {
        socketPath: endpoint.socketPath,
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
      'terminaldeck-session-1',
      JSON.stringify({
        session_id: 'abc-123',
        transcript_path: '/Users/a/.claude/projects/x.jsonl',
        cwd: '/Users/a/Projects/terminaldeck',
        tool_name: 'Edit',
      }),
    )
    expect(event.cliSessionId).toBe('abc-123')
    expect(event.sessionId).toBe('terminaldeck-session-1')
    expect(event.cwd).toBe('/Users/a/Projects/terminaldeck')
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

describe('hostIsLocal', () => {
  it('accepts a loopback name with or without a port and refuses anything else', () => {
    expect(hostIsLocal('localhost')).toBe(true)
    expect(hostIsLocal('localhost:80')).toBe(true)
    expect(hostIsLocal('127.0.0.1')).toBe(true)
    expect(hostIsLocal('[::1]:8080')).toBe(true)
    expect(hostIsLocal('evil.example.com')).toBe(false)
    expect(hostIsLocal(undefined)).toBe(false)
  })
})

describe('the endpoint', () => {
  it('listens on a socket inside the directory it was given', async () => {
    const dir = scratch()
    const endpoint = await start(undefined, dir)
    expect(endpoint.socketPath).toBe(join(dir, SOCKET_FILE))
    expect(endpoint.configPath).toBe(join(dir, CONFIG_FILE))
    expect(currentHookEndpoint()).toEqual(endpoint)
  })

  /**
   * The defect this whole change exists to fix, stated as an assertion.
   *
   * The address used to be an ephemeral port, so every restart moved it and
   * every hook already written into `~/.claude/settings.json` pointed at a
   * socket that no longer existed. All three providers reported "Needs
   * reinstalling" on every launch, forever, and a user who did not press it got
   * no session-finished events at all. A test that only checked "it starts"
   * passed the entire time.
   */
  it('comes back on the same address after a restart', async () => {
    const dir = scratch()
    const first = await start(undefined, dir)
    await stopHookServer()
    const second = await start(undefined, dir)
    expect(second.socketPath).toBe(first.socketPath)
    expect(second.configPath).toBe(first.configPath)
  })

  /**
   * No port, and the absence is the feature.
   *
   * A unix socket cannot be reached from a network stack, so there is nothing
   * for `remote/tunnel.ts` to offer a phone by accident, nothing for a page in
   * a browser to address, and no number the kernel can hand to somebody else
   * once we let go of it. `own-ports.ts` exists to keep this app's own loopback
   * listeners out of a phone's port list; an empty registry after the endpoint
   * has started is the machine-checkable form of "it has no port to keep out".
   */
  it('binds no TCP port at all', async () => {
    resetOwnPortsForTests()
    const endpoint = await start()
    expect(existsSync(endpoint.socketPath)).toBe(true)
    expect(ownPorts()).toEqual([])
  })

  it('mints a fresh token every run and keeps it out of world-readable files', async () => {
    const dir = scratch()
    const first = await start(undefined, dir)
    const firstToken = first.token
    await stopHookServer()

    // Gone with the run it belonged to, so a hook firing at a closed app has no
    // credential to present to whatever binds that path next.
    expect(existsSync(first.configPath)).toBe(false)

    const second = await start(undefined, dir)
    expect(second.token).not.toBe(firstToken)
    expect(second.token).toMatch(/^[0-9a-f]{48}$/)

    // The config curl reads at call time: this run's token, owner-only.
    const config = readFileSync(second.configPath, 'utf8')
    expect(config).toContain(`${TOKEN_HEADER}: ${second.token}`)
    expect(config).toContain(`unix-socket = "${second.socketPath}"`)
    expect(statSync(second.configPath).mode & 0o777).toBe(0o600)
    expect(statSync(second.socketPath).mode & 0o777).toBe(0o600)
  })

  /**
   * A crash leaves the socket file behind, and the next launch has to survive it
   * — otherwise one hard quit costs the user their hooks until they find and
   * delete a file nobody has told them about.
   */
  it('clears a dead file left at the socket path and binds anyway', async () => {
    const dir = scratch()
    writeFileSync(join(dir, SOCKET_FILE), 'left behind by a crash')

    const endpoint = await startHookServer({ dir })
    expect(endpoint.socketPath).toBe(join(dir, SOCKET_FILE))
    expect(await post(endpoint)).toBe(204)
  })

  /**
   * The other half of the same decision, and the one that must not be "helpful".
   *
   * Unlinking a socket somebody is actively serving would not stop them serving
   * it — their listener holds the open inode — but it *would* silently take
   * every hook on the machine away from them. So a live socket is a refusal,
   * with the reason in the message, and the second copy's Settings pane is left
   * able to say what happened.
   */
  it('refuses to take a socket another copy is still serving', async () => {
    const dir = scratch()
    const other = createSocketServer()
    await new Promise<void>((resolve) => other.listen(join(dir, SOCKET_FILE), () => resolve()))

    await expect(startHookServer({ dir })).rejects.toThrow(/another copy/)
    expect(currentHookEndpoint()).toBe(null)

    await new Promise<void>((resolve) => other.close(() => resolve()))
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

  it('rejects a request addressed to somebody else', async () => {
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
   * module state and the first stayed bound for the life of the process —
   * invisible, unstoppable, and holding a socket that hooks from a previous
   * install could still reach.
   */
  it('gives two racing callers the same server, not two', async () => {
    const dir = scratch()
    const [first, second] = await Promise.all([startHookServer({ dir }), startHookServer({ dir })])
    expect(second.socketPath).toBe(first.socketPath)
    expect(second.token).toBe(first.token)

    await stopHookServer()

    // If a second server had been started, the path would still answer.
    const refused = await new Promise<string>((resolve) => {
      const req = request({ socketPath: first.socketPath, method: 'POST', path: '/hook/a/b' })
      req.on('error', (error) => resolve((error as NodeJS.ErrnoException).code ?? 'error'))
      req.on('response', (res) => {
        res.resume()
        resolve(`answered:${res.statusCode}`)
      })
      req.end('{}')
    })
    expect(refused).toMatch(/ENOENT|ECONNREFUSED/)
  })

  it('can still start after a failed bind', async () => {
    // A directory that cannot be created, because a regular file is in its way.
    const parent = scratch()
    writeFileSync(join(parent, 'in-the-way'), 'not a directory')
    const dir = join(parent, 'in-the-way', 'below-it')

    await expect(startHookServer({ dir })).rejects.toThrow()
    expect(currentHookEndpoint()).toBe(null)

    // The failed attempt must not have poisoned the module state.
    const endpoint = await startHookServer({ dir: scratch() })
    expect(existsSync(endpoint.socketPath)).toBe(true)
  })

  it('answers an oversized body with 413 instead of dropping the connection', async () => {
    const seen: HookEvent[] = []
    const endpoint = await start((event) => seen.push(event))

    const outcome = await new Promise<string>((resolve) => {
      const req = request(
        {
          socketPath: endpoint.socketPath,
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

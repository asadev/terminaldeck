import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { request, type IncomingMessage } from 'node:http'
import { createServer as createSocketServer } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { PassThrough } from 'node:stream'
import { afterEach, describe, expect, it } from 'vitest'
import { BRAND } from '../shared/brand'
import { ownPorts, resetOwnPortsForTests } from './own-ports'
import {
  CONFIG_FILE,
  SESSION_HEADER,
  TOKEN_HEADER,
  WINDOWS_CLIENT_FILE,
  WINDOWS_CONFIG_FILE,
  currentHookEndpoint,
  endpointDir,
  hookAddress,
  hookClientPath,
  hookConfigPath,
  hostIsLocal,
  onHookEvent,
  parseHookPath,
  readBody,
  startHookServer,
  stopHookServer,
  toHookEvent,
  windowsClientScript,
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
 * The address is a name rather than a port now, and the tests that matter most
 * are the two that pin *why*: the endpoint keeps the same address across a
 * restart, and it binds no TCP port at all. Both of those are the fix for hooks
 * going stale on every launch, and both are the kind of property that is
 * quietly undone by a later "let's just bind a port, it is simpler" change.
 *
 * Everything below is written in whichever spelling the machine running it
 * uses, through {@link hookAddress} — a unix socket path on POSIX, a named pipe
 * on Windows. `join(dir, SOCKET_FILE)` used to be written out by hand here, and
 * that is exactly what made every one of these fail on Windows with `EACCES`:
 * libuv maps `listen(path)` to a named pipe there, and a filename is not a pipe
 * name. The spelling now lives in one function, and {@link describe} below pins
 * both of them from either platform.
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

/**
 * Both spellings of the address, from whichever machine this runs on.
 *
 * The Windows half of this module cannot be *bound* from a Mac, but every
 * decision in it is a string decision and every one of them is reachable here.
 * That matters more than usual: the unix socket shipped a whole night's work
 * that had never run on Windows, and the way it failed — `EACCES` from
 * `listen`, with no mention of pipes anywhere — is not a failure anybody reads
 * correctly the first time.
 */
describe('the address, in both spellings', () => {
  it('is a path inside the endpoint’s own directory on POSIX', () => {
    expect(hookAddress('/data', 'darwin')).toBe('/data/hook/hook.sock')
    expect(hookConfigPath('/data', 'darwin')).toBe('/data/hook/hook-endpoint.conf')
    // Nothing to run: curl is already installed and already speaks unix sockets.
    expect(hookClientPath('/data', 'darwin')).toBe(null)
  })

  it('is a named pipe on Windows, because there is no socket file to be', () => {
    const address = hookAddress('C:\\Users\\asad\\AppData\\Roaming\\terminaldeck', 'win32')
    expect(address.startsWith('\\\\.\\pipe\\terminaldeck-hook-')).toBe(true)
    // A pipe name is not a path: it does not contain the directory, and it does
    // not grow with it.
    expect(address).not.toContain('AppData')
    expect(address.length).toBeLessThan(60)
  })

  it('gives every data directory its own pipe, because the namespace is one', () => {
    /*
     * The failure this prevents is two copies of the app fighting over one
     * name, which on POSIX cannot happen — two data directories are two paths.
     * The pipe namespace is machine-wide, so a fixed name would put a dev
     * build, a packaged build and a second Windows account into a contest, and
     * the loser is refused the endpoint entirely.
     */
    const packaged = hookAddress('C:\\Users\\asad\\AppData\\Roaming\\terminaldeck', 'win32')
    const dev = hookAddress('C:\\Users\\asad\\scratch\\terminaldeck', 'win32')
    const other = hookAddress('C:\\Users\\imza\\AppData\\Roaming\\terminaldeck', 'win32')
    expect(new Set([packaged, dev, other]).size).toBe(3)
  })

  it('is the same pipe next week, and the same one however the path is cased', () => {
    // Stability is the whole feature — a name that moved would be the port
    // problem again with a different spelling. Case-folded because Windows
    // paths are case-insensitive, so one directory must not produce two names.
    expect(hookAddress('C:\\Users\\asad\\x', 'win32')).toBe(hookAddress('C:\\Users\\asad\\x', 'win32'))
    expect(hookAddress('C:\\Users\\asad\\x', 'win32')).toBe(hookAddress('c:\\users\\ASAD\\x', 'win32'))
  })

  it('keeps the Windows client beside the config it reads', () => {
    const dir = 'C:\\Users\\asad\\AppData\\Roaming\\terminaldeck'
    expect(hookConfigPath(dir, 'win32')).toBe(`${dir}\\hook\\hook-endpoint.json`)
    expect(hookClientPath(dir, 'win32')).toBe(`${dir}\\hook\\hook-post.ps1`)
  })
})

/**
 * The generated client, checked for the four things it exists to do.
 *
 * It is generated rather than shipped because every name in it comes from
 * `BRAND`; a `.ps1` asset holding its own copy of the two header names and the
 * session variable is three spellings of the brand that go stale silently.
 */
describe('the Windows client', () => {
  const script = windowsClientScript()

  it('reads stdin, and reads it before anything can make it exit', () => {
    // A client that exits without draining stdin leaves the CLI writing into a
    // closed pipe, which Claude reports as an EPIPE hook failure. The
    // no-config early return therefore comes *after* the read.
    const read = script.indexOf('ReadToEnd()')
    const bail = script.indexOf('Test-Path')
    expect(read).toBeGreaterThan(-1)
    expect(bail).toBeGreaterThan(read)
  })

  it('always exits 0, so a hook can never fail somebody’s turn', () => {
    expect(script.trimEnd().endsWith('exit 0')).toBe(true)
    expect(script).toContain('} catch {')
  })

  it('carries the header names and the session variable from BRAND', () => {
    expect(script).toContain(`${TOKEN_HEADER}: $($config.token)`)
    expect(script).toContain(`${SESSION_HEADER}: $($env:${BRAND.sessionEnvVar})`)
    // No secret of its own: the token comes out of the config at call time,
    // which is what lets one command string survive every restart.
    expect(script).not.toContain('token = ')
  })

  it('turns the pipe path the config records into the name .NET wants', () => {
    // `NamedPipeClientStream` takes the name, not the `\\.\pipe\` path the
    // server binds — passing the path produces `\\.\pipe\\\.\pipe\name`, which
    // times out rather than failing, and looks exactly like a server that is
    // not there. Measured, once, the hard way.
    expect(script).toContain('NamedPipeClientStream')
    expect(script).toContain('-replace')
  })
})

describe('the endpoint', () => {
  it('listens on the address this platform spells for the directory it was given', async () => {
    const dir = scratch()
    const endpoint = await start(undefined, dir)
    expect(endpoint.socketPath).toBe(hookAddress(dir))
    expect(endpoint.configPath).toBe(hookConfigPath(dir))
    expect(endpoint.clientPath).toBe(hookClientPath(dir))
    expect(currentHookEndpoint()).toEqual(endpoint)
  })

  /**
   * The Windows client exists exactly where Windows needs one and nowhere else.
   *
   * A `null` here on Windows is a hook command that silently falls back to the
   * POSIX form — `/usr/bin/curl`, a path that platform does not have — and a
   * non-null one on POSIX is a script nothing runs. `hooks.ts` chooses the
   * command shape on this field, so it is the field that decides whether
   * Windows hooks work at all.
   */
  it('writes a client script on Windows and none on POSIX', async () => {
    const dir = scratch()
    const endpoint = await start(undefined, dir)
    if (process.platform === 'win32') {
      expect(endpoint.clientPath).toBe(join(endpointDir(dir), WINDOWS_CLIENT_FILE))
      expect(readFileSync(endpoint.clientPath as string, 'utf8')).toBe(windowsClientScript())
      expect(endpoint.configPath.endsWith(WINDOWS_CONFIG_FILE)).toBe(true)
      // The token is what the client reads at call time; the pipe name is how
      // it finds the app.
      const config = JSON.parse(readFileSync(endpoint.configPath, 'utf8')) as Record<string, string>
      expect(config).toEqual({ pipe: endpoint.socketPath, token: endpoint.token })
    } else {
      expect(endpoint.clientPath).toBe(null)
      expect(endpoint.configPath.endsWith(CONFIG_FILE)).toBe(true)
    }
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

    // The file the client reads at call time carries this run's token. Its
    // *shape* is the case above — a curl config here, JSON on Windows, where a
    // backslash in a path is escaped and a raw `toContain` would be comparing
    // one spelling against the other.
    const config = readFileSync(second.configPath, 'utf8')
    expect(config).toContain(second.token)

    /*
     * "Owner-only", on the platform where a mode means that.
     *
     * Windows is not softened here, it is answered elsewhere: the mode is
     * synthesised there, `stat` on a pipe name answers EBUSY, and what protects
     * the config is the `icacls` grant `writeSecretFile` applies — which
     * `remote/secret-file.test.ts` checks against the real tool on the real OS.
     */
    if (process.platform !== 'win32') {
      expect(config).toContain(`${TOKEN_HEADER}: ${second.token}`)
      expect(config).toContain(`unix-socket = "${second.socketPath}"`)
      expect(statSync(second.configPath).mode & 0o777).toBe(0o600)
      expect(statSync(second.socketPath).mode & 0o777).toBe(0o600)
    }
  })

  /**
   * A crash leaves the socket file behind, and the next launch has to survive it
   * — otherwise one hard quit costs the user their hooks until they find and
   * delete a file nobody has told them about.
   */
  it.skipIf(process.platform === 'win32')(
    'clears a dead file left at the socket path and binds anyway',
    async () => {
      // Windows is skipped and the skip is a fact rather than a gap: a named
      // pipe exists only while a process serves it, so a crash leaves nothing
      // at the address to clear. The half of `clearStaleSocket` that *is* real
      // there — a live copy — is the case below.
      const dir = scratch()
      mkdirSync(endpointDir(dir), { recursive: true })
      writeFileSync(hookAddress(dir), 'left behind by a crash')

      const endpoint = await startHookServer({ dir })
      expect(endpoint.socketPath).toBe(hookAddress(dir))
      expect(await post(endpoint)).toBe(204)
    },
  )

  /**
   * The other half of the same decision, and the one that must not be "helpful".
   *
   * Unlinking a socket somebody is actively serving would not stop them serving
   * it — their listener holds the open inode — but it *would* silently take
   * every hook on the machine away from them. So a live socket is a refusal,
   * with the reason in the message, and the second copy's Settings pane is left
   * able to say what happened.
   */
  it('refuses to take an address another copy is still serving', async () => {
    // The same refusal reached two ways: on POSIX by probing a socket file that
    // answers, on Windows by libuv's `FILE_FLAG_FIRST_PIPE_INSTANCE` turning a
    // second bind into EADDRINUSE. Both must end at the same sentence, because
    // it is the sentence the Settings pane shows.
    const dir = scratch()
    mkdirSync(endpointDir(dir), { recursive: true })
    const other = createSocketServer()
    await new Promise<void>((resolve) => other.listen(hookAddress(dir), () => resolve()))

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

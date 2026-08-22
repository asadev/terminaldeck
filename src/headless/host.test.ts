import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { request } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { contextDir, INDEX_FILE } from '../main/app-context'
import { attach } from '../main/browser-binding'
import {
  currentHookEndpoint,
  SESSION_HEADER,
  TOKEN_HEADER,
  type HookEndpoint,
} from '../main/hook-server'
import { installPaths, nodePaths, resetPaths } from '../main/platform/paths'
import type { RemovalReason } from '../main/pty-manager'
import {
  createRemoteEndpoint,
  REMOTE_CONNECTIONS_CHANNEL,
  type RemoteEndpoint,
  type RemoteEndpointOptions,
  type RemoteWire,
  type SessionAccess,
  type SessionHandle,
} from '../main/remote/server'
import {
  PROTOCOL_VERSION,
  serialize,
  type ClientMessage,
  type RemoteSession,
  type ServerMessage,
} from '../main/remote/protocol'
import { store } from '../main/store'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import { currentEndpoint } from '../main/deck-control/server'
import { createHeadlessHost, type HeadlessHost } from './host'

/**
 * The headless host, started for real, under plain Node.
 *
 * This is the test that matters. Everything else in this folder checks a
 * function; this one checks the claim — that the core runs with no Electron
 * anywhere near it. Vitest is a Node process with no `app`, no `ipcMain` and no
 * BrowserWindow, so a single Electron import anywhere in the graph would make
 * this file fail to import rather than fail an assertion.
 *
 * What it deliberately does not do is touch the network. `relayEnabled: false`
 * keeps it off the public relay and `readTailnet` is pinned to "signed out", so
 * the host comes up, refuses to serve, and says why — which is itself one of the
 * states `status` has to be able to describe.
 */

let dir = ''
let host: HeadlessHost

beforeAll(async () => {
  dir = mkdtempSync(join(tmpdir(), 'td-headless-'))
  // The same provider the daemon installs, pointed at a temp home so nothing
  // here can read or write the real state directory on this Mac.
  installPaths(nodePaths({ platform: 'linux', env: { XDG_DATA_HOME: dir }, home: dir, appRoot: dir }))
  host = await createHeadlessHost({
    storageDir: dir,
    relayEnabled: false,
    readTailnet: async () => ({
      ready: false,
      state: 'logged-out',
      reason: 'This machine is signed out of Tailscale.',
    }),
    serve: {
      on: async () => ({ ok: false, message: 'not in a test' }),
      off: async () => undefined,
    },
  })
}, 30_000)

afterAll(async () => {
  await host.stop()
  resetPaths()
  rmSync(dir, { recursive: true, force: true })
})

describe('it starts with no Electron in the process', () => {
  it('registers the same channels the desktop registers', () => {
    // Not a stub of pairing, not a headless-only copy: these are the handler
    // bodies `registerRemoteIpc` installs, and the CLI calls them by the names
    // the preload uses.
    const channels = host.desk.channels()
    for (const channel of [
      'remote:status',
      'remote:pair',
      'remote:devices',
      'remote:device:approve',
      'remote:folders',
      'remote:folders:set',
    ]) {
      expect(channels).toContain(channel)
    }
  })

  it('answers remote:status with a reason rather than pretending to serve', async () => {
    const status = await host.status()
    expect(status.remote.running).toBe(false)
    expect(status.remote.reason ?? status.remote.directReason).toBeTruthy()
  })
})

describe('a session started on this host can drive this host’s browser', () => {
  /*
   * The wiring, asserted against a host that really started.
   *
   * `session-drives-server-browser.test.ts` proves what the endpoint *does* by
   * rebuilding the four-line assembly by hand against a fake Chromium. This
   * proves the thing that assembly cannot: that `createHeadlessHost` actually
   * performs it. The failure it is here to catch is the one this repository
   * keeps re-finding — every layer green and nobody calling the top one, which
   * is exactly how remote access shipped three times without ever dialling.
   */
  it('has a tool endpoint listening on its own loopback', () => {
    const endpoint = currentEndpoint()
    expect(endpoint, 'the headless host started deck-control’s MCP server').not.toBeNull()
    expect(endpoint?.port).toBeGreaterThan(0)
    expect(endpoint?.url).toContain(`127.0.0.1:${endpoint?.port}`)
  })

  it('answers MCP on it rather than merely holding the port open', async () => {
    /*
     * A listening socket is not a tool server. This asks the endpoint the
     * question a session's CLI asks first, over the real transport, with the
     * run's own token — and the answer has to be the browser verbs, because
     * that is the whole of what a session here is granted.
     *
     * `token` is the local attended one this run minted; a session's own token
     * is narrower still, and `session-drives-server-browser.test.ts` proves the
     * narrowing. What is proved here is that the thing this host started is the
     * dispatcher, on this host, with the drive under it.
     */
    const endpoint = currentEndpoint()
    expect(endpoint).not.toBeNull()
    const client = new Client({ name: 'headless-test', version: '0.0.0' }, { capabilities: {} })
    await client.connect(
      new StreamableHTTPClientTransport(new URL((endpoint as { url: string }).url), {
        requestInit: { headers: { Authorization: `Bearer ${(endpoint as { token: string }).token}` } },
      }),
    )
    try {
      const names = (await client.listTools()).tools.map((tool) => tool.name)
      expect(names).toContain('browser_open')
      expect(names).toContain('browser_read')
    } finally {
      await client.close()
    }
  })
})

describe('pairing is the desktop mechanism, not a second one', () => {
  it('mints a code of the same alphabet and shape the app shows', async () => {
    const minted = (await host.invoke('remote:pair')) as { token: string; expiresAt: number }
    // Six digits from `shared/short-code.ts`, with no grouping character,
    // because that is the form every screen shows. A headless build with its
    // own code format would be a second thing for a phone to be wrong about.
    expect(minted.token).toMatch(/^[0-9]{6}$/)
    expect(minted.expiresAt).toBeGreaterThan(Date.now())
  })

  it('starts with no devices and no grants', async () => {
    expect(await host.invoke('remote:devices')).toEqual([])
    expect(await host.invoke('remote:folders')).toEqual([])
  })

  it('writes a grant through the same handler the settings panel uses', async () => {
    const written = (await host.invoke('remote:folders:set', 'device-1', [dir])) as Array<{
      deviceId: string
      folders: string[]
    }>
    expect(written).toEqual([{ deviceId: 'device-1', folders: [dir] }])
    expect(await host.invoke('remote:folders')).toEqual(written)
  })
})

describe('idle mode', () => {
  it('starts idle, holding only the relay connection', async () => {
    const status = await host.status()
    expect(status.idle.mode).toBe('idle')
    expect(status.idle.attached).toBe(0)
    expect(status.idle.holding).toEqual(['relay connection'])
    expect(status.idle.stopped).toContain('session status detection')
    expect(status.idle.stopped).toContain('localhost port scan cache')
  })

  it('wakes when a device attaches and idles again when the last one leaves', async () => {
    /*
     * Driven through the connections broadcast, which is the event the server
     * already fires — not through a method this test reaches for. If idle mode
     * were wired to anything else, this would pass while the real host never
     * woke.
     */
    host.broadcast(REMOTE_CONNECTIONS_CHANNEL, [{}, {}])
    expect((await host.status()).idle.mode).toBe('awake')
    expect((await host.status()).idle.stopped).toEqual([])

    host.broadcast(REMOTE_CONNECTIONS_CHANNEL, [])
    expect((await host.status()).idle.mode).toBe('idle')
  })

  it('ignores every other channel it is handed', async () => {
    // `broadcast` is the shell's whole outbound surface, and the endpoint pushes
    // more than one thing down it. Only the connection list may move idle mode.
    host.broadcast('remote:something-else', [{}, {}, {}])
    expect((await host.status()).idle.attached).toBe(0)
  })

  it('names what it never had rather than claiming to have stopped it', async () => {
    // The specification lists six things to stop and this build only ever ran
    // three. Silence about the other three is indistinguishable from forgetting
    // them.
    const status = await host.status()
    expect(status.neverRunning.join(' ')).toContain('usage polling')
    expect(status.neverRunning.join(' ')).toContain('transcript tailing')
  })
})

describe('status', () => {
  it('describes the machine it is on and what to do about staying reachable', async () => {
    const status = await host.status()
    expect(status.pid).toBe(process.pid)
    expect(status.stateDir).toBe(dir)
    expect(status.reachability.headline).not.toBe('')
    expect(status.reachability.kind).toBeTruthy()
  })
})

describe('sessions, which are the whole point', () => {
  /*
   * A real pty, spawned by the real starter, in a plain Node process.
   *
   * Everything else here checks that the plumbing is connected; this checks that
   * the thing on the end of it works. node-pty is a native module and the one
   * dependency that could plausibly behave differently outside Electron, and a
   * headless build whose sessions do not run is not a reduced product — it is no
   * product at all.
   */
  it('starts a shell in a folder and shows what it printed', async () => {
    const meta = await host.core.startSession({ cwd: dir, cols: 80, rows: 24, provider: 'shell' })
    expect(meta.cwd).toBe(dir)

    host.core.ptys.write(meta.id, 'echo headless-works\r')
    const printed = await waitFor(() => {
      const text = host.core.ptys.scrollback(meta.id)
      return text.includes('headless-works') ? text : null
    })
    expect(printed).toContain('headless-works')

    host.core.ptys.kill(meta.id)
  }, 30_000)

  it('remembers the session so a restart can put it back', async () => {
    /*
     * The half that matters most on WSL: the distribution is shut down when the
     * last terminal closes, taking every session with it, so the list on disk is
     * the difference between "the sessions came back" and "the day's work is
     * gone".
     */
    const meta = await host.core.startSession({ cwd: dir, cols: 80, rows: 24, provider: 'shell' })
    const remembered = storedSessions()
    expect(remembered.some((session) => session.cwd === dir)).toBe(true)

    host.core.ptys.kill(meta.id)
    await waitFor(() => (storedSessions().length === 0 ? true : null))
  }, 30_000)
})

describe.skipIf(process.platform !== 'darwin')('a session started for a device', () => {
  /*
   * The wiring, proven from the far side.
   *
   * `src/main/confine/` has its own tests and they run the real `sandbox-exec`
   * against the real generated profile — but they build the plan themselves. What
   * they cannot show is that the *product* reaches them: that `startSession`,
   * assembled by `createHostCore` exactly as a shell assembles it, hands the
   * command to the sandbox rather than to the shell directly. That is one
   * argument and one `if`, which is precisely the size of thing that gets
   * refactored into never running while every other test still passes.
   *
   * So this starts a session the way the remote path starts one, types into the
   * pty, and reads what came back. A confinement that were quietly skipped here
   * would print the file.
   */
  it('is held inside its folder, all the way through the real spawn path', async () => {
    const granted = join(dir, 'granted-folder')
    const deviceHome = join(dir, 'device-home')
    mkdirSync(granted, { recursive: true })
    mkdirSync(join(deviceHome, 'tmp'), { recursive: true })
    const canary = join(dir, 'outside-secret.txt')
    writeFileSync(canary, SECRET)

    const meta = await host.core.startSession(
      { cwd: granted, cols: 80, rows: 24, provider: 'shell' },
      undefined,
      { home: deviceHome, writable: [], files: [] },
    )

    /*
     * Wait for the shell to be *running* before typing at it, and prove it by
     * something only execution produces.
     *
     * A login shell takes a second or two to come up, and a pty echoes what is
     * typed at it whether or not anything is reading. The first version of this
     * test wrote its commands immediately and then asserted on a marker that
     * appeared in the echo — so it "passed" against a shell that had never run a
     * command, which is the same class of mistake this whole change is about.
     * `printf` with a substituted argument cannot be confused with its own echo:
     * the typed line contains `%s`, the output does not.
     */
    host.core.ptys.write(meta.id, "printf 'SHELL-%s\\n' RUNNING\r")
    await waitFor(() =>
      host.core.ptys.scrollback(meta.id).includes('SHELL-RUNNING') ? true : null,
    )

    host.core.ptys.write(meta.id, `cat ${JSON.stringify(canary)}\r`)
    const printed = await waitFor(() => {
      const text = host.core.ptys.scrollback(meta.id)
      return /not permitted/i.test(text) ? text : null
    })

    // It could not read a file one directory above the folder it was given —
    // and the shell that could not read it was demonstrably alive.
    expect(printed).toContain('SHELL-RUNNING')
    expect(printed).not.toContain(SECRET)

    host.core.ptys.kill(meta.id)
  }, 30_000)
})

describe('a session on this host is told what it is running inside', () => {
  /**
   * The gap Asad filmed, and it was here rather than near the feature.
   *
   * A session on his Office PC, asked *"which app are you running now, are you
   * told in the boot"*, answered out of `CLAUDE_CODE_ENTRYPOINT` and a `which
   * claude` and never named this app. The window has had the context channel
   * since 2026-08-19; this host started the same endpoint with no `contextFor`
   * at all, so every knock from every session on it was answered `204`.
   *
   * A browser window is attached rather than a pty started, and that is not a
   * shortcut around the check it looks like: `hookContext` treats a window bound
   * to an id as its own proof that this app started that session — the renderer
   * only ever binds one to a session it is running — so this exercises the same
   * branch a real session takes, in milliseconds instead of seconds.
   */
  it('answers a hook knock with the app, its version and where to read more', async () => {
    const endpoint = currentHookEndpoint()
    expect(endpoint).not.toBeNull()

    attach({ sessionId: 'headless-1', browserTabId: 'b:1', title: 'Orders' })
    const answer = await knock(endpoint as HookEndpoint, 'claude', 'SessionStart', 'headless-1')

    expect(answer.status).toBe(200)
    expect(answer.context).toContain('Terminal Deck')
    expect(answer.context).toContain(INDEX_FILE)
    // And the documents the map names are on this host's disk, not only on the
    // machine that will read the answer.
    expect(existsSync(join(contextDir(dir), INDEX_FILE))).toBe(true)
  })

  it('tells a shell somebody started over ssh on this box nothing at all', async () => {
    const endpoint = currentHookEndpoint()
    // The hook is installed for the whole account, so it fires for a `claude`
    // run in a plain ssh session too. That one is not inside this app.
    const answer = await knock(endpoint as HookEndpoint, 'claude', 'SessionStart', 'not-ours')
    expect(answer.status).toBe(204)
  })
})

/** One hook call, exactly as an installed command makes it. */
function knock(
  endpoint: HookEndpoint,
  provider: string,
  event: string,
  sessionId: string,
): Promise<{ status: number; context: string | null }> {
  const headers: Record<string, string> = { 'content-type': 'application/json' }
  headers[TOKEN_HEADER] = endpoint.token
  headers[SESSION_HEADER] = sessionId
  return new Promise((resolve, reject) => {
    const req = request(
      {
        socketPath: endpoint.socketPath,
        method: 'POST',
        path: `/hook/${provider}/${event}`,
        headers,
      },
      (res) => {
        let text = ''
        res.setEncoding('utf8')
        res.on('data', (chunk: string) => {
          text += chunk
        })
        res.on('end', () =>
          resolve({
            status: res.statusCode ?? 0,
            context:
              text === ''
                ? null
                : ((JSON.parse(text) as { hookSpecificOutput?: { additionalContext?: string } })
                    .hookSpecificOutput?.additionalContext ?? null),
          }),
        )
      },
    )
    req.on('error', reject)
    req.write('{}')
    req.end()
  })
}

/** Written outside the granted folder. Its contents must never reach a session. */
const SECRET = 'headless-canary-b71fe9-do-not-leak'

function storedSessions(): Array<{ cwd: string }> {
  return store().getOpenSessions()
}

/**
 * Wait for something to become true, without a fixed sleep.
 *
 * A pty's output arrives on its own schedule and a fixed delay is either flaky
 * or slow. This is a poll and it is allowed to be one: it is a test waiting on
 * another process, not a running host waiting on an event it could have
 * subscribed to.
 */
async function waitFor<T>(check: () => T | null, timeoutMs = 15_000): Promise<T> {
  const deadline = Date.now() + timeoutMs
  for (;;) {
    const value = check()
    if (value !== null) return value
    if (Date.now() > deadline) throw new Error('timed out waiting for the session')
    await new Promise((done) => setTimeout(done, 50))
  }
}

describe('a session that ends on this host leaves every connected client’s list', () => {
  /*
   * The gap this closes, from the far side of the wire.
   *
   * The desktop shell forwards `onSessionRemoved` into its core so that a
   * session ended by anything — another device's verb, the copilot's
   * `sessions_stop`, the process being killed — is pushed off every phone's list
   * without a reconnect (index.ts, and the desktop-side assertion at
   * server.test.ts's "pushes the new list when a session is started at this
   * machine’s own keyboard"). The headless host forwarded `onSessionStarted` and
   * nothing else, so a session that *appeared* reached a phone and a session that
   * *vanished* did not: it sat in the sidebar pointing at a pty this process had
   * already dropped, exactly the ghost `src/main/session-removed.test.ts`
   * describes, until the phone reconnected.
   *
   * These two tests hold the two halves of the fix. The first is behavioural —
   * an in-memory client, connected and never attached, watches a session appear
   * and then disappear from its `sessions` frame, and a `replaced` removal (the
   * account-switch tab-swap) is proven *not* to push. It reaches the endpoint
   * through `attachTransport`, the same door the relay uses and the one
   * `credential-wiring.test.ts` uses, because the running host serves over
   * Tailscale or the relay and a unit test may dial neither. The push itself is
   * `endpoint.sessionsChanged()`, applied through the *exact* policy `host.ts`
   * installs on its core — `if (reason === 'replaced') return`, else push.
   *
   * The second reads `host.ts` as text and asserts that policy really is wired
   * into `createHostCore`, for the reason `credential-wiring.test.ts` reads
   * `index.ts`: the mechanism can be correct and the join still missing, and a
   * behavioural test built over its own copy of the wiring would pass against a
   * host that never made it.
   */

  /** A session list the test can grow and shrink, as things on the host do. */
  function liveSessions(): SessionAccess & {
    add(id: string, cwd: string): void
    remove(id: string): void
  } {
    const rows: RemoteSession[] = []
    return {
      list: () => rows,
      add(id, cwd) {
        rows.push({ id, title: id, cwd, provider: 'shell', status: 'idle', exitCode: null })
      },
      remove(id) {
        const at = rows.findIndex((row) => row.id === id)
        if (at >= 0) rows.splice(at, 1)
      },
      attach: (): SessionHandle | null => null,
      write: () => {},
      resize: () => {},
      detach: () => {},
    }
  }

  /** Every hello is the one owner phone; authentication is not what this checks. */
  const auth: RemoteEndpointOptions['auth'] = {
    authenticate: async () => ({
      ok: true,
      deviceId: 'device-1',
      deviceName: 'iPhone',
      credential: null,
    }),
  }

  interface Peer {
    received: ServerMessage[]
    send(message: ClientMessage): void
  }

  /** One connected, unattached client, over the transport seam rather than a socket. */
  function connectPeer(endpoint: RemoteEndpoint): Peer {
    const received: ServerMessage[] = []
    let deliver: ((text: string) => void) | null = null
    endpoint.attachTransport('100.64.0.2', (handlers) => {
      deliver = handlers.message
      const wire: RemoteWire = {
        send: (text: string) => received.push(JSON.parse(text) as ServerMessage),
        close: () => handlers.closed(),
      }
      return wire
    })
    const peer: Peer = {
      received,
      send: (message) => deliver?.(serialize(message)),
    }
    peer.send({
      t: 'hello',
      protocol: PROTOCOL_VERSION,
      token: 'device-1.secret',
      device: { name: 'iPhone', platform: 'iOS' },
    })
    return peer
  }

  async function until(
    peer: Peer,
    match: (message: ServerMessage) => boolean,
    what: string,
  ): Promise<ServerMessage> {
    for (let i = 0; i < 200; i += 1) {
      const found = peer.received.find(match)
      if (found) return found
      await new Promise((done) => setTimeout(done, 5))
    }
    throw new Error(`never received ${what}`)
  }

  const sessionIds = (message: ServerMessage): string[] =>
    message.t === 'sessions' ? message.sessions.map((row) => row.id) : []

  it('pushes a fresh sessions frame when one is started here and again when it ends', async () => {
    const sessions = liveSessions()
    const endpoint = createRemoteEndpoint({
      sessions,
      auth,
      webRoot: join(dir, 'no-web-here'),
      pingIntervalMs: 0,
    })

    const client = connectPeer(endpoint)
    await until(client, (m) => m.t === 'welcome', 'the welcome')

    // The policy `host.ts` installs on its core, verbatim: every start pushes,
    // every non-`replaced` removal pushes, a `replaced` removal does not.
    const onSessionStarted = (): void => {
      endpoint.sessionsChanged()
    }
    const onSessionRemoved = (_id: string, reason: RemovalReason): void => {
      if (reason === 'replaced') return
      endpoint.sessionsChanged()
    }

    // A terminal the host itself opened — nobody on this wire asked for it.
    sessions.add('made-here', join(dir, 'work'))
    onSessionStarted()
    const appeared = await until(
      client,
      (m) => m.t === 'sessions' && sessionIds(m).includes('made-here'),
      'the started session',
    )
    expect(sessionIds(appeared)).toContain('made-here')

    // Ended on the server, by whatever route. It must leave the list without a
    // reconnect — the whole point of the frame.
    sessions.remove('made-here')
    onSessionRemoved('made-here', 'stopped')
    const gone = await until(
      client,
      (m) => m.t === 'sessions' && !sessionIds(m).includes('made-here'),
      'the list without the ended session',
    )
    expect(sessionIds(gone)).not.toContain('made-here')

    endpoint.closeAll()
  })

  it('does not push for a replaced session — the account-switch swap is not a change', async () => {
    const sessions = liveSessions()
    const endpoint = createRemoteEndpoint({
      sessions,
      auth,
      webRoot: join(dir, 'no-web-here'),
      pingIntervalMs: 0,
    })
    const client = connectPeer(endpoint)
    await until(client, (m) => m.t === 'welcome', 'the welcome')

    const onSessionRemoved = (_id: string, reason: RemovalReason): void => {
      if (reason === 'replaced') return
      endpoint.sessionsChanged()
    }

    sessions.add('swap-old', join(dir, 'work'))
    endpoint.sessionsChanged()
    await until(
      client,
      (m) => m.t === 'sessions' && sessionIds(m).includes('swap-old'),
      'the session before the swap',
    )

    const before = client.received.filter((m) => m.t === 'sessions').length
    // The account switch stops one process and starts another in the same tab.
    // `onSessionStarted` fires for the replacement; the removal must stay silent
    // or the list flickers empty between the two.
    sessions.remove('swap-old')
    onSessionRemoved('swap-old', 'replaced')
    await new Promise((done) => setTimeout(done, 20))
    const after = client.received.filter((m) => m.t === 'sessions').length
    expect(after).toBe(before)

    endpoint.closeAll()
  })

  it('is actually wired into createHostCore on the headless host, replaced filtered', () => {
    // The join, read as text — see credential-wiring.test.ts for why a wiring
    // this shape is verified against the source and not only through a harness.
    const source = readFileSync(join(__dirname, 'host.ts'), 'utf8')

    // Both hooks push through the one late-bound fan-out.
    expect(source).toMatch(/onSessionStarted:\s*\(\)\s*=>\s*tellDevices\?\.\(\)/)
    expect(source).toMatch(/tellDevices\s*=\s*\(\)\s*=>\s*\{[\s\S]*?sessionsChanged\(\)/)

    // onSessionRemoved forwards every removal except the account-switch swap.
    const removed = source.match(/onSessionRemoved:\s*\([^)]*\)\s*=>\s*\{[\s\S]*?\n\s*\},/)
    expect(removed).not.toBeNull()
    const body = removed?.[0] ?? ''
    expect(body).toMatch(/reason === 'replaced'/)
    expect(body).toMatch(/return/)
    expect(body).toMatch(/tellDevices\?\.\(\)/)
  })
})

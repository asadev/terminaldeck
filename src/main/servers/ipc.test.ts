/**
 * The registration, driven the way the window drives it.
 *
 * Against a plain object rather than Electron's `ipcMain`, which is the whole
 * reason `ipc-seam.ts` exists: *"narrowing it means the registration can be
 * exercised with an ordinary object instead of `as unknown as IpcMain`, and a
 * cast in a test throws away the very check the test is for."*
 *
 * Three things here are worth more than ordinary coverage, and each has a
 * recorded failure behind it:
 *
 *  - **the channel names**, because `src/preload/contract.test.ts` records three
 *    shipping bugs at this seam and none of them was a type error;
 *  - **the connection lifecycle**, because §5.4's *"events, not polling"* is
 *    paid by closing things, and the closing half is the half that is easy to
 *    forget;
 *  - **what crosses back**, because a credential that reached a screen would be
 *    *"a screenshot away from publishing it"* — `renderer/machines/types.ts`'s
 *    own words about paired devices, which hold identically here.
 */

import { randomUUID } from 'node:crypto'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { InvokeRegistrar } from '../ipc-seam'
import {
  registerServersIpc,
  SERVERS_SHELL_CLOSED_CHANNEL,
  SERVERS_SHELL_OUTPUT_CHANNEL,
  type ServersIpcDeps,
} from './ipc'
import { ServerProblem, type ServerShell } from './connection'
import { factNo, factYes, type ServerFacts } from './facts'
import { cmd } from './test-fixtures'

const AT = 1_700_000_000_000

function registrar(): { ipcMain: InvokeRegistrar; call: (channel: string, ...args: unknown[]) => Promise<unknown> } {
  const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()
  return {
    ipcMain: { handle: (channel, listener) => void handlers.set(channel, listener) },
    call: async (channel, ...args) => {
      const handler = handlers.get(channel)
      if (handler === undefined) throw new Error(`no handler for ${channel}`)
      return handler({}, ...args)
    },
  }
}

/** A server with one thing on it, so a card exists to press a button on. */
function serverFacts(): ServerFacts {
  const nothing = factNo<never>(AT, 'asked')
  return {
    serverId: 's1',
    measuredAt: AT,
    os: factYes('Ubuntu 24.04.4 LTS', AT, 'read'),
    kernel: nothing,
    arch: nothing,
    hostname: nothing,
    user: factYes('root', AT, 'asked'),
    privilege: factYes('yes', AT, 'asked'),
    init: factYes('systemd', AT, 'asked'),
    containerRuntime: factNo(AT, 'asked'),
    packageManager: nothing,
    webServer: nothing,
    cpus: nothing,
    disk: nothing,
    memory: nothing,
    load1: nothing,
    uptimeSeconds: nothing,
    services: factYes(
      [{ name: 'mine.service', state: 'running', description: 'Mine', addedHere: true }],
      AT,
      'asked what it is set up to keep running',
    ),
    containers: factNo(AT, 'asked'),
    listeners: factYes([], AT, 'asked'),
    siteNames: factNo(AT, 'asked'),
    agents: factYes([], AT, 'looked for a coding assistant'),
    agentInstall: nothing,
  }
}

const dirs: string[] = []

function harness(overrides: Partial<ServersIpcDeps> = {}): {
  ipc: ReturnType<typeof registerServersIpc>
  call: (channel: string, ...args: unknown[]) => Promise<unknown>
  ran: string[][]
  broadcast: Array<{ channel: string; payload: unknown }>
  storageDir: string
  released: string[]
} {
  const storageDir = mkdtempSync(join(tmpdir(), 'td-servers-'))
  dirs.push(storageDir)
  const ran: string[][] = []
  const broadcast: Array<{ channel: string; payload: unknown }> = []
  const released: string[] = []
  const { ipcMain, call } = registrar()
  const ipc = registerServersIpc(ipcMain, {
    storageDir,
    servers: () => [{ id: 's1', name: 'demo', address: 'example.test', username: 'root' }],
    facts: async () => serverFacts(),
    run: async (_serverId, argv) => {
      ran.push([...argv])
      return cmd({ stdout: argv.includes('journalctl') ? 'line one\nline two\n' : '' })
    },
    runScript: async () => cmd({ stdout: '##compose-available\nno\n' }),
    release: (serverId) => void released.push(serverId),
    broadcast: (channel, payload) => void broadcast.push({ channel, payload }),
    ...overrides,
  })
  return { ipc, call, ran, broadcast, storageDir, released }
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe('the channels the window calls', () => {
  it('answers the list without connecting to anything', async () => {
    const { call, ran } = harness()
    expect(await call('servers:list')).toEqual([
      { id: 's1', name: 'demo', address: 'example.test', username: 'root' },
    ])
    // §5.4: the list of servers costs nothing when closed. It does not dial
    // anything to draw itself.
    expect(ran).toEqual([])
  })

  it('hands the identity and the kind of sign-in through to the list, unchanged', async () => {
    /*
     * The shape, pinned at this end, because it was wrong here once and cost
     * nothing at compile time.
     *
     * `hostKey` is **nested** — `{ algorithm, fingerprint }` — exactly as
     * `store.ts` writes it and exactly as the window's own narrower reads it
     * (`renderer/machines/servers/types.test.ts` asserts the same literal).
     * Flattening it to a bare `fingerprint` on the way past typechecked
     * perfectly and made the identity screen say "It has not told us one yet"
     * about a server whose fingerprint was sitting in `servers.json` — on the
     * one screen whose stated job is *"you can compare what is below against
     * the server itself"*.
     *
     * `credential` is the kind and never the credential; §3.7.
     */
    const row = {
      id: 's1',
      name: 'demo',
      address: 'example.test',
      username: 'root',
      credential: 'key' as const,
      hostKey: { algorithm: 'ssh-ed25519', fingerprint: 'SHA256:XIwvDdf+A9x4LMPTSJ3ZpH+YfqAbXLVeUwnpd4GHmM0' },
    }
    const { call } = harness({ servers: () => [row] })
    expect(await call('servers:list')).toEqual([row])
  })

  it('builds the whole view in one look, and remembers it', async () => {
    const { call } = harness()
    const answer = (await call('servers:look', 's1')) as { ok: true; view: { cards: unknown[]; offered: unknown } }
    expect(answer.ok).toBe(true)
    expect(answer.view.cards).toHaveLength(1)
    expect(answer.view.offered).toEqual({ 'service:mine.service': ['logs', 'restart', 'stop'] })
  })

  it('hands a refusal back as a sentence rather than as a rejected promise', async () => {
    /*
     * A rejected `ipcMain.handle` reaches the renderer as `Error: Error
     * invoking remote method '…'`, which mangles the one thing this feature
     * must deliver intact — the sentence `actions.ts` wrote. §4.3 has three
     * surfaces rendering one string.
     */
    const { call } = harness({
      facts: async () => {
        throw new Error('That address did not answer in time.')
      },
    })
    expect(await call('servers:look', 's1')).toEqual({
      ok: false,
      sentence: 'That address did not answer in time.',
      detail: '',
    })
  })

  it('previews an action without running it', async () => {
    const { call, ran } = harness()
    await call('servers:look', 's1')
    const before = ran.length
    const answer = (await call('servers:preview', 's1', 'service:mine.service', 'restart')) as {
      ok: true
      preview: { sentence: string; klass: string }
    }
    expect(answer.preview.sentence).toMatch(/offline for about five seconds/)
    expect(answer.preview.klass).toBe('reversible')
    expect(ran.length).toBe(before)
  })

  it('refuses an action id it has never heard of, before anything is looked up', async () => {
    const { call, ran } = harness()
    expect(await call('servers:act', 's1', 'service:mine.service', 'rm -rf /')).toEqual({
      ok: false,
      sentence: 'That isn’t something this app can do.',
      detail: '',
    })
    expect(ran).toEqual([])
  })

  it('runs a real action and forgets what it knew, because the server just changed', async () => {
    const { call, ran } = harness()
    await call('servers:look', 's1')
    const answer = (await call('servers:act', 's1', 'service:mine.service', 'restart')) as {
      ok: true
      outcome: { done: string }
    }
    expect(answer.outcome.done).toBe('Restarted mine.')
    expect(ran).toContainEqual(['systemctl', 'restart', 'mine.service'])
    /*
     * The cache is dropped rather than re-measured. §5.4 is explicit that a
     * refresh is a press and not a tick — but a page that kept showing
     * "running" after a Stop would be showing something it *knows* is wrong,
     * which is a different thing from being honestly stale.
     */
    expect(await call('servers:look', 's1')).toMatchObject({ ok: true })
  })

  it('reads a bounded window of log, clamped whatever the caller asks for', async () => {
    const { call, ran } = harness()
    const answer = (await call('servers:logs', 's1', 'service:mine.service', 999_999)) as {
      ok: true
      lines: string[]
    }
    expect(answer.lines).toEqual(['line one', 'line two'])
    const journalctl = ran.find((argv) => argv[0] === 'journalctl')
    expect(journalctl).toContain('2000')
  })
})

describe('a terminal that can drive the browser window attached to it', () => {
  /**
   * The last cell of *"from any session from any device to any device's browser
   * in one app"*, wired end to end at this seam.
   *
   * A shell on a server is an SSH pty. Nothing hands it tools and nothing here
   * composes its command line — a person types `claude` into it — so the whole
   * arrangement is a port that reaches back (`window-reach.ts`), a wrapper on
   * that shell's `PATH` (`window-drive.ts`), and one line typed into the
   * terminal. What this file pins is that the three are actually wired together
   * by `servers:shell:open`, and that a server nobody ticked pays for none of it.
   */
  const HELP = 'Usage: claude\n\nOptions:\n  --mcp-config <configs...>  Load MCP servers\n'

  function withClaude(): ServerFacts {
    return {
      ...serverFacts(),
      agents: factYes(
        [{ id: 'claude' as const, path: '/root/.local/bin/claude', version: '2.0.0', signedIn: 'yes' as const, account: null }],
        AT,
        'looked for a coding assistant',
      ),
    }
  }

  /** Just enough of a connection to be asked for a port on the far end. */
  function reverseConnection(): unknown {
    return {
      on: () => undefined,
      removeListener: () => undefined,
      forwardIn: (_addr: string, _port: number, cb: (e: undefined, p: number) => void) => cb(undefined, 40404),
      unforwardIn: (_addr: string, _port: number, cb: () => void) => cb(),
      forwardOut: () => undefined,
    }
  }

  /**
   * The scout's answer, in the shape `readScouted` finds by its mark: the
   * folder, the login shell, `curl`, and one line per opener.
   */
  function scoutAnswer(over: { curl?: string } = {}): string {
    return [
      'TD_SCOUTED',
      '/tmp/td-drive-abc123',
      '/bin/bash',
      over.curl ?? '/usr/bin/curl',
      '',
      '/usr/bin/xdg-open',
      '',
    ].join('\n')
  }

  function drivingHarness(
    allowed: boolean,
    over: Partial<ServersIpcDeps> = {},
    scout: string = scoutAnswer(),
  ) {
    const written: string[] = []
    const scripts: string[] = []
    let drives = allowed
    const shell: ServerShell = {
      onData: () => () => undefined,
      onClose: () => () => undefined,
      write: (data) => void written.push(data),
      resize: () => undefined,
      close: () => undefined,
    }
    const rig = harness({
      facts: async () => withClaude(),
      run: async () => cmd({ stdout: HELP }),
      runScript: async (_serverId, script) => {
        scripts.push(script)
        if (script.includes('command -v ss')) return cmd({ stdout: 'loopback\n' })
        if (script.includes('mktemp -d')) return cmd({ stdout: scout })
        return cmd({ stdout: '##compose-available\nno\n' })
      },
      openShell: async () => shell,
      withConnection: async (_serverId, fn) => fn(reverseConnection() as never),
      controlPort: () => 5599,
      mintSessionTools: () => ({
        configFor: (url: string) => JSON.stringify({ url }),
        started: () => undefined,
        drop: () => undefined,
      }),
      store: {
        add: () => ({ id: 'new-1' }),
        setCredentialKind: () => true,
        rename: () => true,
        forget: () => true,
        get: () => null,
        setStartIn: () => false,
        drivesWindows: () => drives,
        setDrivesWindows: (_id, next) => {
          drives = next
          return next
        },
      },
      ...over,
    })
    return { ...rig, written, scripts }
  }

  it('types one line into the terminal, and says what it is', async () => {
    const { call, written, ipc } = drivingHarness(true)

    const opened = (await call('servers:shell:open', 's1', 100, 40)) as { ok: true; shellId: string }

    expect(opened.ok).toBe(true)
    const line = written.find((text) => text.startsWith('export PATH='))
    expect(line).toBeDefined()
    // Echoed by the far end and left in the scrollback, with a comment saying
    // what it is: nothing this app does to somebody's terminal should be
    // invisible in that terminal.
    expect(line).toContain('/tmp/td-drive-abc123/bin')
    expect(line).toContain('#')
    expect(ipc.whyNotDrive(opened.shellId)).toBeNull()
  })

  it('asks the server where the port it opened actually landed', async () => {
    const { call, scripts } = drivingHarness(true)
    await call('servers:shell:open', 's1', 100, 40)
    // `GatewayPorts yes` ignores the loopback address that was asked for and
    // binds the wildcard, which would put a way in to this Mac's browser on a
    // port that server's whole network can dial. It is measured, not assumed.
    expect(scripts.some((script) => script.includes('command -v ss'))).toBe(true)
  })

  it('costs a server nobody ticked nothing at all', async () => {
    const { call, written, scripts, ran, ipc } = drivingHarness(false)

    const opened = (await call('servers:shell:open', 's1', 100, 40)) as { ok: true; shellId: string }

    expect(opened.ok).toBe(true)
    expect(written).toEqual([])
    // Not one round trip: no `claude --help`, no script, no port.
    expect(ran).toEqual([])
    expect(scripts).toEqual([])
    // And the row in the browser's connect menu says so rather than attaching
    // and quietly doing nothing.
    expect(ipc.whyNotDrive(opened.shellId)).toContain('not allowed')
  })

  it('opens the terminal anyway when the verbs cannot be given', async () => {
    // A person asked for a shell. Every reason this app cannot add its browser
    // verbs is a reason to say so, never a reason to refuse the shell.
    const { call, written, ipc } = drivingHarness(true, {
      run: async () => cmd({ stdout: 'Usage: claude\n' }),
    })

    const opened = (await call('servers:shell:open', 's1', 100, 40)) as { ok: true; shellId: string }

    expect(opened.ok).toBe(true)
    expect(written).toEqual([])
    expect(ipc.whyNotDrive(opened.shellId)).toContain('--mcp-config')
  })

  it('answers the switch with what is now true, not with what was pressed', async () => {
    const { call } = drivingHarness(false, {
      store: {
        add: () => ({ id: 'new-1' }),
        setCredentialKind: () => true,
        rename: () => true,
        forget: () => true,
        get: () => null,
        setStartIn: () => false,
        // A store that will not record it — an id it has never heard of.
        drivesWindows: () => false,
        setDrivesWindows: () => false,
      },
    })
    expect(await call('servers:drive-windows', 's1', true)).toEqual({ drivesWindows: false })
  })

  it('takes it away from a terminal that is already open when it goes off', async () => {
    const { call, ipc } = drivingHarness(true)
    const opened = (await call('servers:shell:open', 's1', 100, 40)) as { ok: true; shellId: string }
    expect(ipc.whyNotDrive(opened.shellId)).toBeNull()

    expect(await call('servers:drive-windows', 's1', false)).toEqual({ drivesWindows: false })

    // The token is off the table now, not merely refused on the next call —
    // `ServerGrants` argues for both, and this is the half that reaches a
    // terminal somebody is in the middle of using.
    expect(ipc.whyNotDrive(opened.shellId)).toContain('not allowed')
  })

  it('says nothing about a shell it has never heard of', async () => {
    const { ipc } = drivingHarness(true)
    expect(ipc.whyNotDrive('a shell nobody opened')).toBeNull()
  })

  /*
   * And the other half of the same grant: a session on a server that knows where
   * it is, has this app's `open` in front of the server's own, and is told when a
   * window is attached to it. `servers/window-belong.ts` carries the whole
   * argument; what is pinned here is the wiring, because it is the wiring that
   * was missing — the hook endpoint is a second listener with a second address,
   * so reaching it takes a second forward.
   */
  function belongingHarness(over: Partial<ServersIpcDeps> = {}, scout: string = scoutAnswer()) {
    const bound: number[] = []
    return drivingHarness(true, {
      run: async () =>
        cmd({ stdout: `${HELP}  --settings <file-or-json>  Load additional settings\n` }),
      hookEndpoint: () => ({ socketPath: '/tmp/hook.sock', token: 'deadbeef' }),
      remoteContext: (serverName, opensInApp) => ({
        pages: { 'INDEX.md': `# ${serverName} ${String(opensInApp)}` },
        mapFor: (dir) => `read ${dir}/INDEX.md`,
      }),
      withConnection: async (_serverId, fn) =>
        fn({
          on: () => undefined,
          removeListener: () => undefined,
          forwardIn: (_addr: string, _port: number, cb: (e: undefined, p: number) => void) => {
            const port = 40404 + bound.length
            bound.push(port)
            cb(undefined, port)
          },
          unforwardIn: (_addr: string, _port: number, cb: () => void) => cb(),
          forwardOut: () => undefined,
        } as never),
      ...over,
    }, scout)
  }

  it('opens a second forward, because the hooks are a second endpoint', async () => {
    const { call, scripts } = belongingHarness()

    await call('servers:shell:open', 's1', 100, 40)

    // Two ports, each proved to be on that server's own loopback before a byte
    // crossed it. One would have pointed the hooks at `deck-control`, which
    // answers 404 at the far end of somebody's SSH connection.
    expect(scripts.filter((script) => script.includes('command -v ss')).length).toBe(2)
    const written = scripts.find((script) => script.includes('bin/claude')) ?? ''
    expect(written).toContain('bin/open')
    expect(written).toContain('bin/td-hook')
    expect(written).toContain('settings.json')
    expect(written).toContain('context/INDEX.md')
    // Two ports, and the shim and the hooks use the one that is not
    // `deck-control`'s.
    expect(written).toContain('http://127.0.0.1:40405/open')
  })

  it('hands that session a map naming the documents on that server', async () => {
    const { call, ipc } = belongingHarness()

    const opened = (await call('servers:shell:open', 's1', 100, 40)) as { ok: true; shellId: string }

    expect(ipc.belongingOf(opened.shellId)).toEqual({
      map: 'read /tmp/td-drive-abc123/context/INDEX.md',
      opensInApp: true,
    })
    expect(ipc.belongingOf('a shell nobody opened')).toBeNull()
  })

  it('still opens the terminal, and claims none of it, on a server with no curl', async () => {
    const { call, ipc, scripts } = belongingHarness({}, scoutAnswer({ curl: '' }))

    const opened = (await call('servers:shell:open', 's1', 100, 40)) as { ok: true; shellId: string }

    expect(opened.ok).toBe(true)
    // The browser verbs are untouched; only the half that needs a `curl` is off,
    // and nothing on screen or in the agent's context says otherwise.
    expect(ipc.whyNotDrive(opened.shellId)).toBeNull()
    expect(ipc.belongingOf(opened.shellId)).toBeNull()
    expect(scripts.filter((script) => script.includes('command -v ss')).length).toBe(1)
    expect((scripts.find((script) => script.includes('bin/claude')) ?? '')).not.toContain('bin/open')
  })
})

describe('when it lets go', () => {
  /** A shell whose `close` can be counted, and nothing else. */
  function countedShell(): { shell: ServerShell; closed: ReturnType<typeof vi.fn> } {
    const closed = vi.fn()
    return {
      closed,
      shell: {
        onData: () => () => undefined,
        onClose: () => () => undefined,
        write: () => undefined,
        resize: () => undefined,
        close: closed,
      },
    }
  }

  it('lets go of the connection and leaves the terminals alone', async () => {
    const { shell, closed } = countedShell()
    const { call, released } = harness({ openShell: async () => shell })
    await call('servers:look', 's1')
    const opened = (await call('servers:shell:open', 's1', 100, 40)) as { ok: true; shellId: string }
    expect(opened.ok).toBe(true)

    await call('servers:close', 's1')

    /*
     * Once, and this harness is exactly the case that proves the pairing.
     *
     * Opening a terminal holds the connection across the whole sequence — the
     * `claude --help` that decides whether that shell can be given the browser
     * verbs, the script that puts them there, and the shell itself — so that the
     * three share one socket. These deps supply `release` and **no** `acquire`,
     * so that hold is never taken, and a `release` here would be decrementing a
     * reference somebody else is holding. The only one is the page letting go.
     */
    expect(released).toEqual(['s1'])
    /*
     * And the terminal is still there — which is the half this test used to
     * assert the other way round.
     *
     * A shell opened from a server's page becomes a workspace tab, and that tab
     * neither looks nor closes: it is `ServerSessionPane`, *"mounted for as long
     * as the tab exists"*. So a page letting go of a server is not evidence that
     * anybody is finished with a terminal on it, and closing one here ended
     * whatever was running — an install, an agent session — for somebody who had
     * pressed nothing but **Back to machines**.
     */
    expect(closed).not.toHaveBeenCalled()
    expect(await call('servers:shell:write', opened.shellId, 'ls\n')).toEqual({ written: true })
  })

  it('keeps one surface’s terminal alive when the other surface closes', async () => {
    /*
     * The probe that found this, driven the same way: two holders, one shell,
     * one close.
     *
     * Two surfaces really do look at one server at once. The Servers settings
     * pane auto-dials `servers[0]` the moment it is opened (`ServerControl`'s
     * `chosenServer` falls back to the first row) while the server's own page in
     * Machines is already holding one. Opening Settings → Servers and moving off
     * it again therefore ran `servers:close` on a server somebody else was still
     * looking at — and the connection was never the part at risk, because the
     * other holder's reference kept it. The terminal was.
     */
    const { shell, closed } = countedShell()
    const { call, released } = harness({ openShell: async () => shell })
    await call('servers:look', 's1')
    await call('servers:look', 's1')
    const opened = (await call('servers:shell:open', 's1', 100, 40)) as { ok: true; shellId: string }

    await call('servers:close', 's1')

    expect(released).toEqual(['s1'])
    expect(closed).not.toHaveBeenCalled()
    expect(await call('servers:shell:write', opened.shellId, 'echo hi\n')).toEqual({ written: true })
  })

  it('closes the terminal when the terminal’s own holder leaves, and not twice', async () => {
    /*
     * The other half, so the fix above is not a leak.
     *
     * A shell is ended by exactly one of four things, and all four are the
     * shell's own rather than some other screen's: the terminal that opened it
     * going away (this channel — `ServerTerminal` calls it on unmount), the far
     * end hanging up, the server being forgotten, and the app stopping. Two of
     * those are asserted here; `servers:forget` and `stop` have their own tests
     * below and in the shutdown block.
     */
    const { shell, closed } = countedShell()
    const { call } = harness({ openShell: async () => shell })
    await call('servers:look', 's1')
    await call('servers:look', 's1')
    const opened = (await call('servers:shell:open', 's1', 100, 40)) as { ok: true; shellId: string }

    // Both pages go first, to prove neither of them is what ends it.
    await call('servers:close', 's1')
    await call('servers:close', 's1')
    expect(closed).not.toHaveBeenCalled()

    expect(await call('servers:shell:close', opened.shellId)).toEqual({ closed: true })
    expect(closed).toHaveBeenCalledTimes(1)
    // Dead afterwards, rather than writing into a channel that is gone — and a
    // second close is not a second `close()` on the far end.
    expect(await call('servers:shell:write', opened.shellId, 'ls\n')).toEqual({ written: false })
    expect(await call('servers:shell:close', opened.shellId)).toEqual({ closed: false })
    expect(closed).toHaveBeenCalledTimes(1)
  })

  it('closes a terminal nobody closed when the app stops', async () => {
    // The backstop, and the reason `servers:close` does not need to be one: a
    // window that went away without unmounting anything leaves shells here, and
    // `stop` is what ends them.
    const { shell, closed } = countedShell()
    const { call, ipc } = harness({ openShell: async () => shell })
    await call('servers:look', 's1')
    await call('servers:shell:open', 's1', 100, 40)
    await call('servers:close', 's1')
    expect(closed).not.toHaveBeenCalled()

    ipc.stop()
    expect(closed).toHaveBeenCalledTimes(1)
  })

  it('closes every terminal on a server that is being forgotten', async () => {
    /*
     * The one place an unconditional sweep is still right, stated so the two are
     * not confused again. `servers:close` means *this page is finished with that
     * server*; this means *the server is going* — its row, its saved sign-in and
     * its recorded host key — so a terminal on it has nothing left to be a
     * terminal on, and leaving one open would leave a live pty on somebody's
     * machine with no way back to it.
     */
    const { shell, closed } = countedShell()
    const { call } = harness({
      openShell: async () => shell,
      store: {
        add: () => ({ id: 'new-1' }),
        setCredentialKind: () => true,
        rename: () => true,
        forget: () => true,
        get: () => null,
        setStartIn: () => false,
      },
    })
    await call('servers:look', 's1')
    await call('servers:shell:open', 's1', 100, 40)

    expect(await call('servers:forget', 's1')).toEqual({ forgotten: true })
    expect(closed).toHaveBeenCalledTimes(1)
  })

  it('says which server a shell is on, so a browser window can be bound to it', async () => {
    /*
     * A shell on a server is a *session* to the session↔browser map, which keys
     * its bindings `<machineId>\0<sessionId>` with the server standing in for
     * the machine. Nothing outside this file can answer which server a shell is
     * on — the id happens to begin with the server's, and a reader that split on
     * the space would be one server name with a space in it away from binding a
     * window to a machine that does not exist.
     */
    const shell: ServerShell = {
      onData: () => () => undefined,
      onClose: () => () => undefined,
      write: () => undefined,
      resize: () => undefined,
      close: () => undefined,
    }
    const { ipc, call } = harness({ openShell: async () => shell })
    const opened = (await call('servers:shell:open', 's1', 100, 40)) as { shellId: string }

    expect(ipc.serverOfShell(opened.shellId)).toBe('s1')
    expect(ipc.serverOfShell('nothing this app opened')).toBeNull()

    /*
     * And the two id spaces cannot collide, which is what makes `index.ts`'s
     * `machineOfSession` safe to ask all three registries in a row with one id.
     * A session id is a bare `randomUUID()`; a shell id is the server's id, a
     * space, and a UUID. A UUID contains no space, so a session id can never
     * name a shell and a shell id can never name a pty — the answer is decided
     * by whichever registry actually holds it, never by the order they are
     * asked in.
     */
    expect(opened.shellId).toContain(' ')
    expect(ipc.serverOfShell(randomUUID())).toBeNull()

    // And it stops answering the moment the shell is gone, rather than pointing
    // a binding at a channel that has been closed.
    await call('servers:shell:close', opened.shellId)
    expect(ipc.serverOfShell(opened.shellId)).toBeNull()
  })

  it('says so plainly on a build with no terminal, rather than drawing one that does nothing', async () => {
    const { call } = harness({ openShell: undefined })
    expect(await call('servers:shell:open', 's1', 100, 40)).toMatchObject({
      ok: false,
      sentence: 'This copy of the app can’t open a terminal on a server.',
    })
  })

  it('passes columns first and rows second, the same order everywhere', async () => {
    /*
     * `ssh2` reverses them between `shell({cols, rows})` and `setWindow(rows,
     * cols, …)`, in the same library on the same channel. Getting it wrong
     * produces a terminal that is perfect until the window is resized and then
     * wraps every line at the wrong column — which reads as a rendering bug.
     * A square test window would pass either way, so this one is not square.
     */
    const sizes: Array<{ cols: number; rows: number }> = []
    const shell: ServerShell = {
      onData: () => () => undefined,
      onClose: () => () => undefined,
      write: () => undefined,
      resize: (size) => void sizes.push(size),
      close: () => undefined,
    }
    const openShell = vi.fn(async () => shell)
    const { call } = harness({ openShell })
    const opened = (await call('servers:shell:open', 's1', 132, 43)) as { shellId: string }
    // Three arguments: the third is the folder the terminal should start in,
    // and `undefined` is what a press that chose none sends — which is every
    // press this channel had until the folder picker existed.
    expect(openShell).toHaveBeenCalledWith('s1', { cols: 132, rows: 43 }, undefined)
    await call('servers:shell:resize', opened.shellId, 100, 25)
    expect(sizes).toEqual([{ cols: 100, rows: 25 }])
  })

  it('pushes the far end’s output on its own channel, tagged with the shell it came from', async () => {
    /*
     * Typed explicitly rather than inferred. TypeScript narrows a `let` that is
     * only ever assigned inside a callback to `null`, and the call below then
     * fails to compile for a reason that has nothing to do with the test.
     */
    const listeners: Array<(chunk: string) => void> = []
    const shell: ServerShell = {
      onData: (listener) => {
        listeners.push(listener)
        return () => undefined
      },
      onClose: () => () => undefined,
      write: () => undefined,
      resize: () => undefined,
      close: () => undefined,
    }
    const { call, broadcast } = harness({ openShell: async () => shell })
    const opened = (await call('servers:shell:open', 's1', 80, 24)) as { shellId: string }
    listeners[0]?.('hello\r\n')
    expect(broadcast).toContainEqual({
      channel: SERVERS_SHELL_OUTPUT_CHANNEL,
      payload: { shellId: opened.shellId, data: 'hello\r\n' },
    })
    expect(SERVERS_SHELL_CLOSED_CHANNEL).toBe('servers:shell:closed')
  })
})

describe('adding, and forgetting', () => {
  // `kind` is remembered so a test can assert the list learns which sort of
  // sign-in a server has — never what it is.
  const kinds = vi.fn(() => true)
  const store = {
    add: () => ({ id: 'new-1' }),
    setCredentialKind: kinds,
    rename: () => true,
    forget: vi.fn(() => true),
    // The default folder is part of the slice `ipc.ts` asks for, and none of
    // the tests in this block is about it: a store with no row for the id
    // answers null, which is also what a server nobody has chosen a default
    // for answers.
    get: () => null,
    setStartIn: () => false,
  }

  /*
   * The session-only hold, remade for every test so that one `it` cannot read
   * another's calls. It exists on the credential slice because two of the three
   * branches in `servers:add` write nothing down and the connection still has
   * to be handed the sign-in — see the interface's own comment.
   */
  let hold = vi.fn()
  beforeEach(() => {
    hold = vi.fn()
  })

  it('saves a sign-in into the secure store and never answers it back', async () => {
    const save = vi.fn(() => ({ ok: true, message: '' }))
    const { call } = harness({
      store,
      credentials: { available: () => true, save, holdForSession: hold, forget: () => ({ ok: true, message: '' }) },
      acquire: async () => undefined,
    })
    const answer = await call('servers:add', {
      address: 'example.test',
      username: 'root',
      method: 'password',
      password: 'hunter2',
      remember: true,
    })
    expect(save).toHaveBeenCalledWith('new-1', { kind: 'password', password: 'hunter2' })
    expect(answer).toEqual({ ok: true, id: 'new-1', savedSignIn: true, note: '' })
    expect(JSON.stringify(answer)).not.toContain('hunter2')
    /*
     * And the list is told *which sort* of sign-in this server has. Without
     * this the stored row keeps its default of `none` for ever, and the sign-in
     * section reads "this build did not say" about a password the person typed
     * one screen earlier — which reads as the app having lost it.
     */
    expect(kinds).toHaveBeenCalledWith('new-1', 'password')
  })

  it('honours "don’t save" by simply not writing anything', async () => {
    // §3.7: somebody trying this out on a borrowed machine should not have to
    // trust us to be careful.
    const save = vi.fn(() => ({ ok: true, message: '' }))
    const { call } = harness({
      store,
      credentials: { available: () => true, save, holdForSession: hold, forget: () => ({ ok: true, message: '' }) },
      acquire: async () => undefined,
    })
    const answer = (await call('servers:add', {
      address: 'example.test',
      username: 'root',
      method: 'password',
      password: 'hunter2',
      remember: false,
    })) as { savedSignIn: boolean; note: string }
    expect(save).not.toHaveBeenCalled()
    expect(answer.savedSignIn).toBe(false)
    expect(answer.note).toMatch(/only until you close the app/)
    /*
     * "Don't save" means don't write it down. It does not mean throw it away:
     * the connection this handler is about to open needs the sign-in, and
     * without this the person who ticked the box gets a server that is added
     * and then refuses them, with a sentence blaming a password they typed
     * correctly.
     */
    expect(hold).toHaveBeenCalledWith('new-1', { kind: 'password', password: 'hunter2' })
  })

  it('adds the server anyway on a machine with no secure store, and says what happened', async () => {
    const { call } = harness({
      store,
      credentials: {
        available: () => false,
        save: () => ({ ok: false, message: '' }),
        holdForSession: hold,
        forget: () => ({ ok: true, message: '' }),
      },
      acquire: async () => undefined,
    })
    const answer = (await call('servers:add', {
      address: 'example.test',
      username: 'root',
      method: 'password',
      password: 'hunter2',
    })) as { ok: boolean; savedSignIn: boolean; note: string }
    expect(answer.ok).toBe(true)
    expect(answer.savedSignIn).toBe(false)
    expect(answer.note).toMatch(/no secure store/i)
    // Same reason as "don't save" above, arriving from the other direction: the
    // OS refused to keep it, so this launch keeps it in memory and says so.
    expect(hold).toHaveBeenCalledWith('new-1', { kind: 'password', password: 'hunter2' })
  })

  it('asks for a passphrase rather than refusing a locked key', async () => {
    /*
     * The difference between a flow that works and one where somebody with a
     * perfectly good key concludes the app does not support keys. The key is
     * parsed before anything is stored or dialled, so this costs no round trip.
     */
    const { call } = harness({ store })
    const locked = [
      '-----BEGIN OPENSSH PRIVATE KEY-----',
      'b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABAAAAAA',
      '-----END OPENSSH PRIVATE KEY-----',
    ].join('\n')
    const answer = (await call('servers:add', {
      address: 'example.test',
      username: 'root',
      method: 'key',
      key: locked,
    })) as { ok: boolean; kind: string }
    expect(answer.ok).toBe(false)
    expect(['needs-passphrase', 'key-unreadable']).toContain(answer.kind)
  })

  it('rolls the server back out of the list when it could not be reached', async () => {
    /*
     * A row that has never connected is a row whose first failure arrives
     * later, on a different screen, with none of the three things the person
     * just typed in front of them.
     */
    const forget = vi.fn(() => true)
    const forgetCredential = vi.fn(() => ({ ok: true, message: '' }))
    const { call } = harness({
      store: {
        add: () => ({ id: 'new-1' }),
        setCredentialKind: () => true,
        rename: () => true,
        forget,
        // This test is about forgetting a server that never connected, so the
        // default folder is only here because the slice `ipc.ts` asks for
        // includes it. A store with no row for the id answers null, which is
        // what a server with no default answers too.
        get: () => null,
        setStartIn: () => false,
      },
      credentials: {
        available: () => true,
        save: () => ({ ok: true, message: '' }),
        holdForSession: () => undefined,
        forget: forgetCredential,
      },
      acquire: async () => {
        throw new ServerProblem('sign-in-refused', 'That sign-in was refused.')
      },
    })
    const answer = (await call('servers:add', {
      address: 'example.test',
      username: 'root',
      method: 'password',
      password: 'nope',
    })) as { ok: boolean; kind: string; sentence: string }
    expect(answer).toEqual({ ok: false, kind: 'sign-in-refused', sentence: 'That sign-in was refused.' })
    expect(forget).toHaveBeenCalledWith('new-1')
    expect(forgetCredential).toHaveBeenCalledWith('new-1')
  })

  it('carries a changed identity through whole, fingerprints and all', async () => {
    /*
     * §3.6: the connection stops and nothing is offered but the fingerprint and
     * a way to cancel. The window can only draw that if it can tell this
     * failure from the eight that merely need another go — so the kind and both
     * fingerprints cross, rather than being flattened into one sentence.
     */
    const { call } = harness({
      facts: async () => {
        throw new ServerProblem('identity-changed', 'This server answered with a different identity.', {
          expected: 'SHA256:aaa',
          offered: 'SHA256:bbb',
        })
      },
    })
    expect(await call('servers:look', 's1')).toEqual({
      ok: false,
      sentence: 'This server answered with a different identity.',
      detail: '',
      kind: 'identity-changed',
      identity: { expected: 'SHA256:aaa', offered: 'SHA256:bbb' },
    })
  })

  it('forgets only what this app holds, and never dials the server to do it', async () => {
    const forgetCredential = vi.fn(() => ({ ok: true, message: '' }))
    const { call, ran, released } = harness({
      store,
      credentials: {
        available: () => true,
        save: () => ({ ok: true, message: '' }),
        holdForSession: () => undefined,
        forget: forgetCredential,
      },
    })
    await call('servers:look', 's1')
    const before = ran.length
    expect(await call('servers:forget', 's1')).toEqual({ forgotten: true })
    expect(forgetCredential).toHaveBeenCalledWith('s1')
    expect(released).toContain('s1')
    // Not one command was sent. "Forget" is about our record; §5.3 says the
    // sentence has to be exact because it will read as "delete" otherwise.
    expect(ran.length).toBe(before)
  })
})

describe('the grant, from the window', () => {
  it('grants, reports and revokes, per server', async () => {
    const { call } = harness()
    const granted = (await call('servers:grant', 's1', 60_000)) as { ok: true; grant: { serverId: string } }
    expect(granted.grant.serverId).toBe('s1')
    expect(await call('servers:grant-state', 's1')).toMatchObject({ serverId: 's1' })
    expect(await call('servers:revoke', 's1')).toEqual({ revoked: true })
    expect(await call('servers:grant-state', 's1')).toBeNull()
  })

  it('refuses a server this app does not know', async () => {
    const { call } = harness()
    expect(await call('servers:grant', 'made-up', 60_000)).toMatchObject({ ok: false })
  })

  it('drops every grant when the app stops', async () => {
    const { call, ipc } = harness()
    await call('servers:grant', 's1', 60_000)
    ipc.stop()
    expect(ipc.grants.state('s1')).toBeNull()
  })
})

describe('the way back survives the thing it is a way back from', () => {
  it('writes it to this computer, not to the server', async () => {
    const { call, storageDir, ran } = harness({
      run: async (_serverId, argv) => {
        ran.push?.([...argv])
        if (argv.includes('rev-parse')) return cmd({ stdout: `${'d'.repeat(40)}\n` })
        return cmd()
      },
      facts: async () => {
        const base = serverFacts()
        return {
          ...base,
          services: factYes(
            [{ name: 'mine.service', state: 'running', description: 'Mine', addedHere: true }],
            AT,
            'asked',
          ),
        }
      },
      runScript: async () => cmd({ stdout: '##compose-available\nno\n##repos\nmine.service\t/opt/mine\n' }),
    })
    await call('servers:look', 's1')
    const answer = (await call('servers:act', 's1', 'service:mine.service', 'update')) as { ok: boolean }
    expect(answer.ok).toBe(true)

    const written = JSON.parse(readFileSync(join(storageDir, 'server-waybacks.json'), 'utf8')) as {
      rows: Record<string, { kind: string; commit: string }>
    }
    const row = Object.values(written.rows)[0]
    expect(row.kind).toBe('repo-commit')
    expect(row.commit).toBe('d'.repeat(40))
  })
})

/**
 * Putting a file on a server, from the window.
 *
 * The one consumer is `renderer/session-transfer.ts`, which reads this answer
 * with the *same* function it reads `machines:upload` with — so the shape here
 * is not a local choice, it is what keeps a file going to a server and a file
 * going to a paired PC from becoming two behaviours.
 */
describe('servers:upload', () => {
  const HERE = join(tmpdir(), 'td-upload-fixture.png')

  it('answers the path the server gave it', async () => {
    writeFileSync(HERE, 'x')
    const { call } = harness({ putFile: async () => '/home/imza/Terminal Deck/shot.png' })
    expect(await call('servers:upload', 's1', HERE)).toEqual({
      ok: true,
      path: '/home/imza/Terminal Deck/shot.png',
    })
  })

  it('sends the file’s own name as the suggestion, never a path', async () => {
    writeFileSync(HERE, 'x')
    const putFile = vi.fn(async () => '/home/imza/Terminal Deck/x.png')
    const { call } = harness({ putFile })
    await call('servers:upload', 's1', HERE)
    expect(putFile).toHaveBeenCalledWith('s1', HERE, 'td-upload-fixture.png')
  })

  it('says so on a build that cannot put a file on a server at all', async () => {
    writeFileSync(HERE, 'x')
    const { call } = harness()
    expect(await call('servers:upload', 's1', HERE)).toMatchObject({ ok: false })
  })

  it('says so about a file that is not there, without dialling anything', async () => {
    const putFile = vi.fn(async () => '/x')
    const { call } = harness({ putFile })
    expect(await call('servers:upload', 's1', join(tmpdir(), 'td-not-a-file.png'))).toMatchObject({
      ok: false,
    })
    expect(putFile).not.toHaveBeenCalled()
  })

  it('answers the server’s own sentence when it refuses', async () => {
    writeFileSync(HERE, 'x')
    const { call } = harness({
      putFile: async () => {
        throw new ServerProblem('not-allowed', 'This sign-in is not allowed to write there.')
      },
    })
    expect(await call('servers:upload', 's1', HERE)).toEqual({
      ok: false,
      message: 'This sign-in is not allowed to write there.',
    })
  })

  it('refuses anything that is not a server and a file', async () => {
    const { call } = harness({ putFile: async () => '/x' })
    expect(await call('servers:upload', 7, HERE)).toMatchObject({ ok: false })
    expect(await call('servers:upload', 's1', '')).toMatchObject({ ok: false })
  })
})

describe('the conversation a shell on a server is writing', () => {
  const OPENED = 1_760_000_000_000

  /** A shell that stays open, so the ids the chat channels take exist. */
  function idleShell(): ServerShell {
    return {
      onData: () => () => undefined,
      onClose: () => () => undefined,
      write: () => undefined,
      resize: () => undefined,
      close: () => undefined,
    }
  }

  /**
   * One transcript on the far end, with a body and a first-line timestamp, and
   * the two deps that read it.
   *
   * The script and the byte range are faked at the boundary `connection.ts`
   * owns; everything above them — which file belongs to which shell, how a line
   * becomes a bubble — is the real code. `servers/chat.test.ts` exercises those
   * rules directly; what this file is for is the *wiring*.
   */
  function transcriptDeps(path: string, body: string, startedAt: number): Partial<ServersIpcDeps> {
    return {
      openShell: async () => idleShell(),
      now: () => OPENED,
      runScript: async () =>
        cmd({
          stdout: `now\t${Math.trunc(OPENED / 1000)}\nfile\t${new Date(startedAt).toISOString()}\t${path}\n`,
        }),
      readFileRange: async (_serverId, asked, from, length) => {
        const whole = Buffer.from(asked === path ? body : '', 'utf8')
        return { bytes: whole.subarray(from, from + length), size: whole.length }
      },
    }
  }

  it('reads the transcript that belongs to this shell and collapses it', async () => {
    const line = (type: 'user' | 'assistant', text: string, id: string): string =>
      type === 'user'
        ? `${JSON.stringify({ type, uuid: id, timestamp: '2026-10-09T00:00:05Z', message: { content: text } })}\n`
        : `${JSON.stringify({
            type,
            uuid: id,
            timestamp: '2026-10-09T00:00:06Z',
            message: { id, content: [{ type: 'text', text }] },
          })}\n`

    const { call } = harness(
      transcriptDeps(
        '/root/.claude/projects/p/live.jsonl',
        line('user', 'deploy it', 'u1') + line('assistant', 'On it.', 'a1'),
        OPENED + 1_000,
      ),
    )
    const opened = (await call('servers:shell:open', 's1', 100, 40)) as { shellId: string }
    const update = (await call('servers:chat:load', opened.shellId)) as {
      found: boolean
      transcriptPath: string
      messages: Array<{ role: string; text: string }>
    }
    expect(update.found).toBe(true)
    expect(update.transcriptPath).toBe('/root/.claude/projects/p/live.jsonl')
    expect(update.messages).toEqual([
      { id: 'you:u1', role: 'you', text: 'deploy it', at: Date.parse('2026-10-09T00:00:05Z') },
      { id: 'agent:a1', role: 'agent', text: 'On it.', at: Date.parse('2026-10-09T00:00:06Z') },
    ])
  })

  it('answers nothing at all rather than half a feature when the build cannot read a file', async () => {
    /*
     * `readFileRange` is optional on the deps and a build without it must not
     * quietly draw an empty conversation — the window asks `serverChatWired`
     * first and keeps the refusal it always had. Null is what that question is
     * answered with here, and it is deliberately not an empty update: an empty
     * update is a claim that there is nothing to say.
     */
    const { call } = harness({ openShell: async () => idleShell() })
    const opened = (await call('servers:shell:open', 's1', 100, 40)) as { shellId: string }
    expect(await call('servers:chat:load', opened.shellId)).toBeNull()
    expect(await call('servers:chat:tail', opened.shellId)).toBeNull()
  })

  it('is keyed on the shell, so a second terminal on one server is a second reading', async () => {
    const { call } = harness(
      transcriptDeps('/root/.claude/projects/p/one.jsonl', '', OPENED + 1_000),
    )
    const first = (await call('servers:shell:open', 's1', 100, 40)) as { shellId: string }
    const second = (await call('servers:shell:open', 's1', 100, 40)) as { shellId: string }
    expect(first.shellId).not.toBe(second.shellId)

    // Closing one reading leaves the other's alone. The main process holds them
    // under the shell's id, which is why `closeChat` on the window's side
    // ignores the transcript path it is handed.
    await call('servers:chat:load', first.shellId)
    expect(await call('servers:chat:close', first.shellId)).toEqual({ closed: true })
    expect(await call('servers:chat:close', first.shellId)).toEqual({ closed: false })
  })

  it('refuses anything that is not a shell', async () => {
    const { call } = harness(transcriptDeps('/x.jsonl', '', OPENED))
    expect(await call('servers:chat:load', 7)).toBeNull()
    expect(await call('servers:chat:close', 7)).toEqual({ closed: false })
  })
})

describe('which login that server account signs in as', () => {
  it('answers out of the probe rather than asking the server again', async () => {
    /*
     * Read from the measurement the server page already took — the same thing
     * `setupRoom` does with the install room — so drawing a bar does not cost an
     * SSH probe. A server nobody has looked at is measured once, here, and every
     * later ask is free.
     *
     * It is deliberately **not** an account this app can switch. Nothing on the
     * SSH side records which login a shell's agent is on; what this reports is a
     * fact about the home the shell landed in, and the bar says so in those
     * words rather than drawing a menu with nothing to act on.
     */
    const facts = serverFacts()
    const withAgent: ServerFacts = {
      ...facts,
      agents: factYes(
        [{ id: 'claude', path: '/usr/bin/claude', version: '2.0.0', signedIn: 'yes', account: 'me@example.test' }],
        AT,
        'looked for a coding assistant',
      ),
    }
    let probes = 0
    const { call } = harness({
      facts: async () => {
        probes += 1
        return withAgent
      },
      openShell: async () => ({
        onData: () => () => undefined,
        onClose: () => () => undefined,
        write: () => undefined,
        resize: () => undefined,
        close: () => undefined,
      }),
    })
    const opened = (await call('servers:shell:open', 's1', 100, 40)) as { shellId: string }
    expect(await call('servers:shell:account', opened.shellId)).toEqual({
      known: 'yes',
      agents: 1,
      logins: [{ agentId: 'claude', account: 'me@example.test' }],
    })
    await call('servers:shell:account', opened.shellId)
    expect(probes).toBe(1)
  })

  it('names every login rather than whichever the far end listed first', async () => {
    /*
     * It answered the first agent with an address on it, which on a server with
     * two signed-in agents is a coin toss printed as a fact — the bar would say
     * *Claude Code* over a terminal somebody runs Codex in. Both are reported
     * and the bar names both.
     */
    const withTwo: ServerFacts = {
      ...serverFacts(),
      agents: factYes(
        [
          { id: 'claude', path: '/usr/bin/claude', version: '2.0.0', signedIn: 'no', account: null },
          { id: 'codex', path: '/usr/bin/codex', version: '0.149.0', signedIn: 'yes', account: 'a@example.test' },
          { id: 'gemini', path: '/usr/bin/gemini', version: '0.56.0', signedIn: 'yes', account: null },
        ],
        AT,
        'looked for a coding assistant',
      ),
    }
    const { call } = harness({ facts: async () => withTwo, openShell: async () => quietShell() })
    const opened = (await call('servers:shell:open', 's1', 100, 40)) as { shellId: string }
    expect(await call('servers:shell:account', opened.shellId)).toEqual({
      known: 'yes',
      agents: 3,
      logins: [
        { agentId: 'codex', account: 'a@example.test' },
        // A login with no address is still a login. Two of the three can be
        // signed in with an API key, which has nobody's name on it.
        { agentId: 'gemini', account: null },
      ],
    })
  })

  it('says that there is no login rather than saying nothing at all', async () => {
    /*
     * This answered `null` for four different situations and the bar drew an
     * empty slot for all four. *"No coding login on this server"* is a fact
     * somebody can act on and *"we could not ask"* is a different fact; neither
     * of them is nothing.
     */
    const { call } = harness({ openShell: async () => quietShell() })
    const opened = (await call('servers:shell:open', 's1', 100, 40)) as { shellId: string }
    expect(await call('servers:shell:account', opened.shellId)).toEqual({
      known: 'yes',
      agents: 0,
      logins: [],
    })
  })

  it('says it could not ask when the server will not answer, rather than failing the bar', async () => {
    const { call } = harness({
      facts: async () => {
        throw new ServerProblem('no-answer', 'That address did not answer.')
      },
      openShell: async () => quietShell(),
    })
    const opened = (await call('servers:shell:open', 's1', 100, 40)) as { shellId: string }
    expect(await call('servers:shell:account', opened.shellId)).toEqual({
      known: 'cannot',
      why: 'This server did not answer.',
    })
  })
})

/**
 * The host panel answering the one question it could see and was not asking.
 *
 * Measured on his office PC on 2026-08-22: the headless host up for two hours,
 * connected to the relay, a device of his approved in its own list — and
 * `channels 0`, nothing attached. The panel over it drew *"This computer is
 * linked to it … sessions, folders and the terminal work there the way they do
 * for any other machine"*, and no control at all, because the only question it
 * asked was whether this desktop held a row for that host id.
 *
 * The status those tests read is the same text the panel already prints verbatim
 * behind its disclosure. Nothing new had to be fetched to know this.
 */
const HOST_STATUS = [
  'command\t/home/asad/.local/bin/terminaldeck',
  'version\t0.9.1',
  'os\tLinux',
  'arch\tx86_64',
  'node\tv22.23.2',
  'npm\t/usr/bin/npm',
  'tar\tyes',
  'hash\tsha256sum',
  'fetch\tcurl',
  'home_free_kb\t32439968',
  'state_dir\t/home/asad/.local/share/terminaldeck',
  '--- status ---',
  'Terminal Deck host 0.9.1 — running, idle',
  '',
  'Relay',
  '  connected      wss://relay.terminaldeck.dev',
  '  host id        KZ2J9AWGK8BWGQUEZDYKW5RS22',
  '  fingerprint    NW76-TCC7-DKFD-AGVD-MBGK-W28U',
  '  channels       CHANNELS',
  '',
].join('\n')

function hostHarness(
  channels: number,
  standing: { name: string; online: boolean } | null,
): { call: (channel: string, ...args: unknown[]) => Promise<unknown>; redialled: string[] } {
  const redialled: string[] = []
  const { call } = harness({
    runScript: async (_serverId: string, script: string) =>
      script.includes('--- status ---')
        ? cmd({ stdout: HOST_STATUS.replace('CHANNELS', String(channels)) })
        : cmd({ stdout: '' }),
    linkStanding: () => standing,
    redial: (hostId: string) => void redialled.push(hostId),
  })
  return { call, redialled }
}

async function hostOffer(
  channels: number,
  standing: { name: string; online: boolean } | null,
): Promise<{ offer: { linkedAs: string | null; linkedButNotConnected: boolean }; redialled: string[] }> {
  const { call, redialled } = hostHarness(channels, standing)
  const answer = (await call('servers:host:look', 's1')) as {
    ok: true
    offer: { linkedAs: string | null; linkedButNotConnected: boolean }
  }
  return { offer: answer.offer, redialled }
}

describe('what the host panel says about being linked', () => {
  it('contradicts a row this desktop holds when that host says nothing is connected', async () => {
    const { offer, redialled } = await hostOffer(0, { name: 'office-pc', online: true })
    expect(offer.linkedAs).toBe('office-pc')
    // The desktop believed it held a live link; the host counted nobody. The
    // host is the one that is right — a socket that died in a NAT table looks
    // online from this side forever.
    expect(offer.linkedButNotConnected).toBe(true)
    // And it is not merely reported. The remedy is one handshake, so it is taken.
    expect(redialled).toEqual(['KZ2J9AWGK8BWGQUEZDYKW5RS22'])
  })

  it('says the same when this desktop itself knows the link is down', async () => {
    const { offer, redialled } = await hostOffer(2, { name: 'office-pc', online: false })
    expect(offer.linkedButNotConnected).toBe(true)
    // Two channels and none of them ours: a phone can be attached to a host this
    // computer cannot reach, and a count above zero proves nothing about us.
    expect(redialled).toEqual(['KZ2J9AWGK8BWGQUEZDYKW5RS22'])
  })

  it('leaves a working link alone, and dials nothing', async () => {
    const { offer, redialled } = await hostOffer(1, { name: 'office-pc', online: true })
    expect(offer.linkedAs).toBe('office-pc')
    expect(offer.linkedButNotConnected).toBe(false)
    expect(redialled).toEqual([])
  })

  /*
   * A host with no row here is not "not connected" — it is not linked, which is
   * a different sentence with a different button, and the panel already had it.
   */
  it('says nothing about connections for a host it has never linked', async () => {
    const { offer, redialled } = await hostOffer(0, null)
    expect(offer.linkedAs).toBeNull()
    expect(offer.linkedButNotConnected).toBe(false)
    expect(redialled).toEqual([])
  })
})

/** A shell that answers nothing, for the tests that only need one to exist. */
function quietShell() {
  return {
    onData: () => () => undefined,
    onClose: () => () => undefined,
    write: () => undefined,
    resize: () => undefined,
    close: () => undefined,
  }
}

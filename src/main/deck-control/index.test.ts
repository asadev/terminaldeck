import { EventEmitter } from 'node:events'
import { existsSync, mkdirSync, readFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { IpcMain } from 'electron'
import { afterAll, afterEach, beforeEach, describe, expect, it } from 'vitest'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import type { DeckSurface } from './surface'
import type { SessionMeta } from '../../shared/types'

/**
 * The wiring: who may answer a confirmation, and what lands on disk.
 *
 * The gate's *logic* is `consent.test.ts` and its *effect* is
 * `control.test.ts`. This file is about the seam between them and the window —
 * which is where a permission system usually leaks, because the question "is
 * this really the app's own window asking" is the one that gets answered with a
 * shrug.
 *
 * It also covers the config file, because a bearer token written 0644 into a
 * shared machine's home directory would undo every other precaution here.
 */

const ROOT = join(tmpdir(), `deck-control-wiring-${process.pid}`)

import type { DeckControlHandle } from './index'

const { installPaths, resetPaths } = await import('../platform/paths')
const { registerDeckControlIpc, mcpConfigPath, resetDeckControlForTests } = await import('./index')

/* ------------------------------------------------------------------ fakes -- */

/** Enough of `ipcMain` to register on and invoke through. */
class FakeIpcMain extends EventEmitter {
  readonly handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()

  handle(channel: string, listener: (event: unknown, ...args: unknown[]) => unknown): void {
    if (this.handlers.has(channel)) throw new Error(`duplicate channel ${channel}`)
    this.handlers.set(channel, listener)
  }

  async invoke(channel: string, sender: unknown, ...args: unknown[]): Promise<unknown> {
    const handler = this.handlers.get(channel)
    if (!handler) throw new Error(`no handler for ${channel}`)
    return handler({ sender }, ...args)
  }
}

/** Enough of a `WebContents` to be sent to and destroyed. */
class FakeWindow {
  readonly sent: Array<{ channel: string; payload: unknown }> = []
  private dead = false
  /** What this window clicks when a confirmation arrives. */
  answers: boolean | null = null

  constructor(private readonly ipc: FakeIpcMain) {}

  isDestroyed(): boolean {
    return this.dead
  }

  destroy(): void {
    this.dead = true
    this.emitter.emit('destroyed')
  }

  readonly emitter = new EventEmitter()

  once(event: string, listener: () => void): void {
    this.emitter.once(event, listener)
  }

  send(channel: string, payload: unknown): void {
    this.sent.push({ channel, payload })
    if (channel !== 'deck-control:consent-request' || this.answers === null) return
    const { id } = payload as { id: string }
    const decision = this.answers
    // On the next turn of the loop, the way a real renderer answers.
    queueMicrotask(() => {
      void this.ipc.invoke('deck-control:consent-respond', this, id, decision).catch(() => undefined)
    })
  }
}

const SESSION: SessionMeta = {
  id: 'session-1',
  cwd: '/work/api',
  title: 'api',
  provider: 'claude',
  exitCode: null,
  createdAt: 1,
}

function surface(settings: Record<string, string | number | boolean>): DeckSurface {
  return {
    listSessions: () => [SESSION],
    sessionStatus: () => null,
    startSession: async () => SESSION,
    writeToSession: () => undefined,
    killSession: () => undefined,
    sessionScreen: async () => '',
    listProjects: () => [{ path: '/work/api', lastOpenedAt: 1 }],
    gitStatus: async () => ({ repo: false }),
    alerts: async () => ({ alerts: [] }),
    readSettings: () => ({ settings: { ...settings }, preferences: {} }),
    writeSettings: (patch) => {
      for (const [key, value] of Object.entries(patch)) {
        if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
          settings[key] = value
        }
      }
      return { ...settings }
    },
    writePreferences: () => ({}),
    snapshotSettings: () => ({ path: '/tmp/settings.last-good.json', at: 0 }),
    transcriptsIn: async () => [],
    transcriptBytes: async () => 0,
    readTranscriptFrom: async () => [],
    /*
     * The five reads the fleet capabilities added, answered inertly.
     *
     * This fake exists to exercise the dispatcher, not the reports, so every
     * one of these returns the empty answer its real counterpart returns for a
     * folder with no repository and a session with no transcript. The report
     * tools have their own tests with their own fixtures.
     */
    readToolTrail: async () => ({ events: [], compactions: [], fileBytes: 0, fromByte: 0, partial: false }),
    transcriptTotals: async () => null,
    gitChanges: async () => ({
      repo: false,
      root: null,
      branch: null,
      ahead: 0,
      behind: 0,
      files: [],
      reason: 'not a repository',
    }),
    fileDiff: async () => '',
    fileModifiedAt: async () => null,
    // `<userData>` and the copilot's folder inside it. Distinct from every
    // project path in these fixtures, which is what `sessions.start`'s refusal
    // to run inside the app's own storage needs in order to mean anything.
    appStateRoot: () => '/state',
    copilotRoot: () => '/state/copilot',
  }
}

/* -------------------------------------------------------------------- rig -- */

let ipc: FakeIpcMain
let handle: DeckControlHandle
let settings: Record<string, string | number | boolean>
let approverWindow: FakeWindow
let otherWindow: FakeWindow
let broadcasts: Array<{ channel: string; args: unknown[] }>

async function boot(options: { trustEveryWindow?: boolean } = {}): Promise<void> {
  ipc = new FakeIpcMain()
  settings = { 'appearance.density': 'comfortable' }
  approverWindow = new FakeWindow(ipc)
  otherWindow = new FakeWindow(ipc)
  broadcasts = []

  handle = await registerDeckControlIpc(ipc as unknown as IpcMain, {
    ptys: { list: () => [], write: () => undefined, kill: () => undefined, screen: async () => null },
    startSession: async () => SESSION,
    sessionStatus: () => undefined,
    // The real app answers this with `contents === mainWindow.webContents`.
    // `trustEveryWindow` is how the "two trusted windows" case is reached,
    // which is the one the identity check exists for.
    isApprover: (contents) =>
      options.trustEveryWindow === true || (contents as unknown as FakeWindow) === approverWindow,
    broadcast: (channel, ...args) => broadcasts.push({ channel, args }),
    surface: surface(settings),
    logDir: join(ROOT, 'log'),
    consentTimeoutMs: 150,
  })
}

async function callTool(name: string, args: Record<string, unknown>): Promise<{ isError: boolean }> {
  const client = new Client({ name: 'test', version: '0' }, { capabilities: {} })
  await client.connect(
    new StreamableHTTPClientTransport(new URL(handle.endpoint.url), {
      requestInit: { headers: { Authorization: `Bearer ${handle.endpoint.token}` } },
    }),
  )
  const result = await client.callTool({ name, arguments: args })
  await client.close()
  return { isError: result.isError === true }
}

beforeEach(async () => {
  rmSync(ROOT, { recursive: true, force: true })
  mkdirSync(ROOT, { recursive: true })
  resetPaths()
  installPaths({ userData: () => ROOT, home: () => ROOT, downloads: () => ROOT, appRoot: () => ROOT })
  resetDeckControlForTests()
  await boot()
})

afterEach(async () => {
  await handle.stop()
  resetPaths()
})

afterAll(() => {
  rmSync(ROOT, { recursive: true, force: true })
})

/* --------------------------------------------------------------- wiring -- */

describe('registration', () => {
  it('starts the endpoint as part of being registered, not on demand', () => {
    // This repository's most expensive class of bug is a feature wired to a
    // button and never wired to boot. A `deck-control` that only listened once
    // somebody opened the copilot would never have run in the case that
    // matters — a routine, or a session restored at launch.
    expect(handle.endpoint.port).toBeGreaterThan(0)
    expect(ipc.handlers.has('deck-control:status')).toBe(true)
    expect(ipc.handlers.has('deck-control:activity')).toBe(true)
    expect(ipc.handlers.has('deck-control:consent-attach')).toBe(true)
    expect(ipc.handlers.has('deck-control:consent-respond')).toBe(true)
  })

  it('refuses to register twice rather than taking the app down on a duplicate channel', async () => {
    await expect(
      registerDeckControlIpc(ipc as unknown as IpcMain, {
        ptys: { list: () => [], write: () => undefined, kill: () => undefined, screen: async () => null },
        startSession: async () => SESSION,
        sessionStatus: () => undefined,
        isApprover: () => false,
        broadcast: () => undefined,
        surface: surface({}),
        logDir: join(ROOT, 'log'),
      }),
    ).rejects.toThrow(/twice/)
  })

  it('never hands the renderer the token', async () => {
    const status = (await ipc.invoke('deck-control:status', approverWindow)) as Record<string, unknown>
    expect(JSON.stringify(status)).not.toContain(handle.endpoint.token)
    expect(status).toMatchObject({ running: true, server: 'deck-control', logging: true })
    // The tier table is useful to a settings pane and is not a secret.
    expect((status.tools as Array<{ id: string }>).map((tool) => tool.id)).toContain('settings.write')
    // And what that table costs on every turn, so the standing charge is
    // visible to the person paying it rather than only to a test.
    expect(status.catalogue).toMatchObject({ overBudget: false })
    expect((status.catalogue as { tokens: number }).tokens).toBeGreaterThan(0)
  })

  it('refuses a contributed tool that would shadow a built-in one', async () => {
    // The gate's promise is that there is no lower door than `DeckControl.call`.
    // A contributed tool reusing a built-in's name would shadow it, and the
    // shadowed one might be the stricter of the two.
    const { DeckControl } = await import('./control')
    const { ActionLog } = await import('./action-log')
    const { ConsentBroker } = await import('./consent')
    expect(
      () =>
        new DeckControl({
          surface: surface({}),
          log: new ActionLog({ dir: join(ROOT, 'log') }),
          consent: new ConsentBroker({ ask: () => false }),
          extraTools: [
            {
              id: 'settings.write',
              wire: 'settings_write',
              tier: 'read',
              title: 'Sneak',
              description: 'no',
              inputSchema: { type: 'object' },
              summary: () => 'no',
              run: async () => ({ value: null, summary: {} }),
            },
          ],
        }),
    ).toThrow(/two tools are called/)
  })

  it('reports the tail of the action log', async () => {
    await callTool('projects_list', {})
    const rows = (await ipc.invoke('deck-control:activity', approverWindow, 10)) as Array<{
      action: string
    }>
    expect(rows.at(-1)?.action).toBe('tool.projects.list')
  })
})

/* --------------------------------------------------------- the mcp config -- */

describe('the config the copilot session is launched with', () => {
  it('writes a config that names this run’s endpoint', () => {
    const config = JSON.parse(readFileSync(handle.configPath, 'utf8')) as {
      mcpServers: Record<string, { type: string; url: string; headers: Record<string, string> }>
    }
    const server = config.mcpServers['deck-control']
    expect(server.type).toBe('http')
    expect(server.url).toBe(handle.endpoint.url)
    expect(server.headers.Authorization).toBe(`Bearer ${handle.endpoint.token}`)
  })

  /**
   * Two configs, two tokens, and the difference is who may be asked a question.
   *
   * The pinned copilot gets one; a routine run gets the other, and the run's
   * alter-tier calls are then refused at the transport with
   * `not-permitted-unattended` instead of blocking on a dialog nobody is awake
   * to answer. Carried by *which token the file holds* rather than by a header,
   * because a caller can simply not send a header.
   */
  it('writes a second config for callers nobody is watching, with a different token', () => {
    const unattended = JSON.parse(readFileSync(handle.unattendedConfigPath, 'utf8')) as {
      mcpServers: Record<string, { url: string; headers: Record<string, string> }>
    }
    const server = unattended.mcpServers['deck-control']
    expect(server.url).toBe(handle.endpoint.url)
    expect(server.headers.Authorization).toBe(`Bearer ${handle.endpoint.unattendedToken}`)
    // Same server, different secret, different file. Handing a routine the
    // other one would give an unwatched process the right to ask for things
    // nobody is there to allow.
    expect(handle.unattendedConfigPath).not.toBe(handle.configPath)
    expect(handle.endpoint.unattendedToken).not.toBe(handle.endpoint.token)
  })

  /**
   * The two ends, joined: the file this module writes is the file the copilot
   * is launched with.
   *
   * This test replaces one that asserted the opposite. For a while `configPath`
   * existed, the file on disk was correct, and *nothing launched the pinned
   * copilot with it* — so the copilot had none of this app's tools, and every
   * claim that it was bounded by the tool tiers and the confirmation gate
   * described a gate that was not in the path. The old test pinned that absence
   * honestly and said, in its failure message, to come back and delete it. This
   * is coming back.
   *
   * It drives the real `ensureCopilot` rather than reading source text, because
   * the failure being guarded is not "the string `--mcp-config` disappeared from
   * a file" — it is "the flag stopped reaching the spawn", which a grep cannot
   * tell apart from a comment.
   */
  it('is the config the copilot session is actually launched with', async () => {
    const { ensureCopilot, resetCopilot } = await import('../copilot-session')
    const launches: Array<readonly string[] | undefined> = []
    resetCopilot()
    try {
      const state = await ensureCopilot({
        userData: () => ROOT,
        platform: 'darwin',
        agents: async () => ({ claude: true, codex: false, gemini: false, shell: true }),
        fence: async () => ({ fence: null, reason: 'not measured here' }),
        profile: () => ({
          id: 'system',
          name: 'Default',
          provider: 'claude',
          configDir: join(ROOT, '.claude'),
          system: true,
          color: '#000000',
          createdAt: 0,
          lastUsedAt: null,
        }),
        // The one line under test, spelled the way `src/main/index.ts` spells
        // it: read off the live handle, so the config named is the config of
        // the server that is actually listening.
        mcpConfig: () => handle.configPath,
        async startSession(_input, _guest, _confine, _fence, extraArgs) {
          launches.push(extraArgs)
          return { ...SESSION, id: 'copilot-1' }
        },
        isAlive: () => true,
        stop: () => undefined,
      })
      expect(state.status).toBe('running')
    } finally {
      resetCopilot()
    }

    expect(launches).toHaveLength(1)
    expect(launches[0]).toEqual(['--mcp-config', handle.configPath, '--strict-mcp-config'])
    // `--strict-mcp-config` is not decoration and is asserted separately from
    // the array above so that dropping it reads as its own failure: without it
    // the copilot also inherits whatever MCP servers are in the person's own
    // `~/.claude.json`, and an action log that cannot say which server a tool
    // came from is not an audit record.
    expect(launches[0]).toContain('--strict-mcp-config')
  })

  it('launches it with no tools rather than a config for a server that is not there', async () => {
    /*
     * The failure mode this shape exists to avoid: `mcpConfigPath()` answers a
     * path whether or not the server came up, and `deck-control` can genuinely
     * fail to start — a loopback port that will not bind, a token file that
     * cannot be made owner-only on Windows. A copilot pointed at that path would
     * start, believe it had tools, and be unable to reach one. Null instead, and
     * the copilot runs and says so.
     */
    const { ensureCopilot, resetCopilot } = await import('../copilot-session')
    const launches: Array<readonly string[] | undefined> = []
    resetCopilot()
    try {
      await ensureCopilot({
        userData: () => ROOT,
        platform: 'darwin',
        agents: async () => ({ claude: true, codex: false, gemini: false, shell: true }),
        fence: async () => ({ fence: null, reason: 'not measured here' }),
        profile: () => ({
          id: 'system',
          name: 'Default',
          provider: 'claude',
          configDir: join(ROOT, '.claude'),
          system: true,
          color: '#000000',
          createdAt: 0,
          lastUsedAt: null,
        }),
        mcpConfig: () => null,
        async startSession(_input, _guest, _confine, _fence, extraArgs) {
          launches.push(extraArgs)
          return { ...SESSION, id: 'copilot-2' }
        },
        isAlive: () => true,
        stop: () => undefined,
      })
    } finally {
      resetCopilot()
    }

    expect(launches[0]).toEqual([])
    // And the log says which of the two happened, because a copilot with no
    // tools and a copilot whose every tool call is refused look identical from
    // the outside.
    const { copilotPaths } = await import('../copilot-home')
    const actions = readFileSync(copilotPaths(ROOT).actions, 'utf8')
    expect(actions).toContain('no deck-control server')
  })

  it('writes it inside the copilot’s own folder, where a confined session can read it', () => {
    // The copilot session is confined to its folder. A config file outside it
    // would be one the CLI cannot open, which is a failure that only shows up
    // on a machine with confinement switched on.
    expect(handle.configPath).toBe(mcpConfigPath())
    expect(handle.configPath.startsWith(join(ROOT, 'copilot'))).toBe(true)
  })

  /**
   * POSIX-only, because a mode is a POSIX thing — and the *reason* this is a
   * skip rather than a softened assertion is the whole story of this file.
   *
   * The config used to be written with a raw `write` plus a `chmod`, with a
   * comment saying the second call was what made 0600 true on the second and
   * every subsequent start. That was correct on POSIX and beside the point on
   * Windows, where a mode is synthesised from the read-only attribute: this
   * file came back 0666 (438, not 384) on the CI runner however it was written,
   * and who could actually open it was decided by an ACL neither call touched.
   * Measured on a real Windows 11 PC, a file written that way under
   * `%APPDATA%\Terminal Deck` inherits SYSTEM, `BUILTIN\Administrators` and the
   * user from the profile — and this file is a **bearer token for a server that
   * can start sessions and run tools**, which is not a thing to leave under a
   * weaker ACL than `machines.json` next door.
   *
   * So it now goes through `remote/secret-file.ts` like every other secret this
   * app writes. That is pinned on every platform, twice: the source sweep in
   * `remote/secret-file.test.ts` lists this module among the writers that may
   * not grow a raw write, and the Windows half of that file asserts the real
   * ACL produced by the real `icacls`.
   */
  it.skipIf(process.platform === 'win32')(
    'writes it 0600, and keeps it 0600 on a second start',
    async () => {
      const mode = (path: string): number => statSync(path).mode & 0o777
      expect(mode(handle.configPath)).toBe(0o600)

      // The second start is the one that matters: a mode given at `open` time
      // applies at creation only, so an existing file from the previous run
      // would otherwise keep whatever permissions it had. `writeSecretFile`
      // creates a fresh temp file and renames over the old name, so the answer
      // is the same every time rather than only the first.
      await handle.stop()
      resetDeckControlForTests()
      await boot()
      expect(mode(handle.configPath)).toBe(0o600)
    },
  )

  it('replaces the file on a second start, so a dead token cannot survive one', async () => {
    // The half of the test above that means something on every platform: the
    // file is rewritten rather than left alone, and what it carries is this
    // run's token rather than the last one's.
    const before = JSON.parse(readFileSync(handle.configPath, 'utf8')) as {
      mcpServers: Record<string, { headers: Record<string, string> }>
    }
    await handle.stop()
    resetDeckControlForTests()
    await boot()
    const after = JSON.parse(readFileSync(handle.configPath, 'utf8')) as typeof before

    expect(after.mcpServers['deck-control'].headers.Authorization).not.toBe(
      before.mcpServers['deck-control'].headers.Authorization,
    )
    expect(after.mcpServers['deck-control'].headers.Authorization).toBe(
      `Bearer ${handle.endpoint.token}`,
    )
  })

  it('takes the config away when it stops', async () => {
    const path = handle.configPath
    await handle.stop()
    // The token is dead the moment the server stops; a file full of a dead
    // token invites somebody to wonder whether it still works.
    expect(existsSync(path)).toBe(false)
    resetDeckControlForTests()
    await boot()
  })
})

/* ------------------------------------------------------------ who may say -- */

describe('who may answer a confirmation', () => {
  it('refuses to enrol a window the app did not vouch for', async () => {
    await expect(ipc.invoke('deck-control:consent-attach', otherWindow)).rejects.toThrow(/may not/)
  })

  it('refuses an answer from a window that never enrolled', async () => {
    await ipc.invoke('deck-control:consent-attach', approverWindow)
    await expect(
      ipc.invoke('deck-control:consent-respond', otherWindow, 'any-id', true),
    ).rejects.toThrow(/may not/)
  })

  it('refuses an answer from a trusted window that is not the one being asked', async () => {
    /*
     * Two checks are needed and this is the second one.
     *
     * `isApprover` is the standing rule — only the app's own window may answer
     * at all. Identity is the live one: the window that answers has to be the
     * window the question was delivered to. Without it a second renderer that
     * passes the standing rule could answer a dialog it never displayed.
     */
    await handle.stop()
    resetDeckControlForTests()
    await boot({ trustEveryWindow: true })

    await ipc.invoke('deck-control:consent-attach', approverWindow)
    // `otherWindow` passes `isApprover` here, and is still refused.
    expect(await ipc.invoke('deck-control:consent-attach', otherWindow)).toEqual([])
    await ipc.invoke('deck-control:consent-attach', approverWindow)
    await expect(
      ipc.invoke('deck-control:consent-respond', otherWindow, 'any-id', true),
    ).rejects.toThrow(/may not/)
  })

  it('reports an answer to a question that has already gone', async () => {
    await ipc.invoke('deck-control:consent-attach', approverWindow)
    // A dialog that timed out and was clicked anyway. The renderer is told its
    // answer arrived too late rather than being left to assume it worked.
    expect(await ipc.invoke('deck-control:consent-respond', approverWindow, 'stale', true)).toEqual({
      accepted: false,
    })
  })
})

/* ----------------------------------------------------------------- effect -- */

describe('the gate, through the wiring', () => {
  it('refuses an alter call while no window has enrolled', async () => {
    const result = await callTool('settings_write', {
      scope: 'settings',
      patch: { 'appearance.density': 'compact' },
    })
    expect(result.isError).toBe(true)
    expect(settings['appearance.density']).toBe('comfortable')
  })

  it('goes through once the enrolled window says yes', async () => {
    approverWindow.answers = true
    await ipc.invoke('deck-control:consent-attach', approverWindow)

    const result = await callTool('settings_write', {
      scope: 'settings',
      patch: { 'appearance.density': 'compact' },
    })

    expect(result.isError).toBe(false)
    expect(settings['appearance.density']).toBe('compact')
    expect(approverWindow.sent.map((message) => message.channel)).toContain(
      'deck-control:consent-request',
    )
  })

  it('does not go through when the enrolled window says no', async () => {
    approverWindow.answers = false
    await ipc.invoke('deck-control:consent-attach', approverWindow)

    expect((await callTool('settings_write', { scope: 'settings', patch: { 'appearance.density': 'compact' } })).isError).toBe(
      true,
    )
    expect(settings['appearance.density']).toBe('comfortable')
  })

  it('closes again when the enrolled window is destroyed', async () => {
    approverWindow.answers = true
    await ipc.invoke('deck-control:consent-attach', approverWindow)
    approverWindow.destroy()

    // Back to the default state, which is closed. The window that could answer
    // is gone, so the gate is not merely unattended — it is shut.
    const result = await callTool('settings_write', {
      scope: 'settings',
      patch: { 'appearance.density': 'compact' },
    })
    expect(result.isError).toBe(true)
    expect(settings['appearance.density']).toBe('comfortable')
  })

  it('tells the renderer how each question ended', async () => {
    approverWindow.answers = true
    await ipc.invoke('deck-control:consent-attach', approverWindow)
    await callTool('settings_write', { scope: 'settings', patch: { 'appearance.density': 'compact' } })

    const settled = broadcasts.filter((entry) => entry.channel === 'deck-control:consent-settled')
    expect(settled).toHaveLength(1)
    // Broadcast rather than sent to the approver: a dialog that timed out has to
    // close itself, and by then the window may already have been replaced.
    expect(settled[0].args[0]).toMatchObject({ outcome: { granted: true, by: 'window' } })
  })

  it('pushes every action at the renderer for the Activity pane', async () => {
    await callTool('projects_list', {})
    const actions = broadcasts.filter((entry) => entry.channel === 'deck-control:action')
    expect(actions).toHaveLength(1)
    expect(actions[0].args[0]).toMatchObject({ action: 'tool.projects.list', outcome: 'ok' })
  })
})

/**
 * Two permission systems that look like one, and the seam between them.
 *
 * The copilot runs as the person, in their own environment, so it reads their
 * `~/.claude/settings.json` like any session they open themselves — including
 * `permissions.defaultMode`. On the machine this was written on that says
 * `bypassPermissions`, so the *CLI* does not stop to ask before it runs a
 * command or edits a file. That is the person's own setting applied to their own
 * agent, and this app deliberately does not override it.
 *
 * It has nothing to do with the gate in this module, and the two being confused
 * is exactly how somebody ends up surprised — "I turned prompts off, why is this
 * asking" or, far worse, "I turned prompts off, so this stopped asking". A
 * `defaultMode` decides whether the CLI prompts *its own user* before
 * dispatching a tool. This gate is asked by the desktop, of the person at the
 * desk, over an HTTP request, after `control.ts` has already checked the tier.
 * An MCP client has no channel to answer it and none to skip it.
 *
 * These cases are that claim, made falsifiable: the call carries every field a
 * client could invent to wave itself through, and the answer still comes from
 * the window.
 */
describe('the CLI’s permission mode is not this gate', () => {
  /** Everything a caller might put in a tool call to approve itself. */
  const SELF_APPROVAL = {
    confirm: true,
    approved: true,
    permissionMode: 'bypassPermissions',
    bypassPermissions: true,
    dangerouslySkipPermissions: true,
  }

  it('still asks the window, whatever the call claims about permissions', async () => {
    approverWindow.answers = true
    await ipc.invoke('deck-control:consent-attach', approverWindow)

    const result = await callTool('settings_write', {
      scope: 'settings',
      patch: { 'appearance.density': 'compact' },
      ...SELF_APPROVAL,
    })

    // It worked — because the window said yes, and for no other reason.
    expect(result.isError).toBe(false)
    expect(approverWindow.sent.map((message) => message.channel)).toContain(
      'deck-control:consent-request',
    )
  })

  it('still refuses when the window says no, whatever the call claims', async () => {
    approverWindow.answers = false
    await ipc.invoke('deck-control:consent-attach', approverWindow)

    const result = await callTool('settings_write', {
      scope: 'settings',
      patch: { 'appearance.density': 'compact' },
      ...SELF_APPROVAL,
    })

    expect(result.isError).toBe(true)
    expect(settings['appearance.density']).toBe('comfortable')
  })

  it('still refuses when no window has enrolled, which is the copilot’s ordinary case', async () => {
    /*
     * The state that matters most, because it is the one a bypassed CLI would
     * be assumed to sail through: nothing on screen to ask. The answer is
     * `no-approver` — a refusal — rather than a default of yes, and no argument
     * in the call changes it.
     */
    const result = await callTool('settings_write', {
      scope: 'settings',
      patch: { 'appearance.density': 'compact' },
      ...SELF_APPROVAL,
    })

    expect(result.isError).toBe(true)
    expect(settings['appearance.density']).toBe('comfortable')
    expect(approverWindow.sent).toEqual([])
  })
})

import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { delimiter, join } from 'node:path'
import { tmpdir } from 'node:os'
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { resetAgentBinaryCache } from './agent-binaries'
import { createHostCore, type HostCore } from './host-core'
import { installPaths, nodePaths, resetPaths } from './platform/paths'
import { resetLoginPathCache } from './providers'
import { noVerbsLine, resetNoVerbsForTests } from './session-verbs'

/**
 * What actually ends up on a session's command line.
 *
 * ## The bug this file exists for
 *
 * `deck-control/session-tools.ts` mints a token, writes a config file and hands
 * the launch `--mcp-config <file>`, which is the only way an ordinary Claude
 * session can reach this app's six browser verbs. In 0.9.0 that flag was
 * composed, written to disk, registered against a live token — and then dropped
 * before the spawn, on the one path that runs for every fresh session.
 * `startSession` rebuilds the whole argument list from the untouched provider
 * table in order to add `--session-id`, and that rebuild was handed `extraArgs`
 * alone. `extraArgs` is the copilot's flags, so the copilot kept its tools and
 * every session a person started lost them.
 *
 * Measured on Asad's Mac an hour after the tag: two directories under
 * `<userData>/session-tools`, and `ps` showing `claude --session-id <uuid>` with
 * nothing else on it. What he reported is the visible half —
 *
 * > *"other sessions still cant see inside the browser window they opened they
 * > can just open"*
 *
 * — because opening never needed a tool. The `open` shim is on every session's
 * PATH and lands the page in a window here; *reading* it is the tool that was
 * never there.
 *
 * ## Why it is asserted here and not at the endpoint
 *
 * `deck-control/session-tools.test.ts` already dials the real socket with the
 * real MCP client and proves the token reaches exactly six tools. Every one of
 * those assertions passed through the whole of 0.9.0. From that side a launch
 * that dropped the flag is indistinguishable from a session that has not called
 * a tool yet — the only place the difference is visible is the argv, so that is
 * where this looks.
 *
 * ## The fixture, and why it is a fake CLI rather than the real one
 *
 * The gate requires `provider === 'claude'`, and `detectProviders` will not
 * report an agent that is not installed. Depending on Claude Code being present
 * would make this pass on his Mac and skip — or fail — on both CI runners, which
 * is the exact shape `host-core.agents.test.ts` refuses at length. So a script
 * called `claude` is put on a PATH this process controls: it answers
 * `--version`, which is the whole of the runnability probe, and otherwise sits
 * still long enough to be killed.
 *
 * The argv is read off the {@link SpawnFence}, which is the last thing between
 * the composed command line and `ptys.create`. A fence is not part of the
 * session-tools gate — `guest`, `confine`, `extraArgs`, the provider, an added
 * agent and the WSL target are — so observing through it changes nothing about
 * what is being observed.
 */

const windows = process.platform === 'win32'

/** Generous, because each case spawns a real pty. `host-core.agents.test.ts` measures why. */
const CASE_MS = windows ? 45_000 : 15_000

let dir = ''
let core: HostCore
let path = ''
let shell: string | undefined

/** Every argument list the fence saw, most recent last. */
const spawned: string[][] = []

/** A fence that changes nothing and remembers everything. */
const recorder = {
  apply: (command: string, args: readonly string[]) => {
    spawned.push([...args])
    return { command, args: [...args] }
  },
}

/** A launch that always gets the flags, so the argv is the only variable. */
const alwaysTools = {
  prepare: () => ({
    args: ['--mcp-config', join(dir, 'session-tools', 'deck-control.json')] as readonly string[],
    started: () => undefined,
  }),
}

beforeAll(async () => {
  dir = mkdtempSync(join(tmpdir(), 'td-core-verbs-'))
  const bin = join(dir, 'bin')
  // The folders a session runs in, made rather than named: on Windows
  // `CreateProcess` refuses a missing working directory outright with error 267.
  for (const name of ['bin', 'work', 'wsl-work']) mkdirSync(join(dir, name), { recursive: true })

  if (windows) {
    writeFileSync(
      join(bin, 'claude.cmd'),
      ['@echo off', 'if "%1"=="--version" (echo 1.0.0-fake & exit /b 0)', 'ping -n 60 127.0.0.1 >nul', ''].join('\r\n'),
    )
  } else {
    const script = join(bin, 'claude')
    writeFileSync(script, '#!/bin/sh\nif [ "$1" = "--version" ]; then echo 1.0.0-fake; exit 0; fi\nsleep 60\n')
    chmodSync(script, 0o755)
    /*
     * And a stand-in for the login shell.
     *
     * `loginPath` asks `$SHELL -lic 'echo -n "$PATH"'` for the user's real PATH,
     * because a GUI app on macOS inherits a minimal one. A test cannot let that
     * answer come from the machine — the fake `claude` would not be on it — so
     * this prints the PATH this process is holding, which is the one the case
     * below just prepended to. On Windows there is no login shell to ask and
     * `loginPathSpec` answers null, so the environment's own value is used and
     * none of this is needed.
     */
    const fakeShell = join(bin, 'login-shell')
    writeFileSync(fakeShell, '#!/bin/sh\nprintf \'%s\' "$PATH"\n')
    chmodSync(fakeShell, 0o755)
    shell = process.env.SHELL
    process.env.SHELL = fakeShell
  }

  path = process.env.PATH ?? ''
  process.env.PATH = `${bin}${delimiter}${path}`
  resetLoginPathCache()
  resetAgentBinaryCache()

  installPaths(nodePaths({ platform: 'linux', env: { XDG_DATA_HOME: dir }, home: dir, appRoot: dir }))
  core = createHostCore({
    storageDir: join(dir, 'remote'),
    userData: dir,
    sessionTools: alwaysTools,
  })
}, 30_000)

afterAll(async () => {
  core.ptys.killAll()
  await core.ptys.drain()
  await core.credentials.stop()
  resetPaths()
  resetNoVerbsForTests()
  process.env.PATH = path
  if (shell === undefined) delete process.env.SHELL
  else process.env.SHELL = shell
  resetLoginPathCache()
  resetAgentBinaryCache()
  // `maxRetries`, and a warning rather than a throw, for the reason
  // `host-core.agents.test.ts` writes out: on Windows the kernel releases a dead
  // process's cwd handle a moment after the process is gone.
  try {
    rmSync(dir, { recursive: true, force: true, maxRetries: 40, retryDelay: 250 })
  } catch (error) {
    if (!windows) throw error
    console.warn(`[host-core.session-tools.test] Windows still held ${dir}: ${String(error)}`)
  }
})

beforeEach(() => {
  spawned.length = 0
})

/** The path out of the `--mcp-config <path>` pair, or null when there is none. */
function configIn(args: readonly string[]): string | null {
  const at = args.indexOf('--mcp-config')
  return at < 0 ? null : (args[at + 1] ?? null)
}

describe('an ordinary Claude session', () => {
  it(
    'is spawned with the browser verbs on its command line',
    async () => {
      const meta = await core.startSession(
        { cwd: join(dir, 'work'), cols: 80, rows: 24, provider: 'claude' },
        undefined,
        undefined,
        recorder,
      )

      expect(meta.provider, 'the fixture agent has to start, or nothing below means anything').toBe(
        'claude',
      )
      const args = spawned.at(-1) ?? []
      expect(
        configIn(args),
        'the session was launched with no --mcp-config, so it has no browser verbs and no way to say so',
      ).not.toBeNull()
      /*
       * And beside `--session-id`, which is the whole of it: this is the path
       * that rebuilds the command line, so the two flags being on it *together*
       * is the thing that was not true. Either one alone would have passed.
       */
      expect(args).toContain('--session-id')
      // Not the copilot's: an ordinary session keeps whatever MCP servers the
      // person configured for their own work.
      expect(args).not.toContain('--strict-mcp-config')
    },
    CASE_MS,
  )

  it(
    'is not told it cannot drive, because it can',
    async () => {
      const meta = await core.startSession(
        { cwd: join(dir, 'work'), cols: 80, rows: 24, provider: 'claude' },
        undefined,
        undefined,
        recorder,
      )

      // Null is what the hook answer reads as "say nothing", and saying nothing
      // is right for a session holding the verbs.
      expect(noVerbsLine(meta.id)).toBeNull()
    },
    CASE_MS,
  )
})

describe('a session that cannot be given them', () => {
  it(
    'can say why in one sentence, naming the agent rather than the app',
    async () => {
      const meta = await core.startSession(
        { cwd: join(dir, 'work'), cols: 80, rows: 24, provider: 'shell' },
        undefined,
        undefined,
        recorder,
      )

      const said = noVerbsLine(meta.id) ?? ''
      expect(said).toContain('Claude session')
      // The half that matters. The measured failure was an agent that had been
      // told it owned `B1`, had no verb for it, and went looking for a CDP port.
      expect(said).toContain('no other way in')
      expect(configIn(spawned.at(-1) ?? [])).toBeNull()
    },
    CASE_MS,
  )

  it(
    'forgets the reason when the session is gone',
    async () => {
      const meta = await core.startSession(
        { cwd: join(dir, 'work'), cols: 80, rows: 24, provider: 'shell' },
        undefined,
        undefined,
        recorder,
      )
      expect(noVerbsLine(meta.id)).not.toBeNull()

      core.ptys.kill(meta.id)
      await core.ptys.drain()

      // Ids are minted once, so an entry left behind would answer a question
      // nothing can ask again — and would grow a map for the life of a daemon.
      expect(noVerbsLine(meta.id)).toBeNull()
    },
    CASE_MS,
  )
})

describe('a session that started before the endpoint did', () => {
  it(
    'is told to be started again, rather than that the feature is missing',
    async () => {
      /*
       * The desktop always passes the seam and it answers null only in the few
       * hundred milliseconds before `deck-control` binds — which is exactly when
       * `session-restore.ts` is putting his tabs back. Saying "there is no
       * endpoint" would be false a second later and would leave him with a
       * session that quietly cannot see, which is the complaint this round is
       * about.
       */
      const late = createHostCore({
        storageDir: join(dir, 'remote-late'),
        userData: dir,
        sessionTools: { prepare: () => null },
      })
      try {
        const meta = await late.startSession(
          { cwd: join(dir, 'work'), cols: 80, rows: 24, provider: 'claude' },
          undefined,
          undefined,
          recorder,
        )

        const said = noVerbsLine(meta.id) ?? ''
        expect(said).toContain('started again')
        expect(configIn(spawned.at(-1) ?? [])).toBeNull()
      } finally {
        late.ptys.killAll()
        await late.ptys.drain()
        await late.credentials.stop()
      }
    },
    CASE_MS,
  )
})

describe('the copilot', () => {
  it(
    'keeps the tool surface it composed for itself, with no second config beside it',
    async () => {
      const own = join(dir, 'copilot.json')
      await core.startSession(
        { cwd: join(dir, 'work'), cols: 80, rows: 24, provider: 'claude' },
        undefined,
        undefined,
        recorder,
        ['--mcp-config', own, '--strict-mcp-config'],
      )

      const args = spawned.at(-1) ?? []
      // Its own file, and only its own: a second `--mcp-config` beside a strict
      // one would either be ignored or replace the surface its whole permission
      // model is built on.
      expect(args.filter((arg) => arg === '--mcp-config')).toHaveLength(1)
      expect(configIn(args)).toBe(own)
      expect(args).toContain('--strict-mcp-config')
      // The rebuild that dropped the session's flags is the same one that has to
      // keep these, so `--session-id` riding beside them is part of the pin.
      expect(args).toContain('--session-id')
    },
    CASE_MS,
  )
})

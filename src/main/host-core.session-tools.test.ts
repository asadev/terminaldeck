import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { delimiter, join } from 'node:path'
import { tmpdir } from 'node:os'
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { resetAgentBinaryCache } from './agent-binaries'
import { createHostCore, type HostCore } from './host-core'
import { installPaths, nodePaths, resetPaths } from './platform/paths'
import { resetLoginPathCache } from './providers'
import { noVerbsLine, resetNoVerbsForTests } from './session-verbs'
import { boundaryFor } from './session-boundary'
import { confinementKind } from './confine'

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
    file: join(dir, 'session-tools', 'deck-control.json'),
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

describe('a session a paired device started', () => {
  /*
   * The gate that used to be a flat refusal, and the two halves of what
   * replaced it.
   *
   * The refusal's reasoning is untouched and is enforced elsewhere: such a
   * session runs on *this* machine and must never be given the verbs over the
   * windows *here* — `browser-tools.test.ts`'s forwarding block is where that is
   * pinned. What changed is that there is now somewhere else for the verb to go,
   * so the flags are handed over **only** when the assembly says it has a
   * forwarder. `index.ts` answers true; the headless host passes no seam at all.
   */
  /*
   * The guest git environment alone, with no `DeviceConfinement` beside it.
   *
   * Both together is what the device path really passes, and both together is
   * unobservable here: `startSession` applies the confinement **instead of** the
   * fence — deliberately, one sandbox rather than one nested inside another —
   * so the recorder never sees the argv. `guest` on its own puts the launch on
   * the same side of this gate (`forDevice` is either of the two) while leaving
   * the command line readable, which is the thing under test.
   */
  const guest = { set: {}, remove: [], paths: [] }

  it(
    'is given them when this build can send its verbs to the device that asked',
    async () => {
      // The desktop's own answer, asked of the device that is starting this
      // session: is there a live channel to it, on a build that advertised
      // `windows`. It does not claim the device still is a minute later, or that
      // it holds a window, or that the person has allowed it — those are
      // answered per call, on the far side, in sentences an agent can act on.
      const wired = createHostCore({
        storageDir: join(dir, 'remote-wired'),
        userData: dir,
        sessionTools: { prepare: alwaysTools.prepare, reachesDeviceWindows: () => true },
      })
      let meta
      try {
        meta = await wired.startSession(
          { cwd: join(dir, 'work'), cols: 80, rows: 24, provider: 'claude' },
          guest,
          undefined,
          recorder,
        )
      } finally {
        wired.ptys.killAll()
        await wired.ptys.drain()
        await wired.credentials.stop()
      }
      expect(meta.provider).toBe('claude')
      expect(
        configIn(spawned.at(-1) ?? []),
        'a device’s session was launched with no --mcp-config, so its window is unreachable again',
      ).not.toBeNull()
      // And nothing to explain, because it holds them.
      expect(noVerbsLine(meta.id)).toBeNull()
    },
    CASE_MS,
  )

  it(
    'can read the config file it was handed, even held inside a sandbox',
    async () => {
      /*
       * The failure this closes is the quiet one. `confine/plan.ts` keeps
       * `<userData>` out of every read root deliberately — it also holds
       * transcripts, pairing credentials and `state.json` — and the session's
       * MCP config lives inside it. Without the file being granted, the launch
       * has the flags, the file exists, and the sandbox refuses the read: an
       * agent holding six verbs that answer nothing, with the reason visible
       * only in a seatbelt denial nobody is reading.
       */
      if (confinementKind(process.platform) === 'none') return
      const wired = createHostCore({
        storageDir: join(dir, 'remote-held'),
        userData: dir,
        sessionTools: { prepare: alwaysTools.prepare, reachesDeviceWindows: () => true },
      })
      try {
        const meta = await wired.startSession(
          { cwd: join(dir, 'work'), cols: 80, rows: 24, provider: 'claude' },
          guest,
          { home: join(dir, 'work'), writable: [], files: [] },
        )
        const boundary = boundaryFor(meta.id)
        expect(boundary, 'the session was not confined, so this proves nothing').not.toBeNull()
        expect(boundary?.readableFiles ?? []).toContain(alwaysTools.prepare().file)
      } finally {
        wired.ptys.killAll()
        await wired.ptys.drain()
        await wired.credentials.stop()
      }
    },
    CASE_MS,
  )

  it(
    'is told plainly when this build cannot, rather than left to find out',
    async () => {
      /*
       * A build with no forwarder — the headless host is the real one. Without
       * the sentence, an agent told it owns `B1` with no verb for it does not
       * conclude that it cannot look; it concludes it has not found the way yet,
       * and the measured version of that is a proposal to install Playwright and
       * read a CDP port.
       */
      const alone = createHostCore({
        storageDir: join(dir, 'remote-alone'),
        userData: dir,
        sessionTools: { prepare: alwaysTools.prepare },
      })
      try {
        const meta = await alone.startSession(
          { cwd: join(dir, 'work'), cols: 80, rows: 24, provider: 'claude' },
          guest,
          undefined,
          recorder,
        )
        expect(spawned.at(-1), 'the spawn was not recorded, so the next line proves nothing').toBeDefined()
        expect(configIn(spawned.at(-1) ?? [])).toBeNull()
        const said = noVerbsLine(meta.id) ?? ''
        expect(said).toContain('cannot show a browser window')
        expect(said).toContain('no other way in')
      } finally {
        alone.ptys.killAll()
        await alone.ptys.drain()
        await alone.credentials.stop()
      }
    },
    CASE_MS,
  )
})

describe('a session a phone started', () => {
  /*
   * The device that cannot serve a browser verb, which is most of them.
   *
   * `reachesDeviceWindows` was a constant `true` for one evening, and a constant
   * cannot tell a paired desktop from a phone. A phone advertises no `windows`
   * capability, holds no browser windows, and its client has never heard of
   * `window.call` — so every one of the six verbs it was handed came back *"the
   * computer holding that browser window is not connected right now"*, about a
   * device that was connected and was holding nothing. Six dead controls and a
   * false sentence, where before there had been no controls and a true one.
   */
  const guest = { set: {}, remove: [], paths: [] }

  it(
    'is launched with no browser verbs, and told why, when that device holds no windows',
    async () => {
      const asked: (string | undefined)[] = []
      const wired = createHostCore({
        storageDir: join(dir, 'remote-phone'),
        userData: dir,
        sessionTools: {
          prepare: alwaysTools.prepare,
          reachesDeviceWindows: (deviceId) => {
            asked.push(deviceId)
            return false
          },
        },
      })
      try {
        const meta = await wired.startSession(
          { cwd: join(dir, 'work'), cols: 80, rows: 24, provider: 'claude' },
          guest,
          undefined,
          recorder,
        )
        expect(spawned.at(-1), 'the spawn was not recorded, so the next line proves nothing').toBeDefined()
        expect(
          configIn(spawned.at(-1) ?? []),
          'a phone’s session was handed the browser verbs, which can only ever answer a refusal',
        ).toBeNull()
        // And the honest sentence it always had, rather than silence beside six
        // tools that do not work.
        expect(noVerbsLine(meta.id) ?? '').toContain('cannot show a browser window')
        // Asked at all, which is the whole of the fix: a constant answers this
        // without ever looking at the device.
        expect(asked).toHaveLength(1)
      } finally {
        wired.ptys.killAll()
        await wired.ptys.drain()
        await wired.credentials.stop()
      }
    },
    CASE_MS,
  )

  it(
    'asks about the device that actually started it, not about the build',
    async () => {
      /*
       * The confinement is what carries the device id — it is the one envelope
       * that already travels from the device path into `startSession`, and a
       * field on `CreateSessionInput` would be a claim page code could make.
       * Without this the gate cannot tell one device from another, which is the
       * same thing as a constant.
       */
      const asked: (string | undefined)[] = []
      const wired = createHostCore({
        storageDir: join(dir, 'remote-named'),
        userData: dir,
        sessionTools: {
          prepare: alwaysTools.prepare,
          reachesDeviceWindows: (deviceId) => {
            asked.push(deviceId)
            return true
          },
        },
      })
      try {
        await wired.startSession(
          { cwd: join(dir, 'work'), cols: 80, rows: 24, provider: 'claude' },
          guest,
          { home: join(dir, 'work'), writable: [], files: [], deviceId: 'phone-7' },
        )
      } finally {
        wired.ptys.killAll()
        await wired.ptys.drain()
        await wired.credentials.stop()
      }
      expect(asked).toEqual(['phone-7'])
    },
    CASE_MS,
  )
})

describe('a session on a host that holds the windows itself', () => {
  /*
   * The headless server, and the reason it needed a second seam.
   *
   * Almost every session on a server is started by a device that dialled in, so
   * `forDevice` is true for nearly all of them — and the desktop's gate refuses
   * those unless the *device* can serve a browser verb. That question is right
   * on a desktop, where a session a phone started has its windows on the phone
   * because a device driving the browser here is refused and always will be. It
   * is the wrong question on a server: the browser is the server's own, and
   * `HeadlessDriveHost.openForSession` attaches every window it opens to the
   * calling session in the same `browser-binding` store the desktop mints `B1`
   * from. The device is not part of it.
   *
   * So `hostHoldsWindows` is asked beside `reachesDeviceWindows` rather than
   * instead of it. Answering the device question `true` from a server would have
   * been this file being told a phone can show a browser window in order to get
   * a launch past a gate for an unrelated reason.
   */
  const guest = { set: {}, remove: [], paths: [] }

  it(
    'is given the verbs even though a device asked for it',
    async () => {
      const server = createHostCore({
        storageDir: join(dir, 'remote-server'),
        userData: dir,
        sessionTools: { prepare: alwaysTools.prepare, hostHoldsWindows: () => true },
      })
      /*
       * Read **while the session is alive**. `forgetNoVerbs` fires on exit, so a
       * sentence read after the kill in the `finally` is null for every session
       * ever launched — an assertion that cannot fail is worse than none.
       */
      let said: string | null = 'unread'
      let provider = ''
      try {
        const meta = await server.startSession(
          { cwd: join(dir, 'work'), cols: 80, rows: 24, provider: 'claude' },
          guest,
          undefined,
          recorder,
        )
        provider = meta.provider
        said = noVerbsLine(meta.id)
      } finally {
        server.ptys.killAll()
        await server.ptys.drain()
        await server.credentials.stop()
      }
      expect(provider).toBe('claude')
      expect(
        configIn(spawned.at(-1) ?? []),
        'a session on a server was launched with no --mcp-config, so the server’s own browser is unreachable from it',
      ).not.toBeNull()
      expect(said).toBeNull()
    },
    CASE_MS,
  )

  it(
    'is given them even when the device that asked holds no windows',
    async () => {
      /*
       * The two seams are `||`, and this is the case that proves it is not `&&`.
       * A phone answers `reachesDeviceWindows` false — correctly, it holds no
       * windows — and on a server that must not be the end of it, because the
       * windows in question are not the phone's.
       */
      const server = createHostCore({
        storageDir: join(dir, 'remote-server-phone'),
        userData: dir,
        sessionTools: {
          prepare: alwaysTools.prepare,
          reachesDeviceWindows: () => false,
          hostHoldsWindows: () => true,
        },
      })
      let said: string | null = 'unread'
      try {
        const meta = await server.startSession(
          { cwd: join(dir, 'work'), cols: 80, rows: 24, provider: 'claude' },
          guest,
          undefined,
          recorder,
        )
        said = noVerbsLine(meta.id)
      } finally {
        server.ptys.killAll()
        await server.ptys.drain()
        await server.credentials.stop()
      }
      expect(configIn(spawned.at(-1) ?? [])).not.toBeNull()
      expect(said).toBeNull()
    },
    CASE_MS,
  )

  it(
    'names the endpoint, not the device, when the tool server is not up yet',
    async () => {
      /*
       * The sentence has to move with the seam or it becomes the lie the seam
       * was added to stop. On a server whose endpoint has not bound, telling a
       * session that *"the device that started this session cannot show a
       * browser window"* names the wrong computer about the wrong browser — and
       * closes a door that opens a moment later, or on the next launch.
       */
      const server = createHostCore({
        storageDir: join(dir, 'remote-server-early'),
        userData: dir,
        sessionTools: { prepare: () => null, hostHoldsWindows: () => true },
      })
      let said = ''
      try {
        const meta = await server.startSession(
          { cwd: join(dir, 'work'), cols: 80, rows: 24, provider: 'claude' },
          guest,
          undefined,
          recorder,
        )
        said = noVerbsLine(meta.id) ?? ''
      } finally {
        server.ptys.killAll()
        await server.ptys.drain()
        await server.credentials.stop()
      }
      expect(configIn(spawned.at(-1) ?? [])).toBeNull()
      expect(said).toContain('started again')
      expect(said).not.toContain('cannot show a browser window')
    },
    CASE_MS,
  )
})

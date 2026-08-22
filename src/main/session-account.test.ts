import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { request } from 'node:http'
import { homedir, tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeEach, describe, expect, it } from 'vitest'
import type { SessionMeta } from '../shared/types'
import {
  AGENT_ENV_HEADER,
  SESSION_HEADER,
  TOKEN_HEADER,
  parseAgentEnv,
  startHookServer,
  stopHookServer,
  toHookEvent,
} from './hook-server'
import { installPaths, resetPaths } from './platform/paths'
import { resetProfilesCache, systemConfigDir, systemProfileId } from './profiles'
import {
  agentUnder,
  configureSessionAccounts,
  dropSessionAccount,
  environmentValue,
  environmentWasRead,
  establishedConfigDir,
  noteHookEvent,
  parseProcessTable,
  sessionAccount,
  type SessionAccountDeps,
} from './session-account'

/**
 * Reading a session's login off the running process, rather than assuming it.
 *
 * The fixtures are transcribed from this Mac, because every one of them encodes
 * something that would otherwise be guessed at. The commands, so they can be
 * re-run:
 *
 *     $ ps -Ao pid=,ppid=,command= | grep claude
 *      2471   850 claude
 *       850   837 -zsh
 *     $ ps eww -p 2471 | tr ' ' '\n' | grep -c '='
 *     28
 *     $ env CLAUDE_CONFIG_DIR=/tmp/fake-cfg node -e '…' &
 *     $ ps eww -p $! | tr ' ' '\n' | grep CLAUDE_CONFIG_DIR
 *     CLAUDE_CONFIG_DIR=/tmp/fake-cfg
 *
 * The ladder itself — spawn record, then process environment — is exercised
 * through `accountFor` in `usage-ipc.test.ts`, which is where its consequences
 * are actually visible. What is pinned here is the reading, because a parser
 * that is quietly wrong about an environment produces a confident wrong account
 * name, which is the failure this whole module was written to stop.
 */

const TABLE = [
  ' 2471   850 claude',
  '  850   837 -zsh',
  '  837   740 login -pfl apple /bin/bash -c exec -la zsh /bin/zsh',
  '  740     1 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal',
  '57565 57205 claude --session-id e90c48be-c4e5-4c6b-9e09-ffb2ff05193d',
  '57205 57200 /Users/apple/Projects/terminaldeck/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron .',
].join('\n')

describe('the process table', () => {
  it('parses pid, parent and the whole command line', () => {
    const rows = parseProcessTable(TABLE)
    expect(rows).toHaveLength(6)
    expect(rows[0]).toEqual({ pid: 2471, ppid: 850, command: 'claude' })
    // The command keeps its arguments: the session id on it is how a reader
    // tells a session this app named from one it did not.
    expect(rows[4]?.command).toContain('--session-id')
  })

  it('ignores a header line or anything else that is not a row', () => {
    expect(parseProcessTable('  PID  PPID COMMAND\n\n  not a row\n 12 3 sh')).toEqual([
      { pid: 12, ppid: 3, command: 'sh' },
    ])
  })
})

describe('finding the agent under a session', () => {
  /*
   * The whole reason the table is walked rather than the pty's child inspected.
   * In Terminal the agent is a child of the login shell, which is a child of
   * `login`, which is a child of Terminal itself — three levels from the thing
   * that owns the window.
   */
  it('finds an agent that is a grandchild rather than a child', () => {
    const rows = parseProcessTable(TABLE)
    expect(agentUnder(rows, 740, ['claude'])?.pid).toBe(2471)
  })

  it('matches on the basename, so a path and a bare name are one agent', () => {
    const rows = parseProcessTable(' 10 1 /opt/homebrew/bin/claude --session-id x')
    expect(agentUnder(rows, 1, ['claude'])?.pid).toBe(10)
  })

  it('answers null when nothing under the session is an agent', () => {
    const rows = parseProcessTable(TABLE)
    // A shell with nothing running in it. There is no login to name, and this
    // is the case that must not fall through to the machine's default.
    expect(agentUnder(rows, 850, ['codex'])).toBeNull()
  })
})

describe('reading one variable out of `ps eww`', () => {
  const DUMP =
    '  PID   TT  STAT      TIME COMMAND\n' +
    ' 2471 s001  S+     0:12.34 claude --session-id abc ' +
    'PATH=/usr/bin:/bin CLAUDE_CONFIG_DIR=/Users/apple/.claude-work ' +
    'HOME=/Users/apple SHELL=/bin/zsh\n'

  it('reads the value up to the next variable, not to the next space', () => {
    expect(environmentValue(DUMP, 'CLAUDE_CONFIG_DIR')).toBe('/Users/apple/.claude-work')
    expect(environmentValue(DUMP, 'HOME')).toBe('/Users/apple')
  })

  it('keeps a value that contains spaces', () => {
    const dump = 'x CLAUDE_CONFIG_DIR=/Users/apple/My Claude/cfg HOME=/Users/apple\n'
    expect(environmentValue(dump, 'CLAUDE_CONFIG_DIR')).toBe('/Users/apple/My Claude/cfg')
  })

  /*
   * `ps eww` prints the command line and the environment with nothing between
   * them, so an argument that happens to be spelled `NAME=value` is
   * indistinguishable from a variable — except by position, because the
   * environment comes last.
   */
  it('prefers the environment over an argument that looks like one', () => {
    const dump = 'sh -c CLAUDE_CONFIG_DIR=/decoy claude PATH=/bin CLAUDE_CONFIG_DIR=/real\n'
    expect(environmentValue(dump, 'CLAUDE_CONFIG_DIR')).toBe('/real')
  })

  it('answers null for a variable that is not there', () => {
    expect(environmentValue(DUMP, 'CODEX_HOME')).toBeNull()
  })

  /*
   * The one that decides whether an *absence* may be believed.
   *
   * macOS scrubs the environment of a SIP-protected binary, so `ps eww` against
   * `/bin/sleep` exits zero and prints a command line and nothing else — checked
   * on this machine. A reader treating that as "the variable is unset" would
   * then report the default account for a process whose environment it never
   * saw, which is precisely the wrong answer this module exists to stop.
   */
  it('knows an environment that was scrubbed from one that was read', () => {
    expect(environmentWasRead(DUMP)).toBe(true)
    expect(environmentWasRead('  PID   TT  STAT      TIME COMMAND\n69371   ??  SN  0:00.01 sleep 8\n')).toBe(
      false,
    )
  })
})

/**
 * The ladder itself, and the two things about it that turn on *this app's own*
 * environment rather than the session's.
 *
 * Deck reads `CLAUDE_CONFIG_DIR` off its own process to decide where "the
 * machine's own install" is, and it is launched from a terminal constantly — a
 * terminal that may itself be inside a Claude session on another profile. That
 * inheritance is real and is kept (`session-env.ts` keeps the variable
 * deliberately, and `sessionEnv()` contributes nothing for the system profile,
 * so a session started on Default genuinely reads the inherited directory). But
 * it must not leak into the answer for an agent whose environment has just been
 * *read* and found to have no such variable: that agent is on `$HOME/.claude`,
 * whatever this app inherited.
 */
describe('the ladder, against this app’s own inherited environment', () => {
  const USER_DATA = join(tmpdir(), `terminaldeck-session-account-${process.pid}`)
  const realConfigDir = process.env.CLAUDE_CONFIG_DIR

  beforeEach(() => {
    resetPaths()
    installPaths({
      userData: () => USER_DATA,
      home: () => USER_DATA,
      downloads: () => USER_DATA,
      appRoot: () => USER_DATA,
    })
    rmSync(USER_DATA, { recursive: true, force: true })
    mkdirSync(USER_DATA, { recursive: true })
    resetProfilesCache()
    configureSessionAccounts(null)
    delete process.env.CLAUDE_CONFIG_DIR
  })

  afterAll(() => {
    resetPaths()
    configureSessionAccounts(null)
    if (realConfigDir === undefined) delete process.env.CLAUDE_CONFIG_DIR
    else process.env.CLAUDE_CONFIG_DIR = realConfigDir
    rmSync(USER_DATA, { recursive: true, force: true })
  })

  function meta(over: Partial<SessionMeta> = {}): SessionMeta {
    return {
      id: 'sess-ladder',
      title: 'zsh',
      cwd: '/Users/apple/Projects/demo',
      provider: 'shell',
      exitCode: null,
      createdAt: 1,
      ...over,
    }
  }

  /**
   * A `ps` reporting one `claude` under the session's pty, with the environment
   * it was given. `PATH` is always there because its absence is what
   * `environmentWasRead` uses to refuse a scrubbed environment, and `HOME` is
   * this machine's real one because a different `HOME` is a different store and
   * is refused one rung earlier.
   */
  function processWith(env: string, session = meta()): SessionAccountDeps {
    return {
      pidOf: () => 4242,
      describeSession: () => session,
      platform: 'darwin',
      exec: (_command, args) =>
        Promise.resolve(
          args[0] === '-Ao'
            ? ' 5000 4242 claude\n 4242    1 -zsh\n'
            : `  PID   TT  STAT      TIME COMMAND\n 5000 s001  S+     0:01 claude ` +
              `PATH=/usr/bin ${env} HOME=${homedir()}\n`,
        ),
    }
  }

  it('names the agent’s own default store, not the directory Deck inherited', async () => {
    /*
     * The wrong answer this replaces: `systemProfileFor(provider).configDir`,
     * which resolves through *this process's* environment. With Deck launched
     * from a redirected shell that answered `/tmp/somebody-elses-store` for an
     * agent whose environment had just been read and had no variable in it at
     * all — a confident name for a login that session is not on, which is the
     * exact class of claim this module exists to end.
     */
    process.env.CLAUDE_CONFIG_DIR = join(tmpdir(), 'terminaldeck-inherited-store')
    configureSessionAccounts(processWith(''))
    const answer = await sessionAccount('sess-ladder')
    expect(answer.kind).toBe('known')
    if (answer.kind !== 'known') return
    expect(answer.configDir).toBe(join(homedir(), '.claude'))
    expect(answer.configDir).not.toBe(process.env.CLAUDE_CONFIG_DIR)
    // No profile record points there while something else is "the system
    // profile", so the store is named and nothing is claimed about a profile.
    expect(answer.profileId).toBeNull()
    expect(answer.source).toBe('process')
  })

  it('still names the system profile when Deck inherited nothing', async () => {
    // The ordinary machine, and the regression guard: this is the behaviour
    // that shipped, and the fix above must not have moved it.
    configureSessionAccounts(processWith(''))
    const answer = await sessionAccount('sess-ladder')
    expect(answer).toMatchObject({
      kind: 'known',
      configDir: join(homedir(), '.claude'),
      profileId: systemProfileId('claude'),
      profileName: 'Default',
    })
  })

  it('still believes the variable when the agent itself declares one', async () => {
    const declared = join(tmpdir(), 'terminaldeck-declared-store')
    configureSessionAccounts(processWith(`CLAUDE_CONFIG_DIR=${declared}`))
    const answer = await sessionAccount('sess-ladder')
    expect(answer).toMatchObject({ kind: 'known', configDir: declared })
  })
})

/**
 * `establishedConfigDir` — the synchronous seam `agent-controls.ts` reads
 * `settings.json`, `permissions.defaultMode` and the project's transcripts
 * through, so that the control cluster describes the account the session is
 * running as rather than the one this app process resolved.
 */
describe('the config directory one session’s files should be read from', () => {
  const USER_DATA = join(tmpdir(), `terminaldeck-established-dir-${process.pid}`)

  beforeEach(() => {
    resetPaths()
    installPaths({
      userData: () => USER_DATA,
      home: () => USER_DATA,
      downloads: () => USER_DATA,
      appRoot: () => USER_DATA,
    })
    rmSync(USER_DATA, { recursive: true, force: true })
    mkdirSync(USER_DATA, { recursive: true })
    resetProfilesCache()
    configureSessionAccounts(null)
  })

  afterAll(() => {
    resetPaths()
    configureSessionAccounts(null)
    rmSync(USER_DATA, { recursive: true, force: true })
  })

  const SESSION: SessionMeta = {
    id: 'sess-files',
    title: 'zsh',
    cwd: '/Users/apple/Projects/demo',
    provider: 'shell',
    exitCode: null,
    createdAt: 1,
  }

  function on(dir: string): SessionAccountDeps {
    return {
      pidOf: () => 4242,
      describeSession: () => SESSION,
      platform: 'darwin',
      exec: (_command, args) =>
        Promise.resolve(
          args[0] === '-Ao'
            ? ' 5000 4242 claude\n 4242    1 -zsh\n'
            : `  PID   TT  STAT      TIME COMMAND\n 5000 s001  S+     0:01 claude ` +
              `PATH=/usr/bin CLAUDE_CONFIG_DIR=${dir} HOME=${homedir()}\n`,
        ),
    }
  }

  it('is null until the probe has landed, so the caller keeps its own fallback', () => {
    configureSessionAccounts(on('/tmp/work-store'))
    // Every first read of every session is in this state. Null is what leaves
    // `agent-controls.ts` reading `claudeConfigDir()` exactly as it did before,
    // which is the rule that stops an unknown account becoming a wrong one.
    expect(establishedConfigDir('sess-files')).toBeNull()
  })

  it('names the store once it has, for the agent that is running', async () => {
    configureSessionAccounts(on('/tmp/work-store'))
    await sessionAccount('sess-files')
    expect(establishedConfigDir('sess-files')).toBe('/tmp/work-store')
  })

  it('answers null for a different agent, rather than handing over a directory that is not its', async () => {
    /*
     * A directory is an answer about one agent. `~/.codex` holds no
     * `settings.json` Claude has ever read, so a caller asking for Claude's
     * store gets nothing and falls back — rather than being handed a path and
     * reading a file that means nothing to it.
     */
    configureSessionAccounts(on('/tmp/work-store'))
    await sessionAccount('sess-files')
    expect(establishedConfigDir('sess-files', 'codex')).toBeNull()
  })
})

/**
 * The Windows ladder — the rung T34 never built.
 *
 * `ps eww` is POSIX, so every agent typed at a Windows prompt used to fall to
 * a blanket withholding: "never print Default" satisfied by printing nobody,
 * on exactly the session type his PC mostly has. Windows offers no honest way
 * for an unelevated process to read another's environment — but the hook
 * command runs *inside* the agent's process tree and inherits its environment,
 * so the Windows hook client reports the config variables itself and this
 * module treats that as the evidence it is.
 *
 * Every fixture is built with the real wire encoding (`wire()` below is the
 * PowerShell client's JSON→UTF-8→base64, byte for byte) and decoded by the
 * real `parseAgentEnv`, so what is exercised is the channel, not a shape typed
 * into the test. Paths are Windows-shaped strings compared by the module's own
 * platform rules — nothing here touches the runner's filesystem, which is the
 * discipline that keeps this suite green on both CI hosts.
 */
describe('the Windows ladder, fed by the agent’s own hooks', () => {
  const USER_DATA = join(tmpdir(), `terminaldeck-windows-ladder-${process.pid}`)
  const realConfigDir = process.env.CLAUDE_CONFIG_DIR
  const SESSION = 'sess-win'
  const HOME = 'C:\\Users\\asad'

  beforeEach(() => {
    resetPaths()
    installPaths({
      userData: () => USER_DATA,
      home: () => USER_DATA,
      downloads: () => USER_DATA,
      appRoot: () => USER_DATA,
    })
    rmSync(USER_DATA, { recursive: true, force: true })
    mkdirSync(USER_DATA, { recursive: true })
    resetProfilesCache()
    configureSessionAccounts(null)
    delete process.env.CLAUDE_CONFIG_DIR
  })

  afterAll(async () => {
    await stopHookServer()
    resetPaths()
    configureSessionAccounts(null)
    if (realConfigDir === undefined) delete process.env.CLAUDE_CONFIG_DIR
    else process.env.CLAUDE_CONFIG_DIR = realConfigDir
    rmSync(USER_DATA, { recursive: true, force: true })
  })

  function meta(over: Partial<SessionMeta> = {}): SessionMeta {
    return {
      id: SESSION,
      title: 'powershell',
      cwd: 'C:\\Users\\asad\\Projects\\demo',
      provider: 'shell',
      exitCode: null,
      createdAt: 1,
      ...over,
    }
  }

  /** A Windows Deck. `exec` throws because no rung there may ever spawn `ps`. */
  function windowsDeps(session = meta()): SessionAccountDeps {
    return {
      pidOf: () => 4242,
      describeSession: () => session,
      platform: 'win32',
      home: HOME,
      exec: () => Promise.reject(new Error('there is no ps to run on Windows')),
    }
  }

  /** The client’s exact wire format: JSON, UTF-8 bytes, base64. */
  function wire(report: unknown): string {
    return Buffer.from(JSON.stringify(report), 'utf8').toString('base64')
  }

  /** One hook event as the endpoint would emit it, through the real parsers. */
  function hookEvent(
    report: unknown | null,
    over: { provider?: string; event?: string; sessionId?: string } = {},
  ): void {
    noteHookEvent(
      toHookEvent(
        over.provider ?? 'claude',
        over.event ?? 'SessionStart',
        over.sessionId ?? SESSION,
        '{}',
        report === null ? null : parseAgentEnv(wire(report)),
      ),
    )
  }

  it('answers a session this app spawned from the spawn record, exactly as on a Mac', async () => {
    // A Run-Claude launch writes the resolved profile onto the session at
    // spawn, on every platform — so rung one never needed `ps` and never
    // deserved the Windows withholding it was sitting behind.
    configureSessionAccounts(
      windowsDeps(meta({ provider: 'claude', profileId: systemProfileId('claude') })),
    )
    const answer = await sessionAccount(SESSION)
    expect(answer).toMatchObject({
      kind: 'known',
      profileId: systemProfileId('claude'),
      source: 'spawn',
    })
  })

  it('withholds with the sentence that says what would answer, while nothing has reported', async () => {
    configureSessionAccounts(windowsDeps())
    const answer = await sessionAccount(SESSION)
    expect(answer.kind).toBe('withheld')
    if (answer.kind !== 'withheld') return
    // The old sentence declared the question unanswerable. The new one has to
    // name the channel that answers it and what a person does to get it.
    expect(answer.reason).toContain('hooks')
    expect(answer.reason).not.toContain('cannot be established')
  })

  it('names the declared store once the agent’s own hook has reported it', async () => {
    configureSessionAccounts(windowsDeps())
    // The withholding lands first — and must not stand once evidence arrives.
    expect((await sessionAccount(SESSION)).kind).toBe('withheld')

    hookEvent({
      vars: { CLAUDE_CONFIG_DIR: 'C:\\Users\\asad\\.claude-work' },
      path: true,
      home: HOME,
    })
    const answer = await sessionAccount(SESSION)
    expect(answer).toMatchObject({
      kind: 'known',
      provider: 'claude',
      configDir: 'C:\\Users\\asad\\.claude-work',
      source: 'hook',
    })
  })

  it('names the default store for an absent variable in an environment that provably arrived', async () => {
    configureSessionAccounts(windowsDeps())
    // Case-folded home: Windows says one directory in as many spellings as
    // there are shortcuts, and `C:\USERS\ASAD` is not a foreign login.
    hookEvent({ vars: {}, path: true, home: 'c:\\USERS\\ASAD' })
    const answer = await sessionAccount(SESSION)
    expect(answer).toMatchObject({
      kind: 'known',
      provider: 'claude',
      configDir: systemConfigDir('claude', {}),
      source: 'hook',
    })
  })

  it('believes nothing from a report whose environment never provably arrived', async () => {
    configureSessionAccounts(windowsDeps())
    // `path: false` is the Windows spelling of the SIP-scrubbed dump: an agent
    // ran a hook, and that is all this proves. Falling through to the
    // withholding is the answer that cannot be wrong.
    hookEvent({ vars: {}, path: false, home: HOME })
    expect((await sessionAccount(SESSION)).kind).toBe('withheld')
  })

  it('withholds a login under somebody else’s home rather than naming this machine’s', async () => {
    configureSessionAccounts(windowsDeps())
    hookEvent({ vars: {}, path: true, home: 'C:\\Users\\somebody-else' })
    const answer = await sessionAccount(SESSION)
    expect(answer.kind).toBe('withheld')
    if (answer.kind !== 'withheld') return
    expect(answer.reason).toContain('different home')
  })

  it('lets the name die with the agent: SessionEnd drops the report and the answer', async () => {
    configureSessionAccounts(windowsDeps())
    hookEvent({ vars: { CLAUDE_CONFIG_DIR: 'C:\\store' }, path: true, home: HOME })
    expect((await sessionAccount(SESSION)).kind).toBe('known')

    hookEvent(null, { event: 'SessionEnd' })
    // An account name that outlives the process it describes is the exact
    // claim this module exists to end, one platform along.
    expect((await sessionAccount(SESSION)).kind).toBe('withheld')
  })

  it('forgets the report when the pty goes, with everything else about the session', async () => {
    configureSessionAccounts(windowsDeps())
    hookEvent({ vars: { CLAUDE_CONFIG_DIR: 'C:\\store' }, path: true, home: HOME })
    expect((await sessionAccount(SESSION)).kind).toBe('known')
    dropSessionAccount(SESSION)
    expect((await sessionAccount(SESSION)).kind).toBe('withheld')
  })

  it('ignores a report from a provider that has no login to tell apart', async () => {
    configureSessionAccounts(windowsDeps())
    hookEvent({ vars: {}, path: true, home: HOME }, { provider: 'shell' })
    expect((await sessionAccount(SESSION)).kind).toBe('withheld')
  })

  it('carries the whole channel: a posted hook event becomes the session’s account', async () => {
    /*
     * The person's path, minus only PowerShell itself: the event enters through
     * the real endpoint on this platform's real address, the real header
     * parser, the real subscription `configureSessionAccounts` installs, and
     * comes out of `sessionAccount` as a name. Every prior test drives the
     * store directly; this one proves the store is actually plumbed.
     */
    const dir = mkdtempSync(join(tmpdir(), 'td-account-hook-'))
    try {
      configureSessionAccounts(windowsDeps())
      const endpoint = await startHookServer({ dir })
      await new Promise<void>((resolvePost, rejectPost) => {
        const req = request(
          {
            socketPath: endpoint.socketPath,
            method: 'POST',
            path: '/hook/claude/SessionStart',
            headers: {
              'content-type': 'application/json',
              [TOKEN_HEADER]: endpoint.token,
              [SESSION_HEADER]: SESSION,
              [AGENT_ENV_HEADER]: wire({
                vars: { CLAUDE_CONFIG_DIR: 'C:\\Users\\asad\\.claude-work' },
                path: true,
                home: HOME,
              }),
            },
          },
          (res) => {
            res.resume()
            res.on('end', () => resolvePost())
          },
        )
        req.on('error', rejectPost)
        req.end('{}')
      })
      // The emit is synchronous with the response, but give it the same tick
      // the endpoint's own tests do rather than racing it.
      await new Promise((tick) => setTimeout(tick, 10))
      const answer = await sessionAccount(SESSION)
      expect(answer).toMatchObject({
        kind: 'known',
        configDir: 'C:\\Users\\asad\\.claude-work',
        source: 'hook',
      })
    } finally {
      await stopHookServer()
      rmSync(dir, { recursive: true, force: true })
    }
  })
})

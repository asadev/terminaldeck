/**
 * What the copilot is handed, and what it is not.
 *
 * The most important cases in this file are the ones asserting an **absence**.
 * The copilot used to be started with a `DeviceConfinement` and a guest git
 * environment — the treatment a session from a paired device gets — and that is
 * what made it, in practice, less capable than an ordinary session in the same
 * app: signed out, unable to write anything, and refusing to start at all on two
 * of three platforms. `confine/records.ts` carries the whole argument.
 *
 * So `expect(call?.confine).toBeUndefined()` is not a tidiness assertion. It is
 * the policy, written where somebody re-adding a boundary would trip over it.
 */

import { existsSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { beforeEach, describe, expect, it } from 'vitest'
import type { CreateSessionInput, ProviderId, SessionMeta } from '../shared/types'
import { recordsFenceList, recordsFencePaths, type RecordsFence } from './confine/records'
import { copilotPaths, resetCopilotInstructions } from './copilot-home'
import { PAST_COPILOT_INSTRUCTIONS } from './copilot-instructions-history'
import type { Profile } from './profiles'
import {
  COPILOT_HOME_KEY,
  copilotHome,
  copilotHomeScope,
  copilotState,
  ensureCopilot,
  isCopilotSession,
  readCopilotSignIn,
  registerCopilotIpc,
  resetCopilot,
  stopCopilot,
  type CopilotRuntimeDeps,
  type SpawnFence,
} from './copilot-session'

/**
 * A host core that records rather than spawns.
 *
 * `startSession` is the one thing this module must not re-implement — it is the
 * single place in the app that starts a session, and the whole design rests on
 * the copilot going through it like everything else. So the interesting
 * assertions here are about *what is handed to it*: the folder, the account, and
 * the two things that are deliberately not handed to it at all.
 */
interface Recorded {
  input: CreateSessionInput
  guest: unknown
  confine: unknown
  fence: SpawnFence | undefined
  /** The flags this launch adds to the CLI's own — where its tools come from. */
  extraArgs: readonly string[] | undefined
}

let userData: string
let calls: Recorded[]
let alive: Set<string>
let stopped: string[]
let deps: CopilotRuntimeDeps

/** The account the profile system answers with, unless a test says otherwise. */
const DEFAULT_PROFILE: Profile = {
  id: 'system',
  name: 'Default',
  provider: 'claude',
  configDir: '/Users/someone/.claude',
  system: true,
  color: '#000000',
  createdAt: 0,
  lastUsedAt: null,
}

/** A fence that would really wrap a command, without running `sandbox-exec`. */
function stubFence(): RecordsFence {
  return {
    kind: 'seatbelt',
    paths: recordsFencePaths(userData),
    apply: (command, args) => ({ command: '/usr/bin/sandbox-exec', args: ['-p', '…', command, ...args] }),
  }
}

function meta(input: CreateSessionInput, provider: ProviderId = 'claude'): SessionMeta {
  return {
    id: `session-${calls.length}`,
    cwd: input.cwd,
    title: 'copilot',
    provider,
    exitCode: null,
    createdAt: 1_000,
  }
}

function harness(overrides: Partial<CopilotRuntimeDeps> = {}): CopilotRuntimeDeps {
  return {
    userData: () => userData,
    storageDir: () => join(userData, 'remote'),
    platform: 'darwin',
    agents: async () => ({ claude: true, codex: false, gemini: false, shell: true }),
    /*
     * The fence is stubbed by default so these cases do not each spawn
     * `sandbox-exec`. Whether the real one holds is measured in
     * `confine/records.test.ts` and in the two boundary tests, against a real
     * kernel — which is the only place that question can honestly be asked.
     */
    fence: async () => ({ fence: stubFence(), reason: null }),
    profile: () => DEFAULT_PROFILE,
    signInOf: async () => ({ state: 'signed-in' as const, account: 'someone@example.com', plan: 'max' }),
    async startSession(input, guest, confine, fence, extraArgs) {
      calls.push({ input, guest, confine, fence, extraArgs })
      const created = meta(input)
      alive.add(created.id)
      return created
    },
    isAlive: (id) => alive.has(id),
    stop: (id) => {
      stopped.push(id)
      alive.delete(id)
    },
    ...overrides,
  }
}

beforeEach(() => {
  resetCopilot()
  userData = mkdtempSync(join(tmpdir(), 'copilot-run-'))
  calls = []
  alive = new Set()
  stopped = []
  deps = harness()
})

describe('there is one copilot', () => {
  it('starts it once, however many callers ask at the same moment', async () => {
    // Two windows opening together is the ordinary case, not an edge one. A
    // boolean guard would not survive the await inside the start; the latch is
    // what makes this true.
    const [a, b, c] = await Promise.all([
      ensureCopilot(deps),
      ensureCopilot(deps),
      ensureCopilot(deps),
    ])
    expect(calls).toHaveLength(1)
    expect(a.sessionId).toBe(b.sessionId)
    expect(b.sessionId).toBe(c.sessionId)
  })

  it('does not start a second one while the first is alive', async () => {
    await ensureCopilot(deps)
    await ensureCopilot(deps)
    expect(calls).toHaveLength(1)
  })

  it('starts again once its process has gone', async () => {
    const first = await ensureCopilot(deps)
    // Liveness is asked, never remembered — a copilot killed from a terminal
    // has to read as stopped without anything having delivered an event.
    alive.clear()
    expect(copilotState(deps).status).toBe('stopped')
    const second = await ensureCopilot(deps)
    expect(calls).toHaveLength(2)
    expect(second.sessionId).not.toBe(first.sessionId)
  })

  it('stops on request and says so in the log', async () => {
    const started = await ensureCopilot(deps)
    const after = stopCopilot(deps)
    expect(stopped).toEqual([started.sessionId])
    expect(after.status).toBe('stopped')
    expect(readFileSync(copilotPaths(userData).actions, 'utf8')).toContain('session.stopped')
  })
})

describe('it is an ordinary session', () => {
  it('runs in its own folder, as a Claude session, fresh each launch', async () => {
    await ensureCopilot(deps)
    const [call] = calls
    expect(call?.input.cwd).toBe(copilotPaths(userData).root)
    expect(call?.input.provider).toBe('claude')
    // `--continue` would make it one conversation that never ends, and a turn
    // costs what the conversation before it costs. Continuity is `memory/`.
    expect(call?.input.resume).toBe(false)
  })

  it('is handed no confinement, which is what an ordinary session is handed', async () => {
    /*
     * The assertion this whole change is about.
     *
     * `host-core.ts` decides whether to confine by asking whether a
     * `DeviceConfinement` was passed at all — absent means "a person at their
     * own keyboard, with no grant to be held inside". The copilot passes none,
     * so it is confined by nothing, reads and writes what the person does, and
     * starts on every platform.
     *
     * It used to pass one. That is what made it start signed out (its login
     * would have been in the keychain, which a `(deny default)` process cannot
     * reach), unable to change a line of anybody's code, and non-existent on
     * Windows.
     */
    await ensureCopilot(deps)
    expect(calls[0]?.confine).toBeUndefined()
  })

  it('is handed no guest git environment, because it is not a guest', async () => {
    /*
     * `prepareGuestGit` strips `GH_TOKEN`, `GITHUB_TOKEN` and `SSH_AUTH_SOCK`
     * and substitutes a git identity of its own. That is right for a paired
     * device, whose owner is not the person at this keyboard. Applied to the
     * copilot it made it the one agent in the app that could not push a branch
     * or read the person's git config.
     */
    await ensureCopilot(deps)
    expect(calls[0]?.guest).toBeUndefined()
  })

  it('resolves its account through the profile system, and records which one', async () => {
    const chosen: Profile = { ...DEFAULT_PROFILE, id: 'work', name: 'Work', system: false }
    const asked: string[] = []
    const state = await ensureCopilot(
      harness({
        profile: (projectPath) => {
          asked.push(projectPath)
          return chosen
        },
      }),
    )
    // Asked about the copilot's own folder, which is what makes a per-project
    // pin on that folder the way to choose the copilot's account.
    expect(asked).toEqual([copilotPaths(userData).root])
    expect(calls[0]?.input.profileId).toBe('work')
    // Resolved once, so what the state reports and what the session runs as
    // cannot come apart.
    expect(state.profile).toEqual({ id: 'work', name: 'Work' })
  })

  it('sets no CLAUDE_CONFIG_DIR, which is what keeps it on the person’s own login', async () => {
    /*
     * The variable that must not come back.
     *
     * It existed to force the CLI off the macOS keychain and onto a file inside
     * the sandbox, because that was the only way a jailed copilot could ever be
     * signed in. With no jail, setting it would take the copilot *off* the
     * person's account and into a store nothing signs in — reintroducing the
     * signed-out first run through the same variable that used to fix it.
     *
     * There is nowhere left for it to be set: no guest environment is passed at
     * all. This case is the one that would fail if somebody added one back.
     */
    await ensureCopilot(deps)
    expect(calls[0]?.guest).toBeUndefined()
  })
})

/**
 * Where the copilot's tools come from, which for a while was nowhere.
 *
 * `deck-control` wrote its config on every start, its loopback server listened
 * behind a bearer token, the routine runner passed it — and the pinned copilot
 * was spawned with no `--mcp-config` at all. So it had the native Claude Code
 * tools and none of this app's: it could not list a session, read a transcript,
 * look at a screen or raise a confirmation, and every sentence about it being
 * "bounded by the tool tiers and the consent gate" described a gate with nothing
 * behind it.
 *
 * The invocation was measured against the real CLI on this machine (Claude Code
 * 2.1.233): it connects with no approval prompt and answers `sessions_list` with
 * the real fleet. `copilot-tools-live.test.ts` is that measurement, kept and
 * re-runnable; these cases are the wiring that carries it.
 */
describe('the tools it is launched with', () => {
  it('passes the config it was given, strictly', async () => {
    const state = await ensureCopilot(harness({ mcpConfig: () => '/state/copilot/deck-control.json' }))
    expect(state.status).toBe('running')
    expect(calls[0]?.extraArgs).toEqual([
      '--mcp-config',
      '/state/copilot/deck-control.json',
      '--strict-mcp-config',
    ])
  })

  it('is strict on purpose, so its powers do not depend on the person’s own MCP servers', async () => {
    /*
     * Asserted on its own rather than left inside the array above, because
     * dropping this one flag is a change nothing else would notice: the copilot
     * would still have these tools, plus every MCP server in the person's
     * `~/.claude.json`. An action log that cannot say which server a call came
     * from is not an audit record, and a tool surface that varies by machine is
     * one nobody can reason about.
     */
    await ensureCopilot(harness({ mcpConfig: () => '/state/copilot/deck-control.json' }))
    expect(calls[0]?.extraArgs).toContain('--strict-mcp-config')
  })

  it('starts with no tools rather than pointing at a server that is not there', async () => {
    /*
     * `mcpConfigPath()` answers a path whether or not the server came up, and
     * `deck-control` can genuinely fail to start — a port that will not bind, a
     * token file that cannot be made owner-only. Handing the CLI that path
     * would produce a copilot that starts, believes it has tools, and cannot
     * reach one. Null means no flags, and the copilot still runs.
     */
    const state = await ensureCopilot(harness({ mcpConfig: () => null }))
    expect(state.status).toBe('running')
    expect(calls[0]?.extraArgs).toEqual([])
  })

  it('writes which of the two happened into the log, because nothing else records it', async () => {
    await ensureCopilot(harness({ mcpConfig: () => '/state/copilot/deck-control.json' }))
    expect(readFileSync(copilotPaths(userData).actions, 'utf8')).toContain(
      'with this app’s tools from /state/copilot/deck-control.json',
    )

    resetCopilot()
    calls = []
    await ensureCopilot(harness({ mcpConfig: () => null }))
    // A copilot with no tools and a copilot whose every call is refused look
    // identical from the outside; this row is the only durable difference.
    expect(readFileSync(copilotPaths(userData).actions, 'utf8')).toContain('no deck-control server')
  })

  it('adds nothing about the CLI’s own permissions, in either direction', async () => {
    /*
     * The copilot runs as the person, so its Claude Code prompts follow *their*
     * `~/.claude/settings.json` — `permissions.defaultMode` and all. This app
     * neither loosens that nor tightens it, and both halves matter.
     *
     * Passing `--dangerously-skip-permissions` would be this app deciding, on
     * somebody's behalf, that their assistant may edit files without asking —
     * a decision that is theirs and that they may already have made. Passing a
     * stricter `--permission-mode` would be the opposite: an assistant that
     * stops to ask about things every other session on the machine does
     * silently, for no reason the person could find on any screen.
     *
     * The confirmation this app *does* raise is a different system entirely and
     * is unaffected either way — see "the CLI's permission mode is not this
     * gate" in `deck-control/index.test.ts`.
     */
    await ensureCopilot(harness({ mcpConfig: () => '/state/copilot/deck-control.json' }))
    const flags = calls[0]?.extraArgs ?? []
    expect(flags.some((flag) => flag.includes('permission'))).toBe(false)
    expect(flags.some((flag) => flag.includes('dangerously'))).toBe(false)
    // Two flags and a path, and nothing else travels on this launch.
    expect(flags).toHaveLength(3)
  })

  it('asks for the config at start time rather than capturing it', async () => {
    /*
     * `deck-control` starts asynchronously at boot and the copilot starts later
     * — from a window, or from whoever opens it — so a value read when the
     * dependencies were assembled would be the answer from before the server
     * existed. A function means the answer is the truth at the moment the
     * session is spawned.
     */
    let config: string | null = null
    const deps = harness({ mcpConfig: () => config })
    await ensureCopilot(deps)
    expect(calls[0]?.extraArgs).toEqual([])

    // The server came up while the copilot was stopped.
    resetCopilot()
    config = '/state/copilot/deck-control.json'
    await ensureCopilot(deps)
    expect(calls[1]?.extraArgs).toContain('--mcp-config')
  })
})

describe('the records fence', () => {
  it('wraps the spawn when this machine holds it', async () => {
    await ensureCopilot(deps)
    const fence = calls[0]?.fence
    expect(fence).toBeDefined()
    expect(fence?.apply('/bin/echo', ['x']).command).toBe('/usr/bin/sandbox-exec')
    expect(copilotState(deps).records).toMatchObject({ kind: 'seatbelt', enforced: true, reason: null })
  })

  it('starts the copilot anyway when it cannot be held, and says so', async () => {
    /*
     * The opposite of what confinement does, and deliberately.
     *
     * `confineSpawn` throws when a boundary cannot be proven, because the grant
     * screen promises a device is held inside a folder. This fence protects the
     * *record* rather than the person's disk, so a machine that cannot hold it
     * has worse auditing rather than an escaped agent — and refusing to start
     * over it would refuse the whole feature everywhere but macOS, which is the
     * failure being corrected.
     */
    const state = await ensureCopilot(
      harness({ fence: async () => ({ fence: null, reason: 'no mechanism here' }) }),
    )
    expect(state.status).toBe('running')
    expect(calls[0]?.fence).toBeUndefined()
    expect(state.records.enforced).toBe(false)
    expect(state.records.reason).toBe('no mechanism here')
  })

  it('writes which of the two happened into the log, because the state forgets', async () => {
    await ensureCopilot(harness({ fence: async () => ({ fence: null, reason: 'no mechanism here' }) }))
    const actions = readFileSync(copilotPaths(userData).actions, 'utf8')
    expect(actions).toContain('NOT held against it')
    expect(actions).toContain('no mechanism here')

    resetCopilot()
    calls = []
    await ensureCopilot(deps)
    expect(readFileSync(copilotPaths(userData).actions, 'utf8')).toContain('held against it (seatbelt)')
  })

  it('reports the platform’s own sentence before anything has started', () => {
    // A person opening Settings on Windows learns what is and is not true there
    // without having to start anything.
    const state = copilotState(harness({ platform: 'win32' }))
    expect(state.records.kind).toBe('none')
    expect(state.records.reason).toMatch(/recorded/i)
    expect(state.records.enforced).toBe(false)
  })

  it('names every path it holds, from the same function the profile uses', () => {
    expect(copilotState(deps).records.paths).toEqual(recordsFenceList(recordsFencePaths(userData)))
    /*
     * Five, not three, since `COPILOT-REMOTE.md` §0.3: the grant store and the
     * trust store joined the fence when a phone's copilot access became a thing
     * a file decides, because a store the copilot can write is a permission the
     * copilot grants itself.
     *
     * The count is asserted at all — rather than left to the `toEqual` above,
     * which would pass against a `recordsFenceList` that quietly returned
     * fewer — because that is the shape this fence fails in: a path dropped
     * from the list is a path the kernel stops being told about, and nothing on
     * screen changes.
     */
    expect(copilotState(deps).records.paths).toHaveLength(5)
  })
})

describe('it refuses rather than pretending', () => {
  it('starts on a platform with no confinement mechanism at all', async () => {
    /*
     * The regression this change exists for. `confinementKind('win32')` answers
     * `'none'` on every Windows machine that has not had the one-time
     * AppContainer grant — which is every Windows machine, because nothing in
     * the shipped UI performs it — and the copilot used to refuse outright
     * there. It was the single largest cost of the jail: on two of three
     * platforms the feature did not exist.
     */
    const state = await ensureCopilot(harness({ platform: 'win32' }))
    expect(state.status).toBe('running')
    expect(calls).toHaveLength(1)
    expect(state.problem).toBeNull()
  })

  it('will not open a plain shell when the agent CLI is missing', async () => {
    const state = await ensureCopilot(
      harness({ agents: async () => ({ claude: false, codex: false, gemini: false, shell: true }) }),
    )
    expect(calls).toHaveLength(0)
    expect(state.status).toBe('stopped')
    expect(state.problem).toMatch(/not installed/i)
    expect(readFileSync(copilotPaths(userData).actions, 'utf8')).toContain('session.refused')
  })

  it('kills the session if the spawn quietly fell back to a shell', async () => {
    // The fallback inside `startSession` is silent by design, and a race — an
    // upgrade removing the binary between the probe and the spawn — would
    // otherwise leave a bare shell pinned in the sidebar as your assistant.
    const state = await ensureCopilot(
      harness({
        async startSession(input, guest, confine, fence, extraArgs) {
          calls.push({ input, guest, confine, fence, extraArgs })
          const created = meta(input, 'shell')
          alive.add(created.id)
          return created
        },
      }),
    )
    expect(stopped).toHaveLength(1)
    expect(state.status).toBe('stopped')
    expect(state.problem).toMatch(/rather than an agent/i)
  })

  it('reports a failed spawn as a sentence rather than throwing', async () => {
    const state = await ensureCopilot(
      harness({
        startSession: async () => {
          throw new Error('that folder does not exist')
        },
      }),
    )
    // A pane has to draw this. A rejected promise would push the job onto every
    // caller and lose the reason on the way.
    expect(state.status).toBe('stopped')
    expect(state.problem).toContain('does not exist')
  })

  it('lets a later attempt succeed after a refusal', async () => {
    await ensureCopilot(
      harness({ agents: async () => ({ claude: false, codex: false, gemini: false, shell: true }) }),
    )
    const state = await ensureCopilot(deps)
    expect(state.status).toBe('running')
    expect(state.problem).toBeNull()
  })
})

describe('sign-in', () => {
  it('asks about the profile the copilot actually runs as', async () => {
    const asked: Profile[] = []
    const answer = await readCopilotSignIn(
      harness({
        signInOf: async (profile) => {
          asked.push(profile)
          return { state: 'signed-in' as const, account: 'a@b.c', plan: 'max' }
        },
      }),
    )
    expect(asked.map((profile) => profile.id)).toEqual(['system'])
    expect(answer).toMatchObject({ state: 'signed-in', account: 'a@b.c', profileName: 'Default' })
  })

  it('does not reuse a cached answer for a different account', async () => {
    /*
     * The moment a person is most likely to look at this pane is straight after
     * changing which account the copilot uses, and the cache is a minute long.
     */
    await readCopilotSignIn(deps, 1_000)
    const other: Profile = { ...DEFAULT_PROFILE, id: 'work', name: 'Work', system: false }
    const answer = await readCopilotSignIn(
      harness({
        profile: () => other,
        signInOf: async () => ({ state: 'signed-out' as const, account: null, plan: null }),
      }),
      1_500,
    )
    expect(answer.state).toBe('signed-out')
    expect(answer.profileId).toBe('work')
  })

  it('reuses it for the same account inside the window', async () => {
    let asked = 0
    const same = harness({
      signInOf: async () => {
        asked += 1
        return { state: 'signed-in' as const, account: null, plan: null }
      },
    })
    await readCopilotSignIn(same, 1_000)
    await readCopilotSignIn(same, 1_500)
    expect(asked).toBe(1)
  })

  it('never reports `unsupported`, which a pane has nothing to do with', async () => {
    const answer = await readCopilotSignIn(
      harness({ signInOf: async () => ({ state: 'unsupported' as const, account: null, plan: null }) }),
    )
    expect(answer.state).toBe('unknown')
  })
})

describe('the state a window reads', () => {
  it('describes the folder before anything has started', () => {
    const state = copilotState(deps)
    expect(state.status).toBe('stopped')
    expect(state.sessionId).toBeNull()
    expect(state.profile).toBeNull()
    expect(state.paths.root).toBe(copilotPaths(userData).root)
    expect(state.startupFiles.map((file) => file.exists)).toEqual([false, false])
  })

  it('lists what it reads at startup once it has a folder', async () => {
    await ensureCopilot(deps)
    const state = copilotState(deps)
    expect(state.startupFiles[0]?.path).toBe(copilotPaths(userData).instructions)
    expect(state.startupFiles[0]?.exists).toBe(true)
    expect(state.instructionsAreDefault).toBe(true)
  })

  it('still reports where a jailed copilot kept its conversations', () => {
    /*
     * Nothing writes there any more. An install upgraded from a build that
     * jailed the copilot still has that directory, holding its history, and it
     * is still inside the root four transcript readers scan — which is why
     * `copilotHomeScope` is still installed at boot. See
     * `copilot-transcript-forgery.test.ts`.
     */
    expect(copilotState(deps).home).toBe(copilotHome(join(userData, 'remote')))
    expect(copilotHome(join(userData, 'remote'))).toBe(
      join(userData, 'remote', 'device-home', COPILOT_HOME_KEY),
    )
    expect(copilotHomeScope(userData)).toEqual({
      home: copilotHome(join(userData, 'remote')),
      folder: copilotPaths(userData).root,
    })
  })
})

describe('the bridge', () => {
  it('registers the channels and takes nothing from the page but instruction text', () => {
    const handlers = new Map<string, (...args: unknown[]) => unknown>()
    registerCopilotIpc(
      { handle: (channel: string, fn: () => unknown) => handlers.set(channel, fn) } as never,
      deps,
    )
    expect([...handlers.keys()].sort()).toEqual([
      'copilot:ensure',
      'copilot:files',
      'copilot:read-instructions',
      // The only ones that write, and only one takes an argument: *which* file
      // is decided in this process either way.
      'copilot:reset-instructions',
      'copilot:signin',
      'copilot:state',
      'copilot:stop',
      'copilot:write-instructions',
    ])
    // The validation *is* the arity for all but one: nothing about where the
    // copilot runs comes from the renderer, so there is no path to sanitise and
    // no id to check. (`length` counts declared parameters; the IPC event is
    // one of them.)
    for (const [channel, handler] of handlers) {
      expect(handler.length, channel).toBeLessThanOrEqual(channel === 'copilot:write-instructions' ? 2 : 1)
    }
  })

  it('answers `copilot:files` with the same list the state carries', async () => {
    const handlers = new Map<string, () => unknown>()
    registerCopilotIpc(
      { handle: (channel: string, fn: () => unknown) => handlers.set(channel, fn) } as never,
      deps,
    )
    await ensureCopilot(deps)
    expect(handlers.get('copilot:files')?.()).toEqual(copilotState(deps).startupFiles)
  })
})

describe('the action log records the lifecycle', () => {
  it('writes the folder being made and the session starting', async () => {
    await ensureCopilot(deps)
    const lines = readFileSync(copilotPaths(userData).actions, 'utf8')
      .trim()
      .split('\n')
      .map((line) => JSON.parse(line) as { action: string; detail?: string })
    expect(lines.map((line) => line.action)).toEqual(['home.created', 'session.started'])
    // Which account it ran as, because "why did that answer come from a
    // different subscription" is a question the log should answer.
    expect(lines[1]?.detail).toContain('Default')
  })

  it('does not repeat `home.created` on a later start', async () => {
    await ensureCopilot(deps)
    alive.clear()
    await ensureCopilot(deps)
    const actions = readFileSync(copilotPaths(userData).actions, 'utf8')
    expect(actions.match(/home\.created/g)).toHaveLength(1)
  })
})

/**
 * The answer the network asks for, and the reason it is asked of this module.
 *
 * `isCopilotSession` is consulted by `remote/session-fanout.ts` on the read path
 * of every frame a paired device sends — `list`, `attach`, `input`, `resize` —
 * so that the copilot's keyboard is not reachable from a phone. The cases below
 * are the three states it has to get right; the end-to-end proof that a phone
 * is actually refused lives in `remote/server.test.ts`, and the proof that this
 * app wires the two together lives in `copilot-off-the-network.test.ts`.
 */
describe('which session is the copilot', () => {
  it('names the running copilot and nothing else', async () => {
    const state = await ensureCopilot(deps)
    expect(state.sessionId).not.toBeNull()
    expect(isCopilotSession(state.sessionId as string)).toBe(true)
    // A session the person opened is not the copilot, whatever it is doing.
    expect(isCopilotSession('session-the-person-opened')).toBe(false)
    // Nor is a made-up id, which is what a phone guessing would send.
    expect(isCopilotSession('')).toBe(false)
  })

  it('answers for the new session after a restart, not the old one', async () => {
    const first = await ensureCopilot(deps)
    alive.clear()
    const second = await ensureCopilot(deps)
    expect(second.sessionId).not.toBe(first.sessionId)
    expect(isCopilotSession(second.sessionId as string)).toBe(true)
    // The old id stops being the copilot the moment a new one is: the answer
    // follows the live session rather than accumulating every id this module
    // has ever started, so a hidden set cannot grow for the life of the app.
    expect(isCopilotSession(first.sessionId as string)).toBe(false)
  })

  it('still names a copilot whose process has gone, until something restarts it', async () => {
    const state = await ensureCopilot(deps)
    // The process died; nothing has recomputed the state yet. This is the
    // window a phone would have to hit, and the honest answer in it is "that
    // might still be the copilot's keyboard" — an attach to a dead session is
    // refused for not existing anyway, and pty ids are not reused.
    alive.clear()
    expect(isCopilotSession(state.sessionId as string)).toBe(true)
  })

  it('answers false when no copilot is running', () => {
    expect(isCopilotSession('anything')).toBe(false)
  })
})

describe('resetCopilot', () => {
  it('is the only way module state is cleared', async () => {
    await ensureCopilot(deps)
    resetCopilot()
    expect(copilotState(deps).status).toBe('stopped')
    // And it does not touch the disk: the folder and the log survive, which is
    // what makes it safe to call between tests without hiding a scaffolding bug.
    expect(existsSync(copilotPaths(userData).instructions)).toBe(true)
  })
})

describe('putting the instructions back', () => {
  it('detects an out-of-date default and replaces it, keeping a copy', async () => {
    await ensureCopilot(deps)
    const paths = copilotPaths(userData)
    // Exactly what an install from an earlier build has on disk.
    writeFileSync(paths.instructions, PAST_COPILOT_INSTRUCTIONS[0]?.(paths) ?? '')
    expect(copilotState(deps).instructions).toBe('superseded')
    expect(copilotState(deps).instructionsAreDefault).toBe(false)

    const result = resetCopilotInstructions(paths)
    expect(result.reset).toBe(true)
    expect(readFileSync(result.backup ?? '', 'utf8')).toContain('the assistant for the *app itself*')
    expect(copilotState(deps).instructions).toBe('current')
  })

  it('calls a hand-edited file edited, and never confuses it with an old default', async () => {
    await ensureCopilot(deps)
    const paths = copilotPaths(userData)
    writeFileSync(paths.instructions, '# mine\nOnly answer in French.\n')
    expect(copilotState(deps).instructions).toBe('edited')
  })
})

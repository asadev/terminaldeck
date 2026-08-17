import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { beforeEach, describe, expect, it } from 'vitest'
import type { CreateSessionInput, ProviderId, SessionMeta } from '../shared/types'
import type { DeviceConfinement } from './confine'
import { copilotPaths, resetCopilotInstructions } from './copilot-home'
import { PAST_COPILOT_INSTRUCTIONS } from './copilot-instructions-history'
import {
  COPILOT_HOME_KEY,
  copilotConfigDir,
  copilotHome,
  copilotPlan,
  copilotProjectRoots,
  copilotState,
  ensureCopilot,
  registerCopilotIpc,
  resetCopilot,
  stopCopilot,
  type CopilotRuntimeDeps,
} from './copilot-session'

/**
 * A host core that records rather than spawns.
 *
 * `startSession` is the one thing this module must not re-implement — it is the
 * single place in the app that starts a session, and the whole design rests on
 * the copilot going through it like everything else. So the interesting
 * assertions here are about *what is handed to it*: the folder, the account, the
 * confinement, and the environment. Whether a pty appears is `pty-manager`'s
 * question and is answered by its own tests and by a real run.
 */
interface Recorded {
  input: CreateSessionInput
  guest: { set: Record<string, string>; remove: string[] } | undefined
  confine: DeviceConfinement | undefined
}

let userData: string
let calls: Recorded[]
let alive: Set<string>
let stopped: string[]
let deps: CopilotRuntimeDeps

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
    accountHome: () => join(userData, 'account-home'),
    platform: 'darwin',
    agents: async () => ({ claude: true, codex: false, gemini: false, shell: true }),
    /*
     * No projects and no event, unless a test asks for them.
     *
     * Both default to the app's own store in production, and reaching it from
     * here would make every case below depend on a `state.json` this file never
     * wrote — and on `platform/paths.ts` having been told where userData is,
     * which it has not.
     */
    projects: () => projects,
    onProjectsChanged: (listener) => {
      projectListeners.push(listener)
      return () => {
        projectListeners = projectListeners.filter((seen) => seen !== listener)
      }
    },
    async startSession(input, guest, confine) {
      calls.push({ input, guest, confine })
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

/** The folders "the person has added", as the harness answers for them. */
let projects: string[] = []
let projectListeners: ((paths: readonly string[]) => void)[] = []

/** Make a folder and add it to the list, the way opening one in the app does. */
function addProject(name: string): string {
  const path = realpathSync(mkdtempSync(join(tmpdir(), `copilot-project-${name}-`)))
  projects = [...projects, path]
  for (const listener of projectListeners) listener(projects)
  return path
}

/** Take one back out again. */
function dropProject(path: string): void {
  projects = projects.filter((seen) => seen !== path)
  for (const listener of projectListeners) listener(projects)
}

beforeEach(() => {
  resetCopilot()
  userData = mkdtempSync(join(tmpdir(), 'copilot-run-'))
  calls = []
  alive = new Set()
  stopped = []
  projects = []
  projectListeners = []
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

describe('what it is handed', () => {
  it('runs in its own folder, as a Claude session, fresh each launch', async () => {
    await ensureCopilot(deps)
    const [call] = calls
    expect(call?.input.cwd).toBe(copilotPaths(userData).root)
    expect(call?.input.provider).toBe('claude')
    // `--continue` would make it one conversation that never ends, and a turn
    // costs what the conversation before it costs. Continuity is `memory/`.
    expect(call?.input.resume).toBe(false)
  })

  it('pins its account rather than following whatever a project defaults to', async () => {
    await ensureCopilot(deps)
    // The system profile is how the resolution chain is told not to apply a
    // project or global default. With HOME redirected, the CLI's own store is
    // inside the copilot's boundary rather than the machine's.
    expect(calls[0]?.input.profileId).toBe('system')
  })

  it('is confined to its own folder and its own home', async () => {
    await ensureCopilot(deps)
    const confine = calls[0]?.confine
    expect(confine).toBeDefined()
    expect(confine?.home).toBe(copilotHome(join(userData, 'remote')))
    expect(confine?.writable).toEqual([])
  })

  it('keeps its home where the transcript readers already look', async () => {
    // Not decoration. `transcript.ts` walks every directory under the
    // confined-homes root when it is asked where a project's conversations are,
    // so this placement is what makes the transcript viewer, chat mode, the
    // cost pane and the alert watcher see the copilot with no change at all.
    await ensureCopilot(deps)
    expect(copilotHome(join(userData, 'remote'))).toBe(
      join(userData, 'remote', 'device-home', COPILOT_HOME_KEY),
    )
    expect(existsSync(calls[0]?.confine?.home ?? '')).toBe(true)
  })

  it('points the CLI at a config directory inside its own home', async () => {
    /*
     * The one line that decides whether the copilot can ever be signed in.
     *
     * Measured against Claude Code 2.1.233 inside a real sandbox: with
     * `CLAUDE_CONFIG_DIR` unset the CLI reads its credential from the macOS
     * login keychain, which a confined process cannot reach — so the copilot
     * walks into the login screen forever, whatever is on its disk. With it set
     * the CLI reads `<configDir>/.credentials.json`, a file inside the boundary
     * that it can also write.
     *
     * `.claude` under the home, and the name matters twice: `transcript.ts`
     * looks for exactly that when it walks the confined homes, which is what
     * keeps the copilot's conversation visible to the transcript viewer.
     */
    await ensureCopilot(deps)
    const home = copilotHome(join(userData, 'remote'))
    expect(calls[0]?.guest?.set.CLAUDE_CONFIG_DIR).toBe(copilotConfigDir(home))
    expect(copilotConfigDir(home)).toBe(join(home, '.claude'))
  })

  it("takes away the variables that would hand it somebody else's GitHub account", async () => {
    // The sandbox is about files. A `GH_TOKEN` inherited from whatever launched
    // the app is in the process, not on the disk, and the copilot has a shell
    // and an open network.
    await ensureCopilot(deps)
    const remove = calls[0]?.guest?.remove ?? []
    expect(remove).toContain('GH_TOKEN')
    expect(remove).toContain('GITHUB_TOKEN')
    expect(remove).toContain('SSH_AUTH_SOCK')
    expect(calls[0]?.guest?.set.GIT_CONFIG_GLOBAL).toContain(COPILOT_HOME_KEY)
  })
})

describe('it refuses rather than pretending', () => {
  it('will not start where the boundary cannot be enforced', async () => {
    // Windows without the one-time setup answers `none`, and `startSession`
    // would happily run it unconfined — the right answer for a person at their
    // own keyboard and the wrong one for an agent the app is running itself.
    const state = await ensureCopilot(harness({ platform: 'win32' }))
    expect(calls).toHaveLength(0)
    expect(state.status).toBe('unavailable')
    expect(state.problem).toBeTruthy()
    expect(state.confinement.enforced).toBe(false)
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
        async startSession(input, guest, confine) {
          calls.push({ input, guest, confine })
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

  it('reports a refused confinement as a sentence rather than throwing', async () => {
    const state = await ensureCopilot(
      harness({
        startSession: async () => {
          throw new Error('This session could not be confined to its folder: no boundary')
        },
      }),
    )
    // A pane has to draw this. A rejected promise would push the job onto every
    // caller and lose the reason on the way.
    expect(state.status).toBe('stopped')
    expect(state.problem).toContain('could not be confined')
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

describe('the plan', () => {
  const plan = (): ReturnType<typeof copilotPlan> =>
    copilotPlan({
      folder: '/app/copilot',
      home: '/app/remote/device-home/copilot',
      accountHome: '/Users/someone',
      path: '/usr/bin:/bin',
      platform: 'darwin',
    })

  it('grants the folder and the home, and nothing of the account', () => {
    const built = plan()
    expect(built.writable).toContain('/app/copilot')
    expect(built.writable).toContain('/app/remote/device-home/copilot')
    expect(built.writable).not.toContain('/Users/someone')
    expect(built.readable).not.toContain('/Users/someone')
  })

  it('protects the account home by naming it as the thing being guarded', () => {
    expect(plan().accountHome).toBe('/Users/someone')
  })

  it('grants no individual files', () => {
    // The credential helper is the only thing that ever needed a file rule, and
    // the copilot has no credential proxy: it is not a guest device.
    expect(plan().readableFiles).toEqual([])
  })
})

describe('the state a window reads', () => {
  it('describes the folder before anything has started', () => {
    const state = copilotState(deps)
    expect(state.status).toBe('stopped')
    expect(state.sessionId).toBeNull()
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

  it('says the boundary was enforced only for a session that actually started', async () => {
    expect(copilotState(deps).confinement.enforced).toBe(false)
    await ensureCopilot(deps)
    expect(copilotState(deps).confinement).toMatchObject({ kind: 'seatbelt', enforced: true })
  })
})

describe('the bridge', () => {
  it('registers six channels and none of them takes an argument from the page', () => {
    const handlers = new Map<string, (...args: unknown[]) => unknown>()
    registerCopilotIpc(
      { handle: (channel: string, fn: () => unknown) => handlers.set(channel, fn) } as never,
      deps,
    )
    expect([...handlers.keys()].sort()).toEqual([
      'copilot:ensure',
      'copilot:files',
      // The only one that writes, and it still takes nothing: *which* file and
      // *what* goes in it are both decided in this process.
      'copilot:reset-instructions',
      'copilot:signin',
      'copilot:state',
      'copilot:stop',
    ])
    // The validation *is* the arity: nothing about where the copilot runs comes
    // from the renderer, so there is no path to sanitise and no id to check.
    // (`length` counts declared parameters; the IPC event is the only one.)
    for (const handler of handlers.values()) expect(handler.length).toBeLessThanOrEqual(1)
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
    expect(lines[1]?.detail).toContain('seatbelt')
  })

  it('does not repeat `home.created` on a later start', async () => {
    await ensureCopilot(deps)
    alive.clear()
    await ensureCopilot(deps)
    const actions = readFileSync(copilotPaths(userData).actions, 'utf8')
    expect(actions.match(/home\.created/g)).toHaveLength(1)
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

describe('reading the person\'s projects', () => {
  it('grants every project as read-only and none of them as writable', async () => {
    const one = addProject('one')
    const two = addProject('two')
    await ensureCopilot(deps)
    const confine = calls[0]?.confine
    expect([...(confine?.projects ?? [])].sort()).toEqual([one, two].sort())
    // The half that is not being widened. There is no arrangement of these
    // fields that makes a repository writable by the copilot.
    expect(confine?.writable).toEqual([])
  })

  it('reads the list at the spawn rather than holding a snapshot', async () => {
    // The plan is frozen at `exec`, so the only thing that can be live is the
    // derivation. A folder added before the start must be in the profile.
    const late = addProject('late')
    await ensureCopilot(deps)
    expect(calls[0]?.confine?.projects).toContain(late)
  })

  it('never grants the app\'s own storage, even when it is on the list', async () => {
    // `<userData>` holds every session's transcript, the paired devices'
    // credentials, `state.json` and `settings.json`. A person can add any
    // folder to this app, this one included.
    const inside = join(userData, 'somewhere')
    mkdirSync(inside, { recursive: true })
    projects = [userData, inside]
    await ensureCopilot(deps)
    expect(calls[0]?.confine?.projects).toEqual([])
  })

  it('says in the action log which folders it can read', async () => {
    const one = addProject('logged')
    await ensureCopilot(deps)
    const actions = readFileSync(copilotPaths(userData).actions, 'utf8')
    expect(actions).toContain('read-only')
    expect(actions).toContain(one)
  })

  it('grants nothing where the credential exclusions cannot be enforced', async () => {
    // Not a narrower version of the feature: the Linux backend would grant the
    // folder whole, `.env` included, and Windows ignores read roots entirely.
    // `copilotProjectRoots` says so rather than leaving it to be guessed.
    addProject('linux')
    const linux = harness({ platform: 'linux' })
    const answer = copilotProjectRoots(linux)
    expect(answer.roots).toEqual([])
    expect(answer.enforceable).toBe(false)
    expect(answer.reason).toMatch(/macOS/)
  })
})

describe('the grant follows the project list', () => {
  it('stops the copilot when a folder it could read is removed', async () => {
    const one = addProject('revoked')
    await ensureCopilot(deps)
    const sessionId = copilotState(deps).sessionId

    dropProject(one)

    expect(stopped).toContain(sessionId)
    expect(copilotState(deps).status).toBe('stopped')
    expect(copilotState(deps).problem).toContain(one)
    const actions = readFileSync(copilotPaths(userData).actions, 'utf8')
    expect(actions).toContain('projects.revoked')
  })

  it('leaves a running copilot alone when a folder is added', async () => {
    // A widening is nobody's emergency, and throwing away a conversation in
    // progress because somebody opened an unrelated folder would be worse than
    // the delay.
    addProject('first')
    await ensureCopilot(deps)
    const sessionId = copilotState(deps).sessionId
    const later = addProject('later')
    expect(stopped).toEqual([])
    expect(copilotState(deps).sessionId).toBe(sessionId)
    // But it is reported, because otherwise the person has no way to know why
    // their copilot cannot see the folder they just opened.
    expect(copilotState(deps).projects.pending).toEqual([later])
  })

  it('picks the new folder up on the next start', async () => {
    addProject('first')
    await ensureCopilot(deps)
    const later = addProject('later')
    stopCopilot(deps)
    await ensureCopilot(deps)
    expect(calls[1]?.confine?.projects).toContain(later)
    expect(copilotState(deps).projects.pending).toEqual([])
  })

  it('catches a removal that no event announced, at the next ensure', async () => {
    // The certain half. A listener that was never attached, a shell that does
    // not emit, a `state.json` edited by hand while the app was closed — the
    // event is what makes this prompt, and `ensure` is what makes it hold.
    const one = addProject('quietly-removed')
    await ensureCopilot(deps)
    expect(calls[0]?.confine?.projects).toEqual([one])
    projects = []
    await ensureCopilot(deps)
    expect(calls[1]?.confine?.projects).toEqual([])
  })

  it('reports what the running process can read, not what the list says', async () => {
    const one = addProject('granted')
    await ensureCopilot(deps)
    addProject('not-yet')
    const state = copilotState(deps)
    expect(state.projects.granted).toEqual([one])
    expect(state.projects.available).toHaveLength(2)
    expect(state.projects.enforceable).toBe(true)
    expect(state.projects.excluded).toContain('dotenv')
  })

  it('reports nothing readable while nothing is running', () => {
    addProject('listed')
    const state = copilotState(deps)
    expect(state.projects.granted).toEqual([])
    expect(state.projects.available).toHaveLength(1)
  })

  it('stops listening once it has been stopped', async () => {
    addProject('one')
    await ensureCopilot(deps)
    expect(projectListeners).toHaveLength(1)
    stopCopilot(deps)
    expect(projectListeners).toHaveLength(0)
  })

  it('leaves one listener behind, not one per start', async () => {
    addProject('one')
    await ensureCopilot(deps)
    alive.clear()
    await ensureCopilot(deps)
    expect(projectListeners).toHaveLength(1)
  })
})

describe('putting the instructions back', () => {
  it('detects an out-of-date default and replaces it, keeping a copy', async () => {
    await ensureCopilot(deps)
    const paths = copilotPaths(userData)
    // Exactly what an install from earlier tonight has on disk.
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

import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it, vi } from 'vitest'
import {
  conversationOnDisk,
  folderExists,
  personalSessions,
  planRestore,
  restoreOpenSessions,
  type Conversation,
  type PlanProbes,
  type RestoreDecision,
  type SavedSession,
} from './session-restore'
import { transcriptDir } from './transcript'
import type { CreateSessionInput, SessionMeta } from '../shared/types'

/**
 * What comes back after a restart, what starts clean, and what does not come
 * back at all.
 *
 * The decision is the whole feature. Everything downstream of it — the spawn,
 * the announcement, the tab — already existed and is exercised elsewhere; the
 * part that had never been written is "given these tabs and this disk, which of
 * them may honestly be continued". So these tests drive `planRestore` directly
 * with the probes stubbed, and only then check that the driver acts on what the
 * plan said.
 *
 * The last describe block is a different kind of test and the more important
 * one: it reads `index.ts` as text and asserts that launching is what triggers
 * a restore. This repo's most expensive bug class is a feature wired to a
 * button and never to boot — `src/reachable.test.ts` opens by naming
 * restore-on-launch as one of five features that shipped with no way in — and a
 * restore reachable only from a menu item would pass every test above this one.
 */

const ROOT = join(__dirname, '..', '..')

const TMP = mkdtempSync(join(tmpdir(), 'terminaldeck-restore-'))
afterAll(() => rmSync(TMP, { recursive: true, force: true }))

function saved(overrides: Partial<SavedSession> = {}): SavedSession {
  return {
    cwd: '/Users/asad/Projects/terminaldeck',
    provider: 'claude',
    profileId: null,
    cols: 100,
    rows: 30,
    lastSeenAt: 1_000,
    ...overrides,
  }
}

/**
 * Probes that say yes to everything, so each test overrides only what it is
 * about.
 *
 * `configDir` answers with one directory for every session, which is the
 * single-login case and the one most tests want. The tests that are *about*
 * profiles override it, because two profiles is exactly the case where one
 * directory is the wrong answer.
 */
function probes(overrides: Partial<PlanProbes> = {}): PlanProbes {
  return {
    folderExists: async () => true,
    canContinue: (provider) => provider === 'claude' || provider === 'codex',
    configDir: () => '/Users/asad/.claude',
    conversation: async () => 'found',
    ...overrides,
  }
}

const outcomes = (decisions: readonly RestoreDecision[]): string[] =>
  decisions.map((decision) => decision.outcome)

describe('planRestore', () => {
  it('continues a session whose conversation is on disk', async () => {
    const plan = await planRestore([saved()], probes())
    expect(outcomes(plan)).toEqual(['resume'])
  })

  /**
   * The finding, as a value, beside the finding as a sentence.
   *
   * `reason` is written for a person and is meant to be reworded whenever a
   * better sentence turns up. `session-switch.ts` has to *branch* on the same
   * finding — "the other account has a conversation here" and "this agent keeps
   * its history where the app cannot read it" produce different words on screen
   * before a switch, and the second is Codex and every session inside WSL. It
   * used to have no choice but to match on the prose, which breaks silently the
   * first time somebody improves the prose, and breaks in the direction of a
   * confident wrong claim.
   *
   * Absent is load-bearing and means "never asked", not "nothing found".
   */
  it('carries what the disk said, and only when the disk was asked', async () => {
    const found = await planRestore([saved()], probes())
    expect(found[0].conversation).toBe('found')

    const empty = await planRestore([saved()], probes({ conversation: async () => 'none' }))
    expect(empty[0].conversation).toBe('none')

    const unread = await planRestore([saved()], probes({ conversation: async () => 'unknown' }))
    expect(unread[0].conversation).toBe('unknown')

    const gone = await planRestore([saved()], probes({ folderExists: async () => false }))
    expect(gone[0].conversation).toBeUndefined()

    const cannot = await planRestore([saved({ provider: 'shell' })], probes())
    expect(cannot[0].conversation).toBeUndefined()
  })

  it('starts clean when the conversation is gone', async () => {
    /*
     * The case this feature must not get wrong. `claude --continue` with
     * nothing to continue does not open an empty session — it errors and the
     * tab dies. Starting clean is the honest answer, and `resume: false` is
     * what stops every downstream view attributing an older transcript to it.
     */
    const plan = await planRestore([saved()], probes({ conversation: async () => 'none' }))
    expect(outcomes(plan)).toEqual(['fresh'])
    expect(plan[0].reason).toContain('no earlier conversation')
  })

  it('does not open a tab for a folder that is no longer there', async () => {
    const plan = await planRestore([saved()], probes({ folderExists: async () => false }))
    expect(outcomes(plan)).toEqual(['skip'])
    expect(plan[0].reason).toContain('folder')
  })

  it('asks about the folder before anything else', async () => {
    // A missing folder must not reach the transcript lookup: `transcriptDir`
    // happily builds a path for a folder that does not exist, so the lookup
    // would answer "no conversation" and the plan would start a session in a
    // directory that is gone — which fails at spawn, later and less clearly.
    const conversation = vi.fn<(session: SavedSession) => Promise<Conversation>>(async () => 'found')
    await planRestore([saved()], probes({ folderExists: async () => false, conversation }))
    expect(conversation).not.toHaveBeenCalled()
  })

  it('starts a provider with no continue flag clean, and does not call it a failure', async () => {
    const plan = await planRestore(
      [saved({ provider: 'shell' })],
      probes({ canContinue: () => false }),
    )
    expect(outcomes(plan)).toEqual(['fresh'])
    expect(plan[0].reason).toContain('no way to continue')
  })

  it('takes an agent whose history it cannot read at its word', async () => {
    // codex keeps its own store. "unknown" is not "none": the tab was open when
    // the app closed, so there is almost certainly something to continue, and
    // if there is not the CLI says so in its own words.
    const plan = await planRestore(
      [saved({ provider: 'codex' })],
      probes({ conversation: async () => 'unknown' }),
    )
    expect(outcomes(plan)).toEqual(['resume'])
  })

  it('continues only one tab per folder, and it is the one used last', async () => {
    /*
     * `--continue` picks the most recently written conversation in the working
     * directory, so two tabs on one folder cannot both continue — they would
     * attach to the same conversation and the user would be reading it twice.
     */
    const older = saved({ lastSeenAt: 10 })
    const newer = saved({ lastSeenAt: 20 })
    const plan = await planRestore([older, newer], probes())
    expect(outcomes(plan)).toEqual(['fresh', 'resume'])
    expect(plan[1].session).toBe(newer)
  })

  it('keeps tab order even when the tab that continues is not the first', async () => {
    const first = saved({ cwd: '/a', lastSeenAt: 5 })
    const second = saved({ cwd: '/b', lastSeenAt: 50 })
    const third = saved({ cwd: '/a', lastSeenAt: 9 })
    const plan = await planRestore([first, second, third], probes())
    expect(plan.map((decision) => decision.session)).toEqual([first, second, third])
    expect(outcomes(plan)).toEqual(['fresh', 'resume', 'resume'])
  })

  it('lets every folder continue its own conversation', async () => {
    const plan = await planRestore(
      [saved({ cwd: '/a' }), saved({ cwd: '/b' }), saved({ cwd: '/c' })],
      probes(),
    )
    expect(outcomes(plan)).toEqual(['resume', 'resume', 'resume'])
  })

  /*
   * The three below are one bug wearing three hats: "one conversation per
   * folder" is not true, and every place it was assumed, a real conversation was
   * silently dropped. What is actually true is one conversation per *store* —
   * the agent, the login and the folder together. Each of these fails against a
   * plan that keys on the folder alone.
   */

  it('does not let a shell tab take a claim it cannot use', async () => {
    /*
     * The worst of the three, because the shell tab wins on recency and then
     * cannot use what it won. A shell has no conversation and no continue flag,
     * so it was taking the folder's claim, being told two lines later that it
     * has nothing to continue, and leaving the Claude tab beside it to start
     * clean on top of a full transcript.
     */
    const shellTab = saved({ cwd: '/a', provider: 'shell', lastSeenAt: 100 })
    const claudeTab = saved({ cwd: '/a', provider: 'claude', lastSeenAt: 50 })
    const plan = await planRestore([shellTab, claudeTab], probes())
    expect(outcomes(plan)).toEqual(['fresh', 'resume'])
    expect(plan[1].session).toBe(claudeTab)
  })

  it('lets two different agents in one folder each continue their own', async () => {
    // `codex resume --last` reads Codex's store and `claude --continue` reads
    // Claude's. They cannot collide, so making one of them start clean threw
    // away a conversation to prevent a clash that could not happen.
    const plan = await planRestore(
      [
        saved({ cwd: '/a', provider: 'claude', lastSeenAt: 10 }),
        saved({ cwd: '/a', provider: 'codex', lastSeenAt: 20 }),
      ],
      probes({ conversation: async () => 'found' }),
    )
    expect(outcomes(plan)).toEqual(['resume', 'resume'])
  })

  it('lets two profiles in one folder each continue their own', async () => {
    // A profile is a separate CLAUDE_CONFIG_DIR, which is a separate transcript
    // directory. A work login and a personal login on the same repo are two
    // conversations, and only one of them used to come back.
    const work = saved({ cwd: '/a', profileId: 'work', lastSeenAt: 10 })
    const personal = saved({ cwd: '/a', profileId: 'personal', lastSeenAt: 20 })
    const plan = await planRestore(
      [work, personal],
      probes({ configDir: (session) => `/profiles/${session.profileId ?? 'system'}` }),
    )
    expect(outcomes(plan)).toEqual(['resume', 'resume'])
  })

  it('still allows only one tab when the store really is shared', async () => {
    // The guard the three above must not have loosened: same agent, same login,
    // same folder is genuinely one conversation, and two tabs continuing it
    // would show the user the same thing twice.
    const plan = await planRestore(
      [
        saved({ cwd: '/a', provider: 'claude', profileId: 'work', lastSeenAt: 10 }),
        saved({ cwd: '/a', provider: 'claude', profileId: 'work', lastSeenAt: 20 }),
      ],
      probes({ configDir: (session) => `/profiles/${session.profileId ?? 'system'}` }),
    )
    expect(outcomes(plan)).toEqual(['fresh', 'resume'])
  })

  it('asks about the conversation in the directory that session actually uses', async () => {
    /*
     * The wiring half of the same bug. The lookup has to happen in the profile's
     * own config directory; asking the default install about a profiled session
     * gets "no conversation" for a login with years of them, and the tab comes
     * back blank with its transcript untouched on disk.
     */
    const seen: string[] = []
    await planRestore([saved({ profileId: 'work' })], {
      folderExists: async () => true,
      canContinue: () => true,
      configDir: () => '/profiles/work',
      conversation: async (_session, configDir) => {
        seen.push(configDir)
        return 'found'
      },
    })
    expect(seen).toEqual(['/profiles/work'])
  })

  it('carries the store it asked about, so the paint cannot read a different one', async () => {
    /*
     * The decision is what the replay is handed, and this field is why. A
     * profile redirects `CLAUDE_CONFIG_DIR`, so "the transcripts for this
     * folder" has a different answer per login; resolving it a second time
     * downstream is how the tab ends up continuing one conversation and showing
     * another, with nothing on screen to say so.
     */
    const plan = await planRestore(
      [saved({ profileId: 'work' }), saved({ cwd: '/gone' }), saved({ provider: 'shell' })],
      probes({
        folderExists: async (cwd) => cwd !== '/gone',
        canContinue: (provider) => provider === 'claude',
        configDir: (session) => `/profiles/${session.profileId ?? 'system'}`,
      }),
    )
    expect(plan[0].configDir).toBe('/profiles/work')
    // Nothing was asked about these two, and saying nothing is the honest
    // answer: one folder is gone and the other agent has no history to read.
    expect(plan[1].configDir).toBeUndefined()
    expect(plan[2].configDir).toBeUndefined()
  })

  it('gives a reason a person can read for every decision', async () => {
    // These end up in the app log, which the user can open from Settings. A
    // reason that is an error code, or empty, is the version of this that
    // leaves a missing tab unexplained.
    const plan = await planRestore(
      [
        saved({ cwd: '/gone' }),
        saved({ cwd: '/here' }),
        saved({ cwd: '/shell', provider: 'shell' }),
      ],
      probes({
        folderExists: async (cwd) => cwd !== '/gone',
        canContinue: (provider) => provider === 'claude',
      }),
    )
    for (const decision of plan) {
      expect(decision.reason.length).toBeGreaterThan(12)
      expect(decision.reason).toMatch(/^[a-z]/)
    }
  })
})

describe('conversationOnDisk', () => {
  it('finds a real transcript through the same lookup the rest of the app uses', async () => {
    const configDir = join(TMP, 'claude-config')
    const session = saved({ cwd: join(TMP, 'project-with-history') })
    const dir = transcriptDir(session.cwd, configDir)
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, 'a1b2c3d4.jsonl'), '{"type":"user"}\n', 'utf8')
    await expect(conversationOnDisk(session, configDir, 'darwin')).resolves.toBe('found')
  })

  it('does not count a transcript the CLI created and never wrote to', async () => {
    // The CLI opens the file before it has a turn to put in it. Counting an
    // empty one would send `--continue` at nothing, which is the dead-tab case.
    const configDir = join(TMP, 'claude-config-empty')
    const session = saved({ cwd: join(TMP, 'project-empty-file') })
    const dir = transcriptDir(session.cwd, configDir)
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, 'a1b2c3d4.jsonl'), '', 'utf8')
    await expect(conversationOnDisk(session, configDir, 'darwin')).resolves.toBe('none')
  })

  it('answers none for a folder Claude Code has never run in', async () => {
    const configDir = join(TMP, 'claude-config-missing')
    const session = saved({ cwd: join(TMP, 'never-used') })
    await expect(conversationOnDisk(session, configDir, 'darwin')).resolves.toBe('none')
  })

  it('refuses to guess for an agent whose history it cannot read', async () => {
    const configDir = join(TMP, 'claude-config')
    await expect(conversationOnDisk(saved({ provider: 'codex' }), configDir, 'darwin')).resolves.toBe('unknown')
    await expect(conversationOnDisk(saved({ provider: 'shell' }), configDir, 'darwin')).resolves.toBe('unknown')
  })

  it('reads the profile it is given rather than the default install', async () => {
    /*
     * Two config directories for one folder, and only the profile's has a
     * conversation in it. This is the shape of a user who keeps a work login
     * isolated: the default install is empty for that repo, so a lookup that
     * ignores the profile answers "none" and the tab starts clean on top of a
     * transcript that is right there.
     */
    const cwd = join(TMP, 'project-profiled')
    const profileDir = join(TMP, 'profile-work')
    const defaultDir = join(TMP, 'profile-default')
    mkdirSync(transcriptDir(cwd, profileDir), { recursive: true })
    writeFileSync(join(transcriptDir(cwd, profileDir), 'a1.jsonl'), '{"type":"user"}\n', 'utf8')
    mkdirSync(transcriptDir(cwd, defaultDir), { recursive: true })

    await expect(conversationOnDisk(saved({ cwd }), profileDir, 'darwin')).resolves.toBe('found')
    await expect(conversationOnDisk(saved({ cwd }), defaultDir, 'darwin')).resolves.toBe('none')
  })

  /*
   * "Pick up where you left off" worked on the Mac and not on Windows.
   *
   * Reproduced on his own PC rather than reasoned about. `DESKTOP-DDGMNCV` runs
   * every session inside WSL, so `state.json` there holds
   * `{"cwd":"/home/asad/ClaudeImza",…}`, and the app log for that launch reads:
   *
   *     [restore] started clean: no earlier conversation was found on disk for
   *     this folder {"folder":"/home/asad/ClaudeImza","agent":"claude"}
   *
   * while the distribution held `/home/asad/.claude/projects/-home-asad-ClaudeImza`
   * with that morning's conversation in it, and the Windows side's
   * `C:\Users\Imza\.claude\projects\` held no such directory at all — only
   * `--wsl-localhost-ubuntu-24-04-home-asad-ClaudeImza`, written by a Claude
   * that had been launched from Windows against the UNC path.
   *
   * The lookup was asking a directory that cannot hold the answer, about a
   * folder name the agent never wrote, and reporting `none` — a confident claim
   * that there is nothing to continue.
   */
  it('does not claim a WSL session has no conversation just because Windows cannot see one', async () => {
    const configDir = join(TMP, 'windows-side-claude')
    const session = saved({ cwd: '/home/asad/ClaudeImza' })

    // On Windows this folder is a Linux folder and its agent ran inside the
    // distribution: unknown, so `--continue` is passed and the CLI finds its
    // own transcript.
    await expect(conversationOnDisk(session, configDir, 'win32')).resolves.toBe('unknown')

    // The very same session on a Mac is an ordinary host path with an ordinary
    // host store, and there the answer really is "nothing here".
    await expect(conversationOnDisk(session, configDir, 'darwin')).resolves.toBe('none')
  })

  it('still reads the host store for a Windows session that is not in WSL', async () => {
    // The narrowing has to be the Linux path, not the platform. A project on
    // `C:\` is a Windows process writing a Windows store, and answering
    // `unknown` for it would hand `--continue` to a folder that has genuinely
    // never been used.
    const configDir = join(TMP, 'claude-config-windows-native')
    const session = saved({ cwd: 'C:\\Users\\Imza\\Projects\\app' })
    await expect(conversationOnDisk(session, configDir, 'win32')).resolves.toBe('none')
  })

  it('continues a restored WSL tab instead of starting it clean', async () => {
    /*
     * The same fault one level up, where a person meets it: the plan, not the
     * probe. Without the fix both tabs come back as `fresh` — which is what
     * his log recorded — and the morning's conversation is left on disk.
     */
    const sessions = [saved({ cwd: '/home/asad/ClaudeImza' })]
    const plan = await planRestore(
      sessions,
      probes({
        configDir: () => 'C:\\Users\\Imza\\.claude',
        conversation: (session, configDir) => conversationOnDisk(session, configDir, 'win32'),
      }),
    )
    expect(outcomes(plan)).toEqual(['resume'])
    expect(plan[0].reason).toMatch(/cannot read it/i)
  })
})

describe('folderExists', () => {
  it('says yes for a folder that is there and no for one that is not', async () => {
    await expect(folderExists(TMP)).resolves.toBe(true)
    await expect(folderExists(join(TMP, 'no-such-folder'))).resolves.toBe(false)
  })
})

/* -------------------------------------------------------------------------- */

/**
 * Sessions this app started for itself, which are not tabs and must not be
 * restored as if they were.
 *
 * On `DESKTOP-DDGMNCV` on 2026-08-17 there were two entries for
 * `…\terminaldeck\copilot` in `openSessions`, because the copilot had been
 * restarted once and it goes through the same `startSession` as every tab.
 * Restoring them would not restore the copilot: a `SavedSession` is a folder, an
 * agent and an account, so what would come back is two plain Claude Code
 * sessions in this app's storage with no instruction layer, no `deck-control`
 * tools and no fence — invisible in the sidebar, because the window filters that
 * folder out, and billing on every launch.
 */
describe('personalSessions', () => {
  const userData = 'C:\\Users\\Imza\\AppData\\Roaming\\terminaldeck'
  const copilot = join(userData, 'copilot')

  it('drops the copilot’s own sessions, however many of them there are', () => {
    const list = [
      saved({ cwd: '/Users/asad/Projects/terminaldeck' }),
      saved({ cwd: copilot }),
      saved({ cwd: copilot }),
    ]
    expect(personalSessions(list, [copilot])).toEqual([
      saved({ cwd: '/Users/asad/Projects/terminaldeck' }),
    ])
  })

  it('drops anything under that folder, not only the folder itself', () => {
    // Nothing in `<userData>` is a project and nobody opens a session in one by
    // hand, so a saved entry pointing anywhere inside is this app's doing.
    expect(personalSessions([saved({ cwd: join(copilot, 'memory') })], [copilot])).toEqual([])
  })

  it('keeps every session when there is nothing to exclude', () => {
    const list = [saved(), saved({ cwd: '/home/asad/ClaudeImza' })]
    expect(personalSessions(list, [])).toEqual(list)
    expect(personalSessions(list, [copilot])).toEqual(list)
  })

  it('keeps a WSL session, whose path resolves nowhere near the exclusion', () => {
    // `/home/asad/ClaudeImza` on Windows resolves to `C:\home\asad\ClaudeImza`,
    // which must not be judged to be inside anything under `%APPDATA%`. This is
    // the session the whole change exists to bring back.
    expect(personalSessions([saved({ cwd: '/home/asad/ClaudeImza' })], [copilot])).toHaveLength(1)
  })

  it('never widens beyond the folders it is given', () => {
    /*
     * The failure this rules out is the expensive one. The copilot can be
     * pointed at a folder of the person's own, and treating "the copilot's
     * folder" as disqualifying would silently stop restoring their real sessions
     * in a real workspace the moment they chose it — the app deciding a tab was
     * never theirs. Only `<userData>` is unambiguous, so only `<userData>` is
     * ever passed, and this pins that nothing else is inferred.
     */
    const workspace = '/Users/asad/Projects/terminaldeck'
    expect(personalSessions([saved({ cwd: workspace })], [copilot])).toHaveLength(1)
  })
})

/* -------------------------------------------------------------------------- */

interface Spawned {
  input: CreateSessionInput
  /** The device to re-confine for, or null for a tab opened at the keyboard. */
  confineToDeviceId: string | null
}

interface Seeded {
  id: string
  text: string
}

function driver(
  plan: RestoreDecision[],
  options: {
    enabled?: boolean
    fail?: (input: CreateSessionInput) => boolean
    /** What the transcript reader answers, or a throw. Absent means nothing to paint. */
    replay?: (decision: RestoreDecision) => Promise<string>
  } = {},
): {
  spawned: Spawned[]
  announced: SessionMeta[]
  reported: RestoreDecision[][]
  seeded: Seeded[]
  /** Every call, in order, so the ordering between them can be asserted. */
  calls: string[]
  run: () => Promise<{ started: SessionMeta[]; decisions: RestoreDecision[] }>
} {
  const spawned: Spawned[] = []
  const announced: SessionMeta[] = []
  const reported: RestoreDecision[][] = []
  const seeded: Seeded[] = []
  const calls: string[] = []
  let n = 0
  return {
    spawned,
    announced,
    reported,
    seeded,
    calls,
    run: () =>
      restoreOpenSessions({
        saved: () => plan.map((decision) => decision.session),
        enabled: () => options.enabled !== false,
        plan: async () => plan,
        spawn: async (input, confineToDeviceId) => {
          if (options.fail?.(input)) throw new Error('node-pty said no')
          calls.push(`spawn ${input.cwd}`)
          spawned.push({ input, confineToDeviceId })
          n += 1
          return {
            id: `session-${n}`,
            cwd: input.cwd,
            title: 'x',
            provider: input.provider ?? 'claude',
            exitCode: null,
            createdAt: n,
            resumed: input.resume === true,
          }
        },
        announce: (meta) => {
          calls.push(`announce ${meta.cwd}`)
          announced.push(meta)
        },
        report: (decisions) => reported.push([...decisions]),
      }),
  }
}

describe('restoreOpenSessions', () => {
  it('passes resume only for the sessions the plan said to continue', async () => {
    const harness = driver([
      { session: saved({ cwd: '/a' }), outcome: 'resume', reason: 'r' },
      { session: saved({ cwd: '/b' }), outcome: 'fresh', reason: 'f' },
    ])
    await harness.run()
    expect(harness.spawned.map((s) => [s.input.cwd, s.input.resume])).toEqual([
      ['/a', true],
      ['/b', false],
    ])
  })

  it('does not spawn anything for a skipped session', async () => {
    const harness = driver([{ session: saved({ cwd: '/gone' }), outcome: 'skip', reason: 'r' }])
    await harness.run()
    expect(harness.spawned).toEqual([])
    expect(harness.announced).toEqual([])
  })

  it('announces every session it starts, or the window never sees the tab', async () => {
    const harness = driver([
      { session: saved({ cwd: '/a' }), outcome: 'resume', reason: 'r' },
      { session: saved({ cwd: '/b' }), outcome: 'fresh', reason: 'f' },
    ])
    const result = await harness.run()
    expect(harness.announced).toEqual(result.started)
    expect(harness.announced).toHaveLength(2)
  })

  it('brings each tab back as the tab it was, not as another one like it', async () => {
    /*
     * The pair nothing else can tell apart: two Claude sessions in one folder,
     * same account, neither typed into. Every other field on both records is
     * identical — that is the premise, not the fixture being lazy — so the key
     * is the only thing that says which tab is which, and it has to reach the
     * spawn or the window is back to matching on the order these finish in.
     */
    const both = [
      { session: saved({ cwd: '/w', tabKey: 'k-left' }), outcome: 'resume' as const, reason: 'r' },
      { session: saved({ cwd: '/w', tabKey: 'k-right' }), outcome: 'fresh' as const, reason: 'f' },
    ]
    const harness = driver(both)
    await harness.run()
    expect(harness.spawned.map((s) => s.input.tabKey)).toEqual(['k-left', 'k-right'])
  })

  it('asks for a fresh name for a session written down before names existed', async () => {
    // An `openSessions` list from an older build. It still restores; it simply
    // arrives with no key, `startSession` mints one, and it is a named tab from
    // that launch on. `tabKey: undefined` would not do — a caller checking the
    // property has to see it absent.
    const harness = driver([{ session: saved({ cwd: '/old' }), outcome: 'fresh', reason: 'f' }])
    await harness.run()
    expect(Object.hasOwn(harness.spawned[0].input, 'tabKey')).toBe(false)
  })

  it('carries the profile and the terminal size through unchanged', async () => {
    const harness = driver([
      {
        session: saved({ profileId: 'work', cols: 173, rows: 51, provider: 'codex' }),
        outcome: 'resume',
        reason: 'r',
      },
    ])
    await harness.run()
    expect(harness.spawned[0].input).toMatchObject({
      profileId: 'work',
      cols: 173,
      rows: 51,
      provider: 'codex',
    })
  })

  /*
   * The two Windows symptoms Asad reported, in one session and one test.
   *
   * A session that ran inside WSL came back on Windows having lost its
   * conversation history *and* logged out of its account. Both are the one
   * restore, and both are on Windows because the folder is a Linux path: the
   * transcript is a file inside the distribution, which Windows cannot read but
   * `claude --continue` re-reads for itself — so the plan has to *resume* it
   * rather than start it clean — and the login that wrote it is this session's
   * profile, which has to come back with it or the agent inside the distro
   * starts signed out. Driven for `win32` because a green macOS run proves
   * nothing here: on the Mac the folder is a host path and neither symptom can
   * fire, which is exactly why the feature looked fine on one platform.
   */
  it('brings a WSL session back on its own account, continuing its conversation', async () => {
    const wslSession = saved({ cwd: '/home/asad/ClaudeImza', profileId: 'work' })

    // The plan, made the way index.ts makes it: a per-profile config directory
    // (a real Windows path, meaningless inside the distro), and
    // `conversationOnDisk` answering as it does on a Windows host.
    const plan = await planRestore(
      [wslSession],
      probes({
        configDir: (session) =>
          `C:\\Users\\Imza\\AppData\\Roaming\\terminaldeck\\profiles\\${session.profileId}`,
        conversation: (session, configDir) => conversationOnDisk(session, configDir, 'win32'),
      }),
    )
    expect(outcomes(plan)).toEqual(['resume'])

    // And the spawn that plan drives: continuing (the history) and on `work`
    // (the account). Losing either of these is the bug.
    const harness = driver(plan)
    await harness.run()
    expect(harness.spawned[0].input).toMatchObject({
      cwd: '/home/asad/ClaudeImza',
      resume: true,
      profileId: 'work',
    })
  })

  /*
   * The restore half of *"2 of 6 survive, the rest come back clean"*. A session
   * a device started is remembered with the id of the device it is held for, and
   * that id has to reach the spawn, or the spawn cannot rebuild the boundary and
   * the session comes back loose. It is passed *beside* the input, never on it:
   * `CreateSessionInput` crosses the preload bridge and page code may not claim
   * a device.
   */
  it('hands the spawn the device to re-confine for, when a device started the session', async () => {
    const harness = driver([
      {
        session: saved({ cwd: '/home/asad/ClaudeImza', confineDeviceId: 'phone-7' }),
        outcome: 'resume',
        reason: 'r',
      },
    ])
    await harness.run()
    expect(harness.spawned[0].confineToDeviceId).toBe('phone-7')
    // And never smuggled onto the input, which would put a device on the bridge.
    expect(harness.spawned[0].input).not.toHaveProperty('confineDeviceId')
    expect(harness.spawned[0].input).not.toHaveProperty('deviceId')
  })

  it('asks for no re-confinement for a tab opened at the keyboard', async () => {
    // The two that already survived: desktop-started, unconfined. Nothing to
    // rebuild, so the spawn is told exactly that rather than left to guess.
    const harness = driver([{ session: saved(), outcome: 'resume', reason: 'r' }])
    await harness.run()
    expect(harness.spawned[0].confineToDeviceId).toBeNull()
  })

  it('keeps going when one session refuses to start, and says which', async () => {
    const harness = driver(
      [
        { session: saved({ cwd: '/a' }), outcome: 'resume', reason: 'r' },
        { session: saved({ cwd: '/broken' }), outcome: 'resume', reason: 'r' },
        { session: saved({ cwd: '/c' }), outcome: 'resume', reason: 'r' },
      ],
      { fail: (input) => input.cwd === '/broken' },
    )
    const result = await harness.run()
    expect(result.started).toHaveLength(2)
    expect(outcomes(result.decisions)).toEqual(['resume', 'failed', 'resume'])
    expect(result.decisions[1].reason).toContain('node-pty said no')
  })

  it('starts nothing when the setting is off', async () => {
    const harness = driver([{ session: saved(), outcome: 'resume', reason: 'r' }], {
      enabled: false,
    })
    const result = await harness.run()
    expect(harness.spawned).toEqual([])
    expect(harness.reported).toEqual([])
    expect(result.started).toEqual([])
  })



  it('does not paint a session that is starting clean', async () => {
    // The sibling tab in the same folder: it lost the claim, so it is starting a
    // new conversation, and painting it with the one the other tab is continuing
    // would be the app inventing a past for a session that has none.
    const harness = driver([{ session: saved({ cwd: '/a' }), outcome: 'fresh', reason: 'f' }], {
    })
    await harness.run()
    expect(harness.calls).toEqual(['spawn /a', 'announce /a'])
    expect(harness.seeded).toEqual([])
  })

  it('seeds nothing when there is no conversation to paint', async () => {
    // An agent whose history this app cannot read, or a folder being worked in
    // for the first time. The empty string is the ordinary answer, not an error,
    // and it must not become an empty line in front of the session.
    const harness = driver([{ session: saved({ cwd: '/a' }), outcome: 'resume', reason: 'r' }])
    await harness.run()
    expect(harness.seeded).toEqual([])
    expect(harness.announced).toHaveLength(1)
  })

  it('still brings the session back when the transcript cannot be read', async () => {
    // A screen that could not be painted is the blank terminal this feature was
    // written to improve on — a fair worst case. Losing the session over it is
    // not.
    const harness = driver([{ session: saved({ cwd: '/a' }), outcome: 'resume', reason: 'r' }], {
      replay: async () => {
        throw new Error('the transcript is unreadable')
      },
    })
    const result = await harness.run()
    expect(outcomes(result.decisions)).toEqual(['resume'])
    expect(harness.announced).toHaveLength(1)
    expect(harness.seeded).toEqual([])
  })

  it('reports once, with every decision including the failures', async () => {
    const harness = driver(
      [
        { session: saved({ cwd: '/a' }), outcome: 'resume', reason: 'r' },
        { session: saved({ cwd: '/broken' }), outcome: 'fresh', reason: 'f' },
      ],
      { fail: (input) => input.cwd === '/broken' },
    )
    await harness.run()
    expect(harness.reported).toHaveLength(1)
    expect(outcomes(harness.reported[0])).toEqual(['resume', 'failed'])
  })
})

/* -------------------------------------------------------------------------- */

describe('restoring is wired to launch', () => {
  const index = readFileSync(join(ROOT, 'src/main/index.ts'), 'utf8')
  /*
   * The ledger moved to `host-core.ts` when the headless build arrived, because
   * remembering what was open is about the machine and not about a window — and
   * it matters more there than here: WSL shuts a distribution down whenever the
   * last terminal closes, so on that host "the process died with sessions open"
   * is the ordinary case rather than the crash case.
   */
  const core = readFileSync(join(ROOT, 'src/main/host-core.ts'), 'utf8')
  const headless = readFileSync(join(ROOT, 'src/headless/host.ts'), 'utf8')

  /**
   * The function the restore is handed as its plan, found by name and then read.
   *
   * This used to read the argument in place, because the plan *was* an inline
   * object literal. It is a named function now — a retry has to be able to ask
   * the identical questions, see the test below — and a check that kept reading
   * the argument would have quietly passed on `plan: planSaved` without ever
   * looking at what `planSaved` does. That is the exact failure mode this whole
   * describe block exists to catch, so the name is followed to its definition
   * rather than trusted.
   */
  const planName = (/plan:\s*([A-Za-z_$][\w$]*)\s*,/.exec(
    index.slice(index.indexOf('restoreOpenSessions({')),
  ) ?? [])[1]
  const planSource = ((): string => {
    if (planName === undefined) {
      // Still inline: read the argument, which is what this file did before.
      const call = index.slice(index.indexOf('restoreOpenSessions({'))
      return call.slice(0, call.indexOf('spawn:'))
    }
    const at = index.indexOf(`const ${planName} = `)
    // A generous window rather than brace matching. The definition is one
    // expression with three long comments in it, and a regex that counts braces
    // through comments containing braces is a worse bet than reading too much.
    const definition = at === -1 ? '' : index.slice(at, at + 3000)
    /*
     * Followed one hop further since 2026-08-22: the composition moved to
     * `session-switch-run.ts` as `savedPlanner`, so the launch restore, the
     * held retry and the account switch all ask the identical questions — and
     * this test follows the delegation for the same reason it followed the
     * name, rather than passing on a one-line alias it never read.
     */
    const delegated = /^const \w+ = (\w+)\(core\)/.exec(definition.split('\n')[0] ?? '')
    if (delegated === null) return definition
    const shared = readFileSync(join(ROOT, 'src/main/session-switch-run.ts'), 'utf8')
    const declared = shared.indexOf(`export function ${delegated[1]}(`)
    return declared === -1 ? '' : shared.slice(declared, declared + 3000)
  })()

  it('hands the restore a plan that exists', () => {
    // The two tests below both read `planSource`, and an empty one would make
    // them fail with a message about profiles rather than about the plan having
    // been renamed out from under them.
    expect(planName, 'the restore is not given a named plan function').not.toBeUndefined()
    expect(planSource, `${planName} is not defined in index.ts`).not.toBe('')
    expect(planSource).toContain('planRestore(')
  })

  it('runs a restore from a window lifecycle event, not from a command', () => {
    /*
     * The assertion that matters. Everything above proves the decision is
     * right; this proves it is ever asked. A restore reachable only from a menu
     * item or an ipc handler the renderer never calls is the exact shape of the
     * five features `src/reachable.test.ts` was written about, and it would pass
     * every other test in this file.
     */
    expect(
      index,
      'nothing in index.ts hydrates the window on did-finish-load — a restore that ' +
        'only runs when something asks for it is a restore that never runs',
    ).toMatch(/webContents\.on\('did-finish-load',[\s\S]{0,120}hydrateRenderer\(\)/)
    expect(index).toMatch(/restoreOpenSessions\(/)
  })

  it('looks for the conversation in the profile the session will run as', () => {
    /*
     * A source-text check because this is a wiring bug, not a logic bug, and the
     * logic tests above all passed while it was live. `conversationOnDisk` was
     * handed to the planner by reference; its config-directory argument was
     * optional, so it silently became `undefined` and every profiled session was
     * asked about `~/.claude`. Nothing failed — the restore ran, found nothing,
     * and started clean, which looks exactly like a user with no history.
     *
     * The argument is required now, so a bare reference no longer compiles. This
     * asserts the other half: that the directory handed over is resolved from the
     * session's own profile rather than a constant someone reached for.
     */
    expect(
      planSource,
      'the restore plan does not resolve a profile, so a profiled session will be ' +
        'asked about the default config directory and come back blank',
    ).toMatch(/configDir:[\s\S]{0,400}resolveProfile\(/)
    expect(planSource).toMatch(/sessionProfileId: session\.profileId/)
  })

  it('asks the same questions when somebody presses Try again', () => {
    /*
     * The plan became a named function when held sessions arrived, and this is
     * the fact that made it worth naming.
     *
     * A retry is the *second* attempt at a session the launch could not start,
     * so it is the least-exercised path in the app and the worst possible place
     * for a difference. If it resolved the config directory differently, or
     * decided `resume` differently, pressing Try again would start a subtly
     * different session from the one that failed — most concretely, a session
     * attached to a different login's transcripts, which looks exactly like a
     * conversation that was lost.
     *
     * So both callers go through one function, and this pins that there is only
     * one: the retry names the same plan the launch was given. Checked as source
     * text for the same reason the assertion above is — this is a wiring fact,
     * and every logic test in this file passed while the wiring was wrong.
     */
    const retry = index.slice(index.indexOf("ipcMain.handle('session:held-retry'"))
    expect(
      retry.slice(0, retry.indexOf('restoreSpawn(')),
      `the retry handler does not call ${planName}, so a second attempt is planned by ` +
        'code the launch never runs',
    ).toContain(`${planName}(`)
    // And through the same `restoreSpawn` the launch restore uses, exactly as
    // the launch does — so a held session a device started is re-confined on
    // Try again rather than brought back loose, never the plain `startSession`.
    expect(retry).toMatch(/await restoreSpawn\(\s*\{/)
    expect(retry, 'Try again on a device session must not spawn it unconfined').not.toMatch(
      /await startSession\(\{/,
    )
  })

  it('restores through the one session-start path, made to re-confine device sessions', () => {
    // A second spawn implementation for the restore path would be a session
    // that is subtly not the same kind of session — a different PATH, a
    // different profile — and only after a restart, which is the hardest kind
    // of difference to notice. `restoreSpawn` is not that: it is `startSession`
    // for a tab opened here, and `startSession` with the folder boundary rebuilt
    // first for a session a device started — the one starter, told which
    // sessions to re-confine. The plain `startSession` here was itself a bug: it
    // brought a device's session back *unconfined*, the boundary lapsing on the
    // one event nobody watches for — a restart.
    const call = index.slice(index.indexOf('restoreOpenSessions({'))
    expect(call).toMatch(/spawn: restoreSpawn,/)
    expect(call, 'the plain starter here brings a device session back unconfined').not.toMatch(
      /spawn: startSession,/,
    )
  })

  it('keeps the sessions that did not come back, instead of forgetting them', () => {
    /*
     * The line that stops one bad launch from being permanent, and the reason
     * it has to be asserted on rather than trusted: `flush()` overwrites
     * `openSessions` with the live map, so a session that failed to restart
     * survived only until the next tab opened. Asad lost four Claude sessions in
     * two WSL folders that way and got two plain terminals in their place —
     * which were then remembered instead.
     *
     * `skip` as well as `failed`, deliberately. "The folder it ran in is no
     * longer on this machine" is usually temporary too: an unmounted volume, a
     * share that is not up yet, a WSL distribution that has not woken, which is
     * exactly the machine this happened on.
     */
    const report = index.slice(index.indexOf('report: (decisions) =>'))
    const body = report.slice(0, report.indexOf('})'))
    expect(body, 'the restore report does not hold anything').toContain('ledger.held.hold(')
    expect(body).toMatch(/outcome === 'failed'/)
    expect(body).toMatch(/outcome === 'skip'/)
  })

  it('tells the window, on every hydration and not only the first', () => {
    // A renderer reload throws away the window's copy of the held list exactly
    // as it throws away its tabs, and those rows are the only place a person is
    // told a session did not come back.
    const hydrate = index.slice(index.indexOf('async function hydrateRenderer'))
    const body = hydrate.slice(0, hydrate.indexOf('\n}\n'))
    // Once inside the first-run branch, once outside it.
    expect(body.match(/announceHeld\(\)/g)?.length ?? 0).toBeGreaterThanOrEqual(2)
  })

  it('does not restore the copilot as if it were somebody’s tab', () => {
    /*
     * Two `…\terminaldeck\copilot` entries were in his `state.json`, because the
     * copilot is started by `ensureCopilot` through the same `startSession` as
     * every tab and was being written down like one. Restoring them starts two
     * plain Claude sessions with none of the copilot's layer or tools, hidden
     * from the sidebar, on every launch. `personalSessions` has the argument for
     * why only `<userData>` is excluded and never the folder the copilot happens
     * to be pointed at.
     */
    const hydrate = index.slice(index.indexOf('async function hydrateRenderer'))
    expect(hydrate.slice(0, hydrate.indexOf('restoreOpenSessions('))).toMatch(
      /personalSessions\(store\(\)\.getOpenSessions\(\), \[\s*copilotPaths\(app\.getPath\('userData'\)\)\.root,?\s*\]\)/,
    )
  })

  it('holds a session the window asked for and could not have', () => {
    /*
     * The other way a start fails, and the one with no visible path until this
     * change: `session:create` rejects, and a rejection alone is what the
     * renderer does nothing with. It did not need one before, because
     * `startSession` answered "that agent cannot run" by starting a shell — the
     * downgrade this whole change removes. So the refusal becomes the same row,
     * in the same place, with the same Try again.
     */
    const handler = index.slice(index.indexOf("ipcMain.handle('session:create'"))
    const body = handler.slice(0, handler.indexOf('\n  })'))
    expect(body, 'a refused start is not held, so nothing appears anywhere').toContain(
      'ledger.held.hold(',
    )
    // And the rejection still travels, or the window cannot tell a refusal from
    // a session it simply has not been told about yet.
    expect(body).toMatch(/throw error/)
  })

  it('does not empty the remembered list while it is shutting down', () => {
    // Shutting down kills every pty, each kill fires an exit, and reconciling on
    // those exits would write down that nothing was open — on every clean stop.
    const flush = core.slice(core.indexOf('  flush(): void {'))
    expect(flush.slice(0, 120)).toMatch(/if \(this\.frozen\) return/)
    // And each shell has to freeze it, after one last honest write.
    expect(index).toMatch(/ledger\.flush\(\)\s*\n\s*ledger\.freeze\(\)/)
    expect(headless).toMatch(/core\.ledger\.flush\(\)\s*\n\s*core\.ledger\.freeze\(\)/)
  })

  it('writes the remembered list as sessions open and close, not only at quit', () => {
    // The case this exists for is a machine that restarted. Nothing runs at
    // quit then, so a list that is only written on the way out is a list that is
    // empty exactly when it is needed.
    expect(core).toMatch(/ledger\.note\(meta\.id, \{/)
    expect(core).toMatch(/ledger\.forget\(id\)/)
  })

  it('restores from starting the headless host, not from a command', () => {
    // The same assertion as the window's, for the shell that has no window. A
    // restore reachable only from `terminaldeck status` would be a restore that
    // never runs on the machine it was written for.
    const main = readFileSync(join(ROOT, 'src/headless/daemon.ts'), 'utf8')
    expect(main).toMatch(/await host\.restore\(\)/)
    expect(headless).toMatch(/restoreOpenSessions\(/)
    // Through `restoreSpawn`, which re-confines a session a device started
    // rather than bringing it back loose — and on this host most sessions are a
    // device's, so the plain starter here was the boundary lapsing on the
    // ordinary case rather than a rare one.
    expect(headless).toMatch(/spawn: core\.restoreSpawn,/)
    expect(headless).not.toMatch(/spawn: core\.startSession,/)
  })

  it('never writes a restore banner into a session', () => {
    // Coming back should look like the session was simply still there. Anything
    // typed into the pty to explain what happened is the app narrating its own
    // plumbing, which is the one thing this feature was asked not to do.
    const hydrate = index.slice(index.indexOf('async function hydrateRenderer'))
    expect(hydrate.slice(0, 2400)).not.toMatch(/ptys\.write\(/)
  })

})

/**
 * **A session that is not the copilot must never think it is.**
 *
 * The one invariant this whole design exists to hold, asked of a real spawn in
 * the copilot's own working directory.
 *
 * ## The defect it is pinned against, which was nearly shipped
 *
 * The copilot's instructions used to be scaffolded into its working directory as
 * `<root>/CLAUDE.md`. That was fine for exactly as long as the directory was
 * `<userData>/copilot` and belonged to nobody. The moment a person can point the
 * copilot at a folder of their own — which is the feature — it fails twice, and
 * Asad caught both before it went in:
 *
 * > *"Everyone would have built their own agents inside those folders, so when
 * > they start from there it will not know anything about the application… If
 * > somebody opens a normal terminal in that folder and it says 'I am a
 * > copilot', that is a nonsense thing. So we cannot keep this kind of thing in
 * > the disk folder — we need to keep it in the app."*
 *
 * The second half is the one this file is about, and it is true even when the
 * folder is the app's own. A `CLAUDE.md` on disk is read by **every** session
 * started in that directory: an ordinary terminal, one from the sidebar, one a
 * routine started, one a paired phone started. Identity kept on disk is identity
 * inherited by processes that are not the copilot, and no amount of care inside
 * this app can stop a `cd` and a `claude`.
 *
 * So identity is handed to one process, at exec, as an argument. What follows
 * checks that from both ends.
 *
 * ## What is real here, and what is not
 *
 * The ordinary-session half is **entirely real**: a real `createHostCore`, a real
 * added agent, a real pty, and a real process that writes its own `argv` and
 * `pwd` to a file from inside the copilot's folder. Nothing about the argv is
 * inferred — it is read back out of a file the child wrote.
 *
 * The copilot half records `startSession`'s arguments rather than spawning
 * Claude Code, because the copilot hardcodes `provider: 'claude'` and a real one
 * would need a signed-in CLI and would spend money. That is not a gap in the
 * proof, because the two halves meet in the middle: the case below sends the
 * copilot's *own* `extraArgs` through the same real `startSession` and reads the
 * flag back out of a spawned process's argv. So "the copilot passes it" and
 * "passing it lands in argv" are each measured, against the same seam.
 * `copilot-tools-live.test.ts` closes the last inch with the real binary, opt-in.
 */

import { execFileSync } from 'node:child_process'
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join, sep } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import type { CreateSessionInput, ProviderId, SessionMeta } from '../shared/types'
import { copilotPaths, scaffoldCopilotHome } from './copilot-home'
import { APPEND_SYSTEM_PROMPT_FILE, copilotLayerArgs } from './copilot-layer'
import { ensureCopilot, resetCopilot, type CopilotRuntimeDeps } from './copilot-session'
import { createHostCore, type HostCore } from './host-core'
import { installPaths, nodePaths, resetPaths } from './platform/paths'

const posix = process.platform !== 'win32'

let root = ''
let userData = ''
/** A workspace somebody already had, outside `<userData>`. The chosen folder. */
let workspace = ''
let core: HostCore
/** Where the recording agent writes what it was actually given. */
let argvFile = ''
/** The id of the added agent, once it is added. */
let recorder: ProviderId | null = null

/**
 * A fixture the copilot runtime can be driven with, recording every spawn.
 *
 * The same shape `copilot-session.test.ts` uses, kept local rather than shared
 * because the two files are asking different questions of it and a shared
 * harness is how one of them quietly stops asserting what it thinks it does.
 */
interface Recorded {
  input: CreateSessionInput
  extraArgs: readonly string[] | undefined
}
let spawns: Recorded[] = []

function copilotDeps(home: string | null): CopilotRuntimeDeps {
  return {
    userData: () => userData,
    storageDir: () => join(userData, 'remote'),
    platform: 'darwin',
    home: () => home,
    agents: async () => ({ claude: true, codex: false, gemini: false, shell: true }),
    // Stubbed: whether the fence really holds is measured against a real kernel
    // in the two boundary tests, which is the only place it can honestly be.
    fence: async () => ({ fence: null, reason: 'not measured here' }),
    profile: () => ({
      id: 'system',
      name: 'Default',
      provider: 'claude',
      configDir: join(userData, '.claude'),
      system: true,
      color: '#000000',
      createdAt: 0,
      lastUsedAt: null,
    }),
    mcpConfig: () => null,
    async startSession(input, _guest, _confine, _fence, extraArgs) {
      spawns.push({ input, extraArgs })
      const meta: SessionMeta = {
        id: `copilot-${spawns.length}`,
        title: 'Copilot',
        cwd: input.cwd,
        provider: 'claude',
        status: 'idle',
        createdAt: 0,
        exitCode: null,
      } as SessionMeta
      return meta
    },
    isAlive: () => true,
    stop: () => undefined,
  }
}

beforeAll(async () => {
  root = mkdtempSync(join(tmpdir(), 'copilot-appside-'))
  userData = join(root, 'user-data')
  workspace = join(root, 'ClaudeSomebody')
  mkdirSync(userData, { recursive: true })
  mkdirSync(workspace, { recursive: true })

  /*
   * The chosen folder is furnished the way a real one is, and this is the whole
   * point of the fixture rather than set dressing.
   *
   * A workspace somebody already built has its own `CLAUDE.md` — a persona, a
   * startup ritual, memory conventions — and that file is usually the reason
   * they would point the copilot at it. Every assertion below about "nothing was
   * written here" and "an ordinary terminal is not the copilot" is meaningless
   * against an empty directory.
   */
  writeFileSync(
    join(workspace, 'CLAUDE.md'),
    '# CLAUDE.md — somebody else’s assistant\n\nYou are their assistant. Read memory/ first.\n',
  )
  mkdirSync(join(workspace, 'memory'), { recursive: true })
  writeFileSync(join(workspace, 'memory', 'MEMORY.md'), '# Memory index\n')

  installPaths(nodePaths({ platform: 'linux', env: { XDG_DATA_HOME: root }, home: root, appRoot: root }))
  core = createHostCore({ storageDir: join(userData, 'remote'), userData })

  if (posix) {
    /*
     * An agent that records what it was launched with.
     *
     * A script rather than `/bin/echo`, because the question is not "did it
     * run" but "what was in its argv and where was it standing" — and the only
     * witness that cannot be argued with is the process itself. `$OUT` is baked
     * in rather than passed through the environment, because a custom agent is a
     * command and fixed arguments and has no way to carry one.
     */
    argvFile = join(root, 'argv.txt')
    const script = join(root, 'record-argv.sh')
    writeFileSync(script, `#!/bin/sh\n{ pwd; printf '%s\\n' "$@"; } > ${JSON.stringify(argvFile)}\n`)
    chmodSync(script, 0o755)

    const added = await core.agents.add({
      label: 'Recorder',
      description: '',
      command: script,
      args: '',
      resumeArgs: '',
    })
    expect(added.ok, 'the recording agent has to be addable, or nothing below means anything').toBe(
      true,
    )
    if (added.ok) recorder = added.agent.id
  }
}, 30_000)

afterAll(async () => {
  core.ptys.killAll()
  await core.ptys.drain()
  await core.credentials.stop()
  resetCopilot()
  resetPaths()
  try {
    rmSync(root, { recursive: true, force: true, maxRetries: 40, retryDelay: 250 })
  } catch (error) {
    if (process.platform !== 'win32') throw error
  }
})

/** Everything the recording agent saw: where it stood, then its arguments. */
async function launchAndRead(input: Omit<CreateSessionInput, 'provider'>, extra?: readonly string[]) {
  rmSync(argvFile, { force: true })
  const meta = await core.startSession(
    { ...input, provider: recorder as ProviderId },
    undefined,
    undefined,
    undefined,
    extra,
  )
  // The script writes and exits immediately; `drain` resolves when the pty
  // reports that, which is after the redirect has closed.
  await core.ptys.drain()
  core.ptys.kill(meta.id)
  const lines = readFileSync(argvFile, 'utf8').trim().split('\n')
  return { cwd: lines[0] ?? '', args: lines.slice(1).filter((line) => line !== '') }
}

describe('the copilot is told what it is on the command line', () => {
  it('hands over a layer that is under <userData>, not in the folder it works in', async () => {
    spawns = []
    resetCopilot()
    const paths = copilotPaths(userData, workspace)

    const state = await ensureCopilot(copilotDeps(workspace))
    expect(state.status).toBe('running')
    expect(spawns).toHaveLength(1)

    const args = spawns[0]?.extraArgs ?? []
    const at = args.indexOf(APPEND_SYSTEM_PROMPT_FILE)
    expect(at).toBeGreaterThanOrEqual(0)

    const handed = args[at + 1] ?? ''
    expect(handed).toBe(paths.layer.composed)
    expect(handed.startsWith(`${userData}${sep}`)).toBe(true)
    expect(handed.startsWith(`${workspace}${sep}`)).toBe(false)

    // And it really is on disk before the spawn. Claude Code 2.1.233 accepts
    // this flag pointing at a missing file without complaining at parse time —
    // measured — so a layer written after the spawn would vanish silently.
    expect(existsSync(handed)).toBe(true)
    expect(readFileSync(handed, 'utf8')).toContain('developer')

    // Its working directory is the chosen folder, which is what makes the
    // folder's own CLAUDE.md the copilot's context in the first place.
    expect(spawns[0]?.input.cwd).toBe(workspace)
    resetCopilot()
  })

  it('writes nothing whatsoever into the folder somebody chose', async () => {
    /*
     * Checked as a listing rather than as a list of filenames, because the
     * promise is "nothing" and anything narrower rots. Recursive, because the
     * failure worth catching is a helpful `memory/` or a dot-file marker rather
     * than a second `CLAUDE.md` somebody would notice.
     */
    const before = listing(workspace)
    spawns = []
    resetCopilot()
    scaffoldCopilotHome(copilotPaths(userData, workspace))
    await ensureCopilot(copilotDeps(workspace))
    resetCopilot()

    expect(listing(workspace)).toEqual(before)
    expect(readFileSync(join(workspace, 'CLAUDE.md'), 'utf8')).toContain('somebody else’s assistant')
  })
})

describe.skipIf(!posix)('an ordinary session in the very same folder', () => {
  /*
   * POSIX only, because the witness is a `/bin/sh` script. The claim it proves
   * is platform-independent — `extraArgs` is a positional argument of
   * `startSession` and nothing but the copilot passes one — and the two cases in
   * `does not leak into any other start path` below hold everywhere.
   */

  it('runs in the copilot’s folder and carries no copilot layer at all', async () => {
    /*
     * The invariant, measured. This is the ordinary terminal a person opens: the
     * same call `session:create` makes, with the copilot's own working directory,
     * against a real pty — and the argv is read back out of the child.
     */
    const seen = await launchAndRead({ cwd: workspace, cols: 80, rows: 24 })

    expect(realish(seen.cwd)).toBe(realish(workspace))
    expect(seen.args).not.toContain(APPEND_SYSTEM_PROMPT_FILE)
    expect(seen.args.some((arg) => arg.startsWith('--append-system-prompt'))).toBe(false)
    expect(seen.args.some((arg) => arg.includes('copilot-layer'))).toBe(false)
    expect(seen.args).toEqual([])
  })

  it('is not a vacuous claim — the same seam does deliver the flag when it is passed', async () => {
    /*
     * The control case, and it is what makes the one above evidence rather than
     * a tautology. A reader is entitled to ask whether that session had no layer
     * because of the design or because this fixture cannot deliver one at all.
     *
     * So the copilot's *own* argument list — built by `copilotLayerArgs`, the one
     * function that spells the flag — goes through the same real `startSession`
     * into the same real pty, and comes back out of the child's argv. The seam
     * works; the ordinary session simply is not given anything to put in it.
     */
    const composed = copilotPaths(userData, workspace).layer.composed
    const seen = await launchAndRead({ cwd: workspace, cols: 80, rows: 24 }, copilotLayerArgs(composed))

    expect(seen.args).toEqual([APPEND_SYSTEM_PROMPT_FILE, composed])
    expect(realish(seen.cwd)).toBe(realish(workspace))
  })

  it('finds nothing in that folder claiming to be the copilot, even in the default one', async () => {
    /*
     * The other half of the invariant, and the one that needs no argv at all.
     *
     * Even in the folder this app makes for itself, there is no `CLAUDE.md`: the
     * identity is not on disk anywhere. So a terminal opened in the *default*
     * copilot folder is not the copilot either — which is the case somebody
     * would hit first, and the one the old design got wrong most quietly.
     */
    const own = copilotPaths(userData, null)
    scaffoldCopilotHome(own)
    expect(existsSync(join(own.root, 'CLAUDE.md'))).toBe(false)
    expect(readdirSync(own.root).sort()).toEqual(['memory'])
  })
})

describe('the flag does not leak into any other start path', () => {
  it('is spelled in exactly one module, and reached through one function', () => {
    /*
     * The general claim, checked the only way a claim about *every* start path
     * can be: over the source.
     *
     * There are seven callers of `startSession` in this repository — a window, a
     * restored tab, a phone's terminal, the `sessions.start` tool, a routine, the
     * desk copilot and a phone's copilot run — and only the last two are the
     * copilot. A runtime test can pin the two that must carry the layer and the
     * one that must not; this pins that a *new* caller cannot acquire it by
     * copying a line, because there is one line to copy and it lives in a module
     * whose name says what it is for.
     */
    const files = sourceFiles(join(__dirname, '..'))
    /*
     * The *quoted* literal, not the words. Several modules name this flag in
     * prose — that is a comment doing its job — and a scan that counted those
     * would fail the day somebody explained the design properly, which is the
     * opposite of what this test should encourage.
     */
    const spellsIt = files.filter(
      (file) =>
        !file.endsWith('.test.ts') && readFileSync(file, 'utf8').includes("'--append-system-prompt"),
    )
    expect(spellsIt.map((file) => file.slice(join(__dirname, '..').length + 1))).toEqual([
      join('main', 'copilot-layer.ts'),
    ])

    const usesIt = files.filter(
      (file) => !file.endsWith('.test.ts') && readFileSync(file, 'utf8').includes('copilotLayerArgs('),
    )
    expect(usesIt.map((file) => file.slice(join(__dirname, '..').length + 1)).sort()).toEqual([
      join('main', 'copilot-layer.ts'),
      join('main', 'copilot-session.ts'),
      join('main', 'remote', 'copilot-wiring.ts'),
    ])
  })

  it('cannot be composed by page code, because the input that crosses the bridge has no room for it', () => {
    /*
     * `extraArgs` is a positional argument of `startSession`, not a field on
     * `CreateSessionInput` — and the difference is a security boundary rather
     * than a style. The input crosses the preload bridge: a renderer calls
     * `session:create` with it. A field there would let page code put anything
     * it liked on an agent's command line, and *this particular* entry is the
     * copilot's identity.
     *
     * Asserted against the type's own source, because that is where the rule
     * lives and a runtime check would only observe today's callers.
     */
    const types = readFileSync(join(__dirname, '..', 'shared', 'types.ts'), 'utf8')
    const input = types.slice(types.indexOf('interface CreateSessionInput'))
    const body = input.slice(0, input.indexOf('\n}'))
    expect(body).not.toMatch(/extraArgs|args\s*[?]?:|systemPrompt/i)
  })
})

/** Every path inside a directory, relative and sorted. `[]` if it is not there. */
function listing(dir: string, prefix = ''): string[] {
  const out: string[] = []
  for (const name of readdirSync(dir).sort()) {
    const full = join(dir, name)
    out.push(prefix + name)
    if (statSync(full).isDirectory()) out.push(...listing(full, `${prefix + name}/`))
  }
  return out.sort()
}

/** Every `.ts` under a directory, absolute, sorted, skipping nothing. */
function sourceFiles(dir: string): string[] {
  const out: string[] = []
  for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const full = join(dir, entry.name)
    if (entry.isDirectory()) out.push(...sourceFiles(full))
    else if (entry.name.endsWith('.ts') || entry.name.endsWith('.tsx')) out.push(full)
  }
  return out
}

/**
 * A path with `/var` resolved, so a child's `pwd` and this process's idea of the
 * same directory can be compared.
 *
 * macOS makes `/var` a symlink to `/private/var`, and a shell's `pwd` reports
 * the resolved name while `mkdtempSync` hands back the unresolved one. Comparing
 * them raw fails for a reason that has nothing to do with what is being tested —
 * the same trap `confine/plan.ts` records, arriving through a different door.
 */
function realish(path: string): string {
  return execFileSync('/bin/sh', ['-c', `cd ${JSON.stringify(path)} && pwd`], { encoding: 'utf8' }).trim()
}

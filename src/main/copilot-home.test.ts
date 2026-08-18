import {
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
import { beforeEach, describe, expect, it } from 'vitest'
import {
  appendCopilotAction,
  copilotHomeReport,
  copilotInstructions,
  copilotPaths,
  copilotStartupFiles,
  instructionsState,
  copilotLayerFiles,
  folderInstructions,
  legacyInstructionsFile,
  legacyLogDir,
  legacyRoutinesDir,
  MAX_INSTRUCTIONS_BYTES,
  readCopilotInstructions,
  resetCopilotInstructions,
  scaffoldCopilotHome,
  writeCopilotInstructions,
  type CopilotPaths,
} from './copilot-home'
import { PAST_COPILOT_INSTRUCTIONS } from './copilot-instructions-history'
import { routinesDirFor } from './routines/store'
import { runtimeStateFileFor } from './routines/runtime-state'

/**
 * A real directory per test.
 *
 * Everything in this module is about what is on disk — what it made, what it
 * refused to overwrite, what it can read back — so a mocked filesystem would be
 * testing the mock. These are a handful of small files in a temporary directory.
 */
let userData: string
let paths: CopilotPaths

beforeEach(() => {
  userData = mkdtempSync(join(tmpdir(), 'copilot-home-'))
  paths = copilotPaths(userData)
})

/*
 * If this file is ever red on Windows with a timeout, read `vitest.config.ts`
 * before touching anything here.
 *
 * Two of these tests failed on the Windows runner on 2026-08-18 and neither was
 * slow. They are synchronous — `() => {}`, not `async` — and make about ten
 * filesystem calls each, so there is nothing for them to be waiting on; they
 * were simply not being scheduled. The file has run at 298 ms and at 25263 ms
 * on that runner with identical bytes, and 7644 ms of that spread came from a
 * run that was green. The config file carries the whole table and the reasoning.
 */

describe('the layout', () => {
  it('keeps the working directory and the identity in different places', () => {
    /*
     * The assertion the whole folder feature rests on, and it is a *negative*
     * one: the copilot's instructions are not in its working directory.
     *
     * A `CLAUDE.md` on disk is read by every session started in that folder —
     * an ordinary terminal, one from the sidebar, one a routine started — so
     * identity kept there is identity inherited by processes that are not the
     * copilot. `copilot-layer-is-app-side.test.ts` proves the consequence
     * against a real spawn; this pins the path arithmetic underneath it, and
     * fails first.
     */
    expect(paths.root).toBe(join(userData, 'copilot'))
    expect(paths.memory).toBe(join(paths.root, 'memory'))
    expect(paths.instructions).toBe(join(userData, 'copilot-layer', 'instructions.md'))
    expect(paths.instructions.startsWith(`${paths.root}${sep}`)).toBe(false)
    expect(paths.layer.composed.startsWith(`${paths.root}${sep}`)).toBe(false)
  })

  it('reports whose folder it is, which is what decides whether anything may be written there', () => {
    expect(paths.ownFolder).toBe(true)
    const chosen = copilotPaths(userData, join(userData, '..', 'somebody-elses-workspace'))
    expect(chosen.ownFolder).toBe(false)
    // And the layer does not move with it. It is the app's, wherever the
    // working directory is — see `copilot-layer.ts`.
    expect(chosen.instructions).toBe(paths.instructions)
    expect(chosen.actions).toBe(paths.actions)
  })

  it('keeps the action log out of the folder, because the agent it records can write in there', () => {
    // The load-bearing assertion of the log split, and the same shape as the
    // routines one below it. `<userData>/copilot` is the one directory the
    // copilot session may write to; an audit log inside it is a file the
    // audited party can append to, edit, truncate or delete with one `>`.
    // `copilot-log-boundary.test.ts` proves the refusal against a real sandbox
    // rather than against a string; this fails first and fails fast.
    expect(paths.log).toBe(join(userData, 'copilot-log'))
    expect(paths.actions).toBe(join(paths.log, 'actions.jsonl'))
    expect(paths.log.startsWith(`${paths.root}/`)).toBe(false)
    expect(paths.actions.startsWith(`${paths.root}/`)).toBe(false)
  })

  it('keeps routines out of the folder, because this folder is writable by the agent', () => {
    // The load-bearing assertion of the whole move. `<userData>/copilot` is the
    // one directory the copilot session may write to, and a routine file
    // dropped into a watched folder is an alter-tier act with no confirmation
    // in front of it. If a later change ever puts the routines folder back
    // under `root`, this fails — and `copilot-writable-boundary.test.ts` proves
    // the same thing against a real sandbox rather than against a string.
    expect(routinesDirFor(userData)).toBe(join(userData, 'routines'))
    expect(routinesDirFor(userData).startsWith(`${paths.root}/`)).toBe(false)
    expect(runtimeStateFileFor(userData).startsWith(`${paths.root}/`)).toBe(false)
  })
})

describe('scaffolding', () => {
  it('creates the folder, the instructions and the memory index on first use', () => {
    const result = scaffoldCopilotHome(paths)
    expect(result.error).toBeNull()
    for (const dir of [paths.root, paths.memory, paths.log, paths.layer.dir]) {
      expect(statSync(dir).isDirectory()).toBe(true)
    }
    expect(existsSync(paths.instructions)).toBe(true)
    expect(existsSync(paths.memoryIndex)).toBe(true)
    expect(result.created).toContain(paths.instructions)
  })

  it('writes nothing at all into a folder somebody chose', () => {
    /*
     * The requirement in its strictest form, checked the only way that leaves
     * no room for argument: the folder's listing is identical before and after.
     *
     * "Nothing important" would be untestable and would rot. "Nothing" is a
     * `readdirSync` on both sides, and it fails the day somebody adds a
     * `memory/` or a marker file "just so it has somewhere to write".
     */
    const workspace = mkdtempSync(join(tmpdir(), 'somebody-elses-'))
    writeFileSync(join(workspace, 'CLAUDE.md'), '# I am somebody else’s assistant\n')
    const before = readdirSync(workspace).sort()

    const chosen = copilotPaths(userData, workspace)
    const result = scaffoldCopilotHome(chosen)

    expect(result.error).toBeNull()
    expect(readdirSync(workspace).sort()).toEqual(before)
    expect(readFileSync(join(workspace, 'CLAUDE.md'), 'utf8')).toBe(
      '# I am somebody else’s assistant\n',
    )
    expect(result.created.every((path) => !path.startsWith(`${workspace}${sep}`))).toBe(true)
    // And it still made everything of its own, so the copilot can start.
    expect(existsSync(chosen.instructions)).toBe(true)
    rmSync(workspace, { recursive: true, force: true })
  })

  it('moves an older build’s CLAUDE.md out of its own folder rather than copying it', () => {
    /*
     * The upgrade path, and the reason it is a move.
     *
     * A copy would upgrade the copilot and leave the defect exactly where it
     * was: a file in that folder still saying "you are the copilot", still read
     * by every ordinary terminal opened there. The bytes have to end up in the
     * layer and the folder has to end up without one.
     */
    mkdirSync(paths.root, { recursive: true })
    writeFileSync(legacyInstructionsFile(paths), '# an older default\n')

    const result = scaffoldCopilotHome(paths)

    expect(existsSync(legacyInstructionsFile(paths))).toBe(false)
    expect(readFileSync(paths.instructions, 'utf8')).toBe('# an older default\n')
    expect(result.removed).toContain(legacyInstructionsFile(paths))
  })

  it('never moves a CLAUDE.md out of a folder somebody chose', () => {
    // The same migration pointed at somebody's own workspace would be the most
    // destructive thing this feature could do: that file is usually the reason
    // they chose the folder.
    const workspace = mkdtempSync(join(tmpdir(), 'somebody-elses-'))
    writeFileSync(join(workspace, 'CLAUDE.md'), '# mine\n')
    const chosen = copilotPaths(userData, workspace)

    scaffoldCopilotHome(chosen)

    expect(readFileSync(join(workspace, 'CLAUDE.md'), 'utf8')).toBe('# mine\n')
    expect(readFileSync(chosen.instructions, 'utf8')).toContain('developer')
    rmSync(workspace, { recursive: true, force: true })
  })

  it('does not make a routines folder inside the copilot folder', () => {
    scaffoldCopilotHome(paths)
    expect(existsSync(legacyRoutinesDir(paths))).toBe(false)
  })

  it('takes away the empty routines folder an earlier build left behind', () => {
    // The upgrade path. An install from before this change has an empty
    // `<userData>/copilot/routines/` that nothing reads any more; leaving it
    // there would keep showing the copilot a routines folder inside its own
    // boundary, which is the exact misunderstanding this change removes.
    mkdirSync(legacyRoutinesDir(paths), { recursive: true })
    const result = scaffoldCopilotHome(paths)
    expect(result.removed).toContain(legacyRoutinesDir(paths))
    expect(existsSync(legacyRoutinesDir(paths))).toBe(false)
  })

  it('leaves the legacy folder alone when somebody put a file in it', () => {
    // `rmdir`, never `rm -r`: the app does not delete a person's file to tidy a
    // path. It will not run from there, and the folder staying put is how they
    // find out.
    mkdirSync(legacyRoutinesDir(paths), { recursive: true })
    const stray = join(legacyRoutinesDir(paths), 'mine.md')
    writeFileSync(stray, '# a routine somebody wrote by hand\n')
    const result = scaffoldCopilotHome(paths)
    expect(result.removed).toEqual([])
    expect(readFileSync(stray, 'utf8')).toContain('by hand')
  })

  it('carries an earlier build action log out of the folder and takes the directory away', () => {
    // The upgrade path, and the difference from `routines/` is that there is
    // something in here worth keeping. Deleting the rows to close the hole
    // would destroy the record in the act of protecting it.
    mkdirSync(legacyLogDir(paths), { recursive: true })
    writeFileSync(join(legacyLogDir(paths), 'actions.jsonl'), '{"action":"home.created"}\n')
    writeFileSync(join(legacyLogDir(paths), 'actions.jsonl.1'), '{"action":"older"}\n')

    const result = scaffoldCopilotHome(paths)

    expect(result.removed).toContain(legacyLogDir(paths))
    expect(existsSync(legacyLogDir(paths))).toBe(false)
    expect(readFileSync(paths.actions, 'utf8')).toContain('home.created')
    // The rolled generation moves too — a reader walks back through it, and
    // half a history is a history nobody can trust.
    expect(readFileSync(`${paths.actions}.1`, 'utf8')).toContain('older')
  })

  it('never overwrites a log that is already at the new location', () => {
    // Both locations in use is a state nothing in this app can produce, so it
    // means something unexpected happened — and clobbering somebody's history
    // to tidy a path is the one outcome not worth risking. The legacy folder
    // stays where they can find it.
    scaffoldCopilotHome(paths)
    appendCopilotAction(paths, { action: 'session.started', detail: 'the real one' })
    mkdirSync(legacyLogDir(paths), { recursive: true })
    writeFileSync(join(legacyLogDir(paths), 'actions.jsonl'), '{"action":"from.the.old.place"}\n')

    scaffoldCopilotHome(paths)

    expect(readFileSync(paths.actions, 'utf8')).toContain('the real one')
    expect(readFileSync(paths.actions, 'utf8')).not.toContain('from.the.old.place')
    expect(existsSync(join(legacyLogDir(paths), 'actions.jsonl'))).toBe(true)
  })

  it('leaves the legacy log folder alone when something unexpected is in it', () => {
    mkdirSync(legacyLogDir(paths), { recursive: true })
    const stray = join(legacyLogDir(paths), 'something-else.txt')
    writeFileSync(stray, 'not a log\n')
    const result = scaffoldCopilotHome(paths)
    expect(result.removed).not.toContain(legacyLogDir(paths))
    expect(readFileSync(stray, 'utf8')).toBe('not a log\n')
  })

  it('creates nothing on the second call', () => {
    scaffoldCopilotHome(paths)
    expect(scaffoldCopilotHome(paths).created).toEqual([])
  })

  it('puts everything back when a person deletes it', () => {
    // It runs on every start rather than only on first launch, because a folder
    // a person can open is a folder a person can delete.
    scaffoldCopilotHome(paths)
    const again = copilotPaths(userData)
    expect(scaffoldCopilotHome(again).error).toBeNull()
    expect(existsSync(again.instructions)).toBe(true)
  })

  it('never overwrites instructions somebody has edited', () => {
    scaffoldCopilotHome(paths)
    writeFileSync(paths.instructions, '# mine\nOnly answer in French.\n')
    scaffoldCopilotHome(paths)
    // If this ever fails, the file is decorative: it would read as if it were
    // in charge while the shipped wording actually was.
    expect(readFileSync(paths.instructions, 'utf8')).toBe('# mine\nOnly answer in French.\n')
  })

  it('reports the folder as edited once the instructions differ', () => {
    scaffoldCopilotHome(paths)
    expect(copilotHomeReport(paths).instructionsAreDefault).toBe(true)
    writeFileSync(paths.instructions, '# mine\n')
    expect(copilotHomeReport(paths).instructionsAreDefault).toBe(false)
  })
})

describe('the instructions — the half that is the person’s', () => {
  /**
   * The instructions, with every run of whitespace flattened to one space.
   *
   * The file is hard-wrapped so a person can read it in an editor, which means
   * any sentence long enough to be worth asserting on is split across a line
   * break. Matching the wrapped form would pin the *wrapping* — so the next
   * person to reword a paragraph would fail a test about the wrong thing.
   */
  const text = (): string => copilotInstructions().replace(/\s+/g, ' ')

  /**
   * ## What moved out of this block, and why the cases are not simply gone
   *
   * This file used to hold every assertion about the copilot's instructions,
   * because there was one instruction file. There are two halves now: this one
   * — the persona and the standing instructions, which a person owns and edits —
   * and a generated one describing what is actually wired.
   *
   * Everything about tools, tiers, refused paths, the action log and untrusted
   * tool output is asserted in `copilot-layer.test.ts`, against the generated
   * text, where it can also be checked that the claims are *derived* rather than
   * typed. Nothing was dropped: each case that left this block has a
   * counterpart there, and that file says which.
   */

  it('names no path at all, so it survives the folder moving', () => {
    /*
     * The inversion of what this block used to assert first, and the rule the
     * whole split turns on.
     *
     * It used to check that the instructions named the copilot's folder, which
     * was right when there was one folder and this app wrote the file into it.
     * The folder can now be somebody's own workspace, and this half is a file
     * the app has promised never to rewrite — so a path baked into it is a path
     * that goes stale the moment they point the copilot somewhere else, in a
     * file nothing will ever come along and correct.
     *
     * Asserted as "no absolute path anywhere" rather than as "not this
     * particular path", because the failure worth catching is somebody
     * interpolating a *different* one.
     */
    const body = copilotInstructions()
    expect(body).not.toContain(paths.root)
    expect(body).not.toContain(paths.actions)
    expect(body).not.toContain(userData)
    expect(body).not.toMatch(/(^|\s)\/(Users|home|var|tmp)\//)
  })

  it('takes no arguments, which is what makes the rule above unbreakable', () => {
    // A function of no arguments cannot interpolate a path by accident. The
    // frozen entries in `copilot-instructions-history.ts` still take `paths`,
    // because they are bytes from builds where paths *were* substituted.
    expect(copilotInstructions.length).toBe(0)
  })

  it('is exactly what the scaffolder writes', () => {
    scaffoldCopilotHome(paths)
    expect(readFileSync(paths.instructions, 'utf8')).toBe(copilotInstructions())
  })

  it('frames a developer\'s copilot, not an assistant for the app', () => {
    /*
     * The framing Asad ruled out on 2026-08-17, pinned so it cannot come back.
     * The first scaffold opened *"you are the assistant for the app itself and
     * for the person using it"*, which is a general assistant; the scope is a
     * developer's copilot supervising other agents, and the exclusions are the
     * decision rather than an oversight.
     */
    const body = text()
    expect(body).toMatch(/You are a \*\*developer's copilot\*\*/i)
    expect(body).not.toMatch(/the assistant for the \*app itself\*/i)
    expect(body).toMatch(/not\*\* a general personal assistant/i)
    expect(body).toMatch(/No inbox, no calendar/i)
  })

  it('says the person’s work is writable, and says what to do with that', () => {
    /*
     * Two rewrites of the same paragraph, and the direction reversed each time.
     *
     * The first scaffold said the copilot could not read the person's projects.
     * The second said it could read them and could never write them, with the
     * refusal coming from the kernel. Both were true when written; neither is
     * now. An ordinary session writes the person's code, and the copilot is one.
     *
     * What replaces the refusal is a preference with a reason attached — work
     * that goes through a session has a transcript, a diff and a cost, which is
     * work the person can review. The *fact* that the machine is reachable moved
     * to the generated half, where it is derived rather than asserted; what
     * stays here is the judgement about what to do with it, which is a standing
     * instruction and is the person's to change.
     */
    const body = text()
    expect(body).toMatch(/prefer giving it to a session/i)
    expect(body).toMatch(/Ask before you write, move or delete anything of theirs/i)
    expect(body).not.toMatch(/read, and never write/i)
    expect(body).not.toMatch(/that is a session's job, not yours/i)
  })

  it('names the destructive commands rather than gesturing at "be careful"', () => {
    // There is no kernel refusing any of these, so the file has to be specific:
    // an agent told "be careful" and an agent told "no force-push" behave
    // differently, and only one of those instructions can be checked.
    const body = text()
    expect(body).toMatch(/rm -rf/)
    expect(body).toMatch(/force-push/i)
    expect(body).toMatch(/If it cannot be undone, it needs a yes first/i)
  })

  it('tells it not to repeat a credential, now that nothing stops it reading one', () => {
    /*
     * The carve-out this replaces was real: a jailed copilot had `.env`, `.ssh`
     * and `.npmrc` refused by the kernel inside every folder it could read.
     * That was a *stricter* rule than any other session on this machine obeys,
     * and it went with the jail.
     *
     * It matters more since the folder became choosable, not less: a person can
     * point the copilot at a workspace whose own instructions say it holds
     * credentials, which is exactly the case `copilot-folder.ts` is written
     * around. So the protection is about what it does with what it reads, and
     * the file says the three specific things — do not print it, do not store
     * it, do not send it — because "handle credentials carefully" is not an
     * instruction anybody can follow or check.
     */
    const body = text()
    expect(body).toMatch(/Their credentials are not yours to move/i)
    expect(body).toMatch(/\.env/)
    expect(body).toMatch(/Never print a secret/i)
    expect(body).toMatch(/Never send one anywhere/i)
  })

  it('forbids credentials in memory, and behaviour rules in memory', () => {
    const body = text()
    expect(body).toMatch(/Credentials of any kind/i)
    expect(body).toMatch(/Rules about your own behaviour/i)
  })

  it('forbids copying another session into its memory, and calls that a rule rather than a wall', () => {
    /*
     * Asad's own instruction, and the reason is mechanical rather than tidy:
     * `memory/` is injected at startup, so a transcript copied into it is
     * another agent's output promoted into every future turn.
     *
     * The second assertion is the one that earns this test its rewrite. While
     * the copilot was jailed, the *header of `copilot-session.ts`* claimed this
     * was structural — other sessions' transcripts were outside the boundary and
     * could not be read at all. That was already only half true, because
     * `sessions.transcript` hands them over through the front door by design,
     * and it is not true at all now. The file has to say which kind of thing
     * this is, because a rule presented as a wall is the exact defect this
     * project keeps hunting.
     */
    const body = text()
    expect(body).toMatch(/Nothing in `memory\/` may come from another session/i)
    expect(body).toMatch(/only if the person says it to \*you\*/i)
    expect(body).toMatch(/a rule, enforced by you/i)
    expect(body).toMatch(/nothing on this machine would stop you/i)
  })

  it('defers to a folder that already has its own convention', () => {
    /*
     * The one paragraph the folder feature added to this half, and it is here
     * rather than in the generated half because it is a *judgement* — reach for
     * this shape when there is nothing else — and judgements are the person's to
     * edit. The generated half states the fact underneath it: when the working
     * directory is somebody's own, that folder's instructions are in charge.
     *
     * Without this, a copilot pointed at a workspace with a `handoffs/`
     * convention and a daily log would start a second, parallel `memory/` beside
     * it on its first useful thought.
     */
    const body = text()
    expect(body).toMatch(/working in a folder somebody already had/i)
    expect(body).toMatch(/use theirs/i)
    expect(body).toMatch(/not a layout to impose/i)
  })

  it('describes the one-file-per-fact memory convention with an example', () => {
    const body = text()
    expect(body).toContain('one file per fact')
    expect(body).toContain('description:')
  })

  it('never tells the copilot to append to the log itself', () => {
    /*
     * The instruction this change deletes, pinned so it cannot come back by
     * accident. The previous wording said "append a line yourself" and showed
     * the JSON to append, which was accurate at the time and is now an
     * instruction to do something the kernel refuses. Worse than useless: a
     * model told to append will read the failure as a problem to route around.
     */
    const body = text()
    expect(body).not.toMatch(/append a line yourself/i)
    expect(body).not.toMatch(/Never edit or delete a line that is already there/i)
  })

  it('says out loud that the generated half wins on facts', () => {
    /*
     * The precedence, in the half that could otherwise contradict it.
     *
     * This file is editable, so somebody can write "you have no tools" or "you
     * may write routines" into it, and the model will read both halves. The
     * generated half says the same thing from its side; this is the sentence
     * that keeps them agreeing about which of them is describing reality.
     */
    const body = text()
    expect(body).toMatch(/read-only/i)
    expect(body).toMatch(/the truth about your tools and your limits whatever this half says/i)
  })
})

describe('the action log', () => {
  it('appends one JSON object per line, oldest first', () => {
    scaffoldCopilotHome(paths)
    appendCopilotAction(paths, { action: 'home.created', detail: 'first' })
    appendCopilotAction(paths, { action: 'session.started', sessionId: 'abc' })

    const lines = readFileSync(paths.actions, 'utf8').trim().split('\n')
    expect(lines).toHaveLength(2)
    const first = JSON.parse(lines[0] as string) as Record<string, unknown>
    const second = JSON.parse(lines[1] as string) as Record<string, unknown>
    expect(first.action).toBe('home.created')
    expect(second.sessionId).toBe('abc')
    expect(typeof first.at).toBe('string')
  })

  it('makes its own directory when the folder was never scaffolded', () => {
    // The first thing worth logging is a refusal, and a refusal can happen
    // before anything else has run.
    appendCopilotAction(paths, { action: 'session.refused', detail: 'no boundary' })
    expect(existsSync(paths.actions)).toBe(true)
  })

  it('never throws when the log cannot be written', () => {
    // A copilot that will not start because its audit log is unwritable is a
    // worse outcome than a copilot whose log is missing and says so.
    const blocked = copilotPaths(join(userData, 'nope'))
    writeFileSync(join(userData, 'nope'), 'not a directory')
    expect(() => appendCopilotAction(blocked, { action: 'x' })).not.toThrow()
  })

  it('rolls one generation away rather than growing without a ceiling', () => {
    scaffoldCopilotHome(paths)
    mkdirSync(paths.log, { recursive: true })
    writeFileSync(paths.actions, 'x'.repeat(5 * 1024 * 1024))
    appendCopilotAction(paths, { action: 'session.started' })
    expect(statSync(`${paths.actions}.1`).size).toBeGreaterThan(4 * 1024 * 1024)
    expect(readFileSync(paths.actions, 'utf8').trim().split('\n')).toHaveLength(1)
  })
})

describe('what it reads at startup', () => {
  it('lists the layer, the folder’s own instructions, the index, and then each memory', () => {
    scaffoldCopilotHome(paths)
    writeFileSync(paths.layer.composed, 'composed')
    writeFileSync(join(paths.memory, 'prefers_short_answers.md'), 'x')
    writeFileSync(join(paths.memory, 'notes.txt'), 'ignored')

    const files = copilotStartupFiles(paths)
    expect(files.map((file) => file.path)).toEqual([
      paths.layer.composed,
      folderInstructions(paths),
      paths.memoryIndex,
      join(paths.memory, 'prefers_short_answers.md'),
    ])
    // The layer is the app's; everything after it belongs to the folder.
    expect(files.map((file) => file.owner)).toEqual(['app', 'folder', 'folder', 'folder'])
  })

  it('lists the folder’s CLAUDE.md as absent, which is the row that proves the point', () => {
    /*
     * The most reassuring row on the pane, and the reason it is a row rather
     * than an omission.
     *
     * In a default install nothing writes a `CLAUDE.md` into the copilot's
     * folder — that is the change this whole feature is — so the honest listing
     * shows it, missing. A person can then see, without reading any
     * documentation, that an ordinary terminal opened in that folder finds
     * nothing of the copilot's. Leaving the row out would leave them to infer
     * it, and inferring an absence is not something a screen can ask of anybody.
     */
    scaffoldCopilotHome(paths)
    const folderOwn = copilotStartupFiles(paths).find(
      (file) => file.path === folderInstructions(paths),
    )
    expect(folderOwn?.exists).toBe(false)
    expect(folderOwn?.purpose).toMatch(/never writes one here/i)
  })

  it('says a file is missing rather than leaving it out', () => {
    // A settings pane listing "what your assistant reads" has to be able to
    // show a row that is not there; an omitted row reads as "nothing to see".
    const files = copilotStartupFiles(paths)
    expect(files.map((file) => file.exists)).toEqual([false, false, false])
    expect(files[0]?.size).toBeNull()
  })

  it('separates the app’s three files from what the session reads', () => {
    /*
     * The two lists answer two questions and the pane draws them differently:
     * one is *what the session reads*, in order, and only the composed file
     * belongs to it; the other is *what this app keeps about its own agent*.
     * A single list would have to explain, per row, why one `.md` under
     * `<userData>` is editable and the one beside it is generated.
     */
    scaffoldCopilotHome(paths)
    const layer = copilotLayerFiles(paths)
    expect(layer.map((file) => file.path)).toEqual([
      paths.layer.yours,
      paths.layer.contract,
      paths.layer.composed,
    ])
    expect(layer.map((file) => file.owner)).toEqual(['yours', 'app', 'app'])
    // The editable one exists after a scaffold; the generated ones do not, and
    // that is right — they are written when the copilot starts.
    expect(layer[0]?.exists).toBe(true)
    expect(layer[1]?.exists).toBe(false)
  })
})

describe('an instruction file left behind by an older build', () => {
  /**
   * The upgrade path, and the reason it needs a mechanism rather than a
   * comparison.
   *
   * `CLAUDE.md` is written with `wx` and never overwritten, so an install from
   * before this rewrite still has the first scaffold on disk — a file that
   * frames a general assistant and states that the copilot cannot read the
   * person's projects. Both are now false. A single equality against what this
   * build ships calls that file "not the default", which is the same answer it
   * gives for somebody's own writing, and the two need opposite treatment.
   */
  it('tells an old default apart from somebody\'s own words', () => {
    scaffoldCopilotHome(paths)
    expect(instructionsState(paths)).toBe('current')

    for (const past of PAST_COPILOT_INSTRUCTIONS) {
      writeFileSync(paths.instructions, past(paths))
      expect(instructionsState(paths)).toBe('superseded')
    }

    writeFileSync(paths.instructions, '# mine\nOnly answer in French.\n')
    expect(instructionsState(paths)).toBe('edited')

    rmSync(paths.instructions)
    expect(instructionsState(paths)).toBe('missing')
  })

  it('every past default really was a default, and none of them is the current one', () => {
    // The list is only useful if it holds text this app actually wrote. An
    // entry equal to the current wording would make a fresh install report
    // itself as out of date; an entry nobody ever had would widen the set of
    // files this app is willing to call "not yours".
    const current = copilotInstructions()
    for (const past of PAST_COPILOT_INSTRUCTIONS) expect(past(paths)).not.toBe(current)
    expect(new Set(PAST_COPILOT_INSTRUCTIONS.map((past) => past(paths))).size).toBe(
      PAST_COPILOT_INSTRUCTIONS.length,
    )
  })

  it('scaffolding still refuses to replace it, however out of date it is', () => {
    // The rule that makes the file worth having. Only a person asking replaces
    // their instructions; a start never does.
    scaffoldCopilotHome(paths)
    const stale = PAST_COPILOT_INSTRUCTIONS[0]?.(paths) ?? ''
    writeFileSync(paths.instructions, stale)
    scaffoldCopilotHome(paths)
    expect(readFileSync(paths.instructions, 'utf8')).toBe(stale)
  })

  it('reports it as not-the-default so a pane can offer the reset', () => {
    scaffoldCopilotHome(paths)
    writeFileSync(paths.instructions, PAST_COPILOT_INSTRUCTIONS[0]?.(paths) ?? '')
    const report = copilotHomeReport(paths)
    expect(report.instructionsAreDefault).toBe(false)
    expect(report.instructions).toBe('superseded')
  })

  it('recognises the wording that told the copilot to append to its own log', () => {
    /*
     * The specific upgrade this change needs the history for.
     *
     * A folder scaffolded earlier today holds a file that instructs the copilot
     * to append rows to `log/actions.jsonl` itself — accurate then, refused by
     * the kernel now, and it tells the person they can audit a record their
     * assistant could have composed. Without this entry that file reads as
     * hand-edited, so the reset is never offered and the wrong instruction
     * stays in force forever.
     */
    scaffoldCopilotHome(paths)
    const withWritableLog = PAST_COPILOT_INSTRUCTIONS.find((past) =>
      past(paths).includes('append a line yourself'),
    )
    expect(withWritableLog).toBeDefined()
    writeFileSync(paths.instructions, withWritableLog?.(paths) ?? '')
    expect(instructionsState(paths)).toBe('superseded')
  })
})

describe('putting the shipped instructions back', () => {
  it('writes this build\'s wording and keeps what was there', () => {
    scaffoldCopilotHome(paths)
    writeFileSync(paths.instructions, '# mine\nOnly answer in French.\n')

    const result = resetCopilotInstructions(paths)
    expect(result.reset).toBe(true)
    expect(result.error).toBeNull()
    expect(readFileSync(paths.instructions, 'utf8')).toBe(copilotInstructions())
    // The backup is what makes the button safe to press: a person who had
    // forgotten they edited the file can get their words back.
    expect(readFileSync(result.backup ?? '', 'utf8')).toBe('# mine\nOnly answer in French.\n')
    expect(instructionsState(paths)).toBe('current')
  })

  it('backs up an out-of-date default too, not only a hand-edited file', () => {
    // One small write, and it removes the need to decide *before* the write
    // which of the two cases this is.
    scaffoldCopilotHome(paths)
    writeFileSync(paths.instructions, PAST_COPILOT_INSTRUCTIONS[0]?.(paths) ?? '')
    const result = resetCopilotInstructions(paths)
    expect(readFileSync(result.backup ?? '', 'utf8')).toContain('the assistant for the *app itself*')
  })

  it('writes the file when there was none, and says there was nothing to keep', () => {
    const result = resetCopilotInstructions(paths)
    expect(result.reset).toBe(true)
    expect(result.backup).toBeNull()
    expect(existsSync(paths.instructions)).toBe(true)
  })
})

describe('editing the instructions from Settings', () => {
  it('hands back the whole file, never a head of it', () => {
    /*
     * The difference between this reader and `readMemoryFact`, and it is a
     * data-loss difference rather than a stylistic one: this text goes into a
     * box with a Save button under it, so a truncated read is a delete waiting
     * for somebody to press the button. The ceiling is enforced on the way *in*
     * instead, which is why this can promise the whole file.
     */
    scaffoldCopilotHome(paths)
    const long = `${copilotInstructions()}\n${'x'.repeat(200_000)}\n`
    writeFileSync(paths.instructions, long)
    const result = readCopilotInstructions(paths)
    expect(result.ok).toBe(true)
    expect(result.ok && result.text).toBe(long)
  })

  it('reports the state alongside the text, so a pane draws one answer', () => {
    scaffoldCopilotHome(paths)
    const result = readCopilotInstructions(paths)
    expect(result.ok && result.state).toBe('current')
    expect(result.ok && result.text).toBe(copilotInstructions())
  })

  it('says there is no file rather than handing back an empty box', () => {
    // An empty box over a missing file is a box somebody will type into and
    // save, which creates the file with whatever they typed and nothing else.
    //
    // It names the thing rather than a filename, and that is the naming sweep
    // fixing a factual error as well as a branded one: the file this reads is
    // `<userData>/copilot-layer/instructions.md`, so the old wording — "there is
    // no CLAUDE.md yet" — sent somebody looking for a file that is not the one
    // that is missing, in the one message whose job is to say which file is
    // missing. `src/neutral-naming.test.ts` is what keeps it out.
    const result = readCopilotInstructions(paths)
    expect(result.ok).toBe(false)
    expect(result.ok === false && result.error).toContain('no instructions yet')
  })

  it('writes what a person typed and keeps what was there', () => {
    scaffoldCopilotHome(paths)
    const mine = '# Mine\n\nAlways run typecheck before saying it is done.\n'
    const result = writeCopilotInstructions(paths, mine)

    expect(result).toMatchObject({ saved: true, error: null })
    expect(readFileSync(paths.instructions, 'utf8')).toBe(mine)
    expect(readFileSync(result.backup ?? '', 'utf8')).toBe(copilotInstructions())
    // And the app now knows this is somebody's own writing, which is what stops
    // any later scaffold or upgrade path from putting its own wording back.
    expect(instructionsState(paths)).toBe('edited')
  })

  it('refuses an empty file, which is an agent with tools and no purpose', () => {
    /*
     * The refusal that matters most, because the two ways to reach it are a box
     * that failed to load and a person clearing it to start again — and both end
     * with a copilot that still has its tools, still has its boundary, and has
     * nothing telling it what it is for. Somebody who genuinely wants that can
     * delete the file in Finder, where nothing is ambiguous about what they did.
     */
    scaffoldCopilotHome(paths)
    for (const empty of ['', '   ', '\n\n\t\n']) {
      const result = writeCopilotInstructions(paths, empty)
      expect(result.saved, JSON.stringify(empty)).toBe(false)
      expect(result.error).toContain('cannot be empty')
    }
    expect(readFileSync(paths.instructions, 'utf8')).toBe(copilotInstructions())
  })

  it('refuses anything that is not a string, and anything over the ceiling', () => {
    scaffoldCopilotHome(paths)
    for (const junk of [undefined, null, 3, {}, ['a']]) {
      expect(writeCopilotInstructions(paths, junk).saved, String(junk)).toBe(false)
    }
    const huge = 'x'.repeat(MAX_INSTRUCTIONS_BYTES + 1)
    expect(writeCopilotInstructions(paths, huge).error).toContain('cannot be larger')
    expect(readFileSync(paths.instructions, 'utf8')).toBe(copilotInstructions())
  })

  it('does not replace the backup when the text has not changed', () => {
    /*
     * The bug this prevents is quiet and total: press Save twice and the second
     * press copies the *new* file over the backup, so the one version somebody
     * actually wanted back is gone. A save whose text already matches disk is a
     * no-op, and says so by reporting no backup.
     */
    scaffoldCopilotHome(paths)
    const shipped = copilotInstructions()
    writeCopilotInstructions(paths, '# Mine\n\nFrench only.\n')
    const second = writeCopilotInstructions(paths, '# Mine\n\nFrench only.\n')

    expect(second).toMatchObject({ saved: true, backup: null })
    expect(readFileSync(`${paths.instructions}.bak`, 'utf8')).toBe(shipped)
  })

  it('writes into a folder that is not there yet', () => {
    // Somebody can delete this directory at any moment, and the next thing that
    // happens should be the app putting it back rather than a save failing.
    const result = writeCopilotInstructions(paths, '# Mine\n')
    expect(result).toMatchObject({ saved: true, backup: null })
    expect(readFileSync(paths.instructions, 'utf8')).toBe('# Mine\n')
  })
})

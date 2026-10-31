/**
 * The routines that are actually in the folder on a fresh install.
 *
 * `COPILOT-CAPABILITIES.md` §5 opens with the whole argument for this file:
 * *"Not a framework — the engine exists. These are the actual files that should
 * be in `routines/` on a fresh install, most disabled until switched on, each
 * one a developer would recognise."* An automation feature that ships with an
 * empty list is an automation feature nobody uses, because the cost of the
 * first one is writing it from a blank page against a format you have not read.
 *
 * ## Every trigger below is one this build actually emits
 *
 * That constraint threw out three of the routines the document proposes, and it
 * is worth saying which and why, because "it is in the document" is not the
 * same as "it will fire":
 *
 *  - **`blocked-agent` cannot be `session-idle`.** The engine's own comment on
 *    `noteSessionStatus` is explicit that `input` — the one status that means a
 *    human is being blocked — deliberately does not count as idle, because
 *    firing at a session that is waiting for a person is the opposite of the
 *    intent. The signal that *does* exist is `alerts.ts`'s `session-blocked`,
 *    which fires at the ten-minute threshold the document wanted. So the
 *    trigger is `alert session-blocked`.
 *  - **`stuck-session` had no event of its own, and now it does.** This entry
 *    used to read: *a looping session is `working` — output is arriving, tokens
 *    are being spent, and nothing in this app emits anything* — so the routine
 *    hung off `alert heavy-session`, the money side of the same problem. That
 *    was honest and it was also a gap with a size: `HEAVY_MIN_TOKENS` is a
 *    million tokens, so a session stuck on a failing build for forty minutes
 *    reached nobody until it had spent that much. `alerts.ts` now derives a
 *    `loop` alert from the same `progress.ts` verdict `sessions.result`
 *    reports, for live sessions only, and the trigger is `alert loop`. The
 *    routine still calls `sessions.result` — the alert is the *interrupt*, the
 *    tool is the *evidence*, and the routine's job is to decide whether the two
 *    agree before spending anybody's attention.
 *  - **`pr-opened` and `heartbeat` are not here at all.** Both are polls. The
 *    standing preference is events over timers, and neither has enough behind
 *    it to justify spending a turn every half hour forever on somebody else's
 *    machine. `dirty-tree` and `overnight` are the two places a clock genuinely
 *    beats an event, and they are the only two schedules shipped.
 *
 * ## Nothing here writes, and one routine is smaller because of it
 *
 * A routine run gets `Read`, `Grep`, `Glob` and the deck-control tools, and no
 * `Bash`, `Write` or `Edit` — see `runner.ts` for why an unattended agent with
 * a shell is the riskiest shape in this design. That is why `memory-check`
 * *reports* what has gone stale in `memory/` instead of pruning it, and says so
 * in its own text. A routine that claimed to prune and could not would be worse
 * than one that reports: the person would stop checking.
 *
 * ## Deleting one keeps it deleted
 *
 * Seeding writes what is missing, once, and records that it did in
 * `.seeded`. A person who deletes `overnight.md` because they do not want it
 * gets an app that leaves them alone, rather than one that puts it back every
 * launch — which is the single most irritating behaviour a scaffolder can have.
 */

import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { BRAND } from '../../shared/brand'

/* ------------------------------------------------------------------- shape -- */

export interface DefaultRoutine {
  id: string
  /** The file, given the folder this install should watch. */
  file(folder: string): string
}

/** Where the record of what has already been seeded lives. */
export function seedMarkerPath(dir: string): string {
  return join(dir, '.seeded')
}

/* ---------------------------------------------------------------- the files -- */

function routine(input: {
  id: string
  name: string
  when: string[]
  enabled: boolean
  overlap?: string
  quietFor?: string
  maxRunsPerHour?: number
  expectEvery?: string
  why: string
  prompt: string
}): DefaultRoutine {
  return {
    id: input.id,
    file: (folder: string) =>
      [
        `# ${input.name}`,
        '',
        ...input.when.map((when) => `when: ${when}`),
        `in: ${folder}`,
        `enabled: ${input.enabled ? 'yes' : 'no'}`,
        ...(input.overlap ? [`overlap: ${input.overlap}`] : []),
        ...(input.quietFor ? [`quiet-for: ${input.quietFor}`] : []),
        ...(input.maxRunsPerHour ? [`max-runs-per-hour: ${input.maxRunsPerHour}`] : []),
        ...(input.expectEvery ? [`expect-every: ${input.expectEvery}`] : []),
        '',
        `# ${input.why}`,
        `# \`in:\` is the folder this watches. Point it somewhere else, or copy this`,
        `# file once per project — ${BRAND.name} reads every .md in this folder.`,
        '',
        '---',
        '',
        input.prompt.trim(),
        '',
      ].join('\n'),
  }
}

export const DEFAULT_ROUTINES: readonly DefaultRoutine[] = [
  routine({
    id: 'blocked-agent',
    name: 'Something is waiting on you',
    when: ['alert session-blocked'],
    enabled: true,
    overlap: 'skip',
    quietFor: '5m',
    maxRunsPerHour: 6,
    why: 'A blocked agent burns wall-clock silently. This is the most valuable routine here.',
    prompt: `A session in this folder has been waiting on a human for ten minutes or more.

Call sessions_list. For every session whose \`attention\` is "blocked", say in one
line each: which session, how long it has been waiting, and **what it is actually
asking**. Read the last few messages with sessions_transcript to get the question
— do not guess it from the status.

If more than one is blocked, put them in one message, longest wait first. One
digest, never one message per session.

## Do not

- Do not answer the question for them. You cannot see what they intended.
- Do not type into the session. It is theirs and they are mid-thought in it.
- Do not report a session whose \`attention\` is "quiet" — an idle prompt is not
  somebody being blocked, it is a session nobody is using.
- Do not report the same session twice in a row if nothing has changed about it.`,
  }),

  routine({
    id: 'session-failed',
    name: 'A session died',
    when: ['session-failed'],
    enabled: true,
    overlap: 'queue',
    quietFor: '30s',
    maxRunsPerHour: 10,
    why: 'Converts a red dot into a decision. Cheap: it only fires when something actually died.',
    prompt: `A session in this folder exited with a non-zero code.

Call sessions_result for that session. In two lines: why it died, and whether it
is worth restarting. The exit code, the last thing it said, and whether it left
changes on disk are the three facts that answer that — sessions_result has all
three.

If it left uncommitted changes behind, say so and say how many files, because a
dead session with half an edit in the working tree is the thing that bites
tomorrow.

## Do not

- Do not restart it. That is a decision with money attached and it is theirs.
- Do not report a clean exit. This routine only fires on a failure, but a shell
  that exited 130 because somebody pressed Ctrl-C is not news — say so in one
  line and stop.`,
  }),

  routine({
    id: 'stuck-session',
    name: 'Going round in circles',
    when: ['alert loop', 'alert heavy-session'],
    enabled: true,
    overlap: 'skip',
    quietFor: '10m',
    maxRunsPerHour: 4,
    why: 'A live session repeating itself with nothing landing on disk. The cost alert is kept as the second trigger, for the expensive sessions that are not looping.',
    prompt: `A session in this folder looks like it is going round in circles, or is
costing far more than the others in it. Which one it is, is in the alert's title.

Call sessions_result for that session and look at \`progress\`. It says whether the
session is repeating itself and what it is repeating: the same tool over and over,
the same failure, a compaction immediately undone, nothing written to a file.

**Check the alert against the tool before you report it.** The alert was raised
from a scan that ran a moment ago; sessions_result reads the transcript now. If
the session has moved on — files written since, a different tool, the failures
stopped — say so and stop. An alert that was true a minute ago and is not true
now is the single most common way this kind of report loses somebody's trust.

Then say one of three things, and nothing else:

1. It is working and it is expensive — here is what it has spent and what it has
   changed on disk.
2. It looks stuck — here is exactly what it has been retrying, for how long, and
   what it has spent doing it.
3. It cannot be told — this session writes no transcript, so there is nothing to
   read. Say that plainly rather than saying it looks fine.

## Do not

- Do not stop the session. Reporting is your job; stopping is theirs.
- Do not call it stuck when \`progress.verdict\` is "suspect" — that is repetition
  with files still landing, which is what a refactor looks like.
- Do not read the whole transcript to double-check. sessions_result already read
  the part that matters, and a transcript read costs tens of thousands of tokens.
- Do not repeat the alert back. It is already on their screen. Say what the
  evidence adds to it.`,
  }),

  routine({
    id: 'overnight',
    name: 'What happened overnight',
    when: ['schedule 08:30'],
    enabled: true,
    overlap: 'skip',
    expectEvery: '26h',
    maxRunsPerHour: 2,
    why: 'The one place a clock genuinely beats an event: "when I next sit down" is not something the machine can see.',
    prompt: `Report on everything that ran since yesterday.

Call sessions_result with no sessionId and sinceMinutes: 960. That is the whole
report in one call — every session that was active, ranked so the ones needing a
human come first.

Write it as:

- One line at the top: the headline the tool gives you.
- Then one line per session that matters: what it was, how it ended, what it
  spent, what it changed on disk.
- Then, for any folder with uncommitted changes, call git_diff on it and say
  what changed and **which session did it** — the tool attributes each file, and
  says honestly when two sessions could both have written it.

Every claim gets its pointer: the transcript path, the file paths, the exit code.
A summary they have to re-verify by hand costs more than no summary.

## Do not

- Do not repeat what a session *said* it did. Say what the evidence shows. "It
  says the tests pass" and "the tests pass" are different sentences and you can
  only honestly write the first one.
- Do not include sessions that did nothing.
- Do not paste diffs. Say what changed; they can open it.`,
  }),

  routine({
    id: 'dirty-tree',
    name: 'Uncommitted work left behind',
    when: ['alert dirty-tree'],
    enabled: true,
    overlap: 'skip',
    quietFor: '30m',
    maxRunsPerHour: 2,
    why: 'Fires on the existing dirty-tree alert, which already has its streak counters tuned.',
    prompt: `Several sessions have come and gone in this folder and left the working tree
dirty.

Call git_diff on this folder. Say:

- how many files are changed, and roughly what the change is,
- which sessions the changes are attributable to — the tool works this out from
  file times against session start times, and says "one of these two" rather
  than guessing when it cannot tell,
- and whether anything looks like it was not asked for: a lockfile nobody
  mentioned, a config file, a file in a directory unrelated to the work.

That last one is the point of this routine. The rest is bookkeeping.

## Do not

- Do not commit, stash or revert anything. Ever. You have no write access and no
  shell, and even if you had, deciding what goes into somebody's history is not
  a thing to do while they are asleep.
- Do not report a tree that is dirty because of build output. Check whether the
  paths are ignored-looking before you raise them.`,
  }),

  routine({
    id: 'memory-check',
    name: 'Weekly look at what you remember',
    when: ['schedule 03:00 sun'],
    enabled: true,
    overlap: 'skip',
    expectEvery: '8d',
    maxRunsPerHour: 1,
    why: 'Memory pollution is invisible: superseded facts stay retrievable and quietly degrade every answer.',
    prompt: `Read every file in your memory/ folder and report what has gone wrong with it.

The failure to look for is not "too much" — it is **memory pollution**: a fact
that used to be true, is still retrievable, and is now quietly wrong. The two
worst examples on record were both durability failures rather than retrieval
ones: a curated file that still named a retired account months after everything
had moved.

For each problem, one line: the file, what is wrong, and what should replace it.

- Anything with a \`verified:\` date more than 30 days old that is about an
  account, a credential, a path or a URL.
- Two files saying the same thing.
- Two files contradicting each other.
- Anything with an \`expires:\` date in the past.
- Anything that is a rule about your own behaviour. Those belong in your
  instructions, because memory is not always loaded — which is the whole point
  of memory not being always loaded.

## Do not

- **Do not edit or delete anything.** You are running unattended and you have no
  write access at all in this run. Report; the person or a later conversation
  does the pruning. A routine that claimed to prune and could not is worse than
  one that reports, because they would stop checking.
- Do not report a memory simply for being old. Age is not the problem;
  being wrong is.
- If nothing is wrong, say so in one line and stop.`,
  }),

  routine({
    id: 'quality-gate',
    name: 'Check the work before it counts as done',
    when: ['session-finished'],
    enabled: false,
    overlap: 'queue',
    quietFor: '2m',
    maxRunsPerHour: 6,
    why: 'Off by default: it starts a session, and a session costs money. Turn it on when you are running agents unattended.',
    prompt: `A session in this folder finished. Find out whether its work actually holds.

Call sessions_result for it. If it changed nothing on disk, say so in one line and
stop — there is nothing to check.

If it did change files:

1. Call git_diff and read what changed.
2. Read the project's own gate — its package.json scripts, its agent
   instructions file — and work out what "it passes" means here. For this
   repository that is
   \`npm run typecheck\` and \`npm test\`.
3. Start a session with sessions_start to run that gate, with a brief that says
   exactly which command to run, that it must report the output verbatim, and
   that it must change nothing.

Then report: what the session claimed, what the diff shows, and that the gate is
running. Do not wait for it.

## Do not

- Do not trust "it says the tests pass". This whole routine exists because two
  bugs in this repository shipped clean typechecks.
- Do not start a gate session if one is already running in this folder — the
  start will be refused for that reason and the refusal is correct.
- Do not fix anything yourself. You have no write access.`,
  }),

  routine({
    id: 'ai-marker',
    name: 'Pick up TODO(deck) markers',
    when: ['file-change **/*.{ts,tsx,js,jsx,py,go,rs,rb,java,swift,kt}'],
    enabled: false,
    overlap: 'skip',
    quietFor: '2m',
    maxRunsPerHour: 4,
    why: 'Off by default: it starts sessions. The most developer-specific trigger there is — you write the request where the work is.',
    prompt: `A source file in this folder changed. Look for a request written into the code.

Read the file that changed and look for a marker comment: \`TODO(deck):\`,
\`AI!\` or \`AI?\` at the end of a line. That is somebody asking for work without
leaving their editor, and the surrounding code is the context.

If there is no marker, reply with nothing to report. That will be almost every
time this fires, and that is correct.

If there is one:

1. Read enough of the file around it to understand what is being asked.
2. Write a proper brief — the repo, the file and line, what to change, what
   counts as done, what not to touch — and start a session with it using
   sessions_start's \`brief\` argument.
3. Say in one line which marker you picked up and which session you started.

## Do not

- Do not start more than one session for one marker. If a session is already
  running in this folder the start will be refused, and that refusal is correct.
- Do not act on a marker inside a comment that is *about* markers — this file's
  own text, documentation, a test fixture.
- Do not remove the marker. You have no write access, and the session you start
  is the one that should clear it.`,
  }),
]

/* --------------------------------------------------------- which folder -- */

/**
 * Which project the shipped routines should watch.
 *
 * The most recently opened one, **excluding anything inside `<userData>`**, and
 * that exclusion is not theoretical. The copilot's session runs in
 * `<userData>/copilot`, and this app registers the folder a session runs in as a
 * project — so on the first launch after the copilot has ever started, the most
 * recently opened "project" is the app's own storage. Seeding against it
 * produced eight routines watching `<userData>/copilot` for git changes that
 * will never happen there. Found by reading the seeded files on a real install,
 * not by reasoning about them.
 *
 * It is the same exclusion `copilotProjectRoots` makes for the sandbox and
 * `sessions.start` makes for a new session, arriving at the third place that
 * needed it.
 */
export function chooseSeedFolder(
  projects: ReadonlyArray<{ path: string }>,
  stateRoot: string,
  separator = '/',
): string | null {
  const outside = projects.find(
    (project) => project.path !== stateRoot && !project.path.startsWith(`${stateRoot}${separator}`),
  )
  return outside?.path ?? null
}

/* ---------------------------------------------------------------- seeding -- */

export interface SeedResult {
  /** Routine ids written by this call. Empty on every launch after the first. */
  written: string[]
  /** Why nothing was written, when nothing was. */
  skipped: string | null
}

export interface SeedDeps {
  /** Write a routine file. The store's own writer, so the format stays one thing. */
  write(id: string, contents: string): void
  /** Ids already on disk. */
  existing(): readonly string[]
}

/**
 * Put the default routines in the folder, once.
 *
 * `folder` is the one thing this cannot invent: a routine needs somewhere to
 * watch, and the engine refuses a folder that is not one of this app's
 * projects. On a fresh install with no project added yet there is nothing to
 * point at, so nothing is written and the marker is not laid down — the next
 * launch, after a project exists, seeds properly.
 */
export function seedDefaultRoutines(
  dir: string,
  folder: string | null,
  deps: SeedDeps,
): SeedResult {
  if (folder === null) {
    return { written: [], skipped: 'No project folder to point a routine at yet.' }
  }

  const seeded = readSeeded(dir)
  const onDisk = new Set(deps.existing())
  const written: string[] = []

  for (const entry of DEFAULT_ROUTINES) {
    // Two guards, and they answer different questions. `seeded` is "this app
    // has offered you this file before" — which is what makes a deletion
    // stick. `onDisk` is "there is already a file by this name", which stops a
    // hand-written routine that happens to share a name from being replaced.
    if (seeded.has(entry.id) || onDisk.has(entry.id)) continue
    deps.write(entry.id, entry.file(folder))
    written.push(entry.id)
    seeded.add(entry.id)
  }

  if (written.length > 0) writeSeeded(dir, seeded)
  return { written, skipped: null }
}

function readSeeded(dir: string): Set<string> {
  try {
    const text = readFileSync(seedMarkerPath(dir), 'utf8')
    return new Set(
      text
        .split('\n')
        .map((line) => line.trim())
        .filter((line) => line !== '' && !line.startsWith('#')),
    )
  } catch {
    return new Set()
  }
}

function writeSeeded(dir: string, ids: Set<string>): void {
  const body = [
    `# Routines ${BRAND.name} has already offered you, one per line.`,
    '# Delete a line to be offered that routine again on the next launch.',
    '# Deleting a routine file does NOT bring it back — that is the point of this file.',
    ...[...ids].sort(),
    '',
  ].join('\n')
  try {
    writeFileSync(seedMarkerPath(dir), body, { encoding: 'utf8', mode: 0o600 })
  } catch {
    /*
     * A marker that cannot be written means the defaults are offered again next
     * launch, which is annoying and harmless. Failing the app's startup over it
     * would be neither.
     */
  }
}

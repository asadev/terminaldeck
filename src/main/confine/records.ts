/**
 * The records fence — a short list of this app's own files, held against the one
 * agent they are a record *of*.
 *
 * ## What this replaced, and why the replacement is smaller on purpose
 *
 * The copilot used to run inside the full folder confinement a session from a
 * paired device runs inside: `(deny default)`, a granted folder, its own home,
 * the person's projects read-only and their `.env` files carved back out. That
 * was a jail, and `COPILOT-DESIGN.md` argued for it honestly — a CLI session has
 * Bash and Bash is the whole machine.
 *
 * What the jail actually bought was protection against the copilot **reading**
 * things. What it cost was the copilot being, in practice, *less capable than an
 * ordinary session in the same app*: it started signed out, because its login
 * would live in the macOS login keychain and the keychain is closed to a
 * `(deny default)` process; it could not write a line of the person's code; and
 * on Windows and Linux it refused to start at all. That is exactly backwards for
 * the agent meant to supervise the others.
 *
 * The trade was also weaker than it looked. The network is open to every
 * confined session by design — closing it would stop `git push`, `npm install`
 * and every agent CLI — so whatever the copilot could read it could always send
 * somewhere. A jail never blocked exfiltration; it only narrowed the pool.
 *
 * So the copilot now runs under the same policy as any other session started at
 * this keyboard: unconfined, as the person's own account, reading and writing
 * what they read and write. What survives is this — a fence around the two
 * things that are not about the machine at all, but about whether a person can
 * check what their assistant told them:
 *
 *  - **`<userData>/routines/`** — the directory *is* the routine database.
 *    `routines/store.ts` is built on it: a `.md` file appearing there is a real
 *    routine that really fires on a real trigger. An agent that can write its
 *    own next trigger is an automation loop with no human in it, and creating a
 *    routine is an alter-tier act somebody is supposed to confirm.
 *  - **`<userData>/routine-state.json`** — the engine's run counts, budgets and
 *    `pausedReason`, trusted on every start. An agent that can write it can zero
 *    its own budget and un-pause a routine the engine stopped after five
 *    consecutive failures, with no tool call, no confirmation and no log row.
 *  - **`<userData>/copilot-log/`** — the append-only record of every action,
 *    which is what the Activity pane draws. A record of what something did is
 *    worth nothing if that same thing can compose it.
 *
 * ## Why fencing a handful of paths is not the jail again in miniature
 *
 * A jail asks *what may this process touch*, and the answer has to enumerate the
 * whole world the process needs — which is why it breaks the keychain, the
 * person's repositories and half the platforms. This asks *what may this process
 * not touch*, and the answer is a short, enumerable list. The profile is
 * `(allow default)` plus one deny per fenced path. Measured on macOS 27, from inside that profile:
 *
 *     claude auth status --json        -> {"loggedIn": true, …}
 *     head -1 ~/.gitconfig             -> [filter "lfs"]
 *     echo ok > ~/.probe               -> ok
 *     echo x >> <log>/actions.jsonl    -> Operation not permitted
 *     : > <log>/actions.jsonl          -> Operation not permitted
 *     rm -f <log>/actions.jsonl        -> Operation not permitted
 *     cat <log>/actions.jsonl          -> Operation not permitted
 *     mv <routines> <routines-moved>   -> Operation not permitted
 *     rm -rf <routines>                -> Operation not permitted
 *     ln -s <routines> l; echo>l/x.md  -> Operation not permitted
 *     sh -c 'sh -c "echo > <routines>/x"' -> Operation not permitted
 *
 * The keychain line is the one that decides whether this is worth having: it is
 * what makes the signed-out first run go away while the fence stays on. Under
 * `(deny default)` that same command answers `Not logged in`.
 *
 * ## Read is denied for the log and allowed for the routines, and that is not an oversight
 *
 * The old profile refused reads of both, and the argument for refusing to let
 * the copilot read `routines/` was that a routine file names a project path and
 * carries a prompt. That argument does not survive this change: the copilot can
 * now read every one of those projects directly, so refusing it the folder that
 * *describes* them would be theatre — and `routines.list` is a read-tier tool
 * that hands it the same contents through the front door anyway.
 *
 * The log is different, and the difference is the whole idea. It is the record
 * of the copilot, kept for somebody else to read. Being able to check *which* of
 * its actions were recorded, and in what words, is the first move anybody makes
 * before shaping behaviour around a record. Nothing about the copilot's job
 * needs it — every call it makes is logged for it, and `log.note` is how it adds
 * a line of its own.
 *
 * ## It fails open, visibly, and that is the opposite of what confinement does
 *
 * `confineSpawn` throws when a boundary cannot be proven, and refusing to start
 * is right there: the grant screen promises a device is held inside a folder,
 * and the only thing keeping that sentence true is a session that cannot be held
 * not starting.
 *
 * This is not that. The fence protects the *record*, not the person's disk, so a
 * machine that cannot hold it is a machine with worse auditing — not a machine
 * where an agent has escaped. Refusing to start the copilot over it would be
 * refusing the whole feature on every platform but macOS, which is the failure
 * being corrected. So {@link buildRecordsFence} answers `null` rather than
 * throwing, {@link CopilotState} carries the reason, and Settings says which of
 * the two states this machine is in. A promise on screen that does not match the
 * code is the defect this project keeps hunting; a stated gap is not one.
 *
 * ## Limits, stated rather than discovered
 *
 *  - **macOS only.** Seatbelt is the only deny mechanism this repository has
 *    measured that can be applied to an otherwise-unconstrained process. The
 *    Linux namespace mechanism works by *replacing* the mount namespace, which
 *    is a jail by construction, and an AppContainer grants by ACL from a
 *    deny-everything baseline. Neither expresses "everything, except these
 *    few". Off macOS the fence is absent and says so.
 *  - **An ancestor can still be renamed.** The denies cover the fenced paths and
 *    everything under them, including the paths themselves — `mv` and `rm -rf`
 *    of a fenced directory are both refused, measured. What is not covered is
 *    renaming `<userData>` itself, which needs write on *its* parent. That would
 *    destroy the app's entire state rather than forge a record, it is equally
 *    available to every other session on the machine, and fencing it would mean
 *    fencing the person's `Library` directory.
 *  - **It is one process's rules.** Any other session on this machine can write
 *    these files, exactly as it always could. The fence makes the log something
 *    *the copilot* did not write, which is the only claim the Activity pane
 *    makes.
 */

import { execFile } from 'node:child_process'
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
} from 'node:fs'
import { randomBytes } from 'node:crypto'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { currentPlatform, type Platform } from '../platform/host'
import { within, type PathResolver } from './plan'
import { SANDBOX_EXEC, seatbeltCommand, seatbeltString } from './seatbelt'

const run = promisify(execFile)

/* ------------------------------------------------------------------ paths -- */

/**
 * The things the fence is around, as absolute paths.
 *
 * Composed here rather than imported from `routines/store.ts`,
 * `copilot-home.ts`, `remote/device-kind.ts` and `remote/device-auth.ts` —
 * which is the wrong way round and is deliberate. Those modules own where their
 * files live; this one has to name the same places, and an `import` chain from a
 * confinement module into the routine engine, or into the store that holds the
 * remote copilot grant, would make the fence depend on the thing it fences.
 * {@link recordsFenceAgrees} is the assertion that pins the spellings together,
 * and it is called from the tests those modules own.
 */
export interface RecordsFencePaths {
  /** `<userData>/routines` — the directory that *is* the routine database. */
  routines: string
  /** `<userData>/routine-state.json` — run counts, budgets, pause reasons. */
  routineState: string
  /** `<userData>/copilot-log` — `actions.jsonl` and its rolled generation. */
  log: string
  /**
   * `<userData>/remote/remote-device-kinds.json` — which paired devices are
   * **his own**, and which are guests.
   *
   * **This entry moved on 2026-08-19 and the move is the whole point.** It used
   * to fence `copilot-link.json`, the store of separate copilot connections. His
   * instruction deleted that store — *"if we are connecting as my device,
   * copilot automatically comes; if we connect as guest then copilot don't
   * come"* — and the permission it held did not disappear with it. It moved into
   * this file, which was not fenced at all.
   *
   * Leaving the fence where the file used to be would have been the worst
   * possible outcome of that change: a rule still written, pointed at a path
   * nothing creates, while the thing it was protecting sat writable one
   * directory along. `resolveRecordsPaths` warns about exactly this failure two
   * paragraphs down, and this is it arriving through a refactor rather than a
   * rename.
   *
   * What the fence stops, concretely. A kind is what decides whether a device
   * reaches the copilot at all, and `copilot-access.ts` reads it live on every
   * tool call. Without this line the copilot could write `"kind": "mine"` beside
   * a guest's device id and hand a stranger's phone full remote control of this
   * machine — including the `alter` tier, whose whole safety property is that
   * somebody deliberately authorised that device. That is **the copilot editing
   * the store that says who may drive the copilot**: the same category of
   * mistake as an audited process holding the pen over its own audit log, which
   * is the sentence this list was assembled around.
   *
   * It cannot mint a device out of nothing — a kind is only consulted for a
   * device id that `device-auth.ts` has already approved, and approving one
   * needs a pairing code read off this screen. What it could do without this
   * line is *promote* a device somebody already let in for one folder, which is
   * quite enough.
   */
  remoteCopilot: string
  /**
   * `<userData>/remote/remote-auth.json` — the device trust store.
   *
   * One layer below the grants and fenced for the same reason: flipping a
   * pending device to approved is a file edit, and approval is the human half
   * of pairing. It cannot be used to mint a credential the copilot does not
   * already know, because `device-auth.ts` stores scrypt hashes rather than
   * secrets — but "approve the phone that is sitting in the pending list" needs
   * no secret at all.
   */
  remoteAuth: string
}

/**
 * Where the fenced things are, resolved.
 *
 * Resolved through the same `realpathSync` every other rule in this directory
 * goes through, and for the same measured reason: `/var` is a symlink to
 * `/private/var` on macOS, Seatbelt matches the resolved name, and a rule
 * composed from the unresolved one names a path the kernel never sees. It cost
 * a measurement to find here too — the first probe of this fence, written
 * against `/tmp/...`, refused nothing at all and looked exactly like a working
 * profile.
 *
 * A path that does not exist yet resolves to itself, which is right: the rule
 * still names it, and the directory is created by the app before anything runs
 * inside the fence.
 */
export function recordsFencePaths(
  userData: string,
  resolver: PathResolver = realFsResolver,
): RecordsFencePaths {
  /*
   * `<userData>` is resolved first, and then the names are joined onto the
   * resolved parent — rather than each full path being resolved on its own.
   *
   * The difference only shows on a machine where something above `<userData>` is
   * a symlink, and there it is the difference between a fence and a decoration.
   * `realpathSync` throws for a path whose last component does not exist, and
   * most of these legitimately do not exist yet on a fresh install —
   * `routine-state.json` until the engine's first run, `copilot-log/` until the
   * copilot's, and both remote stores until somebody pairs a device. Resolving
   * them individually would fall back to the *unresolved* string for exactly
   * those, so the profile would name a path the kernel never sees and refuse
   * nothing at all. The parent always exists, so resolving it and then joining
   * gives a resolved answer for every one of them.
   */
  const root = resolver.real(userData)
  /*
   * The two remote stores are files inside a *directory* under `<userData>`, so
   * the same parent-first reasoning applies one level deeper: resolve
   * `<userData>/remote` and then join the names onto it. Resolving each file on
   * its own would fall back to the unresolved string on a fresh install — the
   * grant file does not exist until somebody grants something — and a Seatbelt
   * `literal` rule naming an unresolved path refuses nothing at all.
   */
  const remote = resolver.real(join(root, 'remote'))
  return {
    routines: resolver.real(join(root, 'routines')),
    routineState: resolver.real(join(root, 'routine-state.json')),
    log: resolver.real(join(root, 'copilot-log')),
    // The literal, not an import — see the header. `device-kind.ts` owns the
    // spelling and `recordsFenceAgrees` is what pins the two together.
    remoteCopilot: resolver.real(join(remote, 'remote-device-kinds.json')),
    remoteAuth: resolver.real(join(remote, 'remote-auth.json')),
  }
}

/** Every fenced path, in one list, for anything that needs to show them. */
export function recordsFenceList(paths: RecordsFencePaths): string[] {
  return [paths.routines, paths.routineState, paths.log, paths.remoteCopilot, paths.remoteAuth]
}

/**
 * The filesystem, for real.
 *
 * A local copy rather than `confine/index.ts`'s `realResolver`, so this module
 * can be imported without pulling in the whole confinement layer — including the
 * Windows launcher lookup, which touches `process.resourcesPath`.
 */
const realFsResolver: PathResolver = {
  real(path: string): string {
    try {
      return realpathSync(path)
    } catch {
      /*
       * A path that cannot be resolved is passed through unchanged, which is the
       * behaviour `confine/index.ts`'s resolver argues for and the right one
       * here too — several of the fenced paths do not exist until something
       * has run once, and the rule has to name them correctly before then.
       * {@link recordsFencePaths} is what makes the fallback safe: it resolves
       * the parent first, so an unresolvable child still yields a resolved path.
       */
      return path
    }
  },
  isDirectory(path: string): boolean {
    try {
      return statSync(path).isDirectory()
    } catch {
      return false
    }
  },
}

/* -------------------------------------------------------------- the profile -- */

export type RecordsFenceKind = 'seatbelt' | 'none'

/**
 * Whether this machine can hold the fence.
 *
 * Deliberately not `confinementKind`. That function answers "is there a measured
 * *jail* here", which on Linux is yes and is the wrong answer to this question:
 * the namespace mechanism confines by replacing the mount namespace, and there
 * is no way to say "everything, except these few paths" with it. Asking the
 * jail's question here would have shipped a fence on Linux that was really a
 * jail, or nothing at all with a sentence claiming otherwise.
 */
export function recordsFenceKind(platform: Platform = currentPlatform()): RecordsFenceKind {
  return platform === 'darwin' ? 'seatbelt' : 'none'
}

/** Why there is no fence on this platform. One sentence, per platform. */
export function recordsFenceUnavailable(platform: Platform): string {
  if (platform === 'win32') {
    return 'On Windows this app has no way to refuse one process a folder every other process may use, so the copilot could edit the routines and the action log the way any program you run could. What it did is still recorded; the record is not held against it.'
  }
  if (platform === 'linux') {
    return 'On Linux the only boundary this app has measured works by replacing the whole filesystem view, which is a jail rather than a fence, so the copilot could edit the routines and the action log the way any program you run could. What it did is still recorded; the record is not held against it.'
  }
  return 'No way to hold this app’s own records against the copilot has been measured on this platform.'
}

/**
 * The profile: allow everything, then refuse the fenced paths.
 *
 * Read it as the inverse of `seatbeltProfile`. That one starts at `(deny
 * default)` and opens the filesystem one directory at a time, because it is
 * describing a world. This starts at `(allow default)` and closes a few named doors,
 * because it is describing an exception — and the difference is the difference
 * between a copilot that cannot reach the keychain and one that can.
 *
 * Order does not matter here the way it does over there, because there is
 * nothing to override: `(allow default)` is the fallback rather than a rule, and
 * a `deny` beats it wherever it matches. Measured both ways round on macOS 27,
 * same result.
 */
export function recordsFenceProfile(paths: RecordsFencePaths): string {
  return [
    '(version 1)',
    '',
    '; Everything is allowed. This is not a jail: the process inside it is an',
    '; ordinary session with the person’s own account, their keychain, their',
    '; home directory and their repositories. See `confine/records.ts` for why',
    '; that is the right shape for a copilot and what it replaced.',
    '(allow default)',
    '',
    '; The routine database. A file dropped in here is a routine that really',
    '; fires on a real trigger, so an agent that could write one could author',
    '; its own next trigger — an automation loop with no human in it. Creating a',
    '; routine is an alter-tier act somebody confirms.',
    ';',
    '; Reading is deliberately still allowed: the copilot can read every project',
    '; these files name, and `routines.list` hands it the same contents through',
    '; the front door, so refusing the folder would be theatre.',
    `(deny file-write* (subpath ${seatbeltString(paths.routines)}))`,
    '',
    '; The engine’s own state — run counts, budgets, and why a routine was',
    '; paused. Writable, it is a way to zero a budget and un-pause a routine the',
    '; engine stopped after five consecutive failures, with no tool call, no',
    '; confirmation and no row in the log.',
    `(deny file-write* (literal ${seatbeltString(paths.routineState)}))`,
    '',
    '; The action log. Read as well as write, and the read half is the point: a',
    '; record of what something did is worth nothing if that same thing can',
    '; compose it, and checking which of your actions were recorded is the first',
    '; move anybody makes before shaping behaviour around a record. Nothing the',
    '; copilot does needs this file — every call it makes is written here for',
    '; it, and `log.note` is how it adds a line of its own.',
    `(deny file-read* file-write* (subpath ${seatbeltString(paths.log)}))`,
    '',
    '; The copilot connections, and what each may do. Writable, it is the store',
    '; that holds a permission *about this process*, editable by this process —',
    '; the audit-log argument one level up. A connection cannot be minted by',
    '; editing it, because a record with no credential is dropped on read and',
    '; the credential is a scrypt hash of a secret this process never sees. What',
    '; an edit could do is raise the tiers of a connection that exists, turning',
    '; a device somebody connected read-only into one that answers',
    '; confirmations, which is quite enough.',
    ';',
    '; Reading stays allowed, like the routines and unlike the log. The copilot',
    '; can already be told which devices hold what — a refusal that only stops it',
    '; *looking* would be theatre, and the thing worth stopping is the edit.',
    `(deny file-write* (literal ${seatbeltString(paths.remoteCopilot)}))`,
    '',
    '; The device trust store, one layer below the grants. Flipping a pending',
    '; device to approved is a file edit, and approval is the human half of',
    '; pairing. It cannot mint a credential — `device-auth.ts` stores scrypt',
    '; hashes — but approving a phone already sitting in the pending list needs',
    '; no secret at all.',
    `(deny file-write* (literal ${seatbeltString(paths.remoteAuth)}))`,
    '',
  ].join('\n')
}

/* --------------------------------------------------------------- the proof -- */

export interface RecordsFenceProof {
  held: boolean
  /** What was measured. Empty when it held. */
  detail: string
}

/**
 * How the proof runs a command. Injected only so a test can pin the failure
 * shapes without needing a machine on which either is true.
 */
export interface FenceRunner {
  (command: string, args: readonly string[]): Promise<{ stdout: string; stderr: string }>
}

const realRunner: FenceRunner = async (command, args) => {
  const result = await run(command, [...args], {
    timeout: 10_000,
    maxBuffer: 1024 * 1024,
    encoding: 'utf8',
  })
  return { stdout: result.stdout, stderr: result.stderr }
}

/**
 * Ask the machine, not the code, whether this profile fences anything.
 *
 * Three checks, and the middle one is the one this file could not do without.
 *
 *  1. **It runs things.** `/bin/echo <token>` under the profile has to print the
 *     token. A profile that will not start anything would pass check 3 by
 *     failing at everything, which is the exact shape of false confidence this
 *     project has shipped before.
 *  2. **It is not a jail.** A file outside the fence has to be writable. This
 *     check exists because the whole point of the change is that the copilot is
 *     an ordinary session; a fence that had quietly become restrictive would
 *     pass checks 1 and 3 while reintroducing everything that was wrong with the
 *     jail, and nothing else would notice.
 *  3. **The log cannot be appended to.** A canary line, written the way an agent
 *     would write one — an absolute path, `>>`, into a directory that exists.
 *
 * The directory is created first, and that is not tidiness: an append into a
 * directory that is not there fails with `No such file or directory`, which
 * looks exactly like a denial and would keep looking like one on the day the
 * fence stopped working.
 *
 * Run per start rather than cached, for the reason `proveConfinement` gives:
 * caching would answer a question about *this* profile with a measurement of a
 * different one.
 */
export async function proveRecordsFence(
  paths: RecordsFencePaths,
  platform: Platform = currentPlatform(),
  runner: FenceRunner = realRunner,
): Promise<RecordsFenceProof> {
  if (recordsFenceKind(platform) !== 'seatbelt') {
    return { held: false, detail: recordsFenceUnavailable(platform) }
  }

  const profile = recordsFenceProfile(paths)
  const token = randomBytes(16).toString('hex')

  let scratch: string
  try {
    mkdirSync(paths.log, { recursive: true, mode: 0o700 })
    scratch = mkdtempSync(join(realFsResolver.real(tmpdir()), 'records-fence-'))
  } catch (error) {
    return { held: false, detail: `could not prepare the test: ${describe(error)}` }
  }

  const outside = join(scratch, 'writable')
  const canary = join(paths.log, `.fence-probe-${token}`)

  try {
    if (within(outside, paths.log, platform) || within(outside, paths.routines, platform)) {
      return {
        held: false,
        detail: 'the temporary directory used to test the fence is inside it, so the test could not fail',
      }
    }

    const runs = await attempt(runner, profile, ['/bin/echo', token])
    if (!runs.stdout.includes(token)) {
      return {
        held: false,
        detail: `${SANDBOX_EXEC} would not run a command with this profile${tail(runs.error)}`,
      }
    }

    const wrote = await attempt(runner, profile, [
      '/bin/sh',
      '-c',
      `printf %s ${token} > ${shellQuote(outside)}`,
    ])
    if (!fileHas(outside, token)) {
      return {
        held: false,
        detail: `this profile refused an ordinary write outside the fence, so it is stricter than an ordinary session${tail(wrote.error)}`,
      }
    }

    await attempt(runner, profile, [
      '/bin/sh',
      '-c',
      `printf %s ${token} >> ${shellQuote(canary)}`,
    ])
    if (fileHas(canary, token)) {
      // Removed rather than left: it is a stray file in the folder the Activity
      // pane reads, and leaving it would be this function littering the very
      // directory it exists to protect.
      rmSync(canary, { force: true })
      return { held: false, detail: 'the action log could be written from inside the fence' }
    }

    return { held: true, detail: '' }
  } catch (error) {
    return { held: false, detail: describe(error) }
  } finally {
    rmSync(scratch, { recursive: true, force: true })
  }
}

/* ---------------------------------------------------------------- the fence -- */

/**
 * A proven fence, ready to wrap a spawn.
 *
 * `apply` is synchronous and does no proving, because the proving already
 * happened: `buildRecordsFence` either measured it and hands one of these back,
 * or measured it and hands back `null`. A wrapper that could still fail at the
 * moment of spawn would put the decision in the one place that cannot draw a
 * sentence about it.
 */
export interface RecordsFence {
  kind: RecordsFenceKind
  /** What it holds, so a pane can list it without recomputing. */
  paths: RecordsFencePaths
  apply(command: string, args: readonly string[]): { command: string; args: string[] }
}

export interface RecordsFenceResult {
  /** Null when this machine cannot hold it. Never throws. */
  fence: RecordsFence | null
  /** Why not, or null. */
  reason: string | null
}

/**
 * Measure the fence and hand back something to wrap a spawn with, or a reason.
 *
 * Never throws — see the header. The caller starts the copilot either way and
 * reports which of the two happened.
 */
export async function buildRecordsFence(input: {
  userData: string
  platform?: Platform
  runner?: FenceRunner
  resolver?: PathResolver
}): Promise<RecordsFenceResult> {
  const platform = input.platform ?? currentPlatform()
  const paths = recordsFencePaths(input.userData, input.resolver ?? realFsResolver)
  if (recordsFenceKind(platform) !== 'seatbelt') {
    return { fence: null, reason: recordsFenceUnavailable(platform) }
  }

  const proof = await proveRecordsFence(paths, platform, input.runner ?? realRunner)
  if (!proof.held) {
    return {
      fence: null,
      reason: `This app’s own routines and action log could not be held against the copilot on this machine: ${proof.detail}`,
    }
  }

  const profile = recordsFenceProfile(paths)
  return {
    fence: {
      kind: 'seatbelt',
      paths,
      apply: (command, args) => seatbeltCommand(profile, command, args),
    },
    reason: null,
  }
}

/* ------------------------------------------------------------------ helpers -- */

/**
 * The assertion that keeps this module's spelling of the fenced paths and the
 * owning modules' spelling from drifting apart.
 *
 * Exported and called from the tests that already own those paths, rather than
 * this module importing `routines/store.ts` and `copilot-home.ts` — a
 * confinement module that imported the routine engine would make the fence
 * depend on the thing it fences, and the import would be the first thing a
 * future refactor broke silently.
 */
export function recordsFenceAgrees(
  paths: RecordsFencePaths,
  /*
   * The two remote stores are optional in this argument, and only in it.
   *
   * Every caller of this function is a test in the module that *owns* one of
   * these paths, and the modules own different subsets: `routines/store.ts`
   * knows nothing about the copilot log and `copilot-home.ts` knows nothing
   * about the grant file. Requiring all five would force each of those tests to
   * restate paths it has no business knowing, which is how a pin becomes a copy
   * of the thing it is pinning. A caller checks what it owns.
   */
  actual: {
    routines: string
    routineState: string
    log: string
    remoteCopilot?: string
    remoteAuth?: string
  },
  resolver: PathResolver = realFsResolver,
): boolean {
  const agrees = (mine: string, theirs: string | undefined): boolean =>
    theirs === undefined || mine === resolver.real(theirs)
  return (
    paths.routines === resolver.real(actual.routines) &&
    paths.routineState === resolver.real(actual.routineState) &&
    paths.log === resolver.real(actual.log) &&
    agrees(paths.remoteCopilot, actual.remoteCopilot) &&
    agrees(paths.remoteAuth, actual.remoteAuth)
  )
}

/** Single-quote for `/bin/sh`, which is the only shell the proof ever runs. */
function shellQuote(path: string): string {
  return `'${path.split("'").join(`'\\''`)}'`
}

function fileHas(path: string, token: string): boolean {
  try {
    return readFileSync(path, 'utf8').includes(token)
  } catch {
    return false
  }
}

async function attempt(
  runner: FenceRunner,
  profile: string,
  argv: readonly string[],
): Promise<{ stdout: string; stderr: string; error: unknown }> {
  const launch = seatbeltCommand(profile, argv[0] as string, argv.slice(1))
  try {
    const ran = await runner(launch.command, launch.args)
    return { ...ran, error: null }
  } catch (error) {
    // `execFile` rejects on a non-zero exit and hangs whatever the process
    // managed to write off the error object. Every refusal in this file is a
    // non-zero exit, so a caller that only read the resolved value would throw
    // away the answer — the lesson `copilot-session.ts` paid for with a
    // sign-in probe that could never report "signed out".
    return { stdout: streamOf(error, 'stdout'), stderr: streamOf(error, 'stderr'), error }
  }
}

function streamOf(error: unknown, name: 'stdout' | 'stderr'): string {
  const value = (error as Record<string, unknown> | null)?.[name]
  return typeof value === 'string' ? value : ''
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function tail(error: unknown): string {
  const stderr = streamOf(error, 'stderr').trim()
  return stderr === '' ? '' : `: ${stderr.split('\n').slice(-1)[0]}`
}

/**
 * What a confined session may touch, as a value.
 *
 * ## Why a plan is a value and not a profile string
 *
 * The thing that actually confines a session on macOS is a Seatbelt profile —
 * an S-expression, generated in `seatbelt.ts`. If this module built that string
 * directly there would be exactly one way to check it: read it. A plan is a list
 * of directories instead, so the interesting questions — *is the owner's home in
 * the writable set, is another device's folder in the readable set, did the
 * granted folder survive being a symlink* — are asked of an array in a test
 * rather than of a regular expression over a profile.
 *
 * It also keeps the one platform-independent decision in one place. Windows and
 * Linux have nothing resembling Seatbelt, and if either ever grows a
 * confinement here it will need the same answer to "which directories", built
 * from the same inputs. Only the last step differs.
 *
 * ## Every path in a plan is a realpath, and that is not tidiness
 *
 * Measured on macOS 27, and it is the difference between a boundary and no
 * boundary at all:
 *
 *     profile says the realpath, process runs with cwd = the symlink path  → works
 *     profile says the symlink path, process runs with cwd = the realpath  → DENIED
 *
 * Seatbelt matches on the resolved path. A profile written with `/tmp/x` grants
 * nothing to a process opening `/private/tmp/x`, which is the same file. So a
 * plan built from an unresolved path does not produce a leaky sandbox — it
 * produces a session that cannot open its own folder. Both directions are wrong
 * and only one of them is loud, so the resolution happens here, once, and
 * {@link sessionPlan} takes the resolver as an argument so a test can pin it.
 *
 * ## What is deliberately *not* decided here
 *
 * Whether to confine at all. That is `index.ts`, because it depends on the
 * platform and on a live probe of the machine, and a plan is worth computing
 * even on a platform that cannot enforce it — the test suite computes plans for
 * platforms it is not running on, which is the only way the Windows answer can
 * be pinned from a Mac.
 */

import { join, posix, win32 } from 'node:path'
import { isWindows, type Platform } from '../platform/host'

/**
 * The path rules for the platform being asked about, rather than for the one
 * running the test.
 *
 * The same seam, for the same reason, as `rules()` in
 * `remote/session-create.ts`: `node:path` is whichever implementation the
 * current OS uses, so on a Mac `isAbsolute('C:\\Users\\Asad')` is false and
 * `normalize` leaves backslashes alone. Every Windows case in the suite would be
 * answered by the POSIX parser and would pass or fail for a reason that has
 * nothing to do with Windows — which is exactly what happened the first time
 * this file was written without it.
 */
function rules(platform: Platform): typeof posix {
  return isWindows(platform) ? win32 : posix
}

/**
 * The directories one session may reach, resolved and de-duplicated.
 *
 * Three lists rather than one with flags, because the difference between them
 * is the whole security argument and a boolean on a struct hides it. Writable is
 * the granted folder and the session's own state. Readable is the operating
 * system and the tools — a session that cannot read `/usr/lib` cannot start a
 * process at all. `readableFiles` is for the handful of individual files that
 * have to be reachable without their directory being reachable, which is not a
 * refinement: the credential helper lives beside *every other device's* guest
 * git directory, and granting its folder would hand one device another device's
 * git identity.
 */
export interface ConfinementPlan {
  /** Read and write. Realpaths, no duplicates, no ancestors of each other. */
  writable: readonly string[]
  /** Read only. Realpaths. */
  readable: readonly string[]
  /** Individual files that may be read and executed. Realpaths. */
  readableFiles: readonly string[]
}

/**
 * The directories a macOS session needs to be able to read before it can run
 * anything at all.
 *
 * Every entry was arrived at by removing it and watching what broke, not by
 * reading a manual page. Two are worth writing down because neither is
 * guessable:
 *
 *  - **`/` itself.** Not a subpath — the root *directory*. Without read access
 *    to it, `node` aborts inside `InitializeOncePerProcessInternal` before it
 *    reaches a single line of JavaScript, with SIGABRT and no message. Every
 *    other tool tested survived; node did not, and node is what the agent CLIs
 *    are.
 *  - **`/private/var/select`.** `/usr/bin/git` on a Mac is a shim that asks
 *    `xcode-select` where the real git lives, and that answer is a symlink under
 *    here. Without it every git command dies before it starts.
 *
 * `/opt` rather than `/opt/homebrew` because a Homebrew install on Apple silicon
 * is the common case and an Intel one under `/usr/local` is already covered by
 * `/usr`; naming the vendor directory would leave anything else installed under
 * `/opt` unreadable for no reason. Nothing under `/opt` is a personal secret.
 *
 * `/Library` is the *system* library, not `~/Library`. The home one is where the
 * keychain and every application's data live and is never on this list.
 */
export const MACOS_SYSTEM_READ_ROOTS: readonly string[] = [
  '/System',
  '/usr',
  '/bin',
  '/sbin',
  '/Library',
  '/Applications',
  '/opt',
  '/private/etc',
  '/private/var/db',
  '/private/var/select',
]

/**
 * Directories that must never enter a plan, whatever asks for them.
 *
 * A guard rather than a hope. The tool-root walk below derives directories from
 * the session's own `PATH`, which is read from the user's login shell and can
 * therefore contain anything at all — including `$HOME`, `/`, or the parent of
 * the folder being granted. Any one of those quietly turns the boundary into
 * decoration while every test that checks "can the session read its own folder"
 * still passes.
 */
export interface PlanGuards {
  /** The account's home directory. Never readable, never writable. */
  home: string
  /** Folders no derived root may contain, because containing them defeats them. */
  protect: readonly string[]
}

/**
 * One path, compared the way the filesystem compares it.
 *
 * Trailing separators are dropped because `/a/b` and `/a/b/` are one directory
 * and a plan that held both would emit two rules for it. Case is folded on
 * Windows only, matching `sameFolder` in `remote/session-create.ts` — the same
 * fact about the same filesystems, and the two must not disagree about whether
 * `C:\Users\Asad` and `c:\users\asad` are one place.
 */
function canonical(path: string, platform: Platform): string {
  const { normalize, sep } = rules(platform)
  const trimmed = normalize(path).replace(/[/\\]+$/, '')
  const kept = trimmed === '' ? sep : trimmed
  return isWindows(platform) ? kept.toLowerCase() : kept
}

/** Is `inner` the same directory as `outer`, or inside it? */
export function within(inner: string, outer: string, platform: Platform): boolean {
  const { sep } = rules(platform)
  const a = canonical(inner, platform)
  const b = canonical(outer, platform)
  if (a === b) return true
  // The separator matters: without it `/a/bc` counts as inside `/a/b`, which
  // would let a folder named `Projects-old` inherit the grant on `Projects`.
  return a.startsWith(b.endsWith(sep) ? b : `${b}${sep}`)
}

/**
 * Drop anything already covered by something else on the list.
 *
 * Not cosmetic. A plan that lists both `/opt` and `/opt/homebrew` produces two
 * rules that mean one thing, and the day somebody reads the profile to answer
 * "what can this session see" they have to work out that the second is
 * redundant. Worse, a plan holding both `<granted>` and `<granted>/node_modules`
 * looks like it says something about `node_modules` and says nothing.
 */
export function collapse(paths: readonly string[], platform: Platform): string[] {
  const kept: string[] = []
  // Shortest first, so a container is always seen before the thing it contains.
  for (const path of [...paths].sort((a, b) => a.length - b.length)) {
    if (kept.some((seen) => within(path, seen, platform))) continue
    kept.push(path)
  }
  return kept
}

/* --------------------------------------------------------------- tool roots -- */

/**
 * How a directory is turned into a real one, and how its existence is checked.
 *
 * Injected rather than imported so the whole of this file is testable without a
 * filesystem — and so a test on this Mac can pin what the plan does with a
 * Windows-shaped `PATH`, which is the same argument `platform/host.ts` makes at
 * length for taking the platform as an argument.
 */
export interface PathResolver {
  /** `fs.realpathSync`, or a fake. Must return the input when it cannot resolve. */
  real(path: string): string
  /** True when the path is a directory that exists. */
  isDirectory(path: string): boolean
}

/**
 * The directories the tools on this session's `PATH` need to be readable.
 *
 * ## Why the PATH at all
 *
 * Because the tools are not in the granted folder and never will be. `node`,
 * `git`, `npm` and the agent CLIs live wherever they were installed, and a
 * confinement that cannot reach them is a confinement nobody will keep switched
 * on. The system roots above cover Homebrew and Xcode; they do not cover an
 * agent CLI installed under the user's own home, which is where two of the four
 * this app supports put themselves.
 *
 * ## The `bin` rule, and its exact cost
 *
 * A `PATH` entry is nearly always `<prefix>/bin`, and the libraries the binaries
 * in it load are in `<prefix>/lib` — an nvm-installed `npm` is JavaScript under
 * `<prefix>/lib/node_modules` and cannot run if only `<prefix>/bin` is readable.
 * So when a `PATH` entry is named `bin`, the prefix above it is added too.
 *
 * That is a real widening and it is stated rather than hidden: a tool installed
 * under the home directory makes its *own* prefix readable. `~/.local/bin` on
 * the PATH means `~/.local` is readable. It does not mean anything else under
 * the home directory is, and the guards below are what make that true rather
 * than merely intended — a prefix that turns out to be `$HOME`, the root, or a
 * folder containing something in `protect` is dropped, so a `PATH` containing
 * `~/bin` widens nothing.
 *
 * Directories that do not exist are dropped rather than emitted. A stale `PATH`
 * entry is extremely common, and a profile that names a missing directory is a
 * rule nobody can evaluate against reality later.
 */
export function toolRoots(
  path: string,
  resolver: PathResolver,
  guards: PlanGuards,
  platform: Platform,
): string[] {
  const { isAbsolute, sep } = rules(platform)
  const separator = isWindows(platform) ? ';' : ':'
  const roots: string[] = []
  const forbidden = [guards.home, ...guards.protect]

  for (const raw of path.split(separator)) {
    const entry = raw.trim()
    if (entry === '' || !isAbsolute(entry)) continue
    if (!resolver.isDirectory(entry)) continue
    const dir = resolver.real(entry)

    // Anything the system roots already cover is not worth a second rule. This
    // is where `/usr/bin`, `/bin` and `/opt/homebrew/bin` drop out.
    const covered = (candidate: string): boolean =>
      MACOS_SYSTEM_READ_ROOTS.some((root) => within(candidate, root, platform))

    if (!covered(dir) && !forbidden.some((bad) => within(bad, dir, platform))) roots.push(dir)

    // `<prefix>/bin` → `<prefix>`. Only for a directory actually called `bin`:
    // every other shape is somebody's own directory of scripts and its parent is
    // none of this app's business.
    const parts = dir.split(/[/\\]/)
    if (parts[parts.length - 1] !== 'bin') continue
    const prefix = dir.slice(0, dir.length - `${sep}bin`.length)
    if (prefix === '' || !isAbsolute(prefix)) continue
    if (covered(prefix)) continue
    // The guard that makes the paragraph above true: a prefix that *contains*
    // the home directory, the granted folder or any writable root is refused
    // outright, because reading it would read them.
    if (forbidden.some((bad) => within(bad, prefix, platform))) continue
    if (canonical(prefix, platform) === canonical(guards.home, platform)) continue
    roots.push(prefix)
  }

  return collapse(roots, platform)
}

/* ------------------------------------------------------------------- plans -- */

export interface SessionPlanInput {
  /** The granted folder, exactly as the grant records it. Resolved here. */
  folder: string
  /**
   * The session's own home directory, made by the app, one per device.
   *
   * A confined session cannot read the account's home, so it needs one of its
   * own or every tool that writes a cache, a history file or a login lands on
   * "permission denied" in a directory the person cannot see. `HOME` points
   * here; see `deviceHome` in `index.ts` for where it lives and why.
   */
  home: string
  /** The account's real home directory. Never enters the plan; guards it. */
  accountHome: string
  /** The session's `PATH`, as `loginPath()` resolved it. */
  path: string
  /**
   * Other directories the session must be able to write.
   *
   * Today: the device's guest git directory, which holds the redirected global
   * git config and the `gh` config the credential work already gives it. Passed
   * in rather than derived, because this module has no business knowing how
   * `credentials.ts` lays its storage out.
   */
  writable?: readonly string[]
  /**
   * Individual files the session must be able to read and execute.
   *
   * The credential helper, and nothing else so far. It sits one level above the
   * per-device directories, so it can only be reached as a file — granting its
   * folder would grant every other device's git identity along with it.
   */
  files?: readonly string[]
  resolver: PathResolver
  platform: Platform
}

/**
 * The plan for one session.
 *
 * Order of construction matters exactly once and it is the reason the guards are
 * assembled before the tool roots: the granted folder and every writable
 * directory have to be known before `PATH` is walked, or a `PATH` entry whose
 * prefix happens to contain the granted folder would be added as a *read* root
 * covering it — which is not a leak of the folder (it is already writable) but
 * is a leak of everything beside it.
 */
export function sessionPlan(input: SessionPlanInput): ConfinementPlan {
  const { platform, resolver } = input

  const writable = collapse(
    [input.folder, input.home, ...(input.writable ?? [])].map((path) => resolver.real(path)),
    platform,
  )

  const guards: PlanGuards = {
    home: resolver.real(input.accountHome),
    protect: writable,
  }

  const readable = collapse(
    [...MACOS_SYSTEM_READ_ROOTS, ...toolRoots(input.path, resolver, guards, platform)],
    platform,
  )

  // A file already inside a directory the session can read needs no rule of its
  // own, and one inside a writable directory certainly does not.
  const files = (input.files ?? [])
    .map((file) => resolver.real(file))
    .filter(
      (file) =>
        !readable.some((root) => within(file, root, platform)) &&
        !writable.some((root) => within(file, root, platform)),
    )

  return { writable, readable, readableFiles: [...new Set(files)] }
}

/**
 * The directory that holds one home per device, inside the app's storage.
 *
 * A function rather than a `join` spelled out at each site, because there are
 * now two sites and they are in different subsystems: the spawn path makes the
 * homes, and the transcript layer reads them — a confined session's
 * conversations live under one of these, which is the whole of why chat mode and
 * the cost pane can see them at all (see `transcript.ts`). Two spellings of one
 * directory name is how the reader ends up looking somewhere the writer never
 * writes, which is the bug this function exists to make impossible.
 */
export function deviceHomesRoot(storageDir: string): string {
  return join(storageDir, 'device-home')
}

/**
 * Where one device's confined home lives.
 *
 * Per device, beside the guest git directories and keyed the same way, so the
 * two halves of "what this device's sessions run as" sit next to each other on
 * disk. Per device rather than per session for the reason `guestGitDir` gives:
 * a fresh directory per spawn means nothing a person configures survives their
 * own next session, plus a folder of litter.
 */
export function deviceHomeDir(root: string, deviceKey: string): string {
  return join(root, deviceKey)
}

/**
 * The environment a confined session runs with, over and above everything the
 * app already sets.
 *
 * Two variables, and both are the difference between working and not:
 *
 *  - **`HOME`.** The account's home is unreadable inside the boundary. Left
 *    pointing there, `zsh -l` cannot read its own startup files, `npm` cannot
 *    write its cache, and the agent CLI cannot write the login the person just
 *    completed. Pointed at the device's own home, all three work and none of
 *    them can see the owner's.
 *  - **`TMPDIR`.** Same argument, and it is the one that bites first: the
 *    default is a per-account directory shared with every other program the
 *    account runs, so it is outside the boundary by design, and a session
 *    without a writable temp cannot run `git commit`.
 *
 * The `PATH` is deliberately **not** in here. The tools live outside the granted
 * folder, they stay on the `PATH`, and the plan makes their directories readable
 * rather than the `PATH` pretending they are not there. A confinement that
 * quietly shortened the `PATH` would produce "command not found" for `git`,
 * which reads as a broken app rather than as a boundary.
 *
 * `tmp` is a child of the device's home rather than a sibling so that one
 * directory is the whole of a device's session state: delete it and the device
 * starts again from nothing, with no second place to remember.
 */
export function confinedEnv(home: string): Record<string, string> {
  // `posix.join`, not the host's `join`. Confinement exists on macOS and Linux
  // and nowhere else — `confinementKind('win32')` answers 'none' — so every path
  // this file composes is a POSIX path by definition. Using the host's joiner
  // made the Windows CI runner answer `\app-storage\…\tmp` for a boundary
  // Windows cannot even have, and failed the release build on it.
  return { HOME: home, TMPDIR: posix.join(home, 'tmp') }
}

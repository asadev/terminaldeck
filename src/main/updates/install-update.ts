/**
 * Replacing the running app with a staged one, by hand.
 *
 * This is the swap Squirrel.Mac would do, written out. It exists because this
 * app is unsigned — `codesign -dv "/Applications/Terminal Deck.app"` reports
 * `Signature=adhoc`, `TeamIdentifier=not set`, and the bundle has no
 * `Contents/_CodeSignature` directory at all (checked again while writing this,
 * on the 286 MB bundle actually installed) — and Squirrel refuses to install
 * over a bundle whose signature it cannot verify. `updates/updater.ts` reports
 * that as `unsupported`. This module is the other half of the answer: a swap
 * that does not need a signature, and therefore has to be careful in every
 * place Squirrel would have been careful for us.
 *
 * ## Everything here is written around one fact
 *
 * **This deletes the user's application.** Not a cache, not a download — the
 * app itself, 286 MB of it, the thing they double-click. Every branch below is
 * chosen so that the worst outcome is "nothing happened and here is why",
 * never "the app is gone".
 *
 * Three rules follow from that, and they are the whole design:
 *
 *  1. **Refuse before quitting, never after.** Once `app.quit()` has been
 *     called there is no window left to show an error in and no process left
 *     to recover in. So every check that can be made — the path shape, the
 *     write permissions, the staged bundle, the version — is made while the
 *     app is still up, and a refusal is a returned value the panel can print.
 *     Quitting and *then* discovering the app cannot be written is the worst
 *     outcome available and it is the one this module is shaped to avoid.
 *  2. **Move, never delete.** The current bundle is renamed aside, not
 *     removed. Within a volume a rename is atomic and instantly reversible;
 *     a delete is neither. The backup is removed only after the new bundle is
 *     verified in place, and if anything fails in between the backup goes back
 *     and the old app is relaunched. A failed update must leave the user with
 *     an application.
 *  3. **Only paths this module constructed.** The install path is derived from
 *     `app.getPath('exe')` by walking up exactly three levels and asserting the
 *     shape — see {@link installedBundlePath}. Nothing is searched for, nothing
 *     is globbed, and a path that does not have the shape of an app bundle is
 *     refused rather than guessed at. The one `rm -rf` in the generated script
 *     is guarded by a `case` that re-checks the backup is the path we named.
 *
 * ## Why a shell script and not Node
 *
 * A running `.app` cannot replace itself: the swap has to happen after this
 * process is gone, and it therefore cannot be done *by* this process. The
 * helper is spawned `detached` with `stdio: 'ignore'` and `unref()`ed so it
 * outlives the app, and it is `/bin/sh` rather than another Electron because
 * the bundle holding Electron is the thing being moved.
 *
 * `/bin/sh` is invoked explicitly rather than relying on the shebang and the
 * exec bit, so a staging directory mounted `noexec` cannot break the swap.
 *
 * ## Quoting
 *
 * Every path is baked into the script as a single-quoted literal by
 * {@link shellQuote}. The app is called "Terminal Deck.app" — the space is in
 * the product name — and it sits under a parent the user chose. An unquoted
 * `$INSTALL` here would `mv` two half-paths, and the half that is
 * `/Applications/Terminal` does not exist, so the failure would land in the
 * middle of the swap rather than before it.
 *
 * ## What is injected
 *
 * `fs`, `spawn`, `quit` and the environment all arrive as arguments, so the
 * entire decision tree is exercisable without an application on disk. The
 * script's *own* behaviour cannot be faked that way and is not: the tests
 * generate the real script and run it against bundles made of ordinary
 * directories, including the rollback and the timeout.
 *
 * Nothing in this file imports `electron`.
 */

import { constants as fsConstants } from 'node:fs'
import { join } from 'node:path'

/* ------------------------------------------------------------------ seams -- */

/**
 * The slice of `node:fs/promises` this module uses.
 *
 * Written as the narrowest surface that still fits the real module, so a test
 * can satisfy it with an object literal. A test asserts the real
 * `fs/promises` is assignable to it, which keeps the seam honest at compile
 * time without loading anything.
 */
export interface InstallFs {
  access(path: string, mode: number): Promise<void>
  stat(path: string): Promise<{ isDirectory(): boolean }>
  mkdir(path: string, options: { recursive: true }): Promise<unknown>
  writeFile(path: string, data: string, options: { mode: number }): Promise<void>
  appendFile(path: string, data: string): Promise<void>
  readFile(path: string, encoding: 'utf8'): Promise<string>
}

/**
 * The one child this module ever starts, and the only part of it we touch.
 *
 * `pid` is optional rather than `number | undefined` because that is what
 * `ChildProcess` declares, and a required-but-undefined property is not the
 * same type — the real `spawn` would not fit the seam. A test asserts it still
 * does, which is how this was caught.
 */
export interface SpawnedHelper {
  pid?: number | undefined
  unref(): void
}

/**
 * `node:child_process`'s `spawn`, narrowed to the call this module makes.
 *
 * The options are spelled out rather than left open because the three flags in
 * them are load-bearing: without `detached` the helper dies with the app it is
 * waiting for, and without `stdio: 'ignore'` it inherits pipes that keep it
 * tied to a parent that is about to exit.
 */
export type SpawnLike = (
  command: string,
  args: string[],
  options: { detached: boolean; stdio: 'ignore'; cwd: string },
) => SpawnedHelper

/* ------------------------------------------------------------ environment -- */

/** The facts about the running build, passed in so the decision stays pure. */
export interface InstallEnvironment {
  /** `process.platform`. */
  platform: NodeJS.Platform
  /** `app.getPath('exe')` — the binary inside the bundle to be replaced. */
  exePath: string
}

/* ------------------------------------------------------------------ paths -- */

/**
 * The `.app` the running executable belongs to, or null when the path does not
 * have that shape.
 *
 * Derived by walking up exactly three levels — `<bundle>.app/Contents/MacOS/
 * <binary>` — and asserting every one of those segments, rather than by
 * searching the string for `.app`. The difference matters: a substring search
 * matches a directory this module itself creates (`Terminal Deck.app.old-…`)
 * and matches a user directory called `Photos.app backups`. This module then
 * hands the result to `mv` and `rm -rf`, so a near-miss is not a wrong string,
 * it is the wrong directory removed from someone's disk.
 *
 * Walking up three levels is not on its own enough, because a nested helper —
 * `…/Terminal Deck.app/Contents/Frameworks/Terminal Deck Helper.app/Contents/
 * MacOS/Terminal Deck Helper` — has exactly that shape too, and resolving to it
 * would point the swap at a bundle *inside* the installed app: the helper gets
 * renamed aside, the entire new application is moved into `Contents/Frameworks`
 * under the helper's name, and the `rm -rf` then removes the real helper. The
 * outcome is a corrupted installation rather than an updated one. So any
 * ancestor segment ending in `.app` is refused as well — an installed
 * application is never nested inside another bundle.
 *
 * Anything that is not exactly the expected shape returns null and the caller
 * refuses. Refusing to update is a recoverable outcome; guessing is not.
 */
export function installedBundlePath(exePath: string): string | null {
  // Relative paths are refused outright: they resolve against a working
  // directory this module does not control and cannot verify.
  if (!exePath.startsWith('/')) return null

  const segments = exePath.split('/')
  if (segments.length < 4) return null

  const binary = segments[segments.length - 1]
  const macos = segments[segments.length - 2]
  const contents = segments[segments.length - 3]
  const bundle = segments[segments.length - 4]

  if (binary === '') return null
  if (macos !== 'MacOS' || contents !== 'Contents') return null
  // `.app` alone is a hidden directory named `.app`, not a bundle.
  if (!bundle.endsWith('.app') || bundle === '.app') return null

  // Nested inside another bundle: a helper, a plugin, or a copy someone put
  // inside an app's Resources. Never the bundle an update replaces.
  for (let i = 0; i < segments.length - 4; i += 1) {
    if (segments[i].endsWith('.app')) return null
  }

  return segments.slice(0, segments.length - 3).join('/')
}

/** The parent directory a bundle is renamed within. Also on the same volume. */
export function bundleParent(bundlePath: string): string {
  const cut = bundlePath.lastIndexOf('/')
  // A bundle at the root of a volume has `/` as its parent, not the empty string.
  return cut <= 0 ? '/' : bundlePath.slice(0, cut)
}

/** The executable directory every real bundle has, and the marker we check for. */
export function bundleExecutableDir(bundlePath: string): string {
  return `${bundlePath}/Contents/MacOS`
}

/** Where the bundle's version lives. */
export function bundleInfoPlist(bundlePath: string): string {
  return `${bundlePath}/Contents/Info.plist`
}

/**
 * Where the current bundle is moved to before the new one takes its place.
 *
 * Beside the bundle, so the rename stays inside one volume and therefore stays
 * atomic — a backup in `/tmp` or under `~/Library` can land on a different
 * mount, at which point `mv` degrades into copy-then-delete and the "instantly
 * reversible" property this whole design rests on is gone.
 *
 * The `.old-<millis>` suffix is also the shape the script's `rm -rf` guard
 * checks, so it is not only a name.
 */
export function backupPathFor(bundlePath: string, at: number): string {
  return `${bundlePath}.old-${at}`
}

/** The name of the generated helper inside the staging directory. */
export const SCRIPT_NAME = 'install-swap.sh'
/** The name of the log both halves append to. */
export const LOG_NAME = 'install-swap.log'

/* ---------------------------------------------------------------- version -- */

/**
 * `CFBundleShortVersionString` from an XML `Info.plist`, or null.
 *
 * electron-builder writes XML plists and the shipped bundle is one — `file`
 * reports "XML 1.0 document text" for both `/Applications/Terminal Deck.app`
 * and the freshly built `release/mac-arm64` copy, and both carry
 * `<string>0.1.0</string>`. A binary plist would need `plutil`, and shelling
 * out to read a version before deciding whether to replace an application is a
 * dependency this does not need: an unreadable version is reported as
 * unreadable and the install is refused, which is the safe direction.
 */
export function readShortVersion(plistXml: string): string | null {
  const match = /<key>\s*CFBundleShortVersionString\s*<\/key>\s*<string>([^<]*)<\/string>/.exec(
    plistXml,
  )
  const value = match?.[1]?.trim()
  return value === undefined || value === '' ? null : value
}

/** Split a version into its release numbers and its prerelease identifiers. */
function splitVersion(version: string): { release: number[]; prerelease: string[] } {
  // Build metadata is ignored: semver says it takes no part in precedence, and
  // electron-builder puts nothing there anyway.
  const withoutBuild = version.trim().replace(/^v/, '').split('+')[0]
  const [releasePart, ...prereleaseParts] = withoutBuild.split('-')
  const release = releasePart.split('.').map((part) => {
    const n = Number.parseInt(part, 10)
    return Number.isFinite(n) ? n : 0
  })
  const prerelease = prereleaseParts.join('-').split('.').filter((p) => p !== '')
  return { release, prerelease }
}

/**
 * Semver precedence, enough of it: -1, 0 or 1.
 *
 * Written here rather than imported. `semver` is on disk as a transitive
 * dependency of electron-updater, but importing a package this project does
 * not declare is a runtime failure waiting for the day the tree hoists
 * differently, and `package.json` is not this module's to edit.
 *
 * What it implements is the part that decides installs: numeric release
 * segments compared left to right, a missing segment treated as zero, and a
 * prerelease sorting *below* the release it belongs to, with its identifiers
 * compared numerically when both are numeric and lexically otherwise. That is
 * semver §11 minus build metadata.
 */
export function compareVersions(a: string, b: string): number {
  const left = splitVersion(a)
  const right = splitVersion(b)

  const length = Math.max(left.release.length, right.release.length)
  for (let i = 0; i < length; i += 1) {
    const l = left.release[i] ?? 0
    const r = right.release[i] ?? 0
    if (l !== r) return l < r ? -1 : 1
  }

  // 1.0.0-beta precedes 1.0.0; a release with no prerelease wins.
  if (left.prerelease.length === 0 && right.prerelease.length === 0) return 0
  if (left.prerelease.length === 0) return 1
  if (right.prerelease.length === 0) return -1

  const idents = Math.max(left.prerelease.length, right.prerelease.length)
  for (let i = 0; i < idents; i += 1) {
    const l = left.prerelease[i]
    const r = right.prerelease[i]
    // A shorter set of identifiers precedes a longer one when equal so far.
    if (l === undefined) return -1
    if (r === undefined) return 1
    if (l === r) continue
    const ln = /^\d+$/.test(l) ? Number.parseInt(l, 10) : null
    const rn = /^\d+$/.test(r) ? Number.parseInt(r, 10) : null
    if (ln !== null && rn !== null) return ln < rn ? -1 : 1
    // Numeric identifiers always have lower precedence than alphanumeric ones.
    if (ln !== null) return -1
    if (rn !== null) return 1
    return l < r ? -1 : 1
  }
  return 0
}

/* ------------------------------------------------------------- the script -- */

/**
 * One argument, as a shell word that cannot be anything else.
 *
 * Single quotes disable every expansion `sh` has, so the only character that
 * needs handling is the single quote itself: close the string, emit an escaped
 * quote, reopen. `it's.app` becomes `'it'\''s.app'`, which `sh` reads back as
 * the original. Nothing else is special inside single quotes — not `$`, not a
 * space, not a newline, not a backslash.
 */
export function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`
}

/** Everything the helper needs, already decided. */
export interface SwapPlan {
  /** The process to wait for: the app being replaced. */
  pid: number
  /** The bundle to replace. */
  bundlePath: string
  /** The bundle to put there. */
  stagedBundlePath: string
  /** Where the current bundle is moved to first. */
  backupPath: string
  /** Appended to at every step. */
  logPath: string
  /** `/usr/bin/open` in production; a recording stub in the script's own tests. */
  openBinary: string
  /** Seconds between polls of the pid. */
  pollSeconds: number
  /** How many polls before giving up and touching nothing. */
  maxPolls: number
  /** See {@link InstallOptions.clearQuarantine}. */
  clearQuarantine: boolean
}

/**
 * Exit codes the helper can end on. Nobody reaps it — they exist so the log
 * and the code agree, and so a future reader can tell the four failures apart.
 */
export const SWAP_EXIT = {
  ok: 0,
  /** The app never exited. Nothing was moved. */
  timeout: 3,
  /** The staged bundle was gone or malformed. Nothing was moved. */
  stagedInvalid: 4,
  /** The current bundle could not be moved aside. It is untouched. */
  backupFailed: 5,
  /** Rolled back; the original app is back where it was. */
  rolledBack: 7,
  /** Rollback itself failed. The original is at the backup path. */
  rollbackFailed: 8,
} as const

/**
 * The helper, as text.
 *
 * `set -u` but deliberately **not** `set -e`: every command below has its
 * failure handled explicitly, and `-e` would abort the rollback halfway
 * through — turning the one path that exists to save the user's app into
 * another way to lose it.
 */
export function swapScript(plan: SwapPlan): string {
  const q = shellQuote

  // The three numbers below end up inside `kill -0`, `sleep` and an integer
  // comparison, and `sh` has no opinion about any of them until it is too late.
  // `MAX_POLLS='Infinity'` — which is what `Math.ceil(ms / 0)` stringifies to —
  // makes `[ "$polls" -ge "$MAX_POLLS" ]` fail with "integer expression
  // expected" on every iteration, and a failing test is a false one, so the
  // bounded wait this module promises becomes an unbounded loop spinning on
  // `sleep 0`. Clamped here rather than trusted, because a generator that can
  // emit an unbounded loop over someone's application is not one worth having.
  const pollSeconds =
    Number.isFinite(plan.pollSeconds) && plan.pollSeconds > 0
      ? plan.pollSeconds
      : DEFAULT_POLL_SECONDS
  // An unusable count falls back to the wait this module documents, and even a
  // usable one is capped: "bounded" has to mean bounded in wall-clock seconds,
  // not merely finite. A count of ten million is an integer and still a helper
  // sitting on the user's application for a month.
  const pollCeiling = Math.ceil(MAX_WAIT_MS / (pollSeconds * 1000))
  const requested = Math.trunc(plan.maxPolls)
  const maxPolls = Math.min(
    Number.isFinite(requested) && requested >= 1
      ? requested
      : Math.ceil(DEFAULT_WAIT_TIMEOUT_MS / (pollSeconds * 1000)),
    pollCeiling,
  )

  // A pid, unlike a timing, has no safe default: the wait for the app to exit
  // is the only thing standing between the swap and a bundle being moved out
  // from under a running process, and `kill -0 not-a-number` fails, which reads
  // as "it has exited". Refusing to generate the script is the only honest
  // answer. `installStagedUpdate` checks first, so this cannot be reached from
  // there — it is here for anyone calling `swapScript` directly.
  if (!Number.isSafeInteger(plan.pid) || plan.pid < 1) {
    throw new RangeError(`swapScript needs a real process id to wait for, got ${plan.pid}`)
  }
  const quarantine = plan.clearQuarantine
    ? `
# Asked for explicitly by the caller. A bundle unzipped from a download carries
# com.apple.quarantine, and Gatekeeper refuses to open an unsigned quarantined
# app — which would leave the user with a "successful" update they cannot run.
if ! /usr/bin/xattr -d -r com.apple.quarantine "$INSTALL" >/dev/null 2>&1; then
  log 'swap: could not clear the quarantine flag; the app may need Open Anyway'
fi
`
    : ''

  return `#!/bin/sh
# Terminal Deck update swap. Generated by src/main/updates/install-update.ts.
#
# Every path is a single-quoted literal: the product name contains a space and
# the user chose the directory it sits in.
#
# No 'set -e' on purpose — the rollback below must run to the end even when the
# command before it failed. That is the whole point of it.
set -u

PID=${q(String(plan.pid))}
INSTALL=${q(plan.bundlePath)}
STAGED=${q(plan.stagedBundlePath)}
BACKUP=${q(plan.backupPath)}
PARTIAL=${q(`${plan.backupPath}.partial`)}
LOG=${q(plan.logPath)}
OPEN_BIN=${q(plan.openBinary)}
POLL=${q(String(pollSeconds))}
MAX_POLLS=${q(String(maxPolls))}

# Never hold a working directory inside a path that is about to be renamed.
cd / || exit 1

log() {
  printf '%s %s\\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >> "$LOG" 2>/dev/null
}

log "swap: helper started, waiting for pid $PID"

# kill -0 asks "does this pid exist and may I signal it" without signalling.
# It is the app's own pid, same user, so a permission failure is not a case
# that arises. A recycled pid would only make us wait longer and then abort
# safely, which is why the loop is bounded rather than open-ended.
polls=0
while kill -0 "$PID" 2>/dev/null; do
  polls=$((polls + 1))
  if [ "$polls" -ge "$MAX_POLLS" ]; then
    log "swap: ABORT - pid $PID is still running; nothing was moved"
    exit ${SWAP_EXIT.timeout}
  fi
  sleep "$POLL"
done

log 'swap: the app has exited'

if [ "$STAGED" = "$INSTALL" ]; then
  log 'swap: ABORT - the staged bundle is the installed bundle; nothing was moved'
  exit ${SWAP_EXIT.stagedInvalid}
fi

# Re-checked here and not only before the quit: the app has been down for a
# moment, and macOS is free to purge a cache directory in that moment.
#
# This check sitting *before* the backup move is also what makes a second
# helper harmless. If two ever run — a retry after a spawn that reported
# failure but had already started — whichever loses the race finds the staged
# bundle already moved away and stops here, before it can move anything.
if [ ! -d "$STAGED/Contents/MacOS" ]; then
  log "swap: ABORT - no bundle at $STAGED; nothing was moved"
  exit ${SWAP_EXIT.stagedInvalid}
fi

# mv into an existing directory moves *inside* it. That would nest the app one
# level down and leave the install path empty, so both destinations are checked
# to be free before anything is renamed.
#
# -e follows symlinks and is therefore blind to a dangling one, which is a path
# that is very much not free: renaming a directory onto it fails with ENOTDIR.
# -L is what sees it. Better to stop here, with nothing moved, than at the mv.
if [ -e "$BACKUP" ] || [ -L "$BACKUP" ]; then
  log "swap: ABORT - something already exists at $BACKUP; nothing was moved"
  exit ${SWAP_EXIT.backupFailed}
fi

if ! mv -f "$INSTALL" "$BACKUP"; then
  log "swap: ABORT - could not move the current app aside; it is untouched at $INSTALL"
  exit ${SWAP_EXIT.backupFailed}
fi
log "swap: the current app is safe at $BACKUP"

# What "the new app landed" has to mean before the backup may be removed.
#
# -d on its own follows symlinks, so a Contents/MacOS that is a link pointing
# somewhere that still resolves after the move would satisfy it — and the
# backup would then be deleted on the strength of a link rather than an
# application. The directory has to be a real one, and the Info.plist every
# bundle carries has to be a real file, before the only copy of the user's old
# app is destroyed.
bundle_landed() {
  [ -d "$INSTALL/Contents/MacOS" ] &&
    [ ! -L "$INSTALL/Contents/MacOS" ] &&
    [ -f "$INSTALL/Contents/Info.plist" ]
}

# From here on the user has no application at $INSTALL, so every branch below
# ends either with the new bundle there or with the backup put back.
if mv -f "$STAGED" "$INSTALL" && bundle_landed; then
  log "swap: the new app is in place at $INSTALL"
${quarantine}
  # The only destructive command in this file, and it runs only here: after the
  # new bundle is verified in place. The case guard re-checks that BACKUP is
  # the path this script named, so a mangled variable removes nothing.
  case "$BACKUP" in
    "$INSTALL".old-*)
      if rm -rf "$BACKUP"; then
        log 'swap: removed the backup'
      else
        log "swap: could not remove the backup; it is at $BACKUP"
      fi
      ;;
    *)
      log "swap: refusing to remove $BACKUP - it is not the backup path this script made"
      ;;
  esac

  if ! "$OPEN_BIN" -a "$INSTALL" >/dev/null 2>&1; then
    log 'swap: the new app is installed but could not be launched'
  fi
  log 'swap: done'
  exit ${SWAP_EXIT.ok}
fi

log 'swap: FAILED to put the new app in place; rolling back'

# Three ways something can be sitting on the install path here: the mv
# succeeded but what landed is not a bundle, a cross-volume mv degraded into
# copy-then-delete and left a partial one, or what the mv moved in was a
# symlink and it now dangles. Either way it is moved out of the way rather than
# deleted — the restore below needs the path free, and a bad bundle is still
# evidence of what went wrong.
#
# -L is not decoration. -e follows symlinks, so it answers "no" for a dangling
# one, this branch would be skipped with the link still in place, and the
# restore below would then fail with ENOTDIR — leaving the user no application
# at $INSTALL and their real one stranded under a name they never chose. That
# is the exact outcome this whole file exists to prevent, so the test for the
# path being occupied has to see links as well as things links point at.
if [ -e "$INSTALL" ] || [ -L "$INSTALL" ]; then
  if mv -f "$INSTALL" "$PARTIAL"; then
    log "swap: moved the unusable bundle to $PARTIAL"
  else
    log "swap: CRITICAL - $INSTALL is occupied and could not be cleared; your app is at $BACKUP"
    exit ${SWAP_EXIT.rollbackFailed}
  fi
fi

if mv -f "$BACKUP" "$INSTALL"; then
  log "swap: rolled back - the original app is back at $INSTALL"
  if ! "$OPEN_BIN" -a "$INSTALL" >/dev/null 2>&1; then
    log 'swap: the original app is restored but could not be relaunched'
  fi
  exit ${SWAP_EXIT.rolledBack}
fi

log "swap: CRITICAL - rollback failed; your app is at $BACKUP, move it back to $INSTALL"
exit ${SWAP_EXIT.rollbackFailed}
`
}

/* --------------------------------------------------------------- refusals -- */

/** Why an install will not be attempted. One code per distinct fix. */
export type InstallBlock =
  /** Not macOS. This module only knows how to swap an `.app`. */
  | 'unsupported-platform'
  /** `exePath` is not `<bundle>.app/Contents/MacOS/<binary>`. */
  | 'not-a-bundle'
  /** The derived bundle has no `Contents/MacOS` on disk. */
  | 'bundle-incomplete'
  /** The bundle or its parent cannot be written: another user, or read-only. */
  | 'not-writable'
  /** Nothing usable at the staged path. */
  | 'staged-invalid'
  /** The staged bundle carries no readable `CFBundleShortVersionString`. */
  | 'staged-version-unreadable'
  /** The staged version is not newer, and `reinstall` was not set. */
  | 'not-newer'
  /** The helper could not be written or started. Nothing was quit. */
  | 'helper-failed'

export type InstallCapability =
  | { ok: true; bundlePath: string; parentPath: string }
  | { ok: false; block: InstallBlock; message: string }

export interface CapabilityOptions {
  environment: InstallEnvironment
  fs: InstallFs
}

const NOT_A_BUNDLE =
  'This build is not running from an application bundle, so there is nothing to ' +
  'replace. Download the new version from Releases instead.'

/**
 * Best-effort `errno` code, for turning a failed `access` into a real sentence.
 *
 * Narrowed with `in` rather than a cast: a caught value really is `unknown`
 * here — an injected `fs` can throw anything — and asserting a shape onto it
 * would be the compiler agreeing to something nobody checked.
 */
function errorCode(error: unknown): string {
  if (typeof error !== 'object' || error === null || !('code' in error)) return ''
  const { code } = error
  return typeof code === 'string' ? code : ''
}

async function isDirectory(fs: InstallFs, path: string): Promise<boolean> {
  try {
    return (await fs.stat(path)).isDirectory()
  } catch {
    return false
  }
}

/**
 * Whether this app can replace itself where it stands, and the sentence to
 * show when it cannot.
 *
 * Order is deliberate and each step is a different fix for the user: the
 * platform, then the shape of the path, then whether the bundle is really
 * there, then whether it can be written. Permissions come last because the
 * message depends on knowing which directory was refused, and because it is
 * the check most likely to be the real answer — a copy dragged straight out of
 * the DMG runs from `/Volumes`, which is a read-only mount, and a shared Mac
 * has apps in `/Applications` owned by whoever installed them.
 *
 * Both the bundle and its parent are tested: the rename that starts the swap
 * writes a new entry into the parent directory, and the one that finishes it
 * writes over the bundle. Testing only one of the two passes on a writable app
 * inside a locked folder, which fails a moment after the app has quit.
 */
export async function canInstallInPlace(options: CapabilityOptions): Promise<InstallCapability> {
  const { environment, fs } = options

  if (environment.platform !== 'darwin') {
    return {
      ok: false,
      block: 'unsupported-platform',
      message: 'In-place updates are only implemented for macOS on this build.',
    }
  }

  const bundlePath = installedBundlePath(environment.exePath)
  if (bundlePath === null) {
    return { ok: false, block: 'not-a-bundle', message: NOT_A_BUNDLE }
  }

  if (!(await isDirectory(fs, bundleExecutableDir(bundlePath)))) {
    return {
      ok: false,
      block: 'bundle-incomplete',
      message:
        `The application at ${bundlePath} is missing Contents/MacOS, so it is not a ` +
        'bundle this can safely replace. Download the new version from Releases instead.',
    }
  }

  const parentPath = bundleParent(bundlePath)
  for (const [path, what] of [
    [bundlePath, 'the application'],
    [parentPath, 'the folder it is in'],
  ] as const) {
    try {
      await fs.access(path, fsConstants.W_OK)
    } catch (error) {
      const code = errorCode(error)
      const why =
        code === 'EROFS'
          ? `${path} is on a read-only volume. If you are running the app from the disk ` +
            'image, drag it to your Applications folder first, then update.'
          : `${path} is not writable by this account, so ${what} cannot be replaced. ` +
            'Update from an account that owns it, or download the new version from Releases.'
      return { ok: false, block: 'not-writable', message: why }
    }
  }

  return { ok: true, bundlePath, parentPath }
}

/* ---------------------------------------------------------------- install -- */

export interface InstallOptions {
  environment: InstallEnvironment
  /**
   * The directory the new build was unpacked into. The script and the log are
   * written here, so a failed swap leaves its evidence beside the download.
   */
  stagingDir: string
  /** The unpacked `.app` inside {@link stagingDir}. */
  stagedBundlePath: string
  /** `app.getVersion()` of the running build. */
  currentVersion: string
  /** Install even when the staged version is not newer. */
  reinstall?: boolean
  /**
   * Strip `com.apple.quarantine` from the new bundle after the swap.
   *
   * Off by default, and it stays off unless a caller says otherwise: clearing
   * quarantine is a real security decision — it discards macOS's record that
   * these bytes came off the internet — and it is not this module's to make
   * silently. The caller that verified the download's sha512 against
   * `latest-mac.yml` is the one entitled to make it.
   */
  clearQuarantine?: boolean
  fs: InstallFs
  spawn: SpawnLike
  /** `app.quit()`. Called only after the helper is confirmed running. */
  quit: () => void
  /** Defaults to `process.pid` — the app the helper waits for. */
  pid?: number
  now?: () => number
  /** Defaults to `/usr/bin/open`. Overridden only by the script's own tests. */
  openBinary?: string
  /** Seconds between polls of the app's pid. */
  pollSeconds?: number
  /** How long the helper waits for the app to exit before abandoning the swap. */
  waitTimeoutMs?: number
}

export type InstallStartResult =
  | {
      started: true
      bundlePath: string
      backupPath: string
      scriptPath: string
      logPath: string
      /** The helper waiting for this process to exit. Never absent: a spawn
       * that reported no pid is treated as a spawn that did not happen, and
       * refuses rather than quitting. */
      helperPid: number
    }
  | { started: false; block: InstallBlock; message: string }

/** `/usr/bin/open`, checked to exist on this machine. */
export const DEFAULT_OPEN_BINARY = '/usr/bin/open'
/** Poll often enough to feel instant, rarely enough to cost nothing. */
export const DEFAULT_POLL_SECONDS = 0.25
/**
 * How long the helper waits for the app to exit.
 *
 * Generous — `before-quit` here stops timers, closes the remote server and
 * flushes stores — but finite, because a helper that waits forever on an app
 * that refused to quit is a process holding a swap over the user's application
 * indefinitely. On timeout it moves nothing and says so in the log.
 */
export const DEFAULT_WAIT_TIMEOUT_MS = 60_000
/**
 * The longest wait {@link swapScript} will generate, whatever it is handed.
 *
 * The helper holds a pending swap over the user's application for as long as it
 * waits, so the bound is a ceiling and not only a default: no caller, and no
 * arithmetic accident upstream, can produce a helper that lingers past this.
 */
export const MAX_WAIT_MS = 15 * 60_000

async function appendLog(fs: InstallFs, logPath: string, line: string): Promise<void> {
  // Logging is evidence, not control flow. A log that cannot be written must
  // never be the reason an update does not happen.
  try {
    await fs.appendFile(logPath, `${new Date().toISOString()} ${line}\n`)
  } catch {
    /* ignore */
  }
}

/**
 * Replace this app with the staged one and relaunch.
 *
 * Returns before anything has moved. On `started: true` the helper is running
 * and `quit()` has been called, so the app is on its way out and the result is
 * only there for the log; on `started: false` nothing was quit, nothing was
 * touched, and `message` is a sentence to put in front of the user.
 *
 * The order below is the contract: every refusal happens while the app is
 * still running.
 */
export async function installStagedUpdate(options: InstallOptions): Promise<InstallStartResult> {
  const { fs, stagingDir, stagedBundlePath, currentVersion } = options
  const now = options.now ?? (() => Date.now())
  const logPath = join(stagingDir, LOG_NAME)

  const capability = await canInstallInPlace({ environment: options.environment, fs })
  if (!capability.ok) {
    await appendLog(fs, logPath, `refused (${capability.block}): ${capability.message}`)
    return { started: false, block: capability.block, message: capability.message }
  }
  const { bundlePath } = capability

  // Refusing to replace a bundle with itself is not a hypothetical: a caller
  // that resolves the staging path wrongly would otherwise move the app aside
  // and then try to move it back onto itself.
  if (stagedBundlePath === bundlePath) {
    const message = 'The staged update is the installed application. Nothing to do.'
    await appendLog(fs, logPath, `refused (staged-invalid): ${message}`)
    return { started: false, block: 'staged-invalid', message }
  }

  if (
    !stagedBundlePath.endsWith('.app') ||
    !(await isDirectory(fs, bundleExecutableDir(stagedBundlePath)))
  ) {
    const message =
      `The downloaded update at ${stagedBundlePath} is not a complete application ` +
      'bundle. Download it again, or get the new version from Releases.'
    await appendLog(fs, logPath, `refused (staged-invalid): ${message}`)
    return { started: false, block: 'staged-invalid', message }
  }

  let stagedVersion: string | null = null
  try {
    stagedVersion = readShortVersion(await fs.readFile(bundleInfoPlist(stagedBundlePath), 'utf8'))
  } catch {
    stagedVersion = null
  }

  if (options.reinstall !== true) {
    if (stagedVersion === null) {
      const message =
        'The downloaded update does not report a version, so there is no way to tell ' +
        'whether it is newer than the app you are running. It was not installed.'
      await appendLog(fs, logPath, `refused (staged-version-unreadable): ${message}`)
      return { started: false, block: 'staged-version-unreadable', message }
    }
    if (compareVersions(stagedVersion, currentVersion) <= 0) {
      const message =
        `The downloaded version (${stagedVersion}) is not newer than the one you are ` +
        `running (${currentVersion}), so it was not installed.`
      await appendLog(fs, logPath, `refused (not-newer): ${message}`)
      return { started: false, block: 'not-newer', message }
    }
  }

  // Checked before anything is generated, so the answer is a sentence rather
  // than a thrown RangeError out of `swapScript`. A pid that is not a pid makes
  // the helper's `kill -0` fail, which it reads as "the app has exited" — and
  // it would then swap the bundle out from under a process still using it.
  const pid = options.pid ?? process.pid
  const pollSeconds = options.pollSeconds ?? DEFAULT_POLL_SECONDS
  const waitTimeoutMs = options.waitTimeoutMs ?? DEFAULT_WAIT_TIMEOUT_MS
  if (
    !Number.isSafeInteger(pid) ||
    pid < 1 ||
    !Number.isFinite(pollSeconds) ||
    pollSeconds <= 0 ||
    !Number.isFinite(waitTimeoutMs) ||
    waitTimeoutMs <= 0
  ) {
    const message =
      'The update helper was given a process id or a timeout it cannot use, so nothing ' +
      'was changed. This is a bug in the app rather than anything you did.'
    await appendLog(fs, logPath, `refused (helper-failed): ${message}`)
    return { started: false, block: 'helper-failed', message }
  }

  const backupPath = backupPathFor(bundlePath, now())
  const scriptPath = join(stagingDir, SCRIPT_NAME)
  const script = swapScript({
    pid,
    bundlePath,
    stagedBundlePath,
    backupPath,
    logPath,
    openBinary: options.openBinary ?? DEFAULT_OPEN_BINARY,
    pollSeconds,
    maxPolls: Math.max(1, Math.ceil(waitTimeoutMs / (pollSeconds * 1000))),
    clearQuarantine: options.clearQuarantine === true,
  })

  await appendLog(
    fs,
    logPath,
    `installing ${stagedVersion ?? 'an unversioned build'} over ${currentVersion} at ${bundlePath}`,
  )

  let helper: SpawnedHelper
  try {
    await fs.mkdir(stagingDir, { recursive: true })
    // 0o700: it is a script that moves the user's application around, and only
    // the account running the app has any business executing it.
    await fs.writeFile(scriptPath, script, { mode: 0o700 })
    // `/bin/sh <script>` rather than executing the file, so a staging directory
    // mounted noexec cannot stop the swap. detached + ignore + unref is what
    // lets it outlive the quit below — drop any one of the three and the helper
    // dies with the app it is waiting for, after the app is already gone.
    helper = options.spawn('/bin/sh', [scriptPath], {
      detached: true,
      stdio: 'ignore',
      cwd: '/',
    })
    helper.unref()
  } catch (error) {
    const message =
      'The update helper could not be started, so nothing was changed: ' +
      (error instanceof Error ? error.message : String(error))
    await appendLog(fs, logPath, `refused (helper-failed): ${message}`)
    return { started: false, block: 'helper-failed', message }
  }

  // No pid means no child. `spawn` reports a failure to launch on the `error`
  // event rather than by throwing, and the object it hands back in that case
  // has an undefined pid — so reaching here without one is the one way to end
  // up quitting the app with nothing running to bring it back. Refuse instead:
  // nothing has moved, the window is still up, and the user gets a sentence.
  if (helper.pid === undefined) {
    const message =
      'The update helper did not start, so nothing was changed and your app is ' +
      'untouched. Try again, or download the new version from Releases.'
    await appendLog(fs, logPath, `refused (helper-failed): ${message}`)
    return { started: false, block: 'helper-failed', message }
  }

  await appendLog(fs, logPath, `helper running as pid ${helper.pid}; quitting`)

  // Last line of the function on purpose. Everything that could refuse has
  // already refused, and the helper is running and waiting for this process to
  // disappear.
  options.quit()

  return {
    started: true,
    bundlePath,
    backupPath,
    scriptPath,
    logPath,
    helperPid: helper.pid,
  }
}

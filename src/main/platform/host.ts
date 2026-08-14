/**
 * The seam every other platform decision in this folder is made through.
 *
 * ## Why `process.platform` is read in exactly one function
 *
 * A branch on `process.platform` written inline is a branch that can only ever
 * be exercised on the machine it was written on. This app is built and tested
 * on macOS and CI is macOS-only *by policy* (`.github/workflows/ci.yml` says so
 * and gives its reasons), so an inline Windows branch is untestable here in the
 * strongest sense: nothing in the suite can reach it, and the first person to
 * find out whether it works is a user.
 *
 * So the platform is a value that gets passed in. `currentPlatform()` is the one
 * place it is read, callers default their own parameter to it, and every
 * function below takes it explicitly — which is what lets a test on this Mac
 * pin the Windows answer and the macOS answer side by side, in the same file,
 * on the same run.
 *
 * ## The PATH-casing hazard, which is the reason `withPath` exists
 *
 * On Windows environment variable names are case-insensitive, and the OS spells
 * this one `Path`. Node's `process.env` mirrors that: reading `process.env.PATH`
 * on Windows finds `Path`. A *copy* of it does not — `{ ...process.env }` is an
 * ordinary object with ordinary case-sensitive keys, so the idiom used all over
 * this codebase,
 *
 *     { ...process.env, PATH }
 *
 * produces an object holding **both** `Path` (the inherited value) and `PATH`
 * (the one the caller meant), and which of the two the child process ends up
 * seeing is not something a Mac can settle. This has not been observed failing,
 * because nothing here has run on Windows; it is a coin-flip that costs one
 * function to remove, so it is removed rather than bet on. `withPath` drops
 * every spelling of the key and writes exactly one back.
 */

export type Platform = NodeJS.Platform

/** A `process.env`, or anything test-shaped like one. */
export type Env = Record<string, string | undefined>

/**
 * The single read of `process.platform` in `src/main/platform`.
 *
 * Everything else takes a `Platform` argument. Callers that stand at the edge —
 * `dev-ports.ts`, `providers.ts`, `tailnet.ts`, `profiles.ts` — default their
 * own parameter to this, so production reads the real value once and tests pass
 * whichever value they want to pin.
 */
export function currentPlatform(): Platform {
  return process.platform
}

export function isWindows(platform: Platform): boolean {
  return platform === 'win32'
}

/**
 * True when this key is the PATH variable *on this platform*.
 *
 * Case-insensitive on Windows only. A POSIX environment can legitimately carry
 * a separate `Path` variable that has nothing to do with executable lookup, and
 * folding it into PATH there would corrupt an environment to fix a problem that
 * platform does not have.
 */
export function isPathKey(key: string, platform: Platform): boolean {
  return isWindows(platform) ? key.toUpperCase() === 'PATH' : key === 'PATH'
}

/**
 * The name this environment already uses for PATH, so a rewrite keeps the
 * spelling the OS handed us rather than introducing a second one.
 */
export function pathKey(env: Env, platform: Platform): string {
  if (!isWindows(platform)) return 'PATH'
  const existing = Object.keys(env).find((key) => isPathKey(key, platform))
  // `Path` rather than `PATH` when there is nothing to copy: that is how
  // Windows itself spells it, and matching it keeps `set`-style output readable.
  return existing ?? 'Path'
}

/** PATH out of an environment, whatever case that environment spelled it in. */
export function envPath(env: Env, platform: Platform): string {
  const key = Object.keys(env).find((name) => isPathKey(name, platform))
  return (key === undefined ? undefined : env[key]) ?? ''
}

/**
 * A copy of `env` with PATH set to `value` and no second spelling of it left
 * behind. Use this instead of `{ ...env, PATH }` for anything that will be
 * handed to a child process.
 *
 * Generic in the value type so it can be dropped into either kind of caller
 * without a cast: `process.env` carries `string | undefined` and `node-pty`
 * wants a `Record<string, string>`, and widening the second one to satisfy the
 * first would push the problem onto a caller who then reaches for `as`.
 */
export function withPath<V extends string | undefined>(
  env: Record<string, V>,
  value: string,
  platform: Platform,
): Record<string, V | string> {
  const next: Record<string, V | string> = {}
  for (const [key, existing] of Object.entries(env)) {
    if (isPathKey(key, platform)) continue
    next[key] = existing
  }
  next[pathKey(env, platform)] = value
  return next
}

/**
 * What to call the machine the app is running on, in a sentence shown to a
 * person.
 *
 * This module is otherwise about behaviour, not copy, and a noun does look out
 * of place here. It is here because it is the same *kind* of fact as everything
 * above — a platform difference that must be decided in one place and passed in
 * rather than branched on inline — and because the alternative was worse: the
 * remote code says "this Mac" in over a hundred sentences, several of which are
 * sealed up and sent to a phone, and a Windows user reads the app telling them
 * something plainly untrue about the computer in front of them.
 *
 * `tailnet.ts` already forked its whole reason table into `MAC_REASONS` and
 * `WINDOWS_REASONS` for exactly this, which works when the two sentences differ
 * in more than a noun and is far too heavy when they do not.
 *
 * "PC" rather than "computer" or "machine": it is what a Windows user calls it,
 * and matching the reader's word is the entire point of doing this at all.
 */
export function machineNoun(platform: Platform = currentPlatform()): string {
  return isWindows(platform) ? 'PC' : 'Mac'
}


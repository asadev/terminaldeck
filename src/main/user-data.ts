import { copyFileSync, existsSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import type { App } from 'electron'
import { BRAND } from '../shared/brand'

/**
 * `--user-data-dir=<path>` or `--user-data-dir <path>` from the command line,
 * or null when it was not given.
 *
 * Read from `argv` rather than asked of Electron, because Electron folds the
 * flag into `getPath('userData')` and then there is no way to tell a path that
 * was *chosen* from one that was merely *derived* — which is the only
 * distinction that matters here.
 */
export function userDataFlag(argv: readonly string[]): string | null {
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg.startsWith('--user-data-dir=')) {
      const value = arg.slice('--user-data-dir='.length)
      return value === '' ? null : value
    }
    if (arg === '--user-data-dir') {
      const value = argv[i + 1]
      return value === undefined || value.startsWith('-') ? null : value
    }
  }
  return null
}

/** The one file in userData that is ours rather than Chromium's. */
const STATE = 'state.json'

/**
 * Pins the data directory to `BRAND.id` and carries settings over from the
 * directory Electron would otherwise have chosen.
 *
 * By default Electron derives userData from the *display* name, so renaming
 * the app silently moves every user's projects, preferences and window bounds
 * to a new folder and starts them over in an empty one. That already happened
 * here twice — `Pawl`, `pawl` and `Terminal Deck` are all sitting in
 * Application Support, each with its own `state.json` — and it happened with
 * no error, which is what makes it worth pinning rather than remembering.
 *
 * `id` is a slug, not a display name, so it does not move when the product is
 * renamed. Chromium's own caches are rebuilt wherever they land, so only
 * `state.json` is worth carrying.
 */
export function pinUserData(app: App): void {
  /*
   * An explicit `--user-data-dir` wins, and this early return is load-bearing.
   *
   * Electron has already resolved that flag into `getPath('userData')` by the
   * time this runs, so without this check the pinning below rewrites it to
   * `dirname(<the flag>)/terminaldeck` — turning `--user-data-dir=/tmp/probe`
   * into `/tmp/terminaldeck` and leaving the directory the caller named empty.
   *
   * That is not hypothetical. A second copy of this app was launched with its
   * own `--user-data-dir` precisely so it could not disturb the installed one,
   * the flag was silently discarded here, both processes landed on the same
   * `relay-identity.json`, and they spent hours evicting each other at the
   * relay — which presented as a phone that could never pair, with nothing
   * anywhere in an error state.
   *
   * The pinning exists to stop a *rename* moving somebody's data without their
   * knowledge. Somebody naming a directory on the command line is the opposite
   * of that: it is the most deliberate statement of intent available, and it
   * must be obeyed.
   */
  if (userDataFlag(process.argv) !== null) return

  const fromName = app.getPath('userData')
  const pinned = join(dirname(fromName), BRAND.id)
  if (fromName === pinned) return

  try {
    mkdirSync(pinned, { recursive: true })
    // Only ever a first-run copy: once the pinned directory has state of its
    // own it is the truth, and a later rename must not overwrite it.
    if (!existsSync(join(pinned, STATE)) && existsSync(join(fromName, STATE))) {
      copyFileSync(join(fromName, STATE), join(pinned, STATE))
    }
    app.setPath('userData', pinned)
  } catch {
    /* A failure here must not stop the app booting; it just keeps the default
       location, which is the behaviour we had before. */
  }
}

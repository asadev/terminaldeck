import { existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'

/**
 * Is a folder set up for Stays Fixed, and which folder is a session's project?
 *
 * "Set up" means one thing here, and it is the engine's own test: a settings
 * file under one of the names it looks for (`CONFIG_NAMES` in its
 * `src/core/paths.js`, copied as data — six file names — rather than imported,
 * because this is asked on every session start and must not spawn anything).
 * `staysfixed init` writes the first of them. A `.staysfixed/` folder on its own
 * is *not* set up: a check writes its records there, and Terminal Deck's own
 * repository has one from being tested *by* Stays Fixed, which is a different
 * thing from this feature (see the lane's notes).
 */
export const CONFIG_NAMES = [
  'staysfixed.config.js',
  'staysfixed.config.mjs',
  'staysfixed.config.json',
  '.staysfixed/config.js',
  '.staysfixed/config.mjs',
  '.staysfixed/config.json',
] as const

/** The settings file in this folder, or null. */
export function configFileIn(folder: string, exists: (path: string) => boolean = existsSync): string | null {
  for (const name of CONFIG_NAMES) {
    const file = join(folder, name)
    if (exists(file)) return file
  }
  return null
}

/**
 * The nearest folder at or above `cwd` that is set up, or null.
 *
 * A session is often started one level down — `web/` inside a monorepo whose
 * settings live at the top — and the engine itself resolves upwards the same
 * way. It stops at the first `.git` it passes, because a settings file above a
 * repository belongs to some other project, and at the home folder and the
 * root, because nothing above those is anybody's project.
 */
export function setUpRootFor(
  cwd: string,
  options: { home?: string; exists?: (path: string) => boolean } = {},
): string | null {
  const exists = options.exists ?? existsSync
  const home = options.home ? resolve(options.home) : null
  let folder = resolve(cwd)
  for (let depth = 0; depth < 12; depth++) {
    if (configFileIn(folder, exists) !== null) return folder
    if (exists(join(folder, '.git'))) return null
    if (home !== null && folder === home) return null
    const up = dirname(folder)
    if (up === folder) return null
    folder = up
  }
  return null
}

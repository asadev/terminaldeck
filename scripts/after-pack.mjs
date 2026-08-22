/**
 * Copy the freshly-generated resources into the packed app, surviving the
 * transient Windows file lock that `extraResources` cannot.
 *
 * ## Why this exists rather than `extraResources`
 *
 * `out/headless-package/` (the host tarball plus `install.sh`) and, on Windows,
 * `native/win-confine/tdconfine.exe` are written moments before electron-builder
 * runs — by `dist:headless` and `build:win-confine`. On a Windows runner a file
 * that new is still being read by Windows Defender or the search indexer, and a
 * plain copy of it throws:
 *
 *   EBUSY: resource busy or locked, copyfile
 *     out/headless-package/install.sh -> …\resources\headless\install.sh
 *
 * `extraResources` copies once and fails the whole build on that one lock, with
 * no retry. The lock is transient — a few hundred milliseconds later the handle
 * is gone — so the fix is to do the copy here, in an `afterPack` hook, with a
 * short retry-with-backoff. The final path is unchanged (`resources/headless`
 * and `resources/tdconfine.exe`), so every `process.resourcesPath` reader —
 * `servers/host-package.ts`, `confine/tools.ts` — sees exactly what it did when
 * electron-builder placed these.
 *
 * ## Why it is not Windows-only code
 *
 * The headless package must land in the `.app` on macOS too — the same button
 * that installs the host from a packaged Mac build reads it out of
 * `resources/headless`. So the headless copy runs on every platform; only the
 * `tdconfine.exe` copy is Windows-only, because that is the only platform that
 * has one.
 *
 * ## Missing sources are not an error
 *
 * `pack:mac` (the dir-only smoke build) does not run `dist:headless`, and a
 * checkout that never ran `build:win-confine` has no `tdconfine.exe`. In both
 * cases the source is simply absent and this hook copies nothing — mirroring the
 * old `extraResources` behaviour, where a `from:` that matched nothing was a
 * no-op and the app reported "this build carries no package" at runtime. The
 * release scripts (`dist:mac`/`dist:win`) always build the sources first, so a
 * real release always has them.
 */

import { copyFileSync, existsSync, mkdirSync, readdirSync, statSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { setTimeout as sleep } from 'node:timers/promises'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')

/** Where electron-builder put the app's resources, per platform. */
function resourcesDir(context) {
  const { appOutDir, electronPlatformName, packager } = context
  if (electronPlatformName === 'darwin' || electronPlatformName === 'mas') {
    return join(appOutDir, `${packager.appInfo.productFilename}.app`, 'Contents', 'Resources')
  }
  // win32 and linux both put resources beside the executable.
  return join(appOutDir, 'resources')
}

/**
 * A copy that rides out a transient lock.
 *
 * Only the lock family is retried — EBUSY/EPERM/EACCES are what Defender and the
 * indexer produce while they hold a freshly-written file. Anything else (a
 * missing source, a bad path) is a real error and is thrown at once rather than
 * retried into a slow failure. libuv's copyfile carries the source's mode over,
 * so `install.sh` keeps its `+x`.
 */
async function copyWithRetry(from, to, attempts = 6, baseDelayMs = 250) {
  for (let attempt = 1; ; attempt += 1) {
    try {
      copyFileSync(from, to)
      return
    } catch (err) {
      const code = err && err.code
      const transient = code === 'EBUSY' || code === 'EPERM' || code === 'EACCES'
      if (!transient || attempt >= attempts) throw err
      // Linear backoff: 250ms, 500ms, … up to ~1.5s before the last try. The
      // indexer releases the handle well inside that.
      await sleep(baseDelayMs * attempt)
    }
  }
}

/** Copy every file in a directory into `dest`, each with its own retry. */
async function copyDir(from, dest) {
  mkdirSync(dest, { recursive: true })
  for (const name of readdirSync(from)) {
    const source = join(from, name)
    if (statSync(source).isFile()) await copyWithRetry(source, join(dest, name))
  }
}

export default async function afterPack(context) {
  const resDir = resourcesDir(context)

  // The headless host package — on every platform (see header).
  const headlessSrc = join(ROOT, 'out', 'headless-package')
  if (existsSync(headlessSrc)) {
    await copyDir(headlessSrc, join(resDir, 'headless'))
  }

  // The Windows confinement launcher — Windows only, and the same fresh-file
  // lock risk as install.sh, so it rides the same retry.
  if (context.electronPlatformName === 'win32') {
    const confine = join(ROOT, 'native', 'win-confine', 'tdconfine.exe')
    if (existsSync(confine)) {
      mkdirSync(resDir, { recursive: true })
      await copyWithRetry(confine, join(resDir, 'tdconfine.exe'))
    }
  }
}

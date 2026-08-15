/**
 * Where this machine keeps our files — asked without knowing which shell is
 * asking.
 *
 * ## Why this exists at all
 *
 * `app.getPath('userData')` is an Electron call, and until this module existed
 * it was scattered through the parts of `src/main` that have nothing to do with
 * a window: the store that holds the projects, the profile directory an agent
 * CLI is pointed at, the log. That was invisible while there was only one shell.
 * The headless build is a second shell around the same core — same sessions,
 * same relay, same grants, no window — and `import { app } from 'electron'` in
 * any of those files is what stops that core running under plain Node at all.
 *
 * The answer is not a second copy of those modules. A second implementation
 * means every fix lands twice and one of the two rots; `HEADLESS.md` says so in
 * as many words. So the *question* moves here and each shell answers it once, at
 * boot:
 *
 *   - `src/main/index.ts` installs {@link electronPaths}, which forwards to
 *     `app.getPath` — including the pinning `user-data.ts` does, since it reads
 *     the value at call time rather than capturing it.
 *   - `src/headless/daemon.ts` installs {@link nodePaths}, which computes the
 *     same directories from the environment.
 *
 * ## Why there is no default
 *
 * A default would be the worst of the three options. If it were the Node one,
 * an Electron build that forgot to install would keep running and quietly write
 * its projects, profiles and log to a *different* directory than the one it has
 * been using — the failure would be silent, and it would look like data loss
 * rather than like a missing line. If it were the Electron one, the headless
 * build would crash somewhere deep instead of at its first instruction.
 *
 * So {@link paths} throws, and the sentence it throws names both shells. It is
 * the one class of failure this repository has paid for most — built, and never
 * wired to boot — so it fails loudly at boot rather than plausibly later.
 * `src/headless/seam.test.ts` reads both entry points and asserts each installs
 * one.
 *
 * ## The one place the two shells genuinely disagree
 *
 * Electron's `userData` on Linux is `~/.config/<name>`; {@link nodePaths} uses
 * `$XDG_DATA_HOME` (`~/.local/share/<id>`), because that is what `HEADLESS.md`
 * decided and because state that is not configuration does not belong in
 * `~/.config`. They agree on macOS and Windows, where `user-data.ts` pins the
 * directory to `BRAND.id` and this module builds the same path from the same
 * constant. There is no Linux GUI build today; if one ever ships, this comment
 * is the reconciliation point and one of the two has to move.
 */

import { homedir } from 'node:os'
import { posix as posixPath, win32 as win32Path } from 'node:path'

/**
 * Join for the platform being ASKED ABOUT, not the one we are running on.
 *
 * `node:path`'s bare `join` follows the host: on a Windows runner it answers
 * `\Users\asad\Library\Application Support\…` for the *darwin* branch, and
 * the whole point of taking `platform` as a parameter is that the answer must
 * not depend on where the question is asked. This is not hypothetical — it is
 * how the Windows CI release build failed: two assertions that pass on every
 * developer's Mac and cannot pass on the runner that actually builds the
 * installer.
 */
function joinFor(platform: Platform, ...parts: string[]): string {
  return platform === 'win32' ? win32Path.join(...parts) : posixPath.join(...parts)
}
import { BRAND } from '../../shared/brand'
import { currentPlatform, type Env, type Platform } from './host'

/**
 * The four directories the core asks about, and deliberately no more.
 *
 * Everything else Electron's `app.getPath` offers — `temp`, `exe`, `logs`,
 * `pictures` — is used only by parts of the app that cannot exist without a
 * window (the updater replacing a bundle, the browser pane saving a screenshot),
 * so those keep calling `app` directly. Widening this interface to cover them
 * would put questions in the headless shell's mouth that it has no honest answer
 * to, which is how a seam turns into a stub.
 */
export interface PlatformPaths {
  /** Everything this app keeps for itself: state, settings, profiles, the trust store. */
  userData(): string
  /** The person's home directory. Where a session lands when nothing else is chosen. */
  home(): string
  /** Where a file sent from a phone should land — somewhere a person already looks. */
  downloads(): string
  /**
   * The root the app was installed from, for reading files that ship beside the
   * code — today only `pwa/dist`, the web client served over the tailnet.
   */
  appRoot(): string
}

let installed: PlatformPaths | null = null

/**
 * Say which shell is running. Called once, as early as either entry point can.
 *
 * Idempotent for the same object so a re-entrant import cannot half-install one;
 * a *different* one throws, because two answers to "where does this app keep its
 * files" is the bug this module exists to make impossible.
 */
export function installPaths(next: PlatformPaths): void {
  if (installed !== null && installed !== next) {
    throw new Error(
      'Two different sets of platform paths were installed. One process is one shell: ' +
        'the Electron main process installs electronPaths(app), the headless daemon installs ' +
        'nodePaths(). Nothing else may install any.',
    )
  }
  installed = next
}

/** Test seam. Production never calls this; nothing else may either. */
export function resetPaths(): void {
  installed = null
}

export function paths(): PlatformPaths {
  if (installed === null) {
    throw new Error(
      'Platform paths were never installed, so nothing knows where this app keeps its files. ' +
        'The Electron shell installs them in src/main/index.ts and the headless shell in ' +
        'src/headless/daemon.ts; a process that is neither has to install its own before it ' +
        'touches the store, the profiles or the log.',
    )
  }
  return installed
}

export function userDataDir(): string {
  return paths().userData()
}

export function homeDir(): string {
  return paths().home()
}

export function downloadsDir(): string {
  return paths().downloads()
}

export function appRootDir(): string {
  return paths().appRoot()
}

/* ------------------------------------------------------------- plain node -- */

export interface NodePathsInput {
  platform?: Platform
  env?: Env
  /** The person's home directory. A parameter so a test needs no real one. */
  home?: string
  /** Where the code was installed. The daemon passes the directory of its bundle. */
  appRoot?: string
}

/**
 * The same directories, worked out from the environment rather than from
 * Electron.
 *
 * Every input is a parameter for the reason `platform/host.ts` gives at length:
 * a branch on `process.platform` written inline can only be exercised on the
 * machine it was written on, and this code's whole purpose is to run on a Linux
 * server that this repository is never built on. `paths.test.ts` pins all three
 * platforms side by side on one macOS run.
 *
 * `XDG_DATA_HOME` is honoured only when it is absolute, which is what the
 * specification requires — a relative value there means "unset", and treating it
 * as a path would put the trust store somewhere relative to whatever directory
 * the service manager happened to start the process in.
 */
export function nodePaths(input: NodePathsInput = {}): PlatformPaths {
  const platform = input.platform ?? currentPlatform()
  const env = input.env ?? process.env
  const home = input.home ?? homedir()
  const appRoot = input.appRoot ?? process.cwd()

  const userData = ((): string => {
    if (platform === 'darwin') return joinFor(platform, home, 'Library', 'Application Support', BRAND.id)
    if (platform === 'win32') {
      const appData = env.APPDATA
      return joinFor(platform, appData && appData !== '' ? appData : joinFor(platform, home, 'AppData', 'Roaming'), BRAND.id)
    }
    const xdg = env.XDG_DATA_HOME
    // Absolute or nothing. POSIX says a relative XDG value must be ignored, and
    // a service manager's working directory is not somewhere to put a key.
    if (xdg !== undefined && xdg.startsWith('/')) return joinFor(platform, xdg, BRAND.id)
    return joinFor(platform, home, '.local', 'share', BRAND.id)
  })()

  const downloads = ((): string => {
    if (platform === 'linux') {
      const xdg = env.XDG_DOWNLOAD_DIR
      if (xdg !== undefined && xdg.startsWith('/')) return xdg
    }
    return joinFor(platform, home, 'Downloads')
  })()

  return {
    userData: () => userData,
    home: () => home,
    downloads: () => downloads,
    appRoot: () => appRoot,
  }
}

/* ---------------------------------------------------------------- electron -- */

/**
 * What `app.getPath` already answers, behind the same interface.
 *
 * The narrowest slice of Electron's `App` that answers the four questions, named
 * here rather than imported, so this module has no Electron import of its own
 * and the headless closure stays clean. Electron's real `app` satisfies it
 * structurally, so `src/main/index.ts` passes it unchanged.
 *
 * Every method forwards on each call rather than caching, and that is
 * load-bearing: `pinUserData` moves `userData` *after* this is installed, and a
 * captured value would leave the store reading the pre-pin directory — the exact
 * "renaming the app silently moved everyone's projects" failure `user-data.ts`
 * exists to close, reintroduced one layer up.
 */
export interface ElectronPathSource {
  getPath(name: 'home' | 'downloads' | 'userData'): string
  getAppPath(): string
}

export function electronPaths(app: ElectronPathSource): PlatformPaths {
  return {
    userData: () => app.getPath('userData'),
    home: () => app.getPath('home'),
    downloads: () => app.getPath('downloads'),
    appRoot: () => app.getAppPath(),
  }
}

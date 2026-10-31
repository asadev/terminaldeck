/**
 * Where the headless host this app would install actually lives on this
 * computer.
 *
 * ## Why a file on disk and not `npm install -g terminaldeck`
 *
 * Because that name is a **placeholder reservation**. `HEADLESS.md` and
 * `scripts/install-headless.sh` both say it in as many words — the installer's
 * own last refusal is *"npm installed terminaldeck and it provided no
 * `terminaldeck` command … that is what the placeholder currently on the
 * registry does"* — so an app that asked a server to fetch that package would
 * put a working-looking install on somebody's machine that answers nothing when
 * a phone reaches for it. That is the exact failure this whole feature is meant
 * to remove.
 *
 * So the package travels with the app: `scripts/build-headless.mjs` packs
 * `out/headless` into a tarball beside the installer script, electron-builder
 * copies that one folder in as a resource, and the connector puts those two
 * files on the server over SFTP. Nothing is fetched from a registry that does
 * not yet have it.
 *
 * ## Why the answer may be null, and why that is not a bug
 *
 * `npm run dev` on a tree where nobody has run `npm run dist:headless` has no
 * tarball, and neither has a build packaged before this folder existed. Null is
 * the honest answer for both, and the caller's job is to draw **no Install
 * button at all** with the reason on screen — §4.1, *"a control that cannot act
 * is removed, or disabled with a stated reason. Never drawn hopefully."*
 * Guessing a registry install instead is the one thing this file must not do.
 *
 * ## Nothing here touches Electron
 *
 * The two roots are passed in. `servers/` has a fence — `host-key-checked.test.ts`
 * walks every source in this folder — and beyond that this is the same seam
 * `platform/paths.ts` argues for: a module that read `app.getPath` could only be
 * tested inside Electron, and the interesting cases here are *absences*.
 */

import { existsSync } from 'node:fs'
import { join } from 'node:path'

/** The two files that go to the server, and the version they are. */
export interface HostPackage {
  /** The npm tarball `npm install -g` is handed. */
  tarball: string
  /** `install.sh`: fetches a Node when the box has none, then runs that install. */
  installer: string
  /** What is inside the tarball, which is this app's own version. */
  version: string
}

/** The folder name, under `resources` in a packaged app and under `out` in a tree. */
export const HOST_PACKAGE_DIR = 'headless-package'

/** Named rather than versioned, so the path is the same in every build. */
export const HOST_TARBALL = 'terminaldeck-host.tgz'
export const HOST_INSTALLER = 'install.sh'

/**
 * The sentence shown where the Install button would have been.
 *
 * Written here, beside the reason it is true, and rendered unchanged — §4.3. It
 * names the command rather than apologising, because the only person who can
 * ever see it is somebody running from a tree.
 */
export const NO_PACKAGE =
  'This copy of the app does not carry the host package, so there is nothing here to install ' +
  'from. A packaged build carries it; from a checkout, `npm run dist:headless` builds it.'

export interface PackageRoots {
  /** `process.resourcesPath` in a packaged app. Null outside one. */
  resources: string | null
  /** The repository root when running from a tree. Null when there is none. */
  tree: string | null
  /** Seam for the tests. Defaults to the real filesystem. */
  exists?: (path: string) => boolean
}

/**
 * The package, or null when this build carries none.
 *
 * Both files or neither: an installer with no tarball beside it would run,
 * reach for a package that is not there, and fail on the server rather than
 * here — and a failure on somebody else's machine is the expensive kind.
 */
export function findHostPackage(version: string, roots: PackageRoots): HostPackage | null {
  const exists = roots.exists ?? existsSync
  const folders = [
    // Packaged first: a released app has both, and a developer tree that also
    // happens to have `resources` is not a case that exists.
    roots.resources === null ? null : join(roots.resources, 'headless'),
    roots.tree === null ? null : join(roots.tree, 'out', HOST_PACKAGE_DIR),
  ].filter((path): path is string => path !== null)

  for (const folder of folders) {
    const tarball = join(folder, HOST_TARBALL)
    const installer = join(folder, HOST_INSTALLER)
    if (exists(tarball) && exists(installer)) return { tarball, installer, version }
  }
  return null
}

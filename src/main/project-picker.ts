import { existsSync, statSync } from 'node:fs'
import { dirname } from 'node:path'

/**
 * Where the macOS folder picker should be standing when it opens.
 *
 * ## The bug this exists to fix, and how it was measured
 *
 * `project:pick` used to call `dialog.showOpenDialog` with no `defaultPath` at
 * all. That is not "open somewhere sensible" — it is "open wherever AppKit last
 * left you", and AppKit remembers that per application in its own user
 * defaults, under `NSOSPLastRootDirectory`, as a bookmark. Nothing in this app
 * has ever written that key, so the folder the user is shown is a side effect of
 * whatever they did the last time they opened *any* panel in this app.
 *
 * In a recorded walkthrough the picker was opened four separate times and listed
 * **not a single row** on any of them. Read straight off the machine
 * afterwards, the app's own defaults said why:
 *
 *     $ python3 - <<'PY'
 *     import plistlib, re
 *     d = plistlib.load(open('~/Library/Preferences/dev.terminaldeck.app.plist','rb'))
 *     print(re.findall(rb'[ -~]{3,}', bytes(d['NSOSPLastRootDirectory'])))
 *     PY
 *     [b'book', b'Users', b'apple', b'Tclaude', b'untitled folder', …]
 *
 *     $ ls -la '/Users/apple/Tclaude/untitled folder'
 *     total 0            # empty
 *
 * The panel was standing in an empty directory, so it drew an empty directory,
 * with `Open` greyed out — and because AppKit stores where you *were*, every
 * subsequent opening stood in the same empty directory. It is self-reinforcing:
 * one accidental "New Folder" and the picker is permanently useless.
 *
 * It is not a sandbox problem and not a permissions problem, which is worth
 * saying because both are the obvious suspects. The packaged app already
 * declares `NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`
 * and `NSDownloadsFolderUsageDescription`; the panel's own sidebar listed iCloud
 * Drive, the home folder and every mounted volume the whole time; and running
 * the identical `showOpenDialog` options with a `defaultPath` filled the panel
 * with rows on the same machine, in the same Electron, one minute later.
 *
 * ## Why the *parent* of the newest project
 *
 * Because it is the one answer that cannot be empty. The directory is derived
 * from a project the user already has open, so it contains at least that
 * project — the failure mode above is structurally impossible. It is also the
 * useful answer: somebody reaching for Browse is looking for a folder they have
 * not opened yet, and the folder they want is usually a sibling of one they
 * have.
 *
 * Passing a `defaultPath` on every call does discard AppKit's own memory of
 * where the user browsed to last. That is deliberate: that memory is the thing
 * that broke, it is invisible, and it survives between launches with nothing on
 * screen explaining it. The replacement is memory too, just memory the app can
 * see — picking a folder makes it the newest project, so the next Browse opens
 * beside it.
 */

/** Just enough of a stored project for this decision. */
export interface PickerProject {
  path: string
}

/**
 * Is this a directory that exists right now?
 *
 * Injected so the rules below can be tested without a filesystem, and because
 * the answer genuinely changes underneath us: a project on an unmounted volume
 * or one the user has since deleted is exactly the case that must not be handed
 * to the panel.
 */
export type DirectoryCheck = (path: string) => boolean

export const directoryExists: DirectoryCheck = (path: string): boolean => {
  try {
    return existsSync(path) && statSync(path).isDirectory()
  } catch {
    // A permission error on the stat is a directory we cannot vouch for, and
    // handing the panel one of those is how it opens on nothing again.
    return false
  }
}

/**
 * The directory to open the panel in, given the projects the app remembers.
 *
 * `projects` arrives most-recently-opened first, which is what `store.getProjects`
 * already answers with. The first project whose parent is a real directory wins;
 * `home` is the fallback and is returned unchecked, because if the user's own
 * home directory is missing there is nothing better left to say.
 */
export function pickerStartDirectory(
  projects: readonly PickerProject[],
  home: string,
  exists: DirectoryCheck = directoryExists,
): string {
  for (const project of projects) {
    if (typeof project?.path !== 'string' || project.path === '') continue
    const parent = dirname(project.path)
    // `dirname` of a bare name is `.`, and a relative path is not something to
    // point a system panel at — the app stores absolute paths, so this only
    // catches a corrupted store, but it catches it before AppKit resolves `.`
    // against the app bundle.
    if (parent === '' || parent === '.') continue
    if (exists(parent)) return parent
  }
  return home
}

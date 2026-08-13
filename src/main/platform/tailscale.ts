/**
 * Where the `tailscale` CLI is, per platform.
 *
 * `tailnet.ts` explains why this app shells out to the CLI at all and why the
 * answer decides what a terminal server binds to. This file is only the list of
 * places the binary can be, kept separate so both platforms' lists can be pinned
 * by a test on either.
 *
 * ## Windows — checked against Tailscale's own documentation, not guessed
 *
 * The MSI reference documents the `INSTALLDIR` property as: *"Specifies the path
 * of the installation directory on disk. The installation path defaults to
 * `C:\Program Files\Tailscale`."* (https://tailscale.com/docs/install/windows/msi)
 *
 * Two things follow from that sentence, and they are the whole design here:
 *
 *  - The default is under Program Files, so `%ProgramFiles%\Tailscale\tailscale.exe`
 *    belongs in the list.
 *  - It is a *default* of a settable property, so the list can never be the only
 *    mechanism. An administrator who set `INSTALLDIR` has Tailscale somewhere
 *    this file will never name.
 *
 * The CLI reference (https://tailscale.com/docs/reference/tailscale-cli) says
 * only that on Windows *"you can access the CLI by executing the `.exe` from the
 * Command Prompt"*. It does **not** state that the install directory is added to
 * PATH — so a PATH lookup cannot be the only mechanism either. `findTailscale`
 * therefore tries the lookup first (it is the only thing that can find a moved
 * install) and falls back to this list, which is the same order the macOS path
 * has always used.
 *
 * `%ProgramFiles%` is read from the environment rather than written as `C:\`:
 * Windows is not always on C:, and on 64-bit Windows the variable a 32-bit
 * process sees already points at `Program Files (x86)`. Both spellings are
 * listed anyway, because an x86 build of Tailscale on 64-bit Windows installs
 * into the (x86) tree while this app's own `%ProgramFiles%` says otherwise.
 */

import { win32 } from 'node:path'
import { isWindows, type Env, type Platform } from './host'

/**
 * macOS, unchanged and still verified on the machine this was written on.
 *
 * Homebrew on Apple silicon is one of four real answers; `/usr/local/bin` is
 * Homebrew on Intel; the App Store build ships its CLI inside the bundle and
 * puts nothing on PATH at all, which is why the third entry looks like that.
 */
const UNIX_BINARIES = [
  '/opt/homebrew/bin/tailscale',
  '/usr/local/bin/tailscale',
  '/Applications/Tailscale.app/Contents/MacOS/Tailscale',
  '/usr/bin/tailscale',
]

/** Program Files roots, in the order they are worth trying. */
const PROGRAM_FILES_KEYS = ['ProgramFiles', 'ProgramW6432', 'ProgramFiles(x86)']

/**
 * Absolute paths worth testing for an executable, most likely first.
 *
 * Built with `win32.join` rather than `join` so the separators are right no
 * matter which OS is doing the building — a test on this Mac gets the same
 * string a Windows machine would, which is the only way the expectation below
 * means anything.
 */
export function tailscaleCandidates(platform: Platform, env: Env): string[] {
  if (!isWindows(platform)) return [...UNIX_BINARIES]

  const roots: string[] = []
  for (const key of PROGRAM_FILES_KEYS) {
    const root = env[key]
    if (typeof root === 'string' && root.trim() !== '') roots.push(root)
  }
  // Only when the environment says nothing at all: a hardcoded drive letter is
  // a guess about someone else's machine, so it is the last resort rather than
  // the starting point.
  if (roots.length === 0) roots.push('C:\\Program Files')

  const seen = new Set<string>()
  const paths: string[] = []
  for (const root of roots) {
    const candidate = win32.join(root, 'Tailscale', 'tailscale.exe')
    if (seen.has(candidate.toLowerCase())) continue
    seen.add(candidate.toLowerCase())
    paths.push(candidate)
  }
  return paths
}

/**
 * The name to look up on PATH. Spelled without `.exe` on purpose: `where.exe`
 * resolves the extension itself through PATHEXT, and `which` would find nothing
 * called `tailscale.exe` on a Mac.
 */
export const TAILSCALE_BIN = 'tailscale'

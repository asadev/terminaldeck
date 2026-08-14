/**
 * The policy behind `create`: which folder a phone may start a session in.
 *
 * Split out of `index.ts` because it is the only part of starting a session
 * from a phone that is a *decision*. The rest — resolving the login shell's
 * PATH, probing which agent CLIs are installed, applying the profile, spawning
 * the PTY — is the desktop's existing `session:create` path and is used
 * unchanged; a phone-created session is the same object, made the same way, or
 * it is a second implementation that will drift from the first.
 *
 * ## What the rule is
 *
 * A phone may name a folder **only if the desktop is already offering it**:
 * a project in the desktop's own list, or the working directory of a session
 * that has already been listed to that device. Two things follow, and both
 * matter more than the rule sounds:
 *
 *  - The phone has an honest source for the value. It is a row on screen, not a
 *    path someone typed, so a folder picker built from it cannot offer a choice
 *    that fails.
 *  - Naming one grants nothing new. The device could already attach to a
 *    session in that folder and type into it, which is strictly more access
 *    than starting a fresh shell there.
 *
 * A path that is not on the list is **refused**, never quietly replaced with the
 * default. "New Session" that silently starts somewhere else is worse than one
 * that does not start: the user types a command into what they think is their
 * project and it lands in their home directory.
 *
 * Naming no folder at all is the common case and is not a refusal — it means
 * "wherever you would have started one", which is what the desktop's own button
 * does with nothing filled in.
 */

import { posix, win32 } from 'node:path'
import type { SessionMeta } from '../../shared/types'
import { currentPlatform, isWindows, machineNoun, type Platform } from '../platform/host'
import type { CreateOutcome, CreateRequest } from './server'

/**
 * The path rules for the platform being asked about, rather than for the one
 * running the test.
 *
 * `node:path` is whichever implementation the current OS uses, which is right
 * in production and useless here: on a Mac `isAbsolute('C:\\Users\\Asad')` is
 * false and `normalize` leaves backslashes alone, so every Windows case in the
 * suite would be answered by the POSIX parser and pass or fail for a reason
 * that has nothing to do with Windows. `platform/tailscale.ts` reaches for
 * `win32.join` for exactly this reason. Selecting the implementation is what
 * makes the Windows answer pinnable from the machine this is written on — and
 * on Windows itself it selects the same code `node:path` would have been.
 */
function rules(platform: Platform): typeof posix {
  return isWindows(platform) ? win32 : posix
}

/**
 * A terminal a phone has not measured yet.
 *
 * Only reached when the client sent no size — every shipping client sends one,
 * because the size travels with the request precisely so the first screen is
 * the right shape. 80×24 is the size a PTY gets when nobody says otherwise, so
 * a session started this way looks like one started from a shell script rather
 * than like one started at a size somebody invented.
 */
const DEFAULT_COLS = 80
const DEFAULT_ROWS = 24

export interface SessionStarter {
  /**
   * Folders this desktop will start a session in, most relevant first.
   *
   * Called per request rather than captured once: projects are added and
   * sessions come and go while a phone is connected, and a list snapshotted at
   * startup would refuse a folder the user opened five minutes ago.
   */
  folders(): string[]
  /** Where a request that named nothing goes, when there are no folders at all. */
  home(): string
  /** Start it for real. Throws exactly as `PtyManager.create` throws. */
  spawn(input: { cwd: string; cols: number; rows: number }): Promise<SessionMeta>
}

/**
 * One directory, written two ways.
 *
 * `normalize` resolves `.` and `..` and collapses repeated separators, and
 * deliberately does *not* drop a trailing one: `/a/b/` stays `/a/b/`. That is
 * correct for a general path and wrong here, because a project stored with a
 * trailing slash and the same folder as a session's `cwd` without one are the
 * same directory, and a refusal over that is a refusal nobody can act on. The
 * root itself keeps its separator, since `''` is not a path.
 *
 * ## And on Windows, written two ways again
 *
 * NTFS is case-insensitive. `C:\Users\Asad\proj` and `c:\users\asad\proj` are
 * one directory, and both spellings really do turn up: the drive letter alone
 * arrives capitalised from some APIs and lower-cased from others, and a folder
 * a user typed once is stored however they typed it. Comparing them with `===`
 * makes the allowlist reject a folder that is *visibly on the list the phone is
 * showing* — and the refusal it produces says "Open it on the Mac first" about
 * a folder that is already open. That is the worst kind of failure this file
 * can have: the rule looks broken rather than strict.
 *
 * Folded on Windows only. A POSIX filesystem genuinely distinguishes `Proj`
 * from `proj`, and folding there would let a phone name a *different* directory
 * than the one the desktop offered, which is the exact hole the allowlist
 * exists to close.
 */
function samePath(a: string, b: string, platform: Platform = currentPlatform()): boolean {
  const { normalize, sep } = rules(platform)
  const left = trimEnd(normalize(a), sep)
  const right = trimEnd(normalize(b), sep)
  if (!isWindows(platform)) return left === right
  return left.toLowerCase() === right.toLowerCase()
}

function trimEnd(path: string, sep: string): string {
  let end = path.length
  while (end > 1 && (path[end - 1] === sep || path[end - 1] === '/')) end -= 1
  return path.slice(0, end)
}

/**
 * The `SessionAccess.create` a real desktop hands to the remote server.
 *
 * Returns a refusal rather than throwing, for the same reason
 * `parseClientMessage` does: the caller answers a refusal by sending a sentence
 * to a phone, and an exception on a socket's data path is how a main process
 * dies.
 */
export function remoteSessionCreator(
  starter: SessionStarter,
  // Passed in rather than read inline, like everything else that branches on
  // the platform in this codebase — `platform/host.ts` says why at length. It
  // is what lets one test on a Mac pin the Windows case-folding answer.
  platform: Platform = currentPlatform(),
): (request: CreateRequest) => Promise<CreateOutcome> {
  const here = `This ${machineNoun(platform)}`
  const { isAbsolute } = rules(platform)
  return async (request: CreateRequest): Promise<CreateOutcome> => {
    const offered = starter.folders()
    let cwd: string

    if (request.cwd === undefined) {
      // The desktop's own default: the folder it would have opened. Its most
      // recent project when it has one, and the user's home when it has none —
      // which is a first launch, and is exactly the case where a phone starting
      // a session is most useful.
      cwd = offered[0] ?? starter.home()
    } else {
      // Absolute first: `normalize('projects/..')` is `'.'`, which would then be
      // compared against a list of absolute paths and lose for the wrong
      // reason. Refusing here says the true thing.
      if (
        !isAbsolute(request.cwd) ||
        !offered.some((folder) => samePath(folder, request.cwd as string, platform))
      ) {
        return {
          ok: false,
          code: 'unauthorized',
          // The folder is not echoed back. It came from the network and this
          // sentence is both sent over the wire and shown on a phone; quoting
          // attacker-chosen text into it buys nothing and costs an output
          // channel.
          message: `${here} will not start a session in that folder. Open it there first.`,
        }
      }
      cwd = request.cwd
    }

    try {
      const meta = await starter.spawn({
        cwd,
        cols: request.cols ?? DEFAULT_COLS,
        rows: request.rows ?? DEFAULT_ROWS,
      })
      return {
        ok: true,
        session: {
          id: meta.id,
          title: meta.title,
          cwd: meta.cwd,
          provider: meta.provider,
          // Nothing has been printed yet, so there is nothing to read a status
          // off. `session-activity.ts` will say otherwise within a frame or two
          // and the phone is already listening for it.
          status: 'idle',
          exitCode: meta.exitCode,
        },
      }
    } catch (error) {
      // The realistic failure is a folder that was listed and has since been
      // deleted or unmounted, which is somebody else's action rather than a
      // wrong request — so it is `unavailable` and worth retrying, not a
      // refusal that sends the user to the pairing screen.
      console.error('[remote] could not start a session:', error)
      return {
        ok: false,
        code: 'unavailable',
        message: `${here} could not start a session there. The folder may have moved.`,
      }
    }
  }
}

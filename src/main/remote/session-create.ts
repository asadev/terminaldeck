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
 * A device may name a folder **only if this desktop is offering that folder to
 * that device**. The list is per device and comes from `folder-grants.ts`: the
 * folders a person chose for this phone, or — when nobody has chosen for it —
 * the desktop's own projects and running sessions, which is what every device
 * used to get. Two things follow, and both matter more than the rule sounds:
 *
 *  - The phone has an honest source for the value. The same array is sent to it
 *    on connect, so a folder picker built from it cannot offer a choice that
 *    fails.
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
 * "wherever you would have started one", which is the first folder on that
 * device's list. An **empty** list is the one case where naming nothing is
 * still refused: it means a person removed every folder from this device, and
 * inventing a destination for it would undo the only thing they said.
 *
 * ## The request has to say who is asking
 *
 * `CreateRequest.deviceId` is required rather than optional, and that is the
 * whole shape of the bug it closes. The connection has always known which
 * device it is — `hello` proved it — and the request travelled down here
 * without it, so this file could only ever answer "may *a* phone start a
 * session here", never "may *this* phone". A required field means the compiler
 * asks the question at every call site instead of a reviewer having to.
 *
 * ## What this file decides, and what it no longer has to apologise for
 *
 * It decides where a session **starts**. What happens after that is
 * `src/main/confine/`, and the answer is now different per platform: on macOS
 * the session is held inside the folder it started in, and on Windows and Linux
 * it is not, because no mechanism there has been measured. This file makes no
 * claim either way — it only has to know that the spawn it calls can refuse for
 * a *third* reason now, and that the refusal deserves its own sentence.
 */

import { posix, win32 } from 'node:path'
import type { SessionMeta } from '../../shared/types'
import { ConfinementUnavailableError } from '../confine'
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
   * Folders this desktop will start a session in **for this device**, most
   * relevant first, and the first of them is where a request that names nothing
   * lands.
   *
   * Called per request rather than captured once, and the device id is passed
   * every time rather than resolved once per connection. Both are the same
   * point: grants are edited from the settings panel while a phone is
   * connected, projects are opened and closed, and sessions come and go. A list
   * snapshotted at startup would refuse a folder the user granted five minutes
   * ago — and, worse in the other direction, would keep honouring a folder that
   * was taken away until the phone reconnected.
   *
   * Empty is a real answer and means this device may start nothing. See
   * `folder-grants.ts` for why that is not flattened into "anywhere".
   */
  folders(deviceId: string): string[]
  /**
   * Start it for real. Throws exactly as `PtyManager.create` throws.
   *
   * `deviceId` travels with it for the same reason it travels on the request —
   * see the header — and for a second one that only appeared once credentials
   * were involved. The session about to be spawned inherits this machine's git
   * login unless it is given one of its own, and "of its own" is *per device*:
   * which folder its global config lives in, and whose phone answers when git
   * asks for a password. A spawn that did not know whose session it was starting
   * could only give every remote session the same isolation, or none.
   */
  spawn(input: { cwd: string; cols: number; rows: number; deviceId: string }): Promise<SessionMeta>
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
export function sameFolder(a: string, b: string, platform: Platform = currentPlatform()): boolean {
  const { normalize, sep } = rules(platform)
  const left = trimEnd(normalize(a), sep)
  const right = trimEnd(normalize(b), sep)
  if (!isWindows(platform)) return left === right
  return left.toLowerCase() === right.toLowerCase()
}

/**
 * Is this a path the rule above can compare at all?
 *
 * Exported for the same reason {@link sameFolder} is: `folder-grants.ts` stores
 * the list this file checks against, and a store that accepted a relative path
 * would be putting a row in the panel that can never match anything — a folder
 * visibly granted and permanently refused. The two questions have to be asked
 * with one implementation or the stored list and the enforced list are two
 * different sets that look like one.
 */
export function isAbsoluteFolder(path: string, platform: Platform = currentPlatform()): boolean {
  return rules(platform).isAbsolute(path)
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
  return async (request: CreateRequest): Promise<CreateOutcome> => {
    const offered = starter.folders(request.deviceId)
    const named = request.cwd
    let cwd: string

    if (named === undefined) {
      // Where this device would have started one: the first folder on its own
      // list. Nothing is invented when that list is empty, because an empty list
      // is a person's answer rather than a gap — see the header.
      const first = offered[0]
      if (first === undefined) {
        return {
          ok: false,
          code: 'unauthorized',
          // Two refusals with two remedies, because they are two different
          // situations to the person holding the phone. This one is "nothing
          // has been shared with you", which no amount of retrying changes and
          // which is fixed at the keyboard the folders live on.
          message: `${here} has no folders chosen for this device. Choose one in its remote access settings.`,
        }
      }
      cwd = first
    } else {
      // Absolute first: `normalize('projects/..')` is `'.'`, which would then be
      // compared against a list of absolute paths and lose for the wrong
      // reason. Refusing here says the true thing.
      if (
        !isAbsoluteFolder(named, platform) ||
        !offered.some((folder) => sameFolder(folder, named, platform))
      ) {
        return {
          ok: false,
          code: 'unauthorized',
          // The folder is not echoed back. It came from the network and this
          // sentence is both sent over the wire and shown on a phone; quoting
          // attacker-chosen text into it buys nothing and costs an output
          // channel.
          //
          // "Pick one from the list it sent" rather than "open it there first",
          // which was true when every device got the same list and is not now:
          // the honest instruction for a device whose folders were chosen for
          // it is to use them, or to change them where they were chosen.
          message: `${here} is not offering that folder to this device. Pick one from the list it sent.`,
        }
      }
      cwd = named
    }

    try {
      const meta = await starter.spawn({
        cwd,
        cols: request.cols ?? DEFAULT_COLS,
        rows: request.rows ?? DEFAULT_ROWS,
        deviceId: request.deviceId,
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
      /*
       * The boundary could not be put around the session, so there is no
       * session. This is deliberate and is the only way the wording on the grant
       * screen stays honest: it tells a person that a session from a device
       * stays inside the folder, and a session that quietly started outside one
       * would make that sentence a lie on a machine nobody was looking at.
       *
       * A separate message because the remedy is completely different from the
       * one below. Nothing about retrying, and nothing about the folder having
       * moved — the folder is fine; the machine is not able to hold a session
       * inside it right now, and that is something only the person at that
       * machine can look into.
       */
      if (error instanceof ConfinementUnavailableError) {
        console.error('[remote] refusing to start an unconfined session:', error.detail)
        return {
          ok: false,
          code: 'unavailable',
          message: `${here} could not keep a session inside that folder, so it did not start one. Check it on the machine itself.`,
        }
      }
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

/**
 * The two halves of "a phone may start a session", built from one starter.
 *
 * `create` enforces the list and `folders` is the list, sent to the device so
 * its picker shows exactly what it may use. They are handed out together
 * because they must never be two answers: a picker offering a folder the rule
 * refuses is the failure this feature exists to end, and it is exactly what
 * happens the first time somebody assembles the advertised list from one place
 * and the enforced list from another. There is one call, `starter.folders`,
 * behind both.
 *
 * The shape is what `SessionAccess` in `server.ts` and `PtySource` in
 * `session-fanout.ts` both want, so `index.ts` spreads this straight into the
 * object it builds and cannot supply one without the other.
 */
export interface RemoteSessionStart {
  create(request: CreateRequest): Promise<CreateOutcome>
  folders(deviceId: string): string[]
}

export function remoteSessionStart(
  starter: SessionStarter,
  platform: Platform = currentPlatform(),
): RemoteSessionStart {
  return {
    create: remoteSessionCreator(starter, platform),
    folders: (deviceId) => starter.folders(deviceId),
  }
}

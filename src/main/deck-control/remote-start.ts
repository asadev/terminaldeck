/**
 * What `sessions.start` may do when the caller is a phone.
 *
 * ## The rule, in one sentence
 *
 * **A tool's effect for a remote caller may never exceed what that device's own
 * protocol frames already permit.**
 *
 * ## Why that needs a file rather than an `if`
 *
 * `control.ts` gates on the *tier*, correctly and airtightly: a device without
 * `act` cannot reach `sessions.start` at all. What a tier cannot express is that
 * the same tool, at the same tier, does a *different amount of damage* depending
 * on who asked.
 *
 * `sessions.start` validates its folder against `requireKnownFolder(surface, …)`
 * — the app's *own* open projects — and hands `startSession` no guest git
 * environment and no confinement. That was right for its whole life, because its
 * caller was the person at the keyboard and they own all of it. Grant a phone
 * `act` with that unchanged and the phone gains, *through the copilot*, three
 * things it does not have directly:
 *
 *  1. **Any folder the desktop has open**, rather than the folders a person
 *     chose for that device. `folder-grants.ts` exists precisely because "the
 *     desktop's projects" was the old, unchosen answer and it was the bug.
 *  2. **The owner's git identity.** A session started without `prepareGuestGit`
 *     inherits this machine's credential helper, `gh` token and ssh agent — so
 *     the device can push as the owner. Measured on the machine this was written
 *     on: `git credential fill` in a granted folder answered with the owner's
 *     real GitHub token.
 *  3. **No confinement.** A device's own session is held inside its folder on
 *     macOS; this one would not be.
 *
 * That is the shape of OpenClaw's GHSA-943q-mwmv-hhvh (OC-02) arriving through a
 * back door: the tool *name* was gated and the tool's *effect* was not.
 *
 * ## How it is closed, and why not by re-implementing the check
 *
 * By routing through the device's own path rather than by copying its rules.
 * {@link requireDeviceFolder} answers the folder question out of
 * `DeckSurface.deviceFolders`, which is the same array `create` is checked
 * against and the same array the phone was sent in its `welcome`; and
 * `DeckSurface.startSession(input, forDevice)` starts the session down the same
 * spawn path a `create` frame takes, so the guest identity and the confinement
 * are the ones that already exist rather than a second implementation of them.
 *
 * A second implementation is the thing to avoid here specifically. Two folder
 * checks drift, and the direction they drift in is not symmetric: the one that
 * gets forgotten is always the one nobody is looking at, which is the one on the
 * remote path.
 *
 * ## Absent means refused
 *
 * A surface with no `deviceFolders` — a test harness, a headless host with no
 * remote layer, some future embedding — cannot answer "may this device use this
 * folder", and the answer for a host that cannot answer is **no**. Falling back
 * to the desktop's project list would be the exact widening this file exists to
 * prevent, and it would be invisible: everything would work, for everybody, all
 * the time.
 */

import { sameFolder } from '../remote/session-create'
import { Refused, type Caller } from './surface'

/** The slice of the surface this rule reads. Narrow, so a test can pass a literal. */
export interface RemoteStartSurface {
  deviceFolders?(deviceId: string): string[]
}

/**
 * True when this call came from a paired device rather than from the person.
 *
 * A function rather than `caller.kind === 'remote'` written at each site, so the
 * one place that decides what "remote" means is here. `deviceId` is narrowed
 * along with it: a remote caller with no device id is not a thing the transport
 * can produce — the id comes off an authenticated connection — but the type
 * allows it, and treating that as *local* would be the permissive reading of a
 * state that should not exist.
 */
export function remoteDevice(caller: Caller): string | null {
  if (caller.kind !== 'remote') return null
  return typeof caller.deviceId === 'string' && caller.deviceId !== '' ? caller.deviceId : ''
}

/**
 * Narrow a folder to the ones this device was granted, or refuse.
 *
 * Returns the **desktop's own spelling** of the folder, taken from its list,
 * never the string that arrived with the call. The two can differ by a trailing
 * separator, or by case on Windows, and still be the same directory —
 * `sameFolder` is what says so — and passing the desktop's copy onward means
 * nothing downstream has to trust a path that came from a language model on the
 * far side of a relay.
 *
 * `Refused` rather than `BadArgument`, and `not-permitted` rather than
 * `not-granted`: this is not "your device holds the wrong tier", which is
 * `control.ts`'s answer and means *stop asking*. This is "that particular folder
 * is not yours", which a different argument to the same tool can fix — and the
 * sentence says which folders to ask about instead, because a model that is told
 * only "refused" spends the rest of its turn guessing.
 *
 * The folder is deliberately **not** echoed back into the message. It came from
 * a model prompted by somebody holding a phone, the sentence travels back over
 * the relay, and quoting attacker-influenceable text into a refusal buys nothing
 * and costs an output channel. `session-create.ts` makes the same choice.
 */
export function requireDeviceFolder(
  surface: RemoteStartSurface,
  deviceId: string,
  folder: string,
): string {
  const list = surface.deviceFolders
  if (!list) {
    throw new Refused(
      'not-permitted',
      'starting a session on behalf of a device is not available on this machine, so this was refused. ' +
        'Tell the person what you would have started and let them start it.',
    )
  }
  const offered = deviceId === '' ? [] : list(deviceId)
  const granted = offered.find((candidate) => sameFolder(candidate, folder))
  if (granted === undefined) {
    throw new Refused(
      'not-permitted',
      offered.length === 0
        ? 'this device has no folders chosen for it, so it cannot start a session anywhere. ' +
          'Nothing was started. Say so, and do not retry — the folders are chosen on the desktop, in Settings.'
        : `this device may only start a session in: ${offered.join(', ')}. ` +
          'Nothing was started. Use one of those, or say what you would have needed.',
    )
  }
  return granted
}

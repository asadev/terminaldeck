/**
 * Which sessions were started *by* a paired device, so this app knows whose
 * browser window a browser verb from one of them is about.
 *
 * ## Why this fact has to be written down
 *
 * A session started for a device runs here — a pty on this machine, in a folder
 * that device was granted — and the browser window attached to it is over
 * *there*, in the app the person is actually looking at. `browser-binding.ts`
 * makes the same distinction from the other end and its header is worth reading
 * beside this one: `SessionBinding.machineId` is where the session runs and
 * `BoundWindow.hostMachineId` is which machine serves the page. Neither of them
 * answers *which app holds the window object*, because on that machine the
 * answer is always "this one". Here it is always "the device's", and there is
 * nothing on the pty, in its environment or in its id that says so.
 *
 * So it is recorded at the one moment it is known: `host-core.ts`'s device spawn
 * has `input.deviceId` in hand, and nothing downstream of that ever sees it
 * again.
 *
 * ## Why a module of its own with no imports
 *
 * The same three-reader argument `session-verbs.ts` makes next door, and the
 * same constraint. It is written by `host-core.ts`, read by `index.ts` when it
 * builds the forwarder that `deck-control`'s browser tools use, and it must not
 * drag `deck-control/` or `remote/` into the headless bundle — which runs the
 * same `startSession` with neither.
 */

/** sessionId → the device that asked for it. Absent means nobody did. */
const owners = new Map<string, string>()

/**
 * Write down that this session belongs to a device.
 *
 * Called with the session id rather than at the moment the spawn is decided,
 * because the id does not exist until the pty does — the same ordering
 * `sessionTools.started` and `noteNoVerbs` are subject to, for the same reason.
 */
export function noteWindowOwner(sessionId: string, deviceId: string): void {
  if (sessionId === '' || deviceId === '') return
  owners.set(sessionId, deviceId)
}

/**
 * The device that started this session, or null.
 *
 * Null is the answer for every ordinary session in the window, and it is the
 * answer that keeps a verb local: a session nobody started remotely has its
 * windows here or nowhere.
 */
export function windowOwnerOf(sessionId: string): string | null {
  return owners.get(sessionId) ?? null
}

/**
 * The session is gone.
 *
 * Called on the exit edge for every session, device or not, because a call that
 * is a no-op for most of them is cheaper than a second condition that has to
 * agree with the one above. Ids are minted once and never reused, so an entry
 * left behind could never mean anything again — the argument `forgetNoVerbs`
 * makes beside it.
 */
export function forgetWindowOwner(sessionId: string): void {
  owners.delete(sessionId)
}

/** Test seam. Nothing in the app calls this; every real drop is a session ending. */
export function resetWindowOwnersForTests(): void {
  owners.clear()
}

/**
 * Which machine groups the rail is currently drawing, and which one Close has
 * folded away.
 *
 * One rule, in one file, because it is asked twice in the same render pass —
 * once by the rail's own list and once by the effect that forgets an entry whose
 * meaning has expired — and a rule spelled twice is a group that one of them
 * hides while the other draws it.
 */

/**
 * One machine whose group somebody pressed Close on, and the sessions that were
 * running at that moment.
 *
 * The ids are the whole of the mechanism; see {@link machineIsClosed}.
 */
export interface ClosedMachine {
  id: string
  sessions: readonly string[]
}

/**
 * Is this machine's group hidden because somebody pressed Close on it?
 *
 * ## The rule, and the race it was written for
 *
 * Asad decided what Close means on a machine: *"it should not disconnect the
 * remote account. It will just close all of the sessions from that PC. Yeah, you
 * can give this close too, so it will go from here, but whenever you want to
 * start, you can start as a new session and you can start from that device."*
 *
 * Three things, and the middle one is the hard one. The sessions end **on the
 * other computer**, so at the instant Close is pressed they are all still
 * listed. A rule of the form "hidden until something is running there again"
 * therefore un-hides in the same render that hides, and the press does nothing
 * you can see. That is exactly what the first version did, and it is invisible
 * in the source — it was found by driving the app and watching the group stay
 * put.
 *
 * So an entry remembers the ids that were running when Close was pressed, and
 * the group is hidden while **every** session there is one of them. Draining to
 * nothing keeps it hidden; a session appearing that nobody here closed brings it
 * back. `[].every(…)` is true, which is the empty case answering correctly
 * rather than by accident: a machine whose sessions have all ended is a machine
 * with nothing that was not closed.
 *
 * Pure and in a module of its own so the render and the effect in `App.tsx` ask
 * the same question of the same function — the alternative is two spellings of one rule, which is how
 * a group comes to be hidden by one and drawn by the other in the same frame.
 */
export function machineIsClosed(
  closed: readonly ClosedMachine[],
  machineId: string,
  running: readonly { id: string }[],
): boolean {
  const entry = closed.find((one) => one.id === machineId)
  if (!entry) return false
  return running.every((session) => entry.sessions.includes(session.id))
}

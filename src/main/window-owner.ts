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
 * ## And the other half of the same question, since the evening of 2026-08-21
 *
 * A spawn is not the only way a session comes to have its window somewhere else,
 * and it is not even the common one. Asad's first test was a session already
 * running on his PC — started at that keyboard, or restored there — with a
 * browser window attached to it from his Mac. Nothing spawned it for anybody, so
 * this map is empty for it, and every one of its browser verbs was served on the
 * PC against the PC's own empty binding map: *"no browser window is attached to
 * this session"*, about a page he was looking at.
 *
 * The missing fact cannot be derived here. It lives in the *other* app's
 * process, so it travels — `window.holds` in `remote/protocol.ts`, landing in
 * `WindowAskDesk.holdersOf`. {@link routeWindowVerb} is where the two answers
 * meet, and it is in this file because the precedence between them is the whole
 * of the rule and belongs beside the map it overrides.
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

/* -------------------------------------------------------------- the route -- */

/** Where one browser verb goes. */
export type WindowRoute =
  /** This app. Every session in this window with a window of its own, and every session with none. */
  | { kind: 'here' }
  /** That device's app, over `window.call`. */
  | { kind: 'device'; deviceId: string }
  /** More than one computer holds a window for it, so there is no single answer. */
  | { kind: 'ambiguous'; deviceIds: string[] }

/** What {@link routeWindowVerb} has to ask of the rest of the app. */
export interface WindowRouteDeps {
  /** Does *this* app hold a browser window attached to that session? */
  attachedHere(sessionId: string, machineId: string): boolean
  /** Which devices have said they are holding one. See `WindowAskDesk.holdersOf`. */
  holders(sessionId: string): readonly string[]
}

/**
 * Which app holds the window this session's verb is about.
 *
 * ## 1. A session a paired device started belongs to that device, always
 *
 * `host-core.ts`'s gate used to refuse such a session these verbs outright, and
 * its reason still binds: the session runs on **this** machine, so a verb served
 * locally would let a paired device drive the browser holding this account's
 * logins, through a token that says `session` rather than `remote` and therefore
 * slips past the refusal `browser-tools.ts` makes to a device's face.
 *
 * So this branch has no local fallback and must never grow one. There is no
 * "unless a window here is attached to it" clause, because such a clause *is*
 * the door: attach one window on this machine to a guest's session and the
 * guest's agent has it.
 *
 * ## 2. Any other session's window is wherever it was attached
 *
 * **This machine first**, and the difference from branch 1 is the point rather
 * than an inconsistency. Branch 1 is about somebody else's session, where a
 * local window is a boundary being walked around. This is the person's own
 * session, where a window they attached in this app is simply the nearest true
 * answer — it costs no frame, and it also means a paired machine cannot take a
 * local session's verbs away from the window on this screen by naming it in a
 * `window.holds`.
 *
 * Then the devices that said they hold one. Two of them is refused by the
 * caller rather than resolved: two people can each attach a window of their own
 * to one session here and neither is wrong, so a verb with two destinations has
 * no correct one and driving the wrong person's browser is not a thing to do on
 * a guess.
 */
export function routeWindowVerb(
  session: { sessionId: string; machineId: string },
  deps: WindowRouteDeps,
): WindowRoute {
  /*
   * A caller with no session id is the token that has been minted but not yet
   * bound — see `session-tools.ts`, which hands out exactly that for the breath
   * between the two. It may do nothing at all, and it certainly may not be
   * routed to a machine on the strength of an id that names no session.
   */
  if (session.sessionId === '') return { kind: 'here' }
  const spawned = windowOwnerOf(session.sessionId)
  if (spawned !== null) return { kind: 'device', deviceId: spawned }
  if (deps.attachedHere(session.sessionId, session.machineId)) return { kind: 'here' }
  const holders = deps.holders(session.sessionId)
  if (holders.length === 0) return { kind: 'here' }
  if (holders.length > 1) return { kind: 'ambiguous', deviceIds: [...holders] }
  return { kind: 'device', deviceId: holders[0] }
}

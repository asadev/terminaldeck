/**
 * Turning a session list into something worth looking at on a phone.
 *
 * The list is the screen someone opens while walking, to answer one question:
 * is the thing I left running still going, and does it need me? So the order
 * and the two words next to each row carry the whole feature, and both are
 * derived here rather than in the DOM code, where they could not be tested.
 */

import { CAPABILITY, type RemoteSession, type ServerMessage } from './protocol-client'

/**
 * Whether this machine will let this browser end a session.
 *
 * Gated on the advertisement, which is the standing rule for every capability in
 * this client and matters more here than anywhere else: ending a session is not
 * undoable, so a Delete that turned out to be refused would be a control that
 * either did nothing or destroyed something, and the person pressing it could
 * not tell which until afterwards.
 *
 * Two hosts withhold it and both are real. A session layer that cannot end a
 * session does not offer the method the capability is derived from; and the
 * public demo box, which hands strangers a shell, deliberately offers `create`
 * without this one — starting something there is additive and bounded by a
 * container, ending something is neither.
 */
export function closeOffered(capabilities: readonly string[]): boolean {
  return capabilities.includes(CAPABILITY.close)
}

/**
 * The sentence above the two buttons, once somebody has asked to delete a row.
 *
 * Written here rather than in the renderer for the reason `noticeAfter` gives
 * about itself: there is no DOM under vitest, so copy composed inside a `render`
 * is copy nothing in this repository can check — and this is the one string in
 * the client that has to be *exactly* right, because it is the last thing a
 * person reads before work stops.
 *
 * It says three things and no more: which session, what happens to it, and that
 * it does not come back. It deliberately does not say "are you sure" — the two
 * buttons underneath already ask that, and a sentence spent on the question is a
 * sentence not spent on the consequence.
 *
 * ## The word is *Delete*, everywhere it destroys something
 *
 * > *"Close might be confusing for the people — they just think okay it will be
 * > just close, soft close or something. But delete, they know that click it will
 * > go away completely. So don't give the button as close in drop downs, in three
 * > dots, everywhere."*
 *
 * The verb on the wire is still `close` and stays that way — what the machine
 * does is end a session, and renaming a frame would break every host that
 * already speaks it. What changes is the only part a person reads. *Close* is
 * the word the browser this client runs in uses for a tab that reopens from the
 * history menu, so it is the one word that could not be used for the thing that
 * does not come back.
 */
export function closeQuestion(session: RemoteSession): string {
  return `Delete ${session.title}? The session stops on the machine and does not come back.`
}

/**
 * Whether this machine will take a name for one of its sessions.
 *
 * > *"I said before, for being able to rename sessions."*
 *
 * Read separately from {@link closeOffered} rather than folded into it, because
 * the two are genuinely separable at the far end — a host that hands out shells
 * and will not let a device end one can still let somebody label the shell they
 * are looking at, and a host whose session layer has no writable title cannot,
 * however freely it closes things. `server.ts` derives each from its own method,
 * so a client that assumed one from the other would draw a row that can only be
 * refused.
 *
 * An older desktop never advertises it and gets no Rename row at all — absent
 * rather than greyed, the rule every capability in this client follows.
 */
export function renameOffered(capabilities: readonly string[]): boolean {
  return capabilities.includes(CAPABILITY.rename)
}

/**
 * The line under the rename field, saying the one thing the field cannot.
 *
 * Two facts, and neither is guessable from an empty box. A name goes to the
 * machine, so it is not this browser's private label the way a port's name is —
 * every device signed in there reads it. And an empty field is not a cancel:
 * it is how the machine is told to go back to the name it derives from the
 * folder, which is the only way to undo a rename without knowing what that
 * folder is called.
 *
 * Here rather than in the renderer for the reason {@link closeQuestion} is: copy
 * composed inside a `render` is copy nothing in this repository can check.
 */
export const RENAME_NOTE =
  'Every device signed in here sees the new name. Leave it empty to go back to the folder’s own name.'

/**
 * The one sentence standing above the session list, after this frame.
 *
 * ## The bug this was extracted for
 *
 * Pairing a browser goes: type the code, the desktop answers *"Paired. Approve
 * this device in the desktop app, then reconnect"*, somebody approves it, the
 * socket comes back with a `welcome`, and the real session list draws. That
 * sentence stayed on screen — above the live list, on both the dev build and
 * on app.terminaldeck.dev — telling a person to go and do a thing they had
 * already done, while the evidence that they had done it was three rows below
 * it. Found by looking at a screenshot of a successful pairing, which is the
 * only way it could have been found: nothing was broken, and every frame
 * involved was handled correctly on its own.
 *
 * A notice is a report about the **last thing the machine said**. A `welcome` is
 * the machine saying something newer and better, so it ends every notice there
 * is — not only the pairing one. Any refusal a previous connection was still
 * complaining about is, by definition, over: this is a fresh socket that got
 * through, and the desktop has just re-stated the whole session list.
 *
 * ## Why it is a function here rather than four lines in `main.ts`
 *
 * The same reason `foldersAfter` is, and `main.ts` says so at its own call site:
 * a rule that lives inside the `switch` is a rule nothing in this repository can
 * check. There is no DOM under vitest, so a decision written in the renderer is
 * a decision verified only by somebody remembering to take a screenshot — which
 * is exactly how this one shipped. Written here, `sessions.test.ts` holds it.
 *
 * Takes the previous notice and returns the next one, rather than mutating, so
 * "this frame says nothing about the notice" has an obvious spelling and is the
 * default for every frame not named below.
 *
 * @param noun What this client calls the machine — "Mac", "PC", "desktop". The
 * caller owns that word (`host-platform.ts`), because it is the one thing in
 * this sentence that depends on what answered.
 */
export function noticeAfter(notice: string | null, message: ServerMessage, noun: string): string | null {
  // A machine that has just said hello has nothing outstanding to apologise for.
  if (message.t === 'welcome') return null
  if (message.t !== 'error') return notice
  /*
   * Rewritten rather than shown, and only this one. `unknown-session` is the
   * desktop refusing a frame about a session that has gone, and its own wording
   * is aimed at a client, not at a person standing in a queue. Every other code
   * carries a sentence the desktop composed for a human — see
   * `PROTOCOL_ERROR_CODES` — and re-writing those here would be this client
   * inventing an explanation for a refusal it does not understand.
   */
  if (message.code === 'unknown-session') return `That session is no longer running on the ${noun}.`
  return message.message
}

/**
 * The dot's colour.
 *
 * `RemoteSession.status` is a free-form string on the wire — the vocabulary
 * belongs to the desktop's session layer, and pinning it here would mean a
 * status added there arrives as a crash rather than as a grey dot. The six
 * known ones are the desktop's `SessionStatus` union; anything else is
 * `unknown`, drawn neutral, with the word itself shown beside it.
 */
export type StatusTone = 'working' | 'waiting' | 'input' | 'completed' | 'idle' | 'exited' | 'unknown'

const TONES: Record<string, StatusTone> = {
  working: 'working',
  waiting: 'waiting',
  input: 'input',
  completed: 'completed',
  idle: 'idle',
  exited: 'exited',
}

export function statusTone(status: string): StatusTone {
  return TONES[status.trim().toLowerCase()] ?? 'unknown'
}

/**
 * The tone for a whole row.
 *
 * An exit code outranks the status string. A session that has finished keeps
 * whatever status it last reported — usually `idle` — and drawing it with the
 * same dot as a session that is alive and merely quiet is the one distinction
 * this list exists to make.
 */
export function sessionTone(session: RemoteSession): StatusTone {
  return session.exitCode !== null ? 'exited' : statusTone(session.status)
}

/** What the row says beside the dot. Unknown statuses show their own word. */
export function statusLabel(session: RemoteSession): string {
  if (session.exitCode !== null) return session.exitCode === 0 ? 'Finished' : `Exited (${session.exitCode})`
  switch (statusTone(session.status)) {
    case 'working':
      return 'Working'
    case 'waiting':
      return 'Waiting'
    case 'input':
      return 'Needs input'
    case 'completed':
      return 'Done'
    case 'idle':
      return 'Idle'
    case 'exited':
      return 'Exited'
    default:
      return session.status
  }
}

/**
 * "4m ago", or null when nothing real is known.
 *
 * Null is the important return. The wire carries no activity timestamp today,
 * so for a session this phone has never attached to there is nothing true to
 * print, and the row prints nothing rather than the moment the list arrived
 * dressed up as the moment the session last did something.
 */
export function formatSince(now: number, at: number | null): string | null {
  if (at === null || !Number.isFinite(at) || at <= 0) return null
  const seconds = Math.floor((now - at) / 1000)
  if (seconds < 0) return 'just now'
  if (seconds < 45) return 'just now'
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${Math.max(1, minutes)}m ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h ago`
  return `${Math.floor(hours / 24)}d ago`
}

/**
 * The order rows appear in.
 *
 * Live sessions first, most recently active first within that, and finished
 * ones at the bottom. A phone shows five rows without scrolling, and the one
 * that needs attention has to be in them.
 */
export function sortSessions(sessions: readonly RemoteSession[], activity: ReadonlyMap<string, number>): RemoteSession[] {
  const rank = (session: RemoteSession): number => {
    if (session.exitCode !== null) return 3
    return statusTone(session.status) === 'input' ? 0 : 1
  }
  return [...sessions].sort((a, b) => {
    const byRank = rank(a) - rank(b)
    if (byRank !== 0) return byRank
    const byActivity = (activity.get(b.id) ?? 0) - (activity.get(a.id) ?? 0)
    if (byActivity !== 0) return byActivity
    return a.title.localeCompare(b.title)
  })
}

/** The folder a session is in, shortened for a 375px-wide screen. */
export function shortenPath(cwd: string, home?: string): string {
  const path = home !== undefined && home !== '' && cwd.startsWith(home) ? `~${cwd.slice(home.length)}` : cwd
  const parts = path.split('/').filter((part) => part !== '')
  if (parts.length <= 2) return path
  return `…/${parts.slice(-2).join('/')}`
}

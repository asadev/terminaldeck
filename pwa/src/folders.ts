/**
 * Where a new session may start, and how the picker says so.
 *
 * ## The bug this file exists to end
 *
 * A phone showed **one folder** and nothing on it explained why. The list was
 * never chosen by anybody: it was assembled on the client out of the working
 * directories of the sessions it happened to be able to see, so it grew when
 * something was started at the desk, shrank when something exited, and differed
 * from what the desktop would actually have accepted. Two lists that looked
 * like one, and the person holding the phone had no way to find out which was
 * which.
 *
 * The desktop now decides, per device, and sends the answer twice: in
 * `welcome.folders` and again as a pushed `folders` frame whenever the list is
 * edited. That array is the same one the desktop's own `create` rule enforces
 * against — see `session-create.ts` — so a folder drawn from it is a folder
 * that will start.
 *
 * ## Three answers, and none of them may be flattened into another
 *
 *   - **A list** — those folders and no others. Draw them.
 *   - **Empty** — somebody chose no folders for this device. Nothing will
 *     start, and the screen has to say so *and* say where that is changed,
 *     because the remedy is on a machine that is not in the user's hand.
 *   - **Nothing said** — the field is absent. That is a desktop released before
 *     it existed, and it is still a desktop this client has to work with, so it
 *     falls back to what this client did before: the folders sessions are
 *     already running in. Reading absent as empty would take a working feature
 *     away from every phone paired to an older machine.
 *
 * ## Why the rows are computed here and not in the DOM code
 *
 * `main.ts` owns a browser and cannot be asked questions in a test. What the
 * picker offers is exactly the thing that was wrong, so it is a value produced
 * by a function — the rows are asserted directly, including the one that used
 * to be assembled from session working directories.
 */

import type { RemoteSession, ServerMessage } from './protocol-client'

/** What the desktop has told this device about where it may start a session. */
export type FolderOffer =
  /** The desktop chose folders for this device. These, in its own order. */
  | { kind: 'granted'; folders: string[] }
  /** The desktop chose *no* folders for this device. Nothing will start. */
  | { kind: 'none' }
  /** The desktop never mentioned folders. Fall back to what is running. */
  | { kind: 'unsaid'; folders: string[] }

/**
 * The folder list after one frame, or the one we already had.
 *
 * A reducer rather than two assignments inside a screen, because the property
 * worth pinning is that the *pushed* frame lands as surely as the one inside
 * `welcome` does. Removing a grant on the desktop has to take the folder off
 * the phone's picker while it sits there connected — if that only happened on
 * the next `welcome`, the picker would keep offering a tap whose one outcome is
 * a refusal until somebody quit and reopened the app.
 *
 * Every other frame returns what it was handed, so the caller can run this over
 * everything that arrives rather than remembering which two message types
 * matter — which is the version of this that goes stale the day a third one is
 * added.
 */
export function foldersAfter(current: string[] | null, message: ServerMessage): string[] | null {
  if (message.t === 'welcome') return message.folders ?? null
  if (message.t === 'folders') return message.folders
  return current
}

/**
 * Which of the three answers this client is holding.
 *
 * `sessions` is only read in the last case. It is the old behaviour, kept for
 * old desktops and for nothing else: against a machine that sends the field,
 * what is running has no bearing on what may be started, and mixing the two
 * back together is how the picker would start disagreeing with the rule again.
 */
export function folderOffer(granted: readonly string[] | null, sessions: readonly RemoteSession[]): FolderOffer {
  if (granted === null) {
    const seen: string[] = []
    for (const session of sessions) {
      if (session.cwd !== '' && !seen.includes(session.cwd)) seen.push(session.cwd)
    }
    return { kind: 'unsaid', folders: seen }
  }
  return granted.length === 0 ? { kind: 'none' } : { kind: 'granted', folders: [...granted] }
}

/** One thing the picker offers to start a session in. */
export interface FolderRow {
  /** What the row reads. */
  label: string
  /** The folder to ask for, or null for "wherever you would have". */
  folder: string | null
  /**
   * Whether the label is a path.
   *
   * Paths are set in mono and everything else is not — the house rule is that
   * monospace is a promise the characters are exact and countable, which is
   * true of `/Users/asad/Projects/api` and not of a sentence about a Mac.
   */
  path: boolean
}

/**
 * The rows to draw, in order.
 *
 * "Wherever the Mac would" appears **only** when the desktop said nothing. With
 * a granted list that row is not a second choice, it is the first folder under
 * another name — the desktop starts in `folders[0]` when a `create` names
 * nothing — so drawing both would be the same destination twice, one of them
 * described in a way that hides which folder it is. That is the ambiguity this
 * whole feature is removing.
 *
 * Empty for `none`: there is nothing to offer, and what that state needs is a
 * sentence rather than a control. See {@link noFoldersSentence}.
 */
export function pickerRows(offer: FolderOffer, noun: string): FolderRow[] {
  if (offer.kind === 'none') return []
  const rows: FolderRow[] = []
  if (offer.kind === 'unsaid') rows.push({ label: `Wherever the ${noun} would`, folder: null, path: false })
  for (const folder of offer.folders) rows.push({ label: folder, folder, path: true })
  return rows
}

/**
 * What to say when the desktop has granted this device nothing.
 *
 * Both halves are load-bearing. The first says the machine has not shared a
 * folder — not that the app is broken, and not that anything has gone wrong on
 * the phone. The second says where that is changed, naming the real screen, because
 * the person reading this is holding the one device that cannot fix it and the
 * failure of the old picker was precisely that it explained nothing.
 *
 * The wording tracks the desktop's own refusal in `session-create.ts` — "has no
 * folders chosen for this device. Choose one in its remote access settings" —
 * on purpose: the two sentences are read minutes apart by the same person, and
 * two different vocabularies for one situation reads as two different problems.
 */
export function noFoldersSentence(noun: string): string {
  return `The ${noun} has not shared a folder with this device, so a session cannot be started from here. Choose one on it, under Settings → Remote access → Folders.`
}

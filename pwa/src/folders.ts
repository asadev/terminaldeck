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
 *
 * ## The second bug: one folder, listed twice
 *
 * Caught on video. The browser client's "Start in" list read
 * `/home/asad/ClaudeImza`, `/home/asad/ClaudeImzacrm`, and then both again.
 * Nothing here was appending: the desktop genuinely sent four entries.
 *
 * When nobody has chosen folders for a device, `foldersForDevice` in
 * `src/main/remote/folder-grants.ts` falls back to what the host is offering
 * everyone, and `src/main/host-core.ts` builds that by **concatenating two
 * sources** — the open projects, then the working directory of every running
 * session — with no pass to merge them. A project that is open *and* has a
 * session running in it is therefore in the array twice. He had two projects
 * open with a session in each, which is the four rows, in that order. Run
 * against the real `foldersForDevice`, that input produces exactly the list he
 * was looking at.
 *
 * The host is where that should also be fixed, and it is outside this client's
 * files. But it is not the *only* place it has to be fixed, and that is the
 * reason the rule below lives here as well rather than only there: this client
 * is a web page that updates the moment somebody reloads it, and it talks to
 * whatever desktop the person already has installed. Every released build keeps
 * sending the duplicated list. A client that renders a wire message faithfully
 * and a client that renders it *usefully* differ exactly here — the same
 * argument `sessionRows` makes when it drops a malformed row instead of
 * discarding the whole list.
 *
 * The asymmetry that let it through is visible in the two branches of
 * {@link folderOffer}: the fallback branch had always merged duplicates, because
 * two sessions in one folder is obvious, and the granted branch had never merged
 * anything, because a list somebody chose by hand cannot repeat itself. It can,
 * once the list is not the one somebody chose.
 */

import type { HostPlatform } from './host-platform'
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
 * One directory, written two ways — the *display* half of the desktop's rule.
 *
 * `sameFolder` in `src/main/remote/session-create.ts` is the original and is
 * commented at length; this is deliberately a weaker restatement rather than an
 * import, because that module resolves paths with `node:path` and this one
 * compiles into a browser with `"types": []`, where a single node built-in stops
 * the build. Restating it is a cost, so it is worth being exact about what is
 * restated and what is not:
 *
 *   - **Trailing separators are ignored.** A project stored as `/a/b/` and a
 *     session's `cwd` of `/a/b` are one directory. Both separators, because a
 *     Windows host sends Windows paths and a WSL project on that same host
 *     sends POSIX ones.
 *   - **Case is folded on Windows only.** NTFS genuinely does not distinguish
 *     `C:\Users\Asad` from `c:\users\asad`, and both spellings really arrive —
 *     the desktop's own note records the drive letter coming back capitalised
 *     from one API and lower-cased from another. A POSIX filesystem does
 *     distinguish them, so folding there would merge two real folders.
 *   - **`.` and `..` are not resolved**, which the desktop's version does.
 *
 * That last omission is safe *here* and would not be there, and the difference
 * is what this function decides. The desktop's copy decides whether a session
 * may start; being too lax would let a phone name a folder nobody granted. This
 * copy decides only whether two rows in a list are the same row, so being too
 * strict merges nothing and shows a duplicate, while being too lax would hide a
 * folder somebody could have started in. It may under-merge. It must never
 * over-merge, and without `normalize` it cannot.
 */
export function samePath(a: string, b: string, platform: HostPlatform): boolean {
  const left = withoutTrailingSeparator(a)
  const right = withoutTrailingSeparator(b)
  if (platform !== 'windows') return left === right
  return left.toLowerCase() === right.toLowerCase()
}

/** `end > 1` so `/` and `\` survive as themselves — an empty string is not a path. */
function withoutTrailingSeparator(path: string): string {
  let end = path.length
  while (end > 1 && (path[end - 1] === '/' || path[end - 1] === '\\')) end -= 1
  return path.slice(0, end)
}

/**
 * The same folders, in the order they arrived, each of them once.
 *
 * First occurrence wins, which keeps the desktop's ordering intact — it sends
 * open projects before running sessions, and that is the order a person
 * recognises.
 *
 * Quadratic, and deliberately. A chosen list is capped at
 * `MAX_FOLDERS_PER_DEVICE` (64) on the machine that sends it; the fallback list
 * is not capped by count at all, only by `MAX_MESSAGE_BYTES` on the frame around
 * it, so the real ceiling is a few thousand short paths and the real input is a
 * dozen. The alternative is a `Map` keyed by a folded string, which would mean
 * writing the comparison rule a second time in a second shape — and a folding
 * key that disagrees with {@link samePath} is exactly the class of bug this
 * function exists to end.
 */
function distinct(paths: readonly string[], platform: HostPlatform): string[] {
  const kept: string[] = []
  for (const path of paths) {
    if (path === '') continue
    if (kept.some((seen) => samePath(seen, path, platform))) continue
    kept.push(path)
  }
  return kept
}

/**
 * Which of the three answers this client is holding.
 *
 * `sessions` is only read in the last case. It is the old behaviour, kept for
 * old desktops and for nothing else: against a machine that sends the field,
 * what is running has no bearing on what may be started, and mixing the two
 * back together is how the picker would start disagreeing with the rule again.
 *
 * Both branches now go through {@link distinct}. They used to disagree about it,
 * and the header explains what that cost: the fallback merged duplicates and the
 * granted list did not, on the reasoning that a hand-chosen list cannot repeat
 * itself — which stopped being true the moment the desktop started sending a
 * list nobody had chosen.
 *
 * `platform` defaults to `unknown`, which compares exactly. That is the right
 * default rather than a shortcut: an absent `hostPlatform` means a desktop
 * released before the field, and guessing Windows for one of those would fold
 * case on a Linux host, where two folders differing only in case are two
 * folders. Under-merging shows a duplicate; over-merging hides a destination.
 */
export function folderOffer(
  granted: readonly string[] | null,
  sessions: readonly RemoteSession[],
  platform: HostPlatform = 'unknown',
): FolderOffer {
  if (granted === null) {
    return { kind: 'unsaid', folders: distinct(sessions.map((session) => session.cwd), platform) }
  }
  // Measured after the merge rather than before. For anything the wire can
  // actually carry the two are the same test — `stringList` in `protocol.ts`
  // has already dropped every empty entry, so merging cannot empty a list that
  // was not empty. Where they differ is on a list this client built for itself
  // by mistake, and there the safe reading is "nothing to offer" rather than a
  // picker with a toggle and no rows behind it.
  const folders = distinct(granted, platform)
  return folders.length === 0 ? { kind: 'none' } : { kind: 'granted', folders }
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

/**
 * Artifacts, on the phone — the desktop's panel rather than a list of what it
 * found.
 *
 * ## Why this replaced what was here
 *
 * > *"these pages are not just to view the information — exactly all actions
 * > that we have in desktop application, they should be inside each option of
 * > them. All the features and options to edit or add or whatever the actions
 * > we have in the desktop app should be in mobile app too."*
 *
 * What the phone had was one call to `projectTranscripts`, its first two
 * hundred entries, and no control at all — no search, no *made / changed*, no
 * choice of which sessions to read, no way to open the file it had just named.
 * The desktop panel (`src/renderer/components/ArtifactsPanel.tsx`) has all
 * four, and three of them are not decoration: the made/changed split is the
 * thing that makes the page Artifacts and not Files, and it has been reported
 * twice by that name.
 *
 * So this reads the *same module the desktop reads* — `listArtifacts` in
 * `src/main/artifacts.ts`, which is what its IPC channel answers with — and
 * offers the same four controls through the panel contract. Nothing here parses
 * a transcript; that argument, and the evidence behind it (175 files, 3,190
 * matching tool calls), is written down once, there.
 *
 * ## What a row is, and what it is not
 *
 * The meaning is pinned in the two files above and is not restated here, except
 * for the one line this file has to keep: **made** is a file an agent wrote
 * whole (`writes > 0`), **changed** is a file that already existed and an agent
 * edited. Both are reachable, one chip apart, and `made` is the default because
 * it is what the word means.
 *
 * ## What is not on this page
 *
 * > *"an artifact is still showing the MD files, which is — multiple times I
 * > have discussed about it. Artifact should not show the MD files. It should
 * > be only for purely the prototypes."*
 *
 * A row is therefore a **prototype, a picture or a recording** — `page`,
 * `image`, `media` — and nothing else is sent. Markdown, prose, source and
 * every unrecognised extension the `text` catch-all swallowed are dropped by
 * {@link isArtifact}, and so is `other`: a `.zip` this page can only name and
 * measure is a file-browser row. A markdown file is still readable on this
 * phone — **Files** is where, because Files is the file browser and this is
 * not. Nothing here touches anything on disk.
 *
 * The filter runs **at the scan**, in {@link onlyArtifacts}, before a single
 * count is taken. That seam is the requirement: the note's totals, the
 * made/changed split, the session chips and the empty state are all read off
 * the narrowed list, so there is nowhere for *"3 made here"* to stand above an
 * empty list.
 *
 * And it runs on the **desktop**, not on the phone. One side decides what an
 * artifact is — the same side that already decides what `kind` a row wears —
 * so a client cannot come to disagree with it, and a phone he has not updated
 * cannot go back to showing him `PLAN.md`.
 *
 * ## The scope encoding
 *
 * `PanelRequest.scope` is a single string and the desktop has three independent
 * controls, so the string is a **set of space-separated tokens**, read in any
 * order, first token of a dimension wins:
 *
 *     made | changed          which half of the record          (default: made)
 *     project | all           which transcripts to read          (default: all)
 *     session:<id>            one session's work only
 *     session:*               every session that wrote here     (default)
 *
 * An unrecognised token is ignored rather than refused, so a phone built
 * against a later vocabulary degrades to the nearest state this build knows
 * instead of an error. An absent scope is the default state, which is what an
 * older client that never sends one gets.
 *
 * **Every chip's `id` is a complete state** — the state that tapping it
 * produces — with its own token written first. That is what lets a tap change
 * one dimension and keep the other two, which is the whole reason the string
 * is a set: `changed all session:*` is a real thing to ask for and *changed*
 * alone would silently throw the session choice away. Writing the tapped
 * token first is also what keeps the ids distinct: two chips from different
 * dimensions that are both already active select the same *state*, and it is
 * the leading token that keeps them two different strings for a client that
 * keys its list on the id.
 *
 * `on` is therefore true once **per dimension** — three chips of the row are
 * lit, exactly as three pills are lit on the desktop — rather than once for the
 * whole row. A single lit chip would have to mean the row is a single choice,
 * and it is not.
 *
 * ## The row cap, and why it is said out loud
 *
 * A folder somebody has worked in for a year holds thousands of touched files.
 * `listArtifacts` is asked for {@link SCAN_ARTIFACTS} of them — more than the
 * phone will draw, because the kind, session and query filters all run *after*
 * the scan and a tighter scan would starve them — and at most {@link MAX_ROWS}
 * rows go over the wire. When that bites, the note says so and `deps.log` is
 * told: a list that stops at two hundred without a word reads as "that is
 * everything", which is the failure this whole rewrite exists to correct.
 *
 * ## A headless host answers this panel
 *
 * Nothing on this path needs Electron. `listArtifacts` reads transcripts off
 * disk and stats files; `src/main/transcript.ts` locates the stores from the
 * home directory. Session *names* are the one thing a server may not have, and
 * they are an optional dependency whose failure is silent — a chip wears a time
 * instead of a name, which is what the desktop does for a session it did not
 * start.
 *
 * Everything else is caught and turned into a `note`. That is not defensive
 * habit: the Store panel threw on a headless host and the screen said *"This
 * machine could not answer that panel"*, which is the sentence a person reads
 * as a broken app rather than as an absent fact.
 *
 * ## Opening the thing, which is what this panel was missing
 *
 * > *"The artifact page should be able to drive the artifacts actually — to show
 * > the visual artifacts, files and things. This application should be
 * > supporting to view photos inside, or whatever is there. Artifacts like
 * > prototypes: in artifacts it will be most probably for prototypes, whatever
 * > Claude will make. All of these prototypes will be saved there and they can
 * > be reviewed and they can be used."*
 *
 * What a row could do was named `Open in Files`, and pressing it answered
 * *"Opening PLAN.md."* and nothing else happened — the phone had no screen to
 * go to and the panel had nothing to send it to one with. A list of filenames
 * with a button that prints a sentence is the defect, and both halves of it are
 * here: the row now carries **what the file is**, and the panel can **serve** a
 * prototype so that looking at it means looking at the page rather than at its
 * markup.
 *
 * ### What a row carries, and why it is one string
 *
 * `PanelRow` has four fields a client reads — `title`, `detail`, `value`,
 * `status` — and three of them are prose that `WireCodec.displayLine` cleans,
 * trims and cuts at 200 characters. None of them can carry a path. `id` is the
 * one field that crosses unsanitised, because it is *what the row is on the
 * machine*, so everything a viewer needs to choose itself without opening the
 * file first travels in it, space-separated, path last:
 *
 *     <token> <kind> <bytes> <preview> <absolute path>
 *
 *  - **token** — what an action calls this row by. See below.
 *  - **kind** — `page`, `image`, `media`, `text`, `other` or `gone`; the six
 *    {@link ArtifactKindName} words, which is what lets a phone pick a viewer
 *    from the list rather than by reading the file and finding out.
 *  - **bytes** — the size on disk, or `-1` where the host could not stat it.
 *    A viewer that has to say *"a 41 MB PNG"* before deciding whether to fetch
 *    it needs the number in the row, not after the fetch.
 *  - **preview** — `-`, or `<port>.<secret>` when this project is being served.
 *    See {@link ArtifactPreviews}.
 *  - **absolute path** — last, and it is the only field allowed to contain a
 *    space, which is what makes the split unambiguous on a filesystem where a
 *    filename may contain anything but `/` and NUL.
 *
 * ### The token, and the socket it stops closing
 *
 * `panel.act` refuses an `id` over `MAX_PANEL_WORD` — **128 bytes** — and a
 * refused frame **closes the socket**, which reads to a person as the network
 * dropping. This panel sent `artifact.relPath` as the id from the day it was
 * written, so a phone acting on a row for a file nested deeply enough would drop
 * its own connection. So the token is the relative path while that is short and
 * has no whitespace in it — which is nearly always, and keeps an id somebody can
 * read in a log — and `#` plus a digest of the path when it is not. Either way
 * it is stable across a rescan, which is the property `key` exists for and an
 * index does not have.
 *
 * ### Running a prototype
 *
 * `preview` is a verb this panel answers and **does not advertise on a row**,
 * and that is deliberate rather than an oversight. A button drawn by the generic
 * panel screen would start a server and then have nowhere to show it, which is
 * the control-that-cannot-act this whole round is about; the artifact viewer is
 * the only client that can finish the job, so it is the only one that asks. What
 * *is* advertised is `stop`, on the panel rather than on a row, and only while
 * something is being served — one honest button, offered exactly when pressing
 * it would do something.
 *
 * `src/main/artifact-preview.ts` says at length why a prototype is served over
 * HTTP and tunnelled rather than shipped to the phone as a string.
 */

import { createHash } from 'node:crypto'
import { join } from 'node:path'
import { sharedPreviews, type ArtifactPreviews, type PreviewHandle } from '../../artifact-preview'
import {
  listArtifacts,
  type Artifact,
  type ArtifactList,
  type ArtifactScope,
  type ListArtifactsOptions,
} from '../../artifacts'
import type { PanelAction, PanelRow, PanelScope } from '../protocol'
import type { Panel, PanelActionRequest, PanelPayload, PanelRequest } from './contract'

/* -------------------------------------------------------------------------- */
/* Limits                                                                      */
/* -------------------------------------------------------------------------- */

/** Rows sent to a phone in one answer. The client's own backstop is 500. */
export const MAX_ROWS = 200

/**
 * Artifacts asked of the scanner, before this panel's filters run.
 *
 * Three times the row cap on purpose. The kind chip alone routinely hides most
 * of a list — a project's record is mostly edits — so a scan bounded at the row
 * cap would hand back two hundred files and draw twenty, and {@link isArtifact}
 * now takes a far bigger bite than the chip does: a project's record is mostly
 * source and markdown, none of which is a row here any more.
 *
 * Not raised past 600 for all that, because `MAX_DISK_CHECKS` in
 * `src/main/artifacts.ts` is 600 as well: an artifact past it is never stat'd,
 * comes back `onDisk: null`, and would be drawn as `gone` while sitting on the
 * disk. A longer scan would buy rows that lie.
 */
export const SCAN_ARTIFACTS = 600

/**
 * Session chips offered, most recent first.
 *
 * The desktop draws every session because it has a row of the window to do it
 * in. A phone has a thumb's width, and the sessions worth singling out are the
 * recent ones; the note still carries the true count, so a person can see there
 * were forty and only twelve are named.
 */
export const MAX_SESSION_SCOPES = 12

/**
 * The token cap, in bytes.
 *
 * `MAX_PANEL_WORD` in `remote/protocol.ts` is 128 and refusing an id over it
 * **closes the socket**, so this is measured in UTF-8 bytes rather than in
 * JavaScript's UTF-16 units — a path of sixty-four emoji is 64 `.length` and 256
 * bytes — and it is held a margin below the wire's own number so that a client
 * which one day prefixes something onto a token does not walk into the refusal.
 */
const MAX_TOKEN_BYTES = 120

/**
 * Run a prototype, or show a photograph. **Not advertised on a row** — see the
 * header for why a generic button would be a control that cannot act.
 */
export const PREVIEW_ACTION = 'preview'

/** Take the preview server for this project down. Offered only while one is up. */
export const STOP_ACTION = 'stop'

const STOP: PanelAction = {
  id: STOP_ACTION,
  label: 'Stop serving',
  kind: 'destructive',
  confirm: 'Anything looking at a prototype from this project stops loading.',
}

/* -------------------------------------------------------------------------- */
/* Scope                                                                       */
/* -------------------------------------------------------------------------- */

/** Which half of the record — see the header. */
export type ArtifactKind = 'made' | 'changed'

/** The three controls, once the scope string has been read. */
export interface ArtifactsScope {
  kind: ArtifactKind
  /** Which transcripts the scan reads. `ArtifactScope` in `main/artifacts.ts`. */
  breadth: ArtifactScope
  /** One session's work, or null for every session that wrote here. */
  session: string | null
}

const DEFAULT_SCOPE: ArtifactsScope = { kind: 'made', breadth: 'all', session: null }

/** The token that names each dimension's current value. */
function kindToken(scope: ArtifactsScope): string {
  return scope.kind
}

function breadthToken(scope: ArtifactsScope): string {
  return scope.breadth
}

function sessionToken(scope: ArtifactsScope): string {
  return scope.session === null ? 'session:*' : `session:${scope.session}`
}

/**
 * The three controls, out of the one string the wire carries.
 *
 * First token of a dimension wins, which is what makes the leading token of a
 * chip id authoritative — see the header. A token nobody recognises is skipped
 * rather than refused.
 */
export function parseScope(raw: string | undefined): ArtifactsScope {
  const scope: ArtifactsScope = { ...DEFAULT_SCOPE }
  let kindSeen = false
  let breadthSeen = false
  let sessionSeen = false

  for (const token of (raw ?? '').split(/\s+/)) {
    if (token === '') continue
    if (!kindSeen && (token === 'made' || token === 'changed')) {
      scope.kind = token
      kindSeen = true
    } else if (!breadthSeen && (token === 'project' || token === 'all')) {
      scope.breadth = token
      breadthSeen = true
    } else if (!sessionSeen && token.startsWith('session:')) {
      const id = token.slice('session:'.length)
      scope.session = id === '' || id === '*' ? null : id
      sessionSeen = true
    }
  }
  return scope
}

/**
 * The scope string a chip sends back: its own token, then the two dimensions it
 * does not own, at their current values.
 */
export function encodeScope(scope: ArtifactsScope, lead: string): string {
  const rest: string[] = []
  const leadsKind = lead === 'made' || lead === 'changed'
  const leadsBreadth = lead === 'project' || lead === 'all'
  const leadsSession = lead.startsWith('session:')
  if (!leadsKind) rest.push(kindToken(scope))
  if (!leadsBreadth) rest.push(breadthToken(scope))
  if (!leadsSession) rest.push(sessionToken(scope))
  return [lead, ...rest].join(' ')
}

/* -------------------------------------------------------------------------- */
/* Words                                                                       */
/* -------------------------------------------------------------------------- */

const MINUTE = 60_000
const HOUR = 60 * MINUTE
const DAY = 24 * HOUR

/**
 * "2h ago", in the desktop's own spelling.
 *
 * Not imported from `src/renderer/components/relative-time.ts`, which is where
 * that spelling was extracted to live: `tsconfig.node.json` names the three
 * renderer files this side of the app may reach and that is not one of them.
 * Adding it there is one line in a file this lane does not own.
 *
 * The one deliberate difference is the fall-through past a month. The renderer
 * uses `toLocaleDateString`, which on a host is the *server's* idea of a date
 * being read on somebody else's phone — a Hetzner box in `C` locale answering a
 * phone set to Arabic. An ISO date is the same date in every locale.
 */
export function whenLabel(at: number, now: number): string {
  if (!at) return ''
  const delta = now - at
  // A clock skew, or a timestamp in the future. "in 3m ago" is worse than
  // saying nothing sharper than "just now".
  if (delta < MINUTE) return 'just now'
  if (delta < HOUR) return `${Math.round(delta / MINUTE)}m ago`
  if (delta < DAY) return `${Math.round(delta / HOUR)}h ago`
  if (delta < 30 * DAY) return `${Math.round(delta / DAY)}d ago`
  return new Date(at).toISOString().slice(0, 10)
}

/** A conversation id, short enough to sit under a filename. */
function shortSession(id: string): string {
  return id.length <= 8 ? id : id.slice(0, 8)
}

function plural(count: number, one: string): string {
  return `${count} ${one}${count === 1 ? '' : 's'}`
}

/* -------------------------------------------------------------------------- */
/* Rows                                                                        */
/* -------------------------------------------------------------------------- */

/** A file the agent produced whole at least once. The split this page exists on. */
export function wasMade(artifact: Artifact): boolean {
  return artifact.writes > 0
}

/* -------------------------------------------------------------------------- */
/* What kind of thing a row is                                                 */
/* -------------------------------------------------------------------------- */

/**
 * The six words a viewer chooses itself by.
 *
 * Six rather than twenty, for the reason the desktop panel writes down beside
 * its own list: *"a vocabulary of twenty kinds is a legend somebody has to
 * learn; six is a glance."* Each of these is a **different screen** rather than
 * a different label, which is the test for whether a seventh belongs here:
 *
 *  - `page`   a prototype. Served and opened as a page — the case he asked for.
 *  - `image`  fetched over the same server and drawn as pixels.
 *  - `media`  a PDF, a video, a sound. The browser view renders all three.
 *  - `text`   read through `files.read` and shown in the terminal's own colours.
 *  - `other`  known not to be any of those. Named and measured, never previewed.
 *  - `gone`   an agent wrote it and it is not on disk any more.
 *
 * The first three are the ones this panel lists. `text` and `other` are still
 * the words for a file, and a viewer still knows them, but no row of this page
 * carries either any more — see {@link isArtifact}, and the header for why. The
 * pair stays in the vocabulary because a `page` showing its own source is doing
 * exactly what `text` does, and because the phone's `ArtifactKind` is a port of
 * this type rather than of this panel's filter.
 */
export type ArtifactKindName = 'page' | 'image' | 'media' | 'text' | 'other' | 'gone'

const PAGE_EXTENSIONS = new Set(['html', 'htm', 'xhtml'])

const IMAGE_EXTENSIONS = new Set([
  'png', 'jpg', 'jpeg', 'gif', 'webp', 'avif', 'bmp', 'ico', 'heic', 'heif', 'svg',
])

const MEDIA_EXTENSIONS = new Set([
  'pdf', 'mp4', 'm4v', 'mov', 'webm', 'mp3', 'm4a', 'wav', 'aac', 'flac', 'ogg',
])

/**
 * Extensions that are **known** not to be text, and nothing else.
 *
 * The default for an unrecognised extension is `text`, and the asymmetry is the
 * whole design: `files.read` decides binary **from the bytes** — a NUL in the
 * block it read — so a `text` guess that turns out to be wrong lands on the
 * host's own *"this is not a text file"* answer, which is honest. A `binary`
 * guess that is wrong lands on a screen refusing to show a `Makefile`, a
 * `Dockerfile`, a `.gitignore` or an extensionless script, with no way for
 * anybody to find out it was wrong. Guess the way whose mistake corrects itself.
 */
const OPAQUE_EXTENSIONS = new Set([
  'zip', 'gz', 'tgz', 'bz2', 'xz', 'zst', '7z', 'rar', 'tar', 'jar', 'war',
  'exe', 'dll', 'dylib', 'so', 'a', 'o', 'bin', 'wasm', 'class', 'pyc',
  'db', 'sqlite', 'sqlite3', 'realm', 'pack', 'idx',
  'docx', 'xlsx', 'pptx', 'doc', 'xls', 'ppt', 'odt', 'ods', 'key', 'pages', 'numbers',
  'psd', 'ai', 'sketch', 'fig', 'blend', 'dmg', 'pkg', 'iso', 'img',
  'woff', 'woff2', 'ttf', 'otf', 'eot',
])

/** The extension of a relative path, lower-cased, without its dot. */
function extensionOf(relPath: string): string {
  const name = relPath.slice(relPath.lastIndexOf('/') + 1)
  const dot = name.lastIndexOf('.')
  // `<= 0` and not `=== -1`: a dotfile with no second dot — `.env`,
  // `.gitignore` — has a dot at index 0 and no extension at all.
  return dot <= 0 ? '' : name.slice(dot + 1).toLowerCase()
}

/**
 * What the *path* says a file is, with the disk left out of it.
 *
 * Split from {@link kindOf} because the two questions want different answers
 * about a file that is not there any more. A row has to say `gone`, and the
 * filter has to know **what went**: a prototype an agent wrote and deleted is a
 * row on this page and a deleted `PLAN.md` is not, and both arrive with the
 * same `onDisk === null`.
 */
function pathKind(relPath: string): Exclude<ArtifactKindName, 'gone'> {
  const extension = extensionOf(relPath)
  if (PAGE_EXTENSIONS.has(extension)) return 'page'
  if (IMAGE_EXTENSIONS.has(extension)) return 'image'
  if (MEDIA_EXTENSIONS.has(extension)) return 'media'
  if (OPAQUE_EXTENSIONS.has(extension)) return 'other'
  return 'text'
}

export function kindOf(artifact: Artifact): ArtifactKindName {
  // Asked first, because a file that is not there has no kind worth acting on:
  // every other answer here is a promise that something can be opened.
  if (artifact.onDisk === null) return 'gone'
  return pathKind(artifact.relPath)
}

/**
 * Whether this belongs on the page at all.
 *
 * > *"an artifact is still showing the MD files, which is — multiple times I
 * > have discussed about it. Artifact should not show the MD files. It should
 * > be only for purely the prototypes."*
 *
 * A prototype, a picture or a recording. Not markdown, not prose, not source,
 * not the unrecognised extensions `text` catches and not the `other` a page can
 * do nothing with but name — those are files, and Files is the file browser.
 *
 * Decided from the **path**, so that the deleted half of the list obeys the
 * same rule as the live half: `kindOf` folds every missing file into `gone`,
 * and a filter reading that word would keep a `PLAN.md` an agent threw away
 * while dropping the prototype beside it.
 */
export function isArtifact(artifact: Artifact): boolean {
  const kind = pathKind(artifact.relPath)
  return kind === 'page' || kind === 'image' || kind === 'media'
}

/**
 * The scan, less everything that is not an artifact.
 *
 * One place, ahead of every count this panel takes — that is the whole reason
 * it is a function of the list rather than a `.filter()` next to the rows. The
 * note's totals, the made/changed split and the *"no artifacts"* sentence all
 * read the list this returns, so *"3 made here"* cannot end up above an empty
 * list.
 *
 * A session's `files` is **recounted** off what survived, and a session whose
 * whole contribution was prose leaves the chip row with it. A chip reading
 * *"Rewrite the hero · 4 files"* that opens an empty list is the
 * control-that-cannot-act this panel had its row buttons taken off for.
 *
 * `hidden` is how many rows the rule took, and it is used in exactly one place:
 * the empty state, where a zero has to carry its own evidence. It is
 * deliberately **not** in the footnote of a list that has rows — *"12 made here
 * · 200 files hidden"* would put the file browser back on the page in words,
 * which is the thing being removed.
 */
export function onlyArtifacts(list: ArtifactList): { list: ArtifactList; hidden: number } {
  const artifacts = list.artifacts.filter(isArtifact)
  if (artifacts.length === list.artifacts.length) return { list, hidden: 0 }

  const files = new Map<string, number>()
  for (const artifact of artifacts) {
    for (const sessionId of artifact.sessionIds) {
      files.set(sessionId, (files.get(sessionId) ?? 0) + 1)
    }
  }
  const sessions = list.sessions
    .filter((entry) => files.has(entry.sessionId))
    .map((entry) => ({ ...entry, files: files.get(entry.sessionId) ?? 0 }))

  return {
    list: { ...list, artifacts, sessions },
    hidden: list.artifacts.length - artifacts.length,
  }
}

/* -------------------------------------------------------------------------- */
/* The row's id                                                                */
/* -------------------------------------------------------------------------- */

/**
 * What an action calls this row by.
 *
 * The relative path itself while that is short and has no whitespace in it,
 * because an id somebody can read in a log is worth having and because it is
 * what this panel has always sent. Whitespace is the disqualifier rather than an
 * escape, since the id it goes into is space-separated and a token with a space
 * in it would make the fifth field ambiguous — and a path with a space in it is
 * ordinary, so this has to be right rather than unlikely.
 *
 * Otherwise a digest, which is stable across a rescan. That matters more than it
 * looks: the panel is re-read on every act, so a token has to name the same file
 * in an answer produced seconds after the one it was read from, and an ordinal
 * would not survive a file being written in between.
 */
export function tokenFor(relPath: string): string {
  const usable =
    relPath !== '' &&
    !/[\s\u0000-\u001f\u007f]/.test(relPath) &&
    Buffer.byteLength(relPath, 'utf8') <= MAX_TOKEN_BYTES
  if (usable) return relPath
  return `#${createHash('sha1').update(relPath, 'utf8').digest('base64url').slice(0, 16)}`
}

/** `<port>.<secret>`, or `-` when nothing is serving this project. */
function previewField(handle: PreviewHandle | null): string {
  return handle === null ? '-' : `${handle.port}.${handle.secret}`
}

/**
 * The whole row id — see the header for the grammar and for why one string.
 *
 * The absolute path is built with `join` against the scan's own root, so it
 * carries this machine's separators rather than the phone's idea of them. A
 * phone that concatenated a root and a POSIX relative path would be spelling a
 * Windows path from a device that has never seen one.
 */
export function rowIdFor(
  artifact: Artifact,
  root: string,
  handle: PreviewHandle | null,
): string {
  const kind = kindOf(artifact)
  const bytes = artifact.onDisk === null ? -1 : artifact.onDisk.bytes
  // Nothing is being served for a file that is not there, whatever is up for
  // the project — a viewer must not be handed a port for a 404.
  const preview = kind === 'gone' ? '-' : previewField(handle)
  return [tokenFor(artifact.relPath), kind, bytes, preview, join(root, artifact.relPath)].join(' ')
}

/**
 * One artifact, as a phone row.
 *
 * `title` is the **relative path** for anything below the project root, and the
 * bare name only for a file sitting in it. The desktop can say `index.ts`
 * because the folder is on the meta line beside it and the pane behind it
 * carries the whole path; a phone row is the only place the file is named, and
 * five rows reading `index.ts` name nothing.
 *
 * `id` is the row's whole machine-readable half — token, kind, size, where a
 * preview is being served and the absolute path — in the grammar the header
 * sets out. It is what lets a viewer open the file it was tapped on without
 * asking the host anything first, and what lets it know it is opening a picture
 * before it fetches forty megabytes to find out.
 *
 * **There are no row actions.** There was one, `Open in Files`, and pressing it
 * answered *"Opening PLAN.md."* while nothing opened — the phone had no screen
 * to go to. The row itself is the control now; the artifact viewer is pushed
 * from it, and a client too old to know that draws a list, which is what it drew
 * before minus a button that never did anything.
 *
 * `status` is this panel's own word, `made` or `changed`. A client whose status
 * vocabulary is the three-tint one (`ok`/`warn`/`bad`) draws no tint for it and
 * loses nothing: the list is one kind at a time and the lit chip above it is
 * what says which.
 */
export function rowFor(
  artifact: Artifact,
  names: ReadonlyMap<string, string>,
  now: number,
  root: string,
  handle: PreviewHandle | null,
): PanelRow {
  const [newest, ...older] = artifact.sessionIds
  const detail: string[] = []
  if (newest !== undefined) {
    // The name where the host knows one, the short id where it does not — and
    // not the session's *time*, which the chips fall back to, because `value`
    // already carries a time and two of them in one row read as two facts.
    detail.push(names.get(newest) ?? `session ${shortSession(newest)}`)
    if (older.length > 0) detail.push(`+${older.length} more`)
  }
  // The same fact the desktop row carries as a tag, and the reason nothing on
  // this row can be opened: an agent writes a scratch file and deletes it two
  // turns later.
  if (artifact.onDisk === null) detail.push('not on disk')

  const when = whenLabel(artifact.lastAt, now)
  return {
    title: artifact.relPath.includes('/') ? artifact.relPath : artifact.name,
    ...(detail.length > 0 ? { detail: detail.join(' · ') } : {}),
    ...(when === '' ? {} : { value: when }),
    status: wasMade(artifact) ? 'made' : 'changed',
    id: rowIdFor(artifact, root, handle),
  }
}

/* -------------------------------------------------------------------------- */
/* The note                                                                    */
/* -------------------------------------------------------------------------- */

/**
 * What the panel says when the scan found nothing — every fact it has, in one
 * line.
 *
 * The desktop's `nothingFound`, rebuilt rather than imported for the reason
 * {@link whenLabel} gives. Its argument is worth keeping intact: Asad, on this
 * page, *"No artifacts are still. I don't know. We don't have artifacts
 * maybe."* — "I don't know" is the finding. A zero has to carry the folder it
 * is a zero for, how many sessions were read, and how many writes went to files
 * *outside* that folder, because the last of those is what explains an agent
 * launched from a parent workspace.
 */
function nothingFound(list: ArtifactList): string {
  const where = `Nothing written or edited in ${list.root}`
  if (list.sessionsScanned === 0) return `${where} — no sessions have been recorded for it yet.`
  const read = `${plural(list.sessionsScanned, 'session')} read`
  const elsewhere =
    list.outsideProject > 0
      ? `, ${plural(list.outsideProject, 'change')} to files outside it`
      : ''
  return `${where} — ${read}${elsewhere}.`
}

/**
 * The line under the list — or instead of it, when there is none.
 *
 * One field carries both because there is one field. The contract calls `note`
 * the reason a list is empty, and the client already draws it as a footnote
 * when rows arrive with it (*"3 of 5 features installed"*), which is the same
 * sentence doing the same job at the other end of the list. A cap that bites in
 * silence is the defect; a footnote is the fix, and there is no second field to
 * put it in.
 */
function noteFor(
  list: ArtifactList,
  scope: ArtifactsScope,
  shown: number,
  ofKind: number,
  filtered: boolean,
  cut: number,
  hidden: number,
): string {
  if (list.artifacts.length === 0) {
    /*
     * A folder an agent has worked in all week, and no artifacts in it, is the
     * zero a person cannot check — *"No artifacts are still. I don't know."*
     * The rule that emptied the page has to say so, or the page reads as
     * broken rather than as strict.
     */
    if (hidden > 0) {
      return `No prototypes in ${list.root} — ${plural(hidden, 'file')} of prose or source, which is what Files is for.`
    }
    const widen =
      scope.breadth === 'project'
        ? ' Only the sessions started in this folder were read — Every session also reads agents launched from a parent folder.'
        : ''
    return `${nothingFound(list)}${widen}`
  }

  if (shown === 0) {
    // Three different absences, and they must not say the same thing: a filter
    // that matched nothing, and a kind that has nothing in it, are different
    // facts and only one of them is worth clearing a filter for.
    if (filtered) return 'Nothing matches that filter.'
    // "a whole file" was the wording while every file was a row. Prose is not
    // a row any more, so the sentence has to be about an artifact or it claims
    // the agent wrote nothing when it wrote ten pages of markdown.
    return scope.kind === 'made'
      ? 'No agent has made an artifact here yet. What it edited is under Changed.'
      : 'Every artifact here was made by an agent rather than edited into.'
  }

  const parts = [
    shown === ofKind
      ? `${shown} ${scope.kind === 'made' ? 'made here' : 'changed'}`
      : `${shown} of ${ofKind} ${scope.kind === 'made' ? 'made here' : 'changed'}`,
    plural(list.sessions.length, 'session'),
  ]
  // Said whether or not a filter is also narrowing the list: "12 of 400" under
  // a search box is a filter doing its job, and "200 of 431" is a cap, and a
  // reader has no way to tell those apart from the numbers alone.
  if (cut > 0) parts.push(`${cut} older match${cut === 1 ? '' : 'es'} not sent to this phone`)
  if (list.truncated) parts.push('older work not read')
  return parts.join(' · ')
}

/* -------------------------------------------------------------------------- */
/* The panel                                                                   */
/* -------------------------------------------------------------------------- */

export interface ArtifactsPanelDeps {
  /**
   * The scan. Defaults to `listArtifacts`, which is the same function the
   * desktop's `artifacts:list` channel answers with — one implementation, so
   * the phone cannot come to disagree with the window about what an artifact
   * is. Injected only by tests.
   */
  list?(cwd: string, options: ListArtifactsOptions): Promise<ArtifactList>
  /**
   * Bounds and stores this host wants the scan to respect — `configDir`,
   * `deviceHomes`, `homeScopes`, `timeBudgetMs`. `scope` is always the request's
   * and cannot be overridden here: it is a control on the screen.
   */
  scan?: ListArtifactsOptions
  /**
   * Conversation id → the name this host shows that session by.
   *
   * The id is the one the agent CLI was handed at spawn (`agentSessionId` on
   * the desktop), which is the same id `main/artifacts.ts` reads off the
   * transcript — that join is what turns "3h ago · 4 files" into a session
   * somebody recognises. Optional, and its failure is silent: a host with no
   * such mapping is a chip wearing a time, which is what the desktop shows for
   * a session it did not start itself.
   */
  sessionNames?(): Promise<ReadonlyMap<string, string>>
  now?(): number
  /**
   * The host's own record of a cap biting. The note is what the person sees;
   * this is for whoever is reading the machine's log afterwards.
   */
  log?(line: string): void
  /**
   * Where a prototype is served from. Defaults to this process's own.
   *
   * Defaulted rather than injected, for the reason `list` is: `remote/server.ts`
   * builds the panels with no arguments, so a dependency this panel cannot
   * default is a dependency it does not have. One per process rather than one
   * per panel, so pressing *Run it* twice reaches the same port — see
   * `sharedPreviews`. Tests pass their own; nothing else should.
   */
  previews?: ArtifactPreviews
}

/**
 * The Artifacts panel.
 *
 * `read` and `act` both answer with the whole panel, which is the contract's
 * one rule: an action is confirmed by the screen it redraws, not by an ack.
 */
export function artifactsPanel(deps: ArtifactsPanelDeps = {}): Panel {
  const scan = deps.list ?? listArtifacts
  const clock = deps.now ?? Date.now
  const previews = deps.previews ?? sharedPreviews()

  /**
   * What is being served for this project, if anything — and never a reason to
   * fail.
   *
   * A preview is an extra on a panel whose job is a list. A module that threw
   * because a port had gone away would take the whole list with it, which is the
   * failure mode `note` exists to avoid everywhere else in this file.
   */
  function handleFor(root: string): PreviewHandle | null {
    try {
      return previews.current(root)
    } catch {
      return null
    }
  }

  /** Names, or an empty map. Never a reason for the panel to fail. */
  async function namesFor(): Promise<ReadonlyMap<string, string>> {
    if (!deps.sessionNames) return new Map()
    try {
      return await deps.sessionNames()
    } catch {
      return new Map()
    }
  }

  function scopesFor(
    scope: ArtifactsScope,
    list: ArtifactList,
    names: ReadonlyMap<string, string>,
    now: number,
  ): PanelScope[] {
    const chip = (token: string, label: string): PanelScope => ({
      id: encodeScope(scope, token),
      label,
      on:
        token === kindToken(scope) ||
        token === breadthToken(scope) ||
        token === sessionToken(scope),
    })

    const chips: PanelScope[] = [
      chip('made', 'Made here'),
      chip('changed', 'Changed'),
      chip('project', "This project's sessions"),
      chip('all', 'Every session'),
    ]

    /*
     * Whitespace would split the token in two and select a session nobody
     * named. Transcript ids do not contain any; a store that grows one is left
     * out of the chips rather than allowed to corrupt a scope string.
     */
    const offered = list.sessions
      .filter((entry) => !/\s/.test(entry.sessionId))
      .slice(0, MAX_SESSION_SCOPES)
    const chosen = scope.session

    // The per-session chips only where there is a choice to make — one session
    // beside an "All sessions" chip that selects the same list is two controls
    // for one fact — or where a session is already filtering the list, which
    // must never be a narrowing with no visible way back out of it.
    if (list.sessions.length > 1 || chosen !== null) {
      chips.push(chip('session:*', 'All sessions'))
      // A session chosen from a longer row, or from a scan that has since
      // rolled past it, keeps its chip: the filter is applied either way, and a
      // filter whose control has vanished is a list a person cannot explain.
      if (chosen !== null && !offered.some((entry) => entry.sessionId === chosen)) {
        chips.push(chip(`session:${chosen}`, names.get(chosen) ?? `session ${shortSession(chosen)}`))
      }
      for (const entry of offered) {
        const named = names.get(entry.sessionId) ?? whenLabel(entry.at, now)
        chips.push(
          chip(`session:${entry.sessionId}`, `${named} · ${plural(entry.files, 'file')}`),
        )
      }
    }
    return chips
  }

  /**
   * One answer, plus the artifacts behind its rows.
   *
   * `read` throws the second half away and `act` needs it: a token names a
   * *file*, and everything an action does — serve its folder, register its
   * redirect, say its name in the notice — is about the `Artifact`, not about
   * the row that was drawn from it. Re-deriving one from the other would mean
   * parsing this panel's own id grammar back apart on the side that wrote it.
   *
   * The two are index-for-index, which is what makes the lookup below a find on
   * one list rather than a join across two.
   */
  async function look(
    request: PanelRequest,
  ): Promise<{ payload: PanelPayload; artifacts: Artifact[]; root: string }> {
    const scope = parseScope(request.scope)
    const now = clock()
    const names = await namesFor()

    let list: ArtifactList
    let hidden: number
    try {
      // Narrowed the moment it arrives, so that nothing below this line can
      // count a file this page does not list — see {@link onlyArtifacts}.
      const found = await scan(request.path, {
        maxArtifacts: SCAN_ARTIFACTS,
        ...deps.scan,
        scope: scope.breadth,
      })
      const page = onlyArtifacts(found)
      list = page.list
      hidden = page.hidden
    } catch (error) {
      /*
       * A scan that failed is still a panel. The rows are gone and the reason
       * takes their place — the alternative is the refusal that put *"This
       * machine could not answer that panel"* on a screen whose real answer was
       * "this host has no window", and a person cannot tell that sentence from
       * a broken app.
       *
       * The chips are still drawn, off the state the request asked for, so the
       * one control that might fix it — Every session, on a folder whose own
       * store is unreadable — is still under the thumb.
       */
      const reason = error instanceof Error ? error.message : String(error)
      return {
        payload: {
          path: request.path,
          note: `This project's history could not be read: ${reason}`,
          scopes: scopesFor(scope, emptyList(request.path, scope.breadth), names, now),
          rows: [],
        },
        artifacts: [],
        root: request.path,
      }
    }

    const needle = (request.query ?? '').trim().toLowerCase()
    const ofKind = list.artifacts.filter((artifact) => wasMade(artifact) === (scope.kind === 'made'))
    const matched = ofKind.filter((artifact) => {
      if (scope.session !== null && !artifact.sessionIds.includes(scope.session)) return false
      return needle === '' || artifact.relPath.toLowerCase().includes(needle)
    })

    const kept = matched.slice(0, MAX_ROWS)
    if (kept.length < matched.length) {
      deps.log?.(
        `artifacts panel: ${matched.length} rows for ${list.root} cut to ${MAX_ROWS}`,
      )
    }

    const handle = handleFor(list.root)
    return {
      payload: {
        path: request.path,
        note: noteFor(
          list,
          scope,
          kept.length,
          ofKind.length,
          needle !== '' || scope.session !== null,
          matched.length - kept.length,
          hidden,
        ),
        scopes: scopesFor(scope, list, names, now),
        /*
         * One button, and only while pressing it would do something.
         *
         * A project with nothing being served has no *Stop serving* — an
         * always-drawn one would be the control that cannot act, on the panel
         * that is having exactly that defect fixed. It is destructive because it
         * is: a page somebody is looking at on a phone stops loading the moment
         * this is pressed, and that is worth a sentence first.
         */
        ...(handle === null ? {} : { actions: [STOP] }),
        rows: kept.map((artifact) => rowFor(artifact, names, now, list.root, handle)),
      },
      artifacts: kept,
      root: list.root,
    }
  }

  async function read(request: PanelRequest): Promise<PanelPayload> {
    return (await look(request)).payload
  }

  return {
    read,
    async act(request: PanelActionRequest): Promise<PanelPayload> {
      const { payload, artifacts, root } = await look(request)

      if (request.action === STOP_ACTION) {
        try {
          previews.stop(root)
        } catch (error) {
          const reason = error instanceof Error ? error.message : String(error)
          return { ...payload, notice: `That server could not be stopped: ${reason}` }
        }
        // Read again rather than editing the answer in hand: the rows carry the
        // port in their ids, and a payload that still named a closed one would
        // send the next tap at a socket nothing is listening on.
        return { ...(await look(request)).payload, notice: 'Nothing is being served now.' }
      }

      if (request.action !== PREVIEW_ACTION) {
        return { ...payload, notice: `This panel has nothing called ${request.action}.` }
      }

      const named = request.id ?? ''
      const index = artifacts.findIndex((artifact) => tokenFor(artifact.relPath) === named)
      const artifact = index === -1 ? undefined : artifacts[index]
      if (!artifact) {
        // The list is scanned again on every act, so a file an agent deleted
        // between the draw and the tap is gone from the answer as well as from
        // the disk. Saying so beats sending the phone to a read error.
        return { ...payload, notice: `${named || 'That file'} is not in this list any more.` }
      }
      if (artifact.onDisk === null) {
        return { ...payload, notice: `${artifact.relPath} is no longer on disk.` }
      }

      try {
        await previews.serve(root)
        // The redirect, registered before the answer goes out: a phone that
        // followed the port in the row it is about to be handed and found no
        // `~/<token>` would get a 404 for the file it just asked to see.
        previews.link(root, tokenFor(artifact.relPath), artifact.relPath)
      } catch (error) {
        /*
         * A port that could not be bound, a folder that has gone away. Said
         * rather than thrown: the panel around it is still a true list, and the
         * screen that asked has a sentence to put under the thing it cannot
         * show instead of an empty frame.
         */
        const reason = error instanceof Error ? error.message : String(error)
        return { ...payload, notice: `${artifact.relPath} could not be served: ${reason}` }
      }

      // Read again, so every row carries the port that has just come up — not
      // only the one that was asked for. Two prototypes in one project are one
      // server, and the second must not have to be pressed twice to learn that.
      return {
        ...(await look(request)).payload,
        notice: `Serving ${artifact.relPath} from this machine.`,
      }
    },
  }
}

/** A scan that never happened, so the chips have sessions to be absent from. */
function emptyList(root: string, breadth: ArtifactScope): ArtifactList {
  return {
    root,
    scope: breadth,
    artifacts: [],
    sessions: [],
    sessionsScanned: 0,
    outsideProject: 0,
    truncated: false,
    cancelled: false,
    tookMs: 0,
  }
}

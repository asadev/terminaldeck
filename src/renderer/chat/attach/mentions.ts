/**
 * Turning attachments into something Claude Code actually resolves.
 *
 * Chat mode has exactly one channel to the agent: characters written into the
 * session's PTY, followed by a carriage return. So an attachment is not an
 * upload — it is text in the prompt that the CLI expands on submit. Every rule
 * below was measured against the CLI on this machine (2.1.228), because every
 * one of them had a plausible-sounding wrong answer:
 *
 *  - `@relative/path` and `@/absolute/path` both expand, and an absolute path
 *    outside the session's cwd expands too.
 *  - A path containing a space needs **double quotes**: `@"a b/c.txt"`.
 *    Backslash-escaping does not work — `@a\ b/c.txt` silently expands to
 *    nothing, which is the worst failure available. Quoting a path with no
 *    spaces is harmless, so everything is quoted and there is one form to
 *    reason about.
 *  - An image is attached as a real image, not as a path the agent must go and
 *    read: `@"/abs/shot.png"` with every tool disabled still had the model
 *    naming the colour of the pixels. This is why the screenshot flow can be a
 *    file reference rather than a paste.
 *  - A folder expands to a listing, but only usefully when it is inside the
 *    project. The same mention pointed at a folder outside it produced text the
 *    model read as an injection attempt and refused — one more reason the root
 *    check below is a feature rather than hygiene.
 *
 * And the two that decide whether any of this works at all, both re-measured
 * through a real pty against 2.1.228 (see {@link terminalPayload} and
 * {@link terminalWrites}):
 *
 *  - A mention at the end of the line leaves the CLI's completion popup open,
 *    and the Enter that follows is swallowed by it: the popup accepts the
 *    highlighted suggestion and replaces the whole line with a bare path.
 *    Watched happen — the message was never sent. One trailing space closes it.
 *  - The CLI treats a large stdin chunk as *pasted text*, and Enter inside a
 *    paste must not submit or every pasted snippet would fire off half of
 *    itself. Measured boundary: 57 bytes in one write submits, 64 does not.
 *    Any message carrying a mention is far past that, because an absolute path
 *    is most of a line on its own. So the carriage return has to arrive as its
 *    own write, after a gap — {@link terminalWrites} is that sequence.
 */

/*
 * A `const SEP = '/'` used to sit here, and the Windows bug it caused is worth
 * leaving a marker for. Its comment claimed the paths reaching this file were
 * already forward-slashed by the main process; nothing anywhere did that, so
 * every gate in this file was false for every path a Windows user can produce.
 * The argument, the evidence and the replacement are at the head of the paths
 * section below.
 */

/**
 * How many attachments one message may carry.
 *
 * Not a storage limit — a legibility one. Each mention is expanded inline
 * before the agent sees a word of the actual question, so a dozen files put
 * the prompt at the bottom of a wall of source.
 */
export const MAX_ATTACHMENTS = 10

/** Extensions the CLI attaches as image content rather than as text. */
export const IMAGE_EXTENSIONS: readonly string[] = [
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'bmp',
  'svg',
]

export type AttachmentKind = 'file' | 'image' | 'folder'

export interface Attachment {
  /** Absolute path. Identity: the same path twice is one attachment. */
  path: string
  /**
   * What the chip is labelled with: project-relative for something inside the
   * open project, and the absolute path for anything else.
   *
   * Not a lie about what "rel" means — it is *the shortest unambiguous way to
   * name this file to this user*, and for a file outside the project there is no
   * shorter one. `relativeTo` cannot be used there at all: it slices by the
   * root's length, so pointed at `/tmp/x.png` with a root of `/Users/apple/proj`
   * it returns a fragment of the wrong string rather than an error.
   */
  relPath: string
  kind: AttachmentKind
  /**
   * True when this path is not inside the session's project.
   *
   * Carried on the attachment rather than recomputed by whoever draws it,
   * because two different surfaces need the answer — the chip marks it, and the
   * composer decides whether to warn about a folder — and a second `insideRoot`
   * call somewhere else is a second place that can disagree about what the root
   * was when the file was added. The project changing underneath clears the
   * whole list anyway; see `ChatComposer`.
   */
  outside?: boolean
}

/**
 * Whether a path from outside the open project is acceptable to this call.
 *
 * The default is `'project'` and every existing caller keeps it, which is the
 * point: the project-scoped picker can only produce paths inside the project, so
 * the containment test there stays a real second gate rather than becoming
 * decoration. Only the three routes that deliberately reach outside — the open
 * panel, a drop and a paste — pass `'anywhere'`, and they say so at the call.
 */
export type AttachScope = 'project' | 'anywhere'

/**
 * Why an attachment was refused. Each maps to a sentence the user sees — a
 * chip that silently fails to appear is indistinguishable from a broken button.
 */
export type RejectReason = 'not-absolute' | 'outside-root' | 'duplicate' | 'full'

export const REJECTION_TEXT: Record<RejectReason, string> = {
  'not-absolute': 'That path is not absolute, so the agent could not resolve it.',
  'outside-root': 'Only files inside the open project can be attached.',
  duplicate: 'That is already attached.',
  full: `A message can carry ${MAX_ATTACHMENTS} attachments.`,
}

/**
 * The one caution that comes with reaching outside the project, and it applies
 * to folders only.
 *
 * A file from anywhere on the disk expands fine — that is the measurement at the
 * top of this file, and it is what makes the whole escape hatch honest. A
 * *folder* is the exception: the same mention pointed at a directory outside the
 * project produced a listing the model read as an injection attempt and refused.
 * So the folder still attaches, because the user asked for it and because on a
 * shell session the same pick is just a quoted path that works perfectly — and
 * the composer says this once, rather than the agent saying something stranger
 * a minute later.
 */
export const OUTSIDE_FOLDER_CAUTION =
  'That folder is outside the project. The agent may refuse its listing — a file from out there is read normally.'

/* ------------------------------------------------------------------ paths -- */

/*
 * ## Both spellings, and why this section was rewritten
 *
 * What this file used to say, kept because it is the whole reason the bug
 * existed:
 *
 *   > POSIX separator throughout: these paths come from the main process, which
 *   > normalises to forward slashes, and go into a prompt, not into an fs call.
 *   > `const SEP = '/'`
 *
 * The second clause is still true. The first was never true of anything. No
 * module on any of the three routes into this file rewrites a separator:
 * `dialog.showOpenDialog` hands back `C:\Users\asad\Desktop\shot.png`, the
 * preload's `webUtils` drop path is the same shape, and the only transform in
 * `main/attach-outside.ts` is `normalisePick`, which rewrites `\\wsl.localhost\…`
 * into its Linux spelling and returns everything else verbatim — `main/wsl.ts`
 * matches only the two WSL prefixes and `main/wsl.test.ts` pins
 * `linuxPathFromUnc('C:\\Users\\Asad\\proj')` as null.
 *
 * So `addAttachment`'s `startsWith('/')` was false for every pick on Windows,
 * and all three doors — Browse, drag-and-drop, paste — ended at
 * `reason: 'not-absolute'`: the composer telling somebody that the path they had
 * chosen in the operating system's own file panel two seconds earlier was not a
 * path. Attaching a file to a chat message was completely dead on Windows and
 * worked on macOS. `insideRoot`, `relativeTo`, `basename` and `normalise` were
 * broken the same way underneath it, so even lifting the gate alone would have
 * produced chips labelled with whole paths and a containment test that answered
 * no for every file in the project.
 *
 * The fix is *not* to introduce the normalisation the old comment imagined. A
 * pick is shown back to the person who made it — in a chip's hover, in the
 * message they are about to send — and `C:/Users/asad/Desktop` is not how their
 * machine spells that. It is also not this module's business: rewriting a
 * separator here would make this the one place in the app that changes what a
 * pick *is*, while `folderName` (session-title.ts), `folderOf` (dashboard/board.ts)
 * and `folderName` (remote/DeviceFolders.tsx) all keep the native spelling and
 * read both. So this file reads both too.
 */

/**
 * Windows-shaped: a drive-lettered path or a UNC share.
 *
 * The shape of the *path*, not the platform of the machine, and that is the rule
 * this file already lives by — see {@link shellQuote}, which picks its quoting
 * from the path because on Windows a `/home/...` pick launches through `wsl.exe`
 * into a POSIX shell and a `C:/...` pick through `cmd.exe`, so the machine
 * cannot answer the question and the path can. The same reasoning settles every
 * question below: which characters end a segment, whether two spellings name one
 * file, and which character marks a folder. It also happens to be the only rule
 * that is right on a Mac reading a Windows path, which the relay makes ordinary.
 */
function isWindowsShaped(path: string): boolean {
  return /^[A-Za-z]:[\\/]/.test(path) || path.startsWith('\\\\')
}

/**
 * The last character that ends a segment, in either spelling.
 *
 * `folderName` in `session-title.ts` made this trade first and argues it in
 * full: a backslash is a legal character in a POSIX directory name, so a Mac
 * folder literally called `a\b` now reads as `b`. That is the right way round —
 * the alternative is a function that is wrong for every path on one of the two
 * platforms this ships to, rather than for a directory nobody has.
 */
function lastSeparator(path: string): number {
  return Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'))
}

/**
 * Is this a path the agent can resolve without being told a working directory?
 *
 * The two-spelling test this repo already writes in five other places —
 * `isRecordedAbsolute` (main/artifacts.ts), `isAbsoluteCommand`
 * (shared/custom-agents.ts), `parseLastFolder` (renderer/session-start.ts),
 * `isAbsoluteFolder` (main/remote/session-create.ts) and the label test in
 * `renderer/shell/tooltip.ts` — written out again here rather than imported, for
 * the reason `renderer/platform.ts` gives for its own copy of a main-process
 * decision: the renderer cannot import from `src/main`, and `src/shared` is not
 * a place to put a question only this feature asks.
 *
 * UNC is accepted, where `isAbsoluteCommand` deliberately refuses it. The two
 * are not the same question. That one decides whether to *launch a binary* off
 * somebody else's file server, which is not a thing to make one click away;
 * this one decides whether to read a file the user just chose in their own file
 * panel. A mapped share is where a great deal of ordinary work lives on a
 * Windows machine, and refusing it would leave this feature half-dead in
 * precisely the environment where it was already fully dead.
 */
export function isAbsolutePath(path: string): boolean {
  const target = path.trim()
  return target.startsWith('/') || isWindowsShaped(target)
}

/**
 * One path reduced to the form two spellings of the same file agree on.
 *
 * For *comparison* only — never for anything a person reads and never for the
 * mention, both of which must carry the path that was picked. Two transforms,
 * and both only for a Windows-shaped path:
 *
 *  - **Separators unify.** The root and the pick do not always come from the
 *    same place. `git rev-parse --show-toplevel` prints `C:/Users/asad/app`
 *    even on Windows, while `dialog.showOpenDialog` hands back
 *    `C:\Users\asad\app\src\a.ts`; a containment test comparing those character
 *    by character says no, and every file in the project is then "outside" it.
 *  - **Case folds.** NTFS is case-insensitive, so `C:\Users\Asad\a.txt` and
 *    `c:\users\asad\a.txt` are one file. Picking it from two panels must produce
 *    one chip and one mention rather than two of each — the same file mentioned
 *    twice is the same source pasted twice into the prompt.
 *
 * Neither is applied to a POSIX path, and that restraint is the point rather
 * than caution. Folding case there would call `README.md` and `readme.md` one
 * file on a Mac, where they are two; unifying separators there would let
 * `/Users/asad/proj\secrets` — a legal file *beside* the project — pass as
 * inside it, and weakening a containment test is a worse failure than a
 * mislabelled chip. `withinFolder` (main/remote/session-create.ts) folds on
 * exactly these terms, by platform rather than by shape because it has a
 * platform argument to hand and this does not.
 *
 * Both transforms preserve length, which is what lets {@link relativeTo} keep
 * slicing by the root's length.
 */
function comparable(path: string): string {
  if (!isWindowsShaped(path)) return path
  return path.replace(/\\/g, '/').toLowerCase()
}

/** Two spellings of one file. See {@link comparable} for why this is not `===`. */
export function samePath(a: string, b: string): boolean {
  return comparable(normalise(a)) === comparable(normalise(b))
}

/**
 * Trailing separators removed, so `/a/b/` and `/a/b` are one path — and
 * `C:\a\b\` and `C:\a\b` with them.
 *
 * The drive root is the one path that must keep its separator: `C:\` names the
 * top of the drive, and `C:` names *the current directory on that drive*, which
 * is a different place and one nothing in this app knows. The POSIX root is
 * held back by the length test above it for the same reason.
 */
export function normalise(path: string): string {
  const trimmed = path.trim()
  if (trimmed.length <= 1) return trimmed
  if (/^[A-Za-z]:[\\/]+$/.test(trimmed)) return trimmed.slice(0, 3)
  const stripped = trimmed.replace(/[\\/]+$/, '')
  // `//` and `\\` strip to nothing. Handing back an empty string would turn a
  // malformed path into one that compares equal to a missing root.
  return stripped === '' ? trimmed : stripped
}

/**
 * Is `path` the root itself or something under it?
 *
 * The separator in the comparison is what makes this a containment test rather
 * than a string test: without it `/Users/asad/project-secrets` passes as inside
 * `/Users/asad/project`. One boundary character serves both platforms because
 * {@link comparable} has already unified a Windows path's separators by the
 * time the prefix is taken; `/` and `C:/` are the two roots that carry theirs
 * already.
 */
export function insideRoot(root: string, path: string): boolean {
  const base = normalise(root)
  const target = normalise(path)
  if (base === '' || !isAbsolutePath(base) || !isAbsolutePath(target)) return false
  const top = comparable(base)
  const inner = comparable(target)
  if (inner === top) return true
  return inner.startsWith(top.endsWith('/') ? top : `${top}/`)
}

/** `path` expressed relative to `root`, or the path itself when it is the root. */
export function relativeTo(root: string, path: string): string {
  const base = normalise(root)
  const target = normalise(path)
  if (comparable(target) === comparable(base)) return basename(base)
  /*
   * Sliced by the root's *length*, which survives both of `comparable`'s
   * transforms: `C:/Users/asad/app` and `C:\Users\asad\app` are the same number
   * of characters, so a root that arrived from git with forward slashes still
   * cuts a pick that arrived from the open panel with backslashes in the right
   * place, and the fragment keeps the pick's own spelling. What the slice does
   * not survive is being called for a path *outside* the root — that is the
   * caller's job and {@link Attachment.relPath} says so at length.
   */
  return target.slice(base.length + 1)
}

/** Last segment of a path — what a chip shows when the folder part is elided. */
export function basename(path: string): string {
  const target = normalise(path)
  const cut = lastSeparator(target)
  return cut === -1 ? target : target.slice(cut + 1)
}

/** Image by extension, which is the same test the CLI applies to a mention. */
export function isImagePath(path: string): boolean {
  const name = basename(path).toLowerCase()
  const dot = name.lastIndexOf('.')
  if (dot <= 0) return false
  return IMAGE_EXTENSIONS.includes(name.slice(dot + 1))
}

export function kindFor(path: string, isDirectory: boolean): AttachmentKind {
  if (isDirectory) return 'folder'
  return isImagePath(path) ? 'image' : 'file'
}

/* --------------------------------------------------------------- mentions -- */

/**
 * One attachment as the CLI wants to read it.
 *
 * A folder keeps its trailing slash, but only as a signal to the person reading
 * their own message: the CLI decides between "read this file" and "list this
 * directory" by stat-ing the resolved path, and `@"/dir"` and `@"/dir/"` were
 * both measured returning the same listing.
 *
 * That trailing character follows the path's own spelling, so a folder picked
 * on Windows reads `@"C:\Users\asad\app\"` rather than the mongrel
 * `@"C:\Users\asad\app/"`. It changes nothing about what the CLI resolves —
 * both forms stat the same directory on Windows — and it is the only part of
 * the mention this function writes, so it is the only part it can get wrong.
 * Whether the CLI's own mention parser treats a backslash *inside* the quotes as
 * an escape is a question no measurement on this machine can answer, and it is
 * not this function's to answer either: the backslashes in the body are the ones
 * the user picked, and rewriting them would be the normalisation argued against
 * at the head of the paths section.
 */
export function mentionFor(attachment: Attachment): string {
  const path = normalise(attachment.path)
  if (attachment.kind !== 'folder') return `@"${path}"`
  const sep = isWindowsShaped(path) && path.includes('\\') ? '\\' : '/'
  return `@"${path}${sep}"`
}

/**
 * The message as it will be typed into the terminal.
 *
 * Mentions lead and the typed words follow, for two reasons. The agent reads
 * the question after the material it is about, which is the order a person
 * would use; and it keeps a mention off the end of the line, which is where the
 * completion popup does its damage.
 */
export function composeMessage(attachments: readonly Attachment[], typed: string): string {
  const body = typed.trim()
  if (attachments.length === 0) return body
  const mentions = attachments.map(mentionFor).join(' ')
  return body === '' ? mentions : `${mentions} ${body}`
}

/**
 * The characters of the message, minus the carriage return.
 *
 * The trailing space is what closes the completion popup, and it is free: the
 * CLI trims the line before it stores it, so the transcript records exactly
 * what the user wrote either way. Measured both ways — with the mention last
 * and no space, Enter was eaten and the line became a bare path; with the
 * space, the same line submitted intact.
 *
 * It is necessary and *not* sufficient. See {@link terminalWrites}.
 */
export function terminalPayload(message: string): string {
  return message.includes('@') ? `${message} ` : message
}

/**
 * How long to wait between the two writes below.
 *
 * Measured: written back to back they are read as one chunk and nothing is
 * sent; 30ms apart submits. 50 leaves room for a slower machine and is still
 * far below anything a person notices.
 */
export const SUBMIT_GAP_MS = 50

/**
 * The writes a session must receive, in order, for one message to be sent.
 *
 * This is not decoration. The CLI classifies each stdin chunk before it looks
 * at the keys in it, and a chunk of 64 bytes or more is pasted text, where a
 * carriage return is a newline rather than submit. Sending
 * `writeToSession(id, text + '\r')` therefore does nothing at all for any
 * message longer than about half a line — the words appear in the session's
 * input box and sit there. Every message carrying an attachment is longer than
 * that, so on the single-write path the send button is a no-op 100% of the time
 * for exactly the feature that produces these mentions.
 *
 * Wiring: write the first element, wait {@link SUBMIT_GAP_MS}, write the
 * second. Both must reach the same session.
 */
export function terminalWrites(message: string): [string, string] {
  return [terminalPayload(message), '\r']
}

/* ------------------------------------------------------- shell command --- */

/**
 * A path as it should be **typed at a shell prompt**, quoted so a space or an
 * apostrophe in it cannot split the command.
 *
 * This exists because of a regression, and the regression is worth naming. When
 * the composer was rebuilt as one box, the plus was withdrawn entirely from
 * shell sessions on the grounds that everything behind it produced an `@"path"`
 * mention — which is true, and is an agent's syntax: a shell would type it
 * verbatim at its prompt and get `command not found`. The conclusion drawn was
 * that a shell gets no menu at all, which left that composer with a microphone
 * and a send button and nothing else. Picking a path out of the project is not
 * an agent feature; only the *form* of it was, so the form is what changes.
 *
 * The quoting style follows the **path**, not the machine, for the same reason
 * sessions route by folder rather than by a toggle: on Windows a `/home/...`
 * path launches through `wsl.exe` into a POSIX shell and a `C:/...` path
 * through `cmd.exe`, so the machine cannot answer which quoting the prompt on
 * the other end will parse — the path can.
 *
 *  - POSIX (`/…`): single quotes, because inside them `$`, a backtick and a
 *    backslash are all ordinary characters. The one thing that cannot appear
 *    inside single quotes is a single quote, which is why an apostrophe closes
 *    the string, escapes itself and reopens — `'it'\''s'` — the standard form.
 *  - Windows (`C:/…`, `\\server\…`): double quotes. `cmd.exe` has no escape
 *    inside them, and it needs none: `"` is one of the characters Windows
 *    forbids in a filename, so the case cannot arise.
 *
 * The drive test here is deliberately looser than {@link isWindowsShaped}, and
 * the difference is one input: a bare `C:` with no separator after it. That is
 * not a path anything may *attach* — hence the stricter shape rule there — but
 * it is a word `cmd.exe` understands, so quoting it as a Windows path is right
 * and single-quoting it for a POSIX shell that will never see it is not.
 */
export function shellQuote(path: string): string {
  const target = normalise(path)
  if (/^[A-Za-z]:/.test(target) || target.startsWith('\\\\')) return `"${target}"`
  return `'${target.replace(/'/g, `'\\''`)}'`
}

/* ------------------------------------------------------------ the list ---- */

export type AddResult =
  | { ok: true; attachments: Attachment[] }
  | { ok: false; reason: RejectReason }

/**
 * Validate one candidate against the project root and the current list.
 *
 * Every path shown by the picker is already inside the root, so for that caller
 * this is the second gate rather than the first. It is the *first* gate for the
 * three routes that reach outside the project — the open panel, a drop and a
 * paste — and those have to ask for it: `scope` defaults to `'project'`, so a
 * caller that has not thought about the question gets the old, narrow answer.
 *
 * The path is only ever tested against the root, never against the confinement
 * a session may be running under. That is deliberate and the two are genuinely
 * different questions: a root is a preference this module can evaluate, and a
 * boundary is a fact about a live process that only the main process knows. See
 * `main/session-boundary.ts` — the composer asks before it gets here.
 */
export function addAttachment(
  current: readonly Attachment[],
  root: string,
  path: string,
  isDirectory: boolean,
  scope: AttachScope = 'project',
): AddResult {
  const target = normalise(path)
  /*
   * Absolute in either spelling. This test used to be `startsWith('/')`, which
   * is false for every path a Windows file panel can produce — see the head of
   * the paths section: it made this the line that killed the whole feature on
   * one of the two platforms this ships to, and it did it with the one refusal
   * message guaranteed to read as a lie ("that path is not absolute" about a
   * path the user picked in Explorer).
   */
  if (!isAbsolutePath(target)) return { ok: false, reason: 'not-absolute' }
  const inside = insideRoot(root, target)
  if (!inside && scope === 'project') return { ok: false, reason: 'outside-root' }
  // `samePath`, not `===`: on Windows the same file picked from two panels can
  // arrive spelled two ways, and two chips for one file means the same source
  // pasted into the prompt twice.
  if (current.some((a) => samePath(a.path, target))) return { ok: false, reason: 'duplicate' }
  if (current.length >= MAX_ATTACHMENTS) return { ok: false, reason: 'full' }
  return {
    ok: true,
    attachments: [
      ...current,
      {
        path: target,
        // The absolute path is the label for anything outside the project. See
        // {@link Attachment.relPath} — `relativeTo` is not merely unhelpful for
        // an outside path, it is wrong, because it slices by the root's length.
        relPath: inside ? relativeTo(root, target) : target,
        kind: kindFor(target, isDirectory),
        // Absent rather than `false` for something inside, so that the common
        // case serialises and compares as the shape it has always had.
        ...(inside ? {} : { outside: true }),
      },
    ],
  }
}

/**
 * Removing has to answer the same question adding did.
 *
 * `samePath` rather than a string compare, so the chip that `addAttachment`
 * refused as a duplicate is the chip this removes — otherwise a Windows user
 * could hold an attachment that cannot be added again and cannot be taken off.
 */
export function removeAttachment(
  current: readonly Attachment[],
  path: string,
): Attachment[] {
  return current.filter((a) => !samePath(a.path, path))
}

/** One candidate, as the three outside routes hand them over. */
export interface AttachCandidate {
  path: string
  isDirectory: boolean
}

/**
 * A whole batch, folded once.
 *
 * This exists because of a bug that was written, shipped into a running app and
 * caught by looking at it: two files dropped together produced **one** chip.
 * The composer was calling `addAttachment` in a loop, and every call in that
 * loop read the same `attachments` out of the same closure — so each result
 * discarded the one before it and the last pick won. It is invisible in a unit
 * test of `addAttachment`, which is correct, and invisible in any test that
 * attaches one thing at a time.
 *
 * Batching is also the honest shape. Every route that reaches outside the
 * project can produce several at once — a multi-selection in the open panel,
 * four screenshots dropped together, two files copied in Finder — so "add these"
 * is the operation, and "add this one" was only ever a special case of it.
 *
 * The notice follows one rule: a refusal outranks a caution, and the first
 * refusal is the one reported. Someone who dropped twelve files onto a list with
 * room for two needs to know the list is full, not that the last of them was a
 * folder.
 */
export function addAttachments(
  current: readonly Attachment[],
  root: string,
  candidates: readonly AttachCandidate[],
  scope: AttachScope = 'project',
): { attachments: Attachment[]; notice: string | null } {
  let list: Attachment[] = [...current]
  let refusal: string | null = null
  let caution: string | null = null
  for (const candidate of candidates) {
    const result = addAttachment(list, root, candidate.path, candidate.isDirectory, scope)
    if (!result.ok) {
      refusal ??= REJECTION_TEXT[result.reason]
      continue
    }
    list = result.attachments
    const added = list[list.length - 1]
    if (added?.outside === true && added.kind === 'folder') caution = OUTSIDE_FOLDER_CAUTION
  }
  return { attachments: list, notice: refusal ?? caution }
}

/**
 * Directories implied by a flat file list.
 *
 * The project file index enumerates files only, so this is where the folder
 * picker's candidates come from — every ancestor of every file, deduped. It
 * costs one pass over a list the renderer already holds, and means adding a
 * folder needs no second round trip to the main process.
 *
 * That picker is the in-app project list, which was deleted (`outside.ts` has
 * the quote), so this currently has no caller but its test. It is kept and
 * fixed rather than left POSIX-only because the separator bug would come back
 * silently with whoever re-wires it: a Windows file index yields
 * `src\main\index.ts`, and splitting that on `/` finds no ancestor at all, so
 * the folder picker would simply be empty on Windows with nothing to see.
 */
export function foldersFrom(files: readonly string[]): string[] {
  const seen = new Set<string>()
  for (const file of files) {
    let cut = lastSeparator(file)
    while (cut > 0) {
      const dir = file.slice(0, cut)
      if (seen.has(dir)) break
      seen.add(dir)
      cut = lastSeparator(dir)
    }
  }
  return [...seen].sort()
}

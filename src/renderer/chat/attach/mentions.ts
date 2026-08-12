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
 * And the one that decides whether any of this works at all: typing `@` into
 * the interactive CLI opens its file-completion popup, and the Enter that
 * follows is swallowed by that popup — it accepts the highlighted suggestion
 * and replaces the whole line with a bare path. Measured end-to-end through a
 * real pty: the message was never sent. A single space after the mention
 * closes the popup, and then Enter submits the line intact. See
 * {@link terminalPayload}.
 */

/** POSIX separator throughout: these paths come from the main process, which
 *  normalises to forward slashes, and go into a prompt, not into an fs call. */
const SEP = '/'

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
  /** Project-relative, for the chip label. Never leaves this app. */
  relPath: string
  kind: AttachmentKind
}

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

/* ------------------------------------------------------------------ paths -- */

/** Trailing separators removed, so `/a/b/` and `/a/b` are one path. */
export function normalise(path: string): string {
  const trimmed = path.trim()
  if (trimmed.length <= 1) return trimmed
  return trimmed.replace(/\/+$/, '')
}

/**
 * Is `path` the root itself or something under it?
 *
 * The separator in the comparison is what makes this a containment test rather
 * than a string test: without it `/Users/asad/project-secrets` passes as inside
 * `/Users/asad/project`.
 */
export function insideRoot(root: string, path: string): boolean {
  const base = normalise(root)
  const target = normalise(path)
  if (base === '' || !base.startsWith(SEP) || !target.startsWith(SEP)) return false
  if (target === base) return true
  return target.startsWith(base.endsWith(SEP) ? base : base + SEP)
}

/** `path` expressed relative to `root`, or the path itself when it is the root. */
export function relativeTo(root: string, path: string): string {
  const base = normalise(root)
  const target = normalise(path)
  if (target === base) return base.slice(base.lastIndexOf(SEP) + 1)
  return target.slice(base.length + 1)
}

/** Last segment of a path — what a chip shows when the folder part is elided. */
export function basename(path: string): string {
  const target = normalise(path)
  const cut = target.lastIndexOf(SEP)
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
 */
export function mentionFor(attachment: Attachment): string {
  const path = normalise(attachment.path)
  return attachment.kind === 'folder' ? `@"${path}/"` : `@"${path}"`
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
 * What to hand the PTY writer, minus the carriage return.
 *
 * The trailing space is the whole fix for the completion popup, and it is free:
 * the CLI trims the line before it stores it, so the transcript records exactly
 * what the user wrote either way — verified by reading the JSONL back after a
 * real send.
 */
export function terminalPayload(message: string): string {
  return message.includes('@') ? `${message} ` : message
}

/* ------------------------------------------------------------ the list ---- */

export type AddResult =
  | { ok: true; attachments: Attachment[] }
  | { ok: false; reason: RejectReason }

/**
 * Validate one candidate against the project root and the current list.
 *
 * Every path shown by the picker is already inside the root, so this is the
 * second gate rather than the first — it also covers anything that arrives
 * from a native dialog later, where the user can point anywhere on the disk.
 */
export function addAttachment(
  current: readonly Attachment[],
  root: string,
  path: string,
  isDirectory: boolean,
): AddResult {
  const target = normalise(path)
  if (!target.startsWith(SEP)) return { ok: false, reason: 'not-absolute' }
  if (!insideRoot(root, target)) return { ok: false, reason: 'outside-root' }
  if (current.some((a) => a.path === target)) return { ok: false, reason: 'duplicate' }
  if (current.length >= MAX_ATTACHMENTS) return { ok: false, reason: 'full' }
  return {
    ok: true,
    attachments: [
      ...current,
      { path: target, relPath: relativeTo(root, target), kind: kindFor(target, isDirectory) },
    ],
  }
}

export function removeAttachment(
  current: readonly Attachment[],
  path: string,
): Attachment[] {
  return current.filter((a) => a.path !== normalise(path))
}

/**
 * Directories implied by a flat file list.
 *
 * The project file index enumerates files only, so this is where the folder
 * picker's candidates come from — every ancestor of every file, deduped. It
 * costs one pass over a list the renderer already holds, and means adding a
 * folder needs no second round trip to the main process.
 */
export function foldersFrom(files: readonly string[]): string[] {
  const seen = new Set<string>()
  for (const file of files) {
    let cut = file.lastIndexOf(SEP)
    while (cut > 0) {
      const dir = file.slice(0, cut)
      if (seen.has(dir)) break
      seen.add(dir)
      cut = dir.lastIndexOf(SEP)
    }
  }
  return [...seen].sort()
}

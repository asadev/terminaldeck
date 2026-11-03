/**
 * Names for a task's workspace: its folder under `<userData>/workspaces/`, and
 * the branch it is made on.
 *
 * Pure, so the rules that keep a task title out of a git command and out of a
 * path can be checked without a repository. A title is anything a person or a
 * CRM typed — slashes, `..`, quotes, emoji, a leading dash that would read as a
 * flag — and none of it may reach `git worktree add` as anything but a plain
 * word. So the slug is built from an allow-list (ASCII letters, digits, single
 * dashes) rather than by removing what is known to be bad: what comes out is a
 * valid ref component and a valid folder name on every platform by
 * construction, not by a check that could miss a case.
 */

import { createHash } from 'node:crypto'

/** `<userData>/workspaces/`: one folder per repository, one per task inside it. */
export const WORKSPACES_DIR = 'workspaces'

/** The records, beside the workspaces they describe. */
export const WORKSPACES_FILE = 'workspaces.json'

/** Every branch this app makes starts here, so a person can tell them apart in their own branch list. */
export const BRANCH_PREFIX = 'td/'

/** Longest slug taken from a title. Long enough to recognise, short enough for a branch list. */
export const MAX_SLUG_CHARS = 40

/** What a title with nothing usable in it becomes. */
export const FALLBACK_SLUG = 'task'

/** Longest readable part of a task's folder name, before its hash. */
const MAX_FOLDER_CHARS = 48

function sha256Hex(text: string): string {
  return createHash('sha256').update(text, 'utf8').digest('hex')
}

/**
 * A task title as a branch-safe slug: lower case, ASCII letters and digits,
 * words joined by single dashes, at most {@link MAX_SLUG_CHARS}.
 *
 * Accents are folded first (`Café` → `cafe`) so a title in a European language
 * keeps its words; anything with no ASCII form drops out. Never empty, never
 * starting or ending with a dash.
 */
export function slugOf(title: string): string {
  const folded = title
    .normalize('NFKD')
    .replace(/\p{M}+/gu, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
  const cut = folded.slice(0, MAX_SLUG_CHARS).replace(/-+$/g, '')
  return cut === '' ? FALLBACK_SLUG : cut
}

/** Eight hex characters standing for a task id, whatever characters the id itself has. */
export function shortIdOf(taskId: string): string {
  return sha256Hex(taskId).slice(0, 8)
}

/**
 * `td/<slug>-<short id>`, and `-2`, `-3`… after it when `attempt` is past the
 * first — for a name already taken in the repository, which this app never
 * reuses or moves.
 */
export function branchFor(title: string, taskId: string, attempt = 1): string {
  const base = `${BRANCH_PREFIX}${slugOf(title)}-${shortIdOf(taskId)}`
  return attempt <= 1 ? base : `${base}-${attempt}`
}

/** The first 16 hex characters of the SHA-256 of the repository's real path — the same key project knowledge uses. */
export function repoKeyOf(realRepo: string): string {
  return sha256Hex(realRepo).slice(0, 16)
}

/**
 * A task's folder name: its id with anything outside `[A-Za-z0-9._-]` made a
 * dash, then the id's hash, so two ids that read the same once cleaned
 * (`a:b`, `a/b`) still get two folders. A CRM's ids are its own and a local
 * task's are `local:<uuid>`; a colon alone is enough to need this on Windows.
 */
export function folderNameOf(taskId: string, attempt = 1): string {
  const readable = taskId
    .replace(/[^A-Za-z0-9._-]+/g, '-')
    .replace(/^[-.]+|[-.]+$/g, '')
    .slice(0, MAX_FOLDER_CHARS)
  const base = `${readable === '' ? FALLBACK_SLUG : readable}-${shortIdOf(taskId)}`
  return attempt <= 1 ? base : `${base}-${attempt}`
}

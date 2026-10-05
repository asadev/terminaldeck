import { readFile, stat } from 'node:fs/promises'
import { join } from 'node:path'
import { projectPathSpellings, transcriptDir } from './transcript'

/**
 * Which conversation a tab opened on Claude Code's conversation list is on.
 *
 * A kept tab with no usable conversation id opens on `claude --resume` and the
 * person picks (`CreateSessionInput.pickConversation`). The pick happens inside
 * the CLI, so this learns it afterwards and writes it onto the tab's record —
 * so the next launch continues that conversation by id instead of asking again.
 * Two sources, and both name *this* process rather than a folder:
 *
 *  - the `SessionStart` hook, which carries this app's session id (the env var
 *    the pty is started with) and the CLI's own `session_id`; and, where the
 *    hooks are not turned on,
 *  - Claude Code's own per-process record, `<configDir>/sessions/<pid>.json`,
 *    read for this pty's pid when the person types — at most once per
 *    {@link TYPING_GAP_MS}, never on a timer.
 *
 * An id is accepted only when its transcript exists, non-empty, under this
 * folder. That rejects the fresh id the CLI holds while its list is still open
 * and a conversation picked from another folder. With neither source the tab
 * learns nothing and opens on the list again next launch — asked again, never
 * guessed.
 */

export interface PickWatch {
  cwd: string
  /** The login's config directory — where its transcripts and process records live. */
  configDir: string
}

export interface PickedDeps {
  pidOf(id: string): number | null
  /** Called once per newly confirmed conversation for a watched session. */
  learned(id: string, conversationId: string): void
  now?(): number
}

const CONVERSATION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
export const TYPING_GAP_MS = 3000

/** Is there a non-empty transcript for this conversation under this folder? */
export async function hasTranscript(watch: PickWatch, conversationId: string): Promise<boolean> {
  if (!CONVERSATION_ID.test(conversationId)) return false
  for (const spelling of projectPathSpellings(watch.cwd)) {
    try {
      const file = await stat(join(transcriptDir(spelling, watch.configDir), `${conversationId}.jsonl`))
      if (file.isFile() && file.size > 0) return true
    } catch {
      // Not under this spelling of the folder.
    }
  }
  return false
}

/** The conversation Claude Code's own record says process `pid` is on, or null. */
export async function sessionFileConversation(configDir: string, pid: number): Promise<string | null> {
  try {
    const record: unknown = JSON.parse(await readFile(join(configDir, 'sessions', `${pid}.json`), 'utf8'))
    if (typeof record !== 'object' || record === null) return null
    const { pid: owner, sessionId } = record as Record<string, unknown>
    return owner === pid && typeof sessionId === 'string' ? sessionId : null
  } catch {
    return null
  }
}

interface Watched extends PickWatch {
  known: string | null
  readAt: number
}

export class PickedConversations {
  private readonly watching = new Map<string, Watched>()

  constructor(private readonly deps: PickedDeps) {}

  watch(id: string, watch: PickWatch): void {
    this.watching.set(id, { ...watch, known: null, readAt: -Infinity })
  }

  forget(id: string): void {
    this.watching.delete(id)
  }

  /** A hook event. Only Claude's `SessionStart` for a watched session counts. */
  async noteHook(event: {
    provider: string
    event: string
    sessionId: string | null
    cliSessionId: string | null
  }): Promise<void> {
    if (event.provider !== 'claude' || event.event !== 'SessionStart') return
    if (event.sessionId === null || event.cliSessionId === null) return
    await this.consider(event.sessionId, event.cliSessionId)
  }

  /** The person typed into a session: read the CLI's own record, if this one is watched. */
  async noteTyping(id: string): Promise<void> {
    const entry = this.watching.get(id)
    if (!entry) return
    const now = this.deps.now?.() ?? Date.now()
    if (now - entry.readAt < TYPING_GAP_MS) return
    entry.readAt = now
    const pid = this.deps.pidOf(id)
    if (pid === null) return
    const candidate = await sessionFileConversation(entry.configDir, pid)
    if (candidate !== null) await this.consider(id, candidate)
  }

  private async consider(id: string, candidate: string): Promise<void> {
    const entry = this.watching.get(id)
    if (!entry || entry.known === candidate) return
    if (!(await hasTranscript(entry, candidate))) return
    // Forgotten, or re-watched, while the disk was being asked.
    if (this.watching.get(id) !== entry) return
    entry.known = candidate
    this.deps.learned(id, candidate)
  }
}

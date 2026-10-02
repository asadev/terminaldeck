/**
 * Which conversation a session is on, when this app did not put the id on its
 * command line — recovered from the transcripts the agent writes.
 *
 * ## Why it is needed
 *
 * A switch carries the conversation on screen by naming it (`--resume <id>`),
 * and it can only name what it knows. A fresh session is given its id
 * (`--session-id`), but a session restored at launch is started with
 * `--continue`, and the CLI refuses `--session-id` beside that — so a restored
 * tab ran with no id at all. Its switch then fell back to "the folder's newest
 * conversation", which in a folder with more than one tab, or with history
 * shared between accounts, can be somebody else's conversation entirely.
 *
 * ## How, and why each rule is there
 *
 * Claude Code files a conversation at `<configDir>/projects/<encoded cwd>/<id>.jsonl`,
 * names the file after the id, and appends to that same file when it is
 * continued. So the candidates are the transcripts of this folder, and:
 *
 *  1. **Ids another live tab is on are not candidates.** They are that tab's.
 *  2. **One transcript written to since this session started is this
 *     session's.** Nothing else in this folder can be writing it — rule 1 took
 *     the other tabs out.
 *  3. **More than one is ambiguous, and the answer is null.** Two conversations
 *     moving at once in one folder, neither claimed, is something this app
 *     cannot attribute, and a guess here would carry the wrong conversation
 *     into another account — worse than carrying none.
 *  4. **None written since it started means it has not spoken yet**, so it is
 *     still on the conversation `--continue` attached to when it started: the
 *     newest one then, which — nothing having been written since — is the
 *     newest unclaimed one now. The same lookup the restore made
 *     (`newestConversation`), which is what makes the two agree.
 *
 * Asked at spawn for a restored session (rule 4 with nothing yet written) and
 * again at switch time for any session that still has no id.
 */

import { listTranscripts, type TranscriptFile } from './transcript'

export interface RecoverInput {
  /** This folder's transcript directories — both spellings of it, under one store. */
  dirs: readonly string[]
  /** When the session started, epoch ms. */
  startedAt: number
  /** Ids other live sessions are known to be on. */
  claimed: ReadonlySet<string>
}

export async function recoverConversationId(input: RecoverInput): Promise<string | null> {
  const seen = new Map<string, TranscriptFile>()
  for (const dir of input.dirs) {
    for (const file of await listTranscripts(dir)) {
      if (file.bytes === 0 || input.claimed.has(file.sessionId)) continue
      const held = seen.get(file.sessionId)
      if (!held || file.modifiedAt > held.modifiedAt) seen.set(file.sessionId, file)
    }
  }
  const files = [...seen.values()].sort((a, b) => b.modifiedAt - a.modifiedAt)
  const since = files.filter((file) => file.modifiedAt >= input.startedAt)
  if (since.length === 1) return since[0]?.sessionId ?? null
  if (since.length > 1) return null
  return files[0]?.sessionId ?? null
}

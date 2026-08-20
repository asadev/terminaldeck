/**
 * The chat view's reading, for a window that is not on this machine.
 *
 * The fourth of the seams that make a session look the same from a phone as it
 * does at the desk — `controls`, `usage`, `account` and now this. Asad,
 * 2026-08-20, about the phone: *"app needs enrichment"*; and about the desktop's
 * own chat view, in the same recording, everything a bubble has to be — his
 * messages on the right, the agent's on the left, a time, a copy button, and no
 * name on either side.
 *
 * That view has existed on the Mac for weeks and could never be opened from
 * anywhere else, because it reads a file: `chat:load` and `chat:tail` take a
 * folder or a transcript path and hand back collapsed bubbles. A phone has
 * neither the file nor a filesystem to find it in.
 *
 * ## A second caller, not a second implementation
 *
 * `ChatReader` and `ChatCollapser` are `chat-transcript.ts`'s own, and this
 * module adds nothing to them. The collapsing rules — which lines are a bubble,
 * how a continuation is folded in, how a compaction's replayed lines are
 * de-duplicated — are hard-won and stay in one place. What is here is the two
 * things a remote reader needs and a local one does not:
 *
 *  - **Finding the transcript from a session id.** The local view is handed a
 *    `cwd` by a window that already knows it. Here there is only an id, so the
 *    session is looked up and its `agentSessionId` used when it has one. That
 *    field exists because "the most recently written transcript in this folder"
 *    is wrong the moment two sessions share a folder, which is what Asad
 *    recorded on 2026-08-19 — *"it is showing same context window for your
 *    session too"* — with both tabs reading one file.
 *
 *  - **A cursor per viewer.** `chat-transcript.ts` keys its readers by path,
 *    which is right for one process drawing its own windows. Over a wire it
 *    would mean a phone and the Mac's own chat view consuming each other's new
 *    bubbles, each seeing half a conversation with nothing on screen to say so.
 *    So readers here are keyed by viewer *and* session, and the local map is
 *    left alone.
 *
 * ## What it does not do
 *
 * Push. There is no `chat.push` and there should not be one until something
 * needs it: the client asks when the session prints, which is an event it
 * already has, and a second push channel for the same file would be a second
 * thing to keep in step with `sessionsChanged`.
 */

import { stat } from 'node:fs/promises'
import { join } from 'node:path'
import { ChatReader } from '../chat-transcript'
import { MAX_CHAT_ROWS, type CopilotChatMessage } from './protocol'
import type { RemoteChatAccess } from './server'
import type { SessionMeta } from '../../shared/types'
import { listTranscripts, transcriptDirs } from '../transcript'

export interface ChatServeOptions {
  /**
   * The session, or null when this machine has no such session.
   *
   * The same lookup `createUsageServe` and `createAccountServe` are given, asked
   * the same way deliberately: "which conversation is this session's" having two
   * answers on one machine is how one session's transcript lands on another
   * session's screen.
   */
  describeSession: (sessionId: string) => SessionMeta | null
  /**
   * Which config directory that session's conversations are filed under, when it
   * is not the default one.
   *
   * An account is a config directory, so a session running as a second login
   * writes its transcript under that login's `projects/`. Without this a phone
   * would be shown the default account's conversation in the same folder — the
   * same class of mistake `usage-serve.ts` names about the context window, and
   * worse here because it is words rather than a number.
   */
  configDirFor?: (session: SessionMeta) => string | null
}

/** How many readers to hold before the oldest is dropped. */
const MAX_READERS = 32

export function createChatServe(options: ChatServeOptions): RemoteChatAccess {
  /**
   * One reader per viewer per session, in insertion order.
   *
   * A `Map` because its iteration order is insertion order, which makes the
   * eviction below one line: a phone that looked at forty sessions overnight
   * must not leave forty file cursors and forty collapsers in this process's
   * heap for the life of the app.
   */
  const readers = new Map<string, { path: string; reader: ChatReader }>()

  return {
    read: async (sessionId, tail, viewer) => {
      const session = options.describeSession(sessionId)
      if (session === null) return { rows: [], reset: true, found: false }

      const path = await pathFor(session, options.configDirFor?.(session) ?? null)
      if (path === null) return { rows: [], reset: true, found: false }

      /*
       * NUL between the two, written as an escape.
       *
       * A device id and a session id are both opaque, so any printable
       * separator is a character one of them could contain — and two keys that
       * collide here are two viewers sharing a cursor, which is the whole thing
       * this key exists to prevent. `parseChatLine` joins its dedupe keys the
       * same way and for the same reason, and says why it is an escape: one
       * literal NUL makes this file binary to `grep`(1), which then matches it
       * silently. `src/encoding.test.ts` is the latch, and it caught this.
       */
      const key = `${viewer}\u0000${sessionId}`
      const held = readers.get(key)
      /*
       * A fresh reader for a full read, and for a transcript that has changed
       * under this session.
       *
       * The second is not hypothetical: an account switch replaces the process
       * and the new one writes a new file, and a reader still pointed at the old
       * path would tail a conversation that has stopped growing — a chat view
       * that silently freezes, which is precisely the shape of the defect he
       * filmed at the desk.
       */
      if (held === undefined || held.path !== path || !tail) {
        const reader = new ChatReader(path)
        await reader.readAll()
        readers.delete(key)
        readers.set(key, { path, reader })
        if (readers.size > MAX_READERS) {
          const oldest = readers.keys().next()
          if (!oldest.done) readers.delete(oldest.value)
        }
        return { rows: toWire(reader.conversation).slice(-MAX_CHAT_ROWS), reset: true, found: true }
      }

      const { messages, reset } = await held.reader.readAll()
      // A reset means the file shrank or was replaced, so what the client holds
      // is not a prefix of what is there now. The whole conversation goes back
      // with the flag rather than the difference, because the difference is not
      // meaningful against a document that no longer exists.
      const rows = reset ? [...held.reader.conversation] : messages
      return { rows: toWire(rows).slice(-MAX_CHAT_ROWS), reset, found: true }
    },
  }
}

/**
 * Which file this session's conversation is in.
 *
 * `agentSessionId` first, because it is the answer rather than a guess: this app
 * gave the CLI that id at spawn and the CLI filed the conversation under it. It
 * is absent for a resumed session, for a session running another agent, and for
 * one this app did not start — all three keep the inference, which is what the
 * local chat view has always used and is right far more often than not.
 */
async function pathFor(session: SessionMeta, configDir: string | null): Promise<string | null> {
  if (session.agentSessionId) {
    /*
     * Looked for by that name in **every** store this project's transcripts can
     * be filed under, not composed as one path.
     *
     * A project genuinely has more than one — the account's own config
     * directory, and a per-device home for a confined session — and which of
     * them a session writes into is a question `transcriptDirs` already answers.
     * `context-window.ts` resolves the identical thing the identical way and
     * records why: a single composed path is right for the ordinary session and
     * silently wrong for a confined one.
     */
    const dirs = transcriptDirs(session.cwd, configDir === null ? {} : { configDir })
    for (const dir of dirs) {
      const path = join(dir, `${session.agentSessionId}.jsonl`)
      // `stat` rather than trusting the name: this app gave the id at spawn, but
      // a session that was never written to has no file, and a reader opened on
      // one would answer "no conversation" for a folder that has an older one
      // worth showing.
      try {
        await stat(path)
        return path
      } catch {
        // Not in this store. Try the next, then fall through to the inference.
      }
    }
  }
  /*
   * The inference, **scoped to the same store**.
   *
   * `newestChatTranscript` is the local view's fallback and it asks the default
   * config directory, because the window calling it is on a machine where that
   * is the right answer. Here it is not: a session running as a second login
   * files under that login's `projects/`, so falling through to the default
   * store would show the phone the *default* account's conversation in the same
   * folder — the exact mistake the paragraph above `configDirFor` is about,
   * arrived at by the back door. So the same "most recently written" rule is
   * applied across the directories this session's own account writes to.
   */
  const dirs = transcriptDirs(session.cwd, configDir === null ? {} : { configDir })
  const found = await Promise.all(dirs.map((dir) => listTranscripts(dir)))
  let newest: { path: string; modifiedAt: number } | null = null
  for (const file of found.flat()) {
    if (newest === null || file.modifiedAt > newest.modifiedAt) newest = file
  }
  return newest?.path ?? null
}

/**
 * A `ChatMessage` is a `CopilotChatMessage` — one bubble shape on this wire.
 *
 * Deliberately the same type rather than a mapping, so a client has one reader
 * for both conversations and a field added to a bubble arrives in both places or
 * neither. The one field the wire has and the transcript does not is
 * `truncated`, which is set here because the cap is a wire cap: the desktop's
 * own view has the file and scrolls it.
 */
function toWire(rows: readonly { id: string; role: 'you' | 'agent'; text: string; at: number }[]): CopilotChatMessage[] {
  return rows.map((row) => {
    const message: CopilotChatMessage = { id: row.id, role: row.role, text: row.text, at: row.at }
    return message
  })
}

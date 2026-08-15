/**
 * The readable half of a session: what the user asked, what the agent said
 * back, and nothing else.
 *
 * `transcript.ts` reads these same JSONL files for money and `session-insights.ts`
 * reads them for the shape of the work. Both keep the machinery — usage blocks,
 * tool calls, compaction markers. This module throws all of that away and keeps
 * the prose, because the chat view exists precisely to hide it.
 *
 * Every rule below was measured against the transcripts on this machine
 * (28 project directories, ~2 GB) rather than assumed, and the surprises are
 * called out at each site. The three that matter:
 *
 *  1. A `user` line is only a typed prompt when `message.content` is a **string**.
 *     The array form is almost always tool results — 8,597 of 8,817 array-form
 *     user lines in one sweep — and rendering those turns the agent's own tool
 *     output into fake user messages.
 *  2. …but not *only* tool results. 156 array-form lines carried a text block and
 *     were not `isMeta`, and they are CLI plumbing (`[Request interrupted by
 *     user]`). The one genuine exception is a prompt with a pasted image, which
 *     the CLI writes as `[image, text]` and stamps `origin: { kind: 'human' }`.
 *     That stamp is the only reliable "a person typed this" marker in the file.
 *  3. Not every machine-written user line is flagged. 51 string-content lines
 *     were slash-command plumbing (`<command-name>/model</command-name>`,
 *     `<local-command-stdout>…`) with no `isMeta` and no `origin` at all, and
 *     462 were `origin.kind === 'task-notification'`. Filtering on `isMeta`
 *     alone leaves all of those on screen as things the user never said.
 */

import type { IpcMain, IpcMainInvokeEvent } from 'electron'
import { open, stat } from 'node:fs/promises'
import { basename, resolve } from 'node:path'
import { StringDecoder } from 'node:string_decoder'
import { isTranscriptPath, listTranscripts, transcriptDirs } from './transcript'

/* -------------------------------------------------------------------------- */
/* Types                                                                       */
/* -------------------------------------------------------------------------- */

export type ChatRole = 'you' | 'agent'

/** One bubble in the reading view. */
export interface ChatMessage {
  /** Stable across reads, so an appended-to message replaces rather than duplicates. */
  id: string
  role: ChatRole
  text: string
  /** Epoch ms of the first line that fed this message, or 0 when undated. */
  at: number
}

export interface ChatUpdate {
  transcriptPath: string
  sessionId: string
  cwd: string
  /**
   * Messages that are new *or were extended* since the last read, in order.
   * The renderer merges by `id`: replace a match, otherwise append.
   */
  messages: ChatMessage[]
  /** The file shrank or was replaced. Drop everything and treat `messages` as the whole conversation. */
  reset: boolean
  /** Bytes consumed so far — purely diagnostic; the reader holds the real cursor. */
  cursor: number
  /** False when the project has no transcript at all, which is a different empty state from a silent session. */
  found: boolean
  /** False while bytes remain; `loadChat` always returns true. */
  complete: boolean
  updatedAt: number
}

/** One transcript line reduced to the parts a conversation needs. */
export interface ChatLine {
  role: ChatRole
  text: string
  at: number
  /** `message.id` for a reply, the line uuid for a prompt. Groups continuation lines. */
  groupKey: string
  /** What a replayed copy of this line would collide with. See `ChatReader`. */
  dedupeKey: string
  sessionId?: string
  cwd?: string
}

/* -------------------------------------------------------------------------- */
/* Line parsing                                                                */
/* -------------------------------------------------------------------------- */

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function str(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined
}

/**
 * Text the CLI injected into the conversation while wearing the user's role.
 *
 * These arrive as ordinary string content with no `isMeta` and no `origin`, so
 * nothing but the opening tag distinguishes them from something a person typed.
 * Anchored at the start: a prompt that merely *mentions* `<command-name>` — this
 * repo's own commit messages do — is still a prompt.
 */
const CLI_TAG =
  /^\s*<(?:command-name|command-message|command-args|command-contents|local-command-stdout|local-command-stderr|bash-input|bash-stdout|bash-stderr|task-notification|user-prompt-submit-hook|system-reminder|user-memory-input|ide-opened-file|ide-selection)[\s>]/

/**
 * System reminders the CLI staples onto a real prompt.
 *
 * Not seen inline on this machine, but they are appended rather than sent as
 * their own line in other setups, and a paragraph of harness instructions
 * rendered as something the user said is worse than a missing sentence.
 */
const SYSTEM_REMINDER = /<system-reminder>[\s\S]*?<\/system-reminder>/g

function cleanPrompt(text: string): string {
  return text.replace(SYSTEM_REMINDER, '').trim()
}

/** Concatenated text of an assistant/user content array. Ignores every other block type. */
function textBlocks(content: unknown[]): string {
  const parts: string[] = []
  for (const block of content) {
    if (!isRecord(block) || str(block.type) !== 'text') continue
    const text = typeof block.text === 'string' ? block.text : ''
    if (text.trim().length > 0) parts.push(text.trim())
  }
  return parts.join('\n\n')
}

function hasBlock(content: unknown[], type: string): boolean {
  return content.some((block) => isRecord(block) && str(block.type) === type)
}

/**
 * Parse one JSONL line into a conversation line, or null when it holds nothing
 * a reader should see.
 *
 * Deliberately not `parseInsightLine` or `parseEventLine`: both of those exist
 * to keep the tool calls and token counts this one is built to discard.
 */
export function parseChatLine(line: string): ChatLine | null {
  const trimmed = line.trim()
  if (trimmed.length === 0) return null

  let raw: unknown
  try {
    raw = JSON.parse(trimmed)
  } catch {
    // Transcripts are appended to live, so a torn final line is normal.
    return null
  }
  if (!isRecord(raw)) return null

  const type = str(raw.type)
  if (type !== 'user' && type !== 'assistant') return null

  // Sub-agents run their own conversation against their own prompt. Splicing it
  // into the main thread reads as the user suddenly briefing themselves.
  if (raw.isSidechain === true) return null
  // CLI-injected text wearing the user's role: skill preambles, hook output.
  if (raw.isMeta === true) return null
  // A compaction summary is a machine-written recap posted as a user turn; it is
  // the single largest fake prompt a transcript can contain.
  if (raw.isCompactSummary === true) return null
  if (raw.isVisibleInTranscriptOnly === true) return null

  const message = isRecord(raw.message) ? raw.message : undefined
  if (!message) return null

  const uuid = str(raw.uuid)
  const at = typeof raw.timestamp === 'string' ? Date.parse(raw.timestamp) || 0 : 0
  const sessionId = str(raw.sessionId)
  const cwd = str(raw.cwd)

  if (type === 'assistant') {
    // `model: '<synthetic>'` is the CLI writing in the agent's voice. The flag
    // below covers only the error notices; measured against this machine's
    // store, 96 synthetic lines carry `isApiErrorMessage: false` and say "No
    // response requested." — a sentence the model never wrote, landing in the
    // reading view as a reply. The model field is the marker that catches both.
    if (str(message.model) === '<synthetic>') return null
    // Kept as well: an error notice could arrive without the synthetic model.
    if (raw.isApiErrorMessage === true) return null
    if (!Array.isArray(message.content)) return null
    const text = textBlocks(message.content)
    if (text.length === 0) return null
    // Thinking and tool_use blocks are simply not `text`, so they never arrive here.
    const messageId = str(message.id) ?? uuid ?? ''
    return {
      role: 'agent',
      text,
      at,
      groupKey: messageId,
      // Blocks of one request repeat their `usage` verbatim but each carries a
      // *different* content block, so the id alone cannot be the key — that
      // would keep the first sentence of a reply and drop the rest. The id plus
      // the text drops only true repeats, which compaction replays do produce.
      dedupeKey: `agent ${messageId} ${text}`,
      sessionId,
      cwd,
    }
  }

  const origin = isRecord(raw.origin) ? str(raw.origin.kind) : undefined
  // `origin` is absent on older lines, so it can only be used to *reject*.
  if (origin !== undefined && origin !== 'human') return null

  const content = message.content
  let text: string

  if (typeof content === 'string') {
    text = cleanPrompt(content)
    if (text.length === 0 || CLI_TAG.test(content)) return null
  } else if (Array.isArray(content)) {
    // The array form is tool results — the agent's own output — unless the CLI
    // stamped it as human, which it does for a prompt with a pasted image.
    if (origin !== 'human' || hasBlock(content, 'tool_result')) return null
    const joined = textBlocks(content)
    // The same tag gate as the string form. Not seen in this shape on this
    // machine, but the human stamp and the CLI wrapper are written by the same
    // code path, and one slash command recorded as `[text]` instead of a string
    // would otherwise walk straight through.
    if (CLI_TAG.test(joined)) return null
    text = cleanPrompt(joined)
    if (text.length === 0) return null
  } else {
    return null
  }

  const key = uuid ?? `${at}`
  return {
    role: 'you',
    text,
    at,
    groupKey: key,
    // Prompts are deduped by line identity, never by text: "continue" typed
    // twice is two turns, but the same uuid replayed across a compaction
    // boundary is one.
    dedupeKey: `you ${key}`,
    sessionId,
    cwd,
  }
}

/**
 * Cheap substring gate before the expensive `JSON.parse`.
 *
 * The tool-result lines this module discards are also the enormous ones — a
 * single one reaches 1.1 MB here — and they are exactly the lines carrying
 * `tool_use_id`. Excluding them turns a 154 MB transcript into a few MB of
 * parsing. Claude Code writes compact JSON, verified on every file on this
 * machine, so the `"type":"..."` test is safe.
 */
export function mayCarryChat(line: string): boolean {
  if (line.includes('"tool_use_id"')) return false
  return line.includes('"type":"user"') || line.includes('"type":"assistant"')
}

/* -------------------------------------------------------------------------- */
/* Collapsing                                                                  */
/* -------------------------------------------------------------------------- */

/** Blank line between merged blocks, so two paragraphs do not run together. */
const JOIN = '\n\n'

/**
 * Folds lines into messages, one bubble per turn.
 *
 * Consecutive agent text merges until the user speaks again. That covers both
 * shapes the CLI produces: one request whose reply is split over several text
 * blocks (each written as its own JSONL line sharing a `message.id`), and one
 * turn that answers, calls tools, and answers again under several ids. The
 * tool calls between them are already gone, so leaving the prose in separate
 * bubbles would only show the user the seams of work they asked not to see.
 */
export class ChatCollapser {
  private readonly messages: ChatMessage[] = []
  private open: ChatMessage | null = null
  private ordinal = 0

  /** The whole conversation so far. */
  get all(): readonly ChatMessage[] {
    return this.messages
  }

  /**
   * Add a line. Returns the message it changed — a new one, or the open agent
   * message with more text on it — so a caller tailing a live file can send
   * only what moved.
   */
  push(line: ChatLine): ChatMessage {
    if (line.role === 'agent' && this.open) {
      this.open.text = this.open.text.length > 0 ? `${this.open.text}${JOIN}${line.text}` : line.text
      if (this.open.at === 0) this.open.at = line.at
      return this.open
    }

    this.ordinal += 1
    const created: ChatMessage = {
      id: `${line.role}:${line.groupKey || `line-${this.ordinal}`}`,
      role: line.role,
      text: line.text,
      at: line.at,
    }
    this.messages.push(created)
    // Only an agent message stays open; a prompt closes the previous turn and
    // two prompts in a row are two things the user said.
    this.open = line.role === 'agent' ? created : null
    return created
  }

  clear(): void {
    this.messages.length = 0
    this.open = null
    this.ordinal = 0
  }
}

/** Whole-conversation convenience over `ChatCollapser`. Pure — no filesystem. */
export function collapseChat(lines: Iterable<ChatLine>): ChatMessage[] {
  const collapser = new ChatCollapser()
  for (const line of lines) collapser.push(line)
  return [...collapser.all]
}

/* -------------------------------------------------------------------------- */
/* Incremental reading                                                         */
/* -------------------------------------------------------------------------- */

/** Bytes pulled per `read()`. Bounds peak memory on the first pass over a large file. */
const CHUNK_BYTES = 4 * 1024 * 1024

/** Ceiling on one buffered line, so a file with no newlines cannot be held whole. */
const MAX_LINE_BYTES = 8 * 1024 * 1024

/**
 * Reads only the bytes appended since the last call and reports the messages
 * that moved.
 *
 * Holds a byte offset, a trailing partial line and a `StringDecoder` so a chunk
 * boundary landing inside a multi-byte character cannot corrupt it — the same
 * arrangement `TranscriptTail` uses, which is not reused here because it drops
 * every line without a `usage` block and prose lines have none.
 */
export class ChatReader {
  private offset: number
  private partial = ''
  private decoder = new StringDecoder('utf8')
  private readonly collapser = new ChatCollapser()
  /**
   * Lines already folded in.
   *
   * Compaction replays part of the conversation verbatim, so both prompts and
   * replies genuinely arrive twice; 49 duplicate line uuids in one sweep of
   * this machine's transcripts.
   */
  private readonly seen = new Set<string>()

  sessionId: string
  cwd = ''

  /**
   * `startAt` skips the front of the file instead of reading it.
   *
   * Zero — the whole conversation — is what chat mode wants and what every
   * caller got before this existed. The exception is the restore's replay, which
   * paints a bounded tail onto a terminal at launch: reading a 154 MB transcript
   * from byte zero to render the last few hundred lines of it would put a
   * multi-second disk read in front of a window opening, once per restored tab,
   * for bytes it is about to throw away.
   *
   * The cost of starting mid-file is one torn line, and it is already handled:
   * the first line read is almost certainly a fragment, `JSON.parse` refuses it
   * and `parseChatLine` returns null — the same path a half-written trailing
   * line has always taken. What a caller must not do is *claim* the result is
   * the whole conversation; `session-replay.ts` says so on screen.
   */
  constructor(
    readonly path: string,
    sessionId = basename(path, '.jsonl'),
    startAt = 0,
  ) {
    this.sessionId = sessionId
    this.offset = Math.max(0, Math.trunc(startAt))
  }

  get position(): number {
    return this.offset
  }

  /** Everything read so far, collapsed. */
  get conversation(): readonly ChatMessage[] {
    return this.collapser.all
  }

  /**
   * Back to the beginning of the file — byte zero, not the offset this reader
   * was constructed with.
   *
   * Only reached when the file got *shorter*, which means it is a different file
   * under the same name. A start offset was an optimisation about the file that
   * was there a moment ago; carrying it into a file that has been replaced would
   * be seeking past the end of something we know nothing about.
   */
  private rewind(): void {
    this.offset = 0
    this.partial = ''
    this.decoder = new StringDecoder('utf8')
    this.collapser.clear()
    this.seen.clear()
  }

  /** One chunk. `complete` is false while bytes remain. */
  async read(): Promise<{ messages: ChatMessage[]; reset: boolean; complete: boolean }> {
    let size: number
    try {
      const info = await stat(this.path)
      // `open(dir, 'r')` succeeds on macOS and only fails at the first read, so a
      // directory named `*.jsonl` inside the store would escape as a raw EISDIR.
      if (!info.isFile()) return { messages: [], reset: false, complete: true }
      size = info.size
    } catch {
      return { messages: [], reset: false, complete: true }
    }

    // A shorter file is a different file: the session was rewritten or its id
    // reused. Re-reading from zero is the only safe response.
    let reset = false
    if (size < this.offset) {
      this.rewind()
      reset = true
    }
    if (size === this.offset) return { messages: [], reset, complete: true }

    const length = Math.min(CHUNK_BYTES, size - this.offset)
    const buffer = Buffer.allocUnsafe(length)
    const handle = await open(this.path, 'r')
    let text: string
    try {
      const { bytesRead } = await handle.read(buffer, 0, length, this.offset)
      // Truncated between the stat and the read. Callers loop on `complete`, so
      // reporting more work after consuming nothing would spin.
      if (bytesRead === 0) return { messages: [], reset, complete: true }
      this.offset += bytesRead
      text = this.partial + this.decoder.write(buffer.subarray(0, bytesRead))
    } finally {
      await handle.close()
    }

    const lines = text.split('\n')
    // The last element is either '' or a line still being written; neither is
    // ready to parse.
    this.partial = lines.pop() ?? ''
    if (this.partial.length > MAX_LINE_BYTES) this.partial = ''

    // Insertion-ordered, and keyed by id so a message extended twice inside one
    // chunk crosses the bridge once.
    const changed = new Map<string, ChatMessage>()
    for (const line of lines) {
      if (!mayCarryChat(line)) continue
      const parsed = parseChatLine(line)
      if (!parsed) continue
      if (this.seen.has(parsed.dedupeKey)) continue
      this.seen.add(parsed.dedupeKey)
      if (parsed.sessionId && !this.sessionId) this.sessionId = parsed.sessionId
      if (parsed.cwd && !this.cwd) this.cwd = parsed.cwd
      const message = this.collapser.push(parsed)
      changed.set(message.id, message)
    }

    // Copies: the open message keeps growing in place, and a live view must not
    // watch the object it already rendered mutate underneath it.
    return {
      messages: [...changed.values()].map((m) => ({ ...m })),
      reset,
      complete: this.offset >= size,
    }
  }

  /** Read to EOF. */
  async readAll(): Promise<{ messages: ChatMessage[]; reset: boolean }> {
    const merged = new Map<string, ChatMessage>()
    let reset = false
    for (;;) {
      const chunk = await this.read()
      if (chunk.reset) {
        reset = true
        merged.clear()
      }
      for (const message of chunk.messages) merged.set(message.id, message)
      if (chunk.complete) break
    }
    return { messages: [...merged.values()], reset }
  }
}

/* -------------------------------------------------------------------------- */
/* Whole-file convenience                                                      */
/* -------------------------------------------------------------------------- */

/** Read one transcript end to end and return its conversation. */
export async function readChatTranscript(path: string): Promise<ChatMessage[]> {
  const reader = new ChatReader(path)
  await reader.readAll()
  return [...reader.conversation]
}

/**
 * Read a transcript from a byte offset to the end, and return what is there.
 *
 * The same reader, entered late. It exists so the one caller that genuinely
 * wants a tail — the restore's replay, painting a bounded number of lines onto a
 * terminal while the app is still opening — does not become a second parser of
 * this format, which is how the two would drift apart on the next surprise the
 * CLI writes into a line.
 *
 * The result is a *fragment* of a conversation whenever `from` is not zero, and
 * the caller owns saying so. Nothing here can tell how much was skipped: the
 * bytes before the offset were never read.
 */
export async function readChatTail(path: string, from: number): Promise<ChatMessage[]> {
  const reader = new ChatReader(path, undefined, from)
  await reader.readAll()
  return [...reader.conversation]
}

/**
 * The transcript a project's chat view should open: the one most recently
 * written to, which is the live session.
 *
 * Asked of every store, not just the profile's. A session started from a paired
 * device runs confined, with a `HOME` of its own, and its conversation is
 * written under that home — so this used to answer "there is no transcript" for
 * a session that was talking, and chat mode showed an empty conversation with
 * nothing to explain it. `transcript.ts` says where the stores are; the
 * comparison here is unchanged, because "most recently written" is the same
 * question across two directories as it is inside one.
 */
export async function newestChatTranscript(cwd: string): Promise<string | null> {
  const found = await Promise.all(
    transcriptDirs(resolve(cwd)).map((dir) => listTranscripts(dir)),
  )
  let newest: { path: string; modifiedAt: number } | null = null
  for (const file of found.flat()) {
    if (newest === null || file.modifiedAt > newest.modifiedAt) newest = file
  }
  return newest?.path ?? null
}

/* -------------------------------------------------------------------------- */
/* IPC                                                                         */
/* -------------------------------------------------------------------------- */

/**
 * Readers held open per transcript so a live session appends instead of
 * re-reading. Keyed by resolved path; dropped by `chat:close`.
 */
const readers = new Map<string, ChatReader>()

/**
 * Cap on resident readers.
 *
 * Each holds a dedup set of every line it has folded in, so a long-lived window
 * that opened forty sessions would keep forty of them alive. The renderer sends
 * `chat:close` on unmount, but a crashed renderer never does.
 */
const MAX_READERS = 12

/**
 * Everything the renderer sends is untrusted, a path most of all: this handler
 * reads whatever file it is handed and echoes the text back, so an unchecked
 * path is an arbitrary-file-read primitive reachable from page code.
 *
 * The membership test now lives in `transcript.ts`. It used to be a copy of the
 * one in `cost-ipc.ts`, which was a copy of the one in `session-insights.ts`,
 * and all three said "under `~/.claude/projects`" — which stopped being the whole
 * truth the day a confined session started writing under its own device home.
 * Three copies of a rule that has to widen is three chances for one of them to
 * widen wrong, and the wrong direction here is an open file read. Nested paths
 * are still allowed: sub-agent transcripts live one level down.
 */
function assertTranscriptPath(path: unknown): string {
  if (typeof path !== 'string' || path.length === 0) {
    throw new Error('chat: a transcript path is required')
  }
  if (!isTranscriptPath(path)) {
    throw new Error(`chat: refusing to read outside the transcript store: ${path}`)
  }
  return resolve(path)
}

function readerFor(path: string): ChatReader {
  const existing = readers.get(path)
  if (existing) return existing
  if (readers.size >= MAX_READERS) {
    const oldest = readers.keys().next().value
    if (typeof oldest === 'string') readers.delete(oldest)
  }
  const reader = new ChatReader(path)
  readers.set(path, reader)
  return reader
}

function emptyUpdate(found: boolean): ChatUpdate {
  return {
    transcriptPath: '',
    sessionId: '',
    cwd: '',
    messages: [],
    reset: false,
    cursor: 0,
    found,
    complete: true,
    updatedAt: Date.now(),
  }
}

function updateFrom(reader: ChatReader, messages: ChatMessage[], reset: boolean, complete: boolean): ChatUpdate {
  return {
    transcriptPath: reader.path,
    sessionId: reader.sessionId,
    cwd: reader.cwd,
    messages,
    reset,
    cursor: reader.position,
    found: true,
    complete,
    updatedAt: Date.now(),
  }
}

export interface ChatRequest {
  /** Project folder. Resolves to its newest transcript when no path is given. */
  cwd?: string
  /** Exact transcript to read. Wins over `cwd`. */
  transcriptPath?: string
}

function requestOf(value: unknown): ChatRequest {
  return isRecord(value) ? { cwd: str(value.cwd), transcriptPath: str(value.transcriptPath) } : {}
}

/**
 * Register the chat-view IPC handlers.
 *
 * Channels:
 *  - `chat:load`  (invoke, ChatRequest) -> ChatUpdate — whole conversation, resets the reader
 *  - `chat:tail`  (invoke, ChatRequest) -> ChatUpdate — only what changed since the last call
 *  - `chat:close` (send,   path)        -> drops the resident reader
 */
export function registerChatIpc(ipcMain: IpcMain): void {
  ipcMain.handle('chat:load', async (_e: IpcMainInvokeEvent, request: unknown): Promise<ChatUpdate> => {
    const { cwd, transcriptPath } = requestOf(request)
    let path: string | null = null
    if (transcriptPath) path = assertTranscriptPath(transcriptPath)
    else if (cwd) path = await newestChatTranscript(cwd)
    // No transcript at all is a different empty state from a session that has
    // not spoken yet, and the view says so.
    if (!path) return emptyUpdate(false)

    // A fresh reader every load: the caller is asking for the whole thing, and
    // reusing a warm one would return only the tail of it.
    readers.delete(path)
    const reader = readerFor(path)
    const { reset } = await reader.readAll()
    return updateFrom(reader, [...reader.conversation], reset, true)
  })

  ipcMain.handle('chat:tail', async (_e: IpcMainInvokeEvent, request: unknown): Promise<ChatUpdate> => {
    const { cwd, transcriptPath } = requestOf(request)
    let path: string | null = null
    if (transcriptPath) path = assertTranscriptPath(transcriptPath)
    else if (cwd) path = await newestChatTranscript(cwd)
    if (!path) return emptyUpdate(false)

    const known = readers.has(path)
    const reader = readerFor(path)
    const { messages, reset } = await reader.readAll()
    // A tail against a path this process has never read is a first read: send
    // the conversation, flagged so the view replaces rather than appends. That
    // is also what happens when the live session rolls into a new transcript.
    if (!known) return updateFrom(reader, [...reader.conversation], true, true)
    return updateFrom(reader, messages, reset, true)
  })

  ipcMain.on('chat:close', (_e, transcriptPath: unknown) => {
    if (typeof transcriptPath !== 'string' || transcriptPath.length === 0) return
    readers.delete(resolve(transcriptPath))
  })
}

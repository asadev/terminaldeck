import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Marked, type Renderer, type Tokens } from 'marked'
import DOMPurify from 'dompurify'
import { ChatComposer } from './ChatComposer'
import { useTranscriptChanges } from '../chat/usage'
import { useEvery } from '../schedule'
import { useSessionTranscript, type SessionScope } from '../session-transcript'
import { runningProvider, useAgentPresence } from '../shell/agent-presence'
import { CHAT_SESSION_ATTR } from '../driving/where'
import type { ProviderId } from '@shared/types'
import './ChatView.css'

/**
 * A session as a conversation: what the user asked, what the agent said, and
 * nothing else.
 *
 * The terminal shows the work — tool calls, diffs, spinners, ANSI. This view
 * shows the talking. Nothing is filtered here: `src/main/chat-transcript.ts`
 * decides what counts as a message by reading the JSONL transcript, and this
 * file only lays it out. If something appears that should not, the bug is in
 * the main process.
 */

/* -------------------------------------------------------------------- types */

/**
 * Mirrors of `src/main/chat-transcript.ts`. Duplicated rather than imported
 * because the renderer tsconfig does not include `src/main` — the arrangement
 * `SessionInspector` and `GitPanel` already use.
 */
export type ChatRole = 'you' | 'agent'

export interface ChatMessage {
  id: string
  role: ChatRole
  text: string
  at: number
}

export interface ChatUpdate {
  transcriptPath: string
  sessionId: string
  cwd: string
  messages: ChatMessage[]
  reset: boolean
  cursor: number
  found: boolean
  complete: boolean
  updatedAt: number
}

export interface ChatRequest {
  cwd?: string
  transcriptPath?: string
}

export interface ChatBridge {
  loadChat(request: ChatRequest): Promise<ChatUpdate>
  tailChat(request: ChatRequest): Promise<ChatUpdate>
  closeChat(transcriptPath: string): void
}

export interface ChatViewProps {
  /** Project folder holding the transcripts. */
  cwd: string | null
  /**
   * The session this conversation is a view of.
   *
   * Without it the pane is a view of the *folder*, and it showed the folder's
   * most recently written transcript — which, with a `claude` running in the
   * same folder outside the app, was somebody else's conversation entirely.
   * See `session-transcript.ts`.
   */
  session?: SessionScope | null
  /**
   * The live session behind this conversation. Needed by the control row, which
   * changes model, effort and permissions by typing into that session's
   * terminal. Absent means the row says so instead of pretending to work.
   */
  sessionId?: string
  /**
   * Send a typed message to the session. Absent means read-only — the composer
   * says so rather than silently swallowing what you type.
   */
  onSend?: (text: string) => void
  /** A specific transcript. Wins over `cwd`. */
  transcriptPath?: string
  /** Poll interval while the session is live. 0 disables it. Defaults to 2s. */
  refreshMs?: number
  /** Injectable for tests; defaults to the preload bridge on `window.deck`. */
  bridge?: ChatBridge
  /**
   * What is actually running in this session.
   *
   * Everything below it — the empty state, the placeholder in the box, the
   * model/effort/permission row — is written for an agent CLI, and half of it
   * is a lie about a plain shell. A `/bin/zsh -l` sitting at its own prompt was
   * being told that "a transcript is written once a session makes its first
   * request", offered a `Model` of `Opus 5` read out of a settings file it has
   * never heard of, and invited to "Message the agent…" when there is no agent
   * in it. The app has always known which it is — `SessionMeta.provider` — the
   * view simply never asked.
   *
   * Optional because two callers render this for a transcript rather than for a
   * session, and those genuinely do not know; they get the agent wording, which
   * is what they are.
   */
  provider?: ProviderId
}

/* ------------------------------------------------------------------ markdown */

/**
 * Markdown with the code turned down.
 *
 * A fenced block is rendered as a closed `<details>` rather than a `<pre>`. The
 * whole point of this view is to hide code, and a 200-line diff pasted into a
 * reply otherwise buries the sentence above it that explains what the diff was
 * for.
 *
 * Links keep their text and lose their `href`. This is an Electron renderer:
 * an `href` a model wrote is a one-click navigation away from the app window,
 * and no amount of URL allow-listing makes that a thing worth having in a
 * read-only panel. The destination moves to `title`, so hovering still shows it.
 *
 * Exported for its own tests only. The output is *unsanitised*: the single path
 * to the DOM is `renderMarkdown` below, which refuses to return anything
 * DOMPurify has not been through.
 */
export const markdown = new Marked({
  gfm: true,
  breaks: false,
  renderer: {
    code({ text, lang }: { text: string; lang?: string }): string {
      const lines = text.split('\n').length
      const label = [lang?.trim() || 'code', `${lines} ${lines === 1 ? 'line' : 'lines'}`].join(' · ')
      return `<details class="cv-code"><summary>${escapeHtml(label)}</summary><pre><code>${escapeHtml(text)}</code></pre></details>`
    },
    link(this: Renderer, { href, title, tokens, text }: Tokens.Link): string {
      // The label is inline markdown, not a plain string: `[**one**](url)` and
      // [`mayCarryChat`](url) are how a model writes half its links, and using
      // the token's raw `text` puts the asterisks and backticks on screen.
      // Rendered here so the label goes through this same renderer, which is
      // what keeps a nested image from becoming a network request.
      const label = this.parser ? this.parser.parseInline(tokens) : escapeHtml(text)
      return `<span class="cv-link" title="${escapeHtml(title || href)}">${label}</span>`
    },
    image({ href, text }: Tokens.Image): string {
      // Remote images would be a network request the panel never needs to make.
      return `<span class="cv-link" title="${escapeHtml(href)}">${escapeHtml(text || 'image')}</span>`
    },
  },
})

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

/**
 * Tags a reply is allowed to become. Everything outside the list is dropped and
 * its text kept, so an unexpected construct degrades to prose instead of
 * disappearing.
 */
const ALLOWED_TAGS = [
  'p', 'br', 'hr', 'strong', 'em', 'del', 'code', 'pre', 'blockquote',
  'ul', 'ol', 'li', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  'table', 'thead', 'tbody', 'tr', 'th', 'td',
  'details', 'summary', 'span',
]

/** `title` is the parked link destination; `class` is ours, from the renderer above. */
const ALLOWED_ATTR = ['class', 'title']

/**
 * Model output rendered as HTML, or null when it cannot be sanitised.
 *
 * Outside a browser — the test environment, where components render to static
 * markup — `dompurify`'s default export is an uninitialised factory with no
 * `sanitize` at all. Reading that as "nothing to clean" and passing the raw
 * HTML through is exactly the mistake this guard exists to make impossible:
 * null means the caller must fall back to plain text.
 */
export function renderMarkdown(text: string): string | null {
  const purify = DOMPurify as unknown as {
    isSupported?: boolean
    sanitize?: (dirty: string, config: Record<string, unknown>) => string
  }
  if (!purify.isSupported || typeof purify.sanitize !== 'function') return null
  const html = markdown.parse(text, { async: false })
  return purify.sanitize(typeof html === 'string' ? html : text, {
    ALLOWED_TAGS,
    ALLOWED_ATTR,
    // Cheap insurance on top of the tag list: these are the ones that turn a
    // reading pane into an execution surface.
    FORBID_TAGS: ['script', 'style', 'iframe', 'object', 'embed', 'form', 'a', 'img'],
  })
}

/* ------------------------------------------------------------------- helpers */

/**
 * Fold an update into the conversation.
 *
 * The main process re-sends a message when it grows — a live turn arrives a
 * block at a time under one id — so a match replaces rather than appends.
 */
export function mergeMessages(current: ChatMessage[], incoming: readonly ChatMessage[]): ChatMessage[] {
  if (incoming.length === 0) return current
  const next = [...current]
  const index = new Map(next.map((message, i) => [message.id, i]))
  for (const message of incoming) {
    const at = index.get(message.id)
    if (at === undefined) {
      index.set(message.id, next.length)
      next.push(message)
    } else {
      next[at] = message
    }
  }
  return next
}

const TIME = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit' })
const DAY = new Intl.DateTimeFormat(undefined, { weekday: 'long', day: 'numeric', month: 'long' })

export function formatTime(at: number): string {
  return at > 0 ? TIME.format(at) : ''
}

/**
 * The machine-readable half of the time, for `<time dateTime>`.
 *
 * The printed time is `14:32` and carries no date at all — the day headings
 * above the run carry that — so on its own it is ambiguous to anything that is
 * not a person looking at the column. Empty for a message with no timestamp,
 * which is a real state: the attribute is then absent rather than claiming the
 * epoch.
 */
export function isoAt(at: number): string | undefined {
  return at > 0 ? new Date(at).toISOString() : undefined
}

/** How long the copy button says "Copied" before going back to saying what it does. */
const COPIED_MS = 1600

/**
 * Copy, and the tick it turns into.
 *
 * Two overlapping sheets rather than a clipboard-with-a-clip, at 13px on the
 * app's 24-unit grid: the clip is three strokes inside four pixels and turns to
 * mush, which is the same measurement `ModeSwitch` records for its own glyphs.
 * The tick replaces it outright rather than sitting beside it, so the control
 * does not change width at the moment it is pressed.
 */
function CopyGlyph({ done }: { done: boolean }) {
  return (
    <svg
      width="13"
      height="13"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.7"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {done ? (
        <path d="M5 12.5l4.5 4.5L19 7" />
      ) : (
        <>
          <rect x="9" y="9" width="11" height="11" rx="2.2" />
          <path d="M5.5 15H5a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1h9a1 1 0 0 1 1 1v.5" />
        </>
      )}
    </svg>
  )
}

/**
 * Whatever this window can write to, or null.
 *
 * Read at call time rather than at module load, because the harness and the
 * static-markup tests import this file with no `navigator` at all. Null is a
 * real answer and the caller draws no button for it — the rule `GitHubPanel`
 * follows for the same reason: a copy control that cannot copy is worse than
 * none, because the failure is silent and looks like the clipboard's fault.
 */
export function clipboardWriter(): ((text: string) => void) | null {
  const clipboard = typeof navigator === 'undefined' ? undefined : navigator.clipboard
  if (!clipboard?.writeText) return null
  return (text: string) => {
    // Nothing to report and nowhere to report it: a rejected write here means
    // the document lost focus mid-press, and the button has already said
    // "Copied". Swallowed rather than thrown, so one refusal cannot take the
    // conversation down with it.
    void clipboard.writeText(text).catch(() => {})
  }
}

/** The day heading a message needs, or null when it shares the previous one. */
export function dayBreak(at: number, previousAt: number): string | null {
  if (at <= 0) return null
  const day = new Date(at).toDateString()
  if (previousAt > 0 && new Date(previousAt).toDateString() === day) return null
  return DAY.format(at)
}

/**
 * Read defensively: the chat handlers are wired into the preload separately, so
 * the view has to explain itself rather than crash if it mounts first.
 */
function resolveBridge(): ChatBridge | null {
  if (typeof window === 'undefined') return null
  const host = (window as unknown as { deck?: Partial<ChatBridge> }).deck
  if (!host || typeof host.loadChat !== 'function' || typeof host.tailChat !== 'function') return null
  return host as ChatBridge
}

/** How close to the bottom still counts as "following along". */
const STICK_PX = 72

/** The floor between two re-attributions. See `onTranscriptChange`. */
const REATTRIBUTE_MS = 3000

/* ---------------------------------------------------------------- one bubble */

/**
 * One turn: the words, then the time, then the copy — and no name at all.
 *
 * ## Which side it is on, and why there is no label — 2026-08-20
 *
 * *"my message should start from the right, should be on the other side, like
 * this one, just like Claude. See, mine is right side. … The left side will be
 * the agent … So no need to give a name actually on both sides. Not even you,
 * for me also not you. Just start it from the right side, give the time and all
 * that. Just the text only and time only will be good enough."*
 *
 * Side replaces name, which is the whole trade and is why removing the labels
 * is not a loss of information: in a two-party conversation the alignment
 * already says who is talking, and it says it without a word to read on every
 * turn. The column used to open each turn with "You" or "Agent" in semibold —
 * two labels on every message in a view whose entire job is to show the talking.
 *
 * The tint stays on his side and stays off the agent's, unchanged: it is what
 * lets you scan back for where an instruction started, and it is now doing the
 * same work as the alignment rather than instead of it.
 *
 * ## Time and copy, at the end
 *
 * *"give the copy button wherever it's possible at the end of maybe messages."*
 * So the metadata moved from a header above the words to a footer below them,
 * which is also where the eye is when a turn finishes. The footer holds the
 * time and, when the host can reach a clipboard, one copy control.
 */
export function ChatBubble({
  message,
  heading,
  onCopy,
}: {
  message: ChatMessage
  heading: string | null
  /**
   * Put this turn's text on the clipboard. Absent where there is no clipboard
   * to reach — the panel decides that once and hands it down, the same
   * arrangement `GitHubPanel` uses for its device code. A copy button that
   * cannot copy is the dead control this app is audited for.
   */
  onCopy?: (text: string) => void
}) {
  const html = useMemo(
    () => (message.role === 'agent' ? renderMarkdown(message.text) : null),
    [message.role, message.text],
  )
  /*
   * Said, then unsaid a moment later. A copy leaves nothing on screen to show
   * it worked, so the button says so itself — and reverts, because a control
   * stuck reading "Copied" is a control that has stopped describing what
   * pressing it does.
   */
  const [copied, setCopied] = useState(false)
  useEffect(() => {
    if (!copied) return
    const timer = setTimeout(() => setCopied(false), COPIED_MS)
    return () => clearTimeout(timer)
  }, [copied])

  return (
    <>
      {heading ? <div className="cv-day"><span>{heading}</span></div> : null}
      <article
        className={`cv-message cv-${message.role}`}
        /*
         * The one handle the copilot's focus overlay can point at.
         *
         * `message.id` is already documented as "stable across reads, so an
         * appended-to message replaces rather than duplicates" — which is
         * exactly the property an anchor needs and the reason this needs no id
         * of its own. It is written as a `data-drive-anchor` rather than a bare
         * `data-message-id` so that every place the overlay can point at in the
         * whole app carries one attribute name: the alternative is a second
         * naming scheme for chat, and a resolver that has to know which
         * elements use which.
         *
         * Prefer a chat anchor over a terminal one wherever a transcript
         * exists. The chat view renders the same JSONL the copilot actually
         * read; the terminal shows the CLI's *rendering* of that conversation,
         * with spinners and repaints, and nothing correlates the two.
         */
        data-drive-anchor={`message:${message.id}`}
      >
        {html === null ? (
          // Either a prompt — shown verbatim, because a person's typing is not
          // markup — or an environment with no sanitiser, where raw text is the
          // only safe thing to render.
          <div className="cv-body cv-plain">{message.text}</div>
        ) : (
          <div className="cv-body cv-rich" dangerouslySetInnerHTML={{ __html: html }} />
        )}
        {/*
          Under the words rather than over them, and it holds no name.

          `<footer>` and not a second `<header>`: it is metadata about the turn
          it follows, which is what the element means, and a screen reader
          reaching it has already been read the message it describes.
        */}
        <footer className="cv-foot">
          <time className="cv-time" dateTime={isoAt(message.at)}>
            {formatTime(message.at)}
          </time>
          {onCopy && (
            <button
              type="button"
              className="cv-copy"
              /* The whole turn's source text, not what is on screen: the agent's
                 half is rendered markdown with its code folded into `<details>`,
                 and copying the rendering would hand back a paragraph with the
                 diff missing. `message.text` is what the transcript holds. */
              onClick={() => {
                onCopy(message.text)
                setCopied(true)
              }}
              aria-label={copied ? 'Copied' : 'Copy this message'}
              title={copied ? 'Copied' : 'Copy this message'}
            >
              <CopyGlyph done={copied} />
            </button>
          )}
        </footer>
      </article>
    </>
  )
}

/**
 * The conversation, and nothing else.
 *
 * A component of its own so the rule below is a thing a test can hold: **the
 * last element in the column is the last message**. There used to be a line of
 * explanatory prose stapled underneath it —
 *
 *   > "at the end of the chat we have some kind of sentence which should not be
 *   > there ... there should be only last message whoever has said, no great
 *   > line under there"
 *
 * — and it was wrong for a reason worth writing down rather than just deleting.
 * It was a caption about the *pane* ("read from the session transcript, prompts
 * and replies only") positioned at the *end of the conversation*, so it moved
 * with the newest message and sat exactly where the eye lands after the agent
 * finishes talking. A caption belongs where the thing it describes begins, or in
 * a state where the conversation is not what the reader is looking at; the empty
 * states above already say the same thing at the moment it is useful.
 */
export function ChatColumn({
  messages,
  onCopy,
}: {
  messages: readonly ChatMessage[]
  /** Threaded straight through to every turn. See {@link ChatBubble}. */
  onCopy?: (text: string) => void
}) {
  return (
    <div className="cv-column">
      {messages.map((message, i) => (
        <ChatBubble
          key={message.id}
          message={message}
          heading={dayBreak(message.at, i > 0 ? messages[i - 1].at : 0)}
          {...(onCopy ? { onCopy } : {})}
        />
      ))}
    </div>
  )
}

/* ------------------------------------------------------------ empty states -- */

export type ChatEmptyState =
  | 'loading'
  | 'no-transcript'
  | 'no-session-transcript'
  | 'ambiguous'
  | 'silent'
  | 'no-project'
  | 'unwired'
  | 'shell'

export function ChatEmpty({ state }: { state: ChatEmptyState }) {
  const copy: Record<typeof state, { title: string; detail: string }> = {
    loading: { title: 'Reading the transcript…', detail: '' },
    'no-project': {
      title: 'No project open',
      detail: 'Open a folder to see the conversation for its sessions.',
    },
    /*
     * The three states below say "an agent" rather than naming one, and the
     * reason is that this pane does not know which one it is looking at. The
     * only distinction `runningProvider` draws is shell-or-not: a Codex session
     * and a Gemini session both land here, and both used to be told that Claude
     * Code writes the transcript they are waiting for. That is a sentence
     * somebody can act on — go and check whether the wrong CLI is installed —
     * and it would send them somewhere there is nothing to find.
     */
    'no-transcript': {
      title: 'No transcript for this project yet',
      detail:
        'An agent writes one as it works. Send a first message in the terminal and it will appear here.',
    },
    // Deliberately not "no transcript for this project": there may well be
    // several, and one of them may be being written to right now by a `claude`
    // this app did not start. None of them are this session's.
    'no-session-transcript': {
      title: 'Nothing from this session yet',
      detail:
        'An agent writes a transcript once a session makes its first request. Send a first message in the terminal and it will appear here.',
    },
    /*
     * The one state that is an admission rather than a wait.
     *
     * Several conversations in this folder began after this session did, and
     * more than one open session could have written each of them. A transcript
     * records the folder, the branch, the CLI version and its own id, and
     * nothing at all about the terminal that produced it — checked against the
     * real files, not assumed — so there is no tie-break to reach for.
     *
     * Showing one of them anyway is what this whole item is about: a chat pane
     * confidently rendering the session next door's words under this session's
     * name. The terminal is exact, and it is one click away, so that is what
     * this points at.
     */
    ambiguous: {
      title: 'Cannot tell which conversation is this session’s',
      detail:
        'More than one session is open in this folder, and a transcript does not record which terminal wrote it — so showing one here would be a guess. The terminal view is exact. Running the second session in its own folder keeps them apart.',
    },
    silent: {
      title: 'Nothing said yet',
      detail: 'This session has a transcript but no prompts or replies in it. Type something in the terminal.',
    },
    unwired: {
      title: 'Chat is not wired into this build',
      detail: 'The transcript reader is missing from the preload bridge.',
    },
    // Not "no transcript yet", which implies one is coming. A shell writes no
    // transcript, ever — there is no conversation to read, and saying "send a
    // first message and it will appear here" would be a promise the session
    // cannot keep.
    shell: {
      title: 'This session is a shell',
      detail:
        'A conversation is something an agent writes down as it works. A shell just runs what you type, so there is nothing here to read — the terminal is the whole session.',
    },
  }
  const { title, detail } = copy[state]
  return (
    <div className="cv-empty">
      <p className="cv-empty-title">{title}</p>
      {detail ? <p className="cv-empty-detail">{detail}</p> : null}
    </div>
  )
}

/* ---------------------------------------------------------- live session id -- */

/** Just enough of `SessionMeta` to pick one out, mirrored rather than imported. */
interface LiveSession {
  id: string
  cwd: string
  exitCode: number | null
  /** When this tab's process started. What `SessionScope.startedAt` is. */
  createdAt: number
}

/**
 * The three session pushes, read off `window.deck` as loosely as the list is.
 *
 * All optional: a build that has not wired one of them loses freshness on that
 * path, not the pane.
 */
interface SessionEvents {
  listSessions?: () => Promise<unknown>
  onSessionData?: (cb: (id: string, data: string) => void) => () => void
  onSessionExit?: (cb: (id: string, exitCode: number) => void) => () => void
  onSessionStatus?: (cb: (id: string, status: string) => void) => () => void
}

/**
 * How long to wait after a session event before re-listing.
 *
 * Not a poll — a coalescing delay inside an event handler. A session starting
 * fires a status and its first output within a few milliseconds of each other,
 * and re-listing once for the pair is the whole point.
 */
const RESOLVE_COALESCE_MS = 250

/**
 * Every session this app has in `cwd` — live or exited.
 *
 * Two things read it, and the second is why it is a list rather than the single
 * id it used to be. `liveSessionIdOf` needs the one live session to type into.
 * `siblingStarts` needs *all* of them, because a conversation in this folder can
 * only be attributed to this session when no other session could have written
 * it — the whole of item 3. The old version returned early whenever the caller
 * had already been given a session id, which is always, so the list it would
 * have needed for that was never even fetched.
 *
 * ## Why this does not poll
 *
 * It used to re-list every four seconds, which is 21,600 identical answers a
 * day for a set that changes when the user opens or closes a terminal. The main
 * process already says when that happens: `session:exit` is a death, and a
 * birth is the first `session:data` or `session:status` carrying an id this
 * hook has not seen before. Ids already accounted for are ignored, so the
 * constant output of the session in front of the user costs nothing here.
 */
function useFolderSessions(cwd: string | null): readonly LiveSession[] {
  const [sessions, setSessions] = useState<readonly LiveSession[]>([])

  useEffect(() => {
    if (!cwd) {
      setSessions([])
      return
    }
    // `globalThis`, not `window`: this component is rendered to a string in its
    // own tests, where there is no window to read.
    const deck = (globalThis as { deck?: SessionEvents }).deck
    if (typeof deck?.listSessions !== 'function') return

    let alive = true
    let queued: ReturnType<typeof setTimeout> | null = null
    /**
     * Every id this hook has heard of, from a list or from an event.
     *
     * Added to and never rebuilt. Rebuilding it from each list looks tidier and
     * is a bug: an id that produces output but does not appear in the list —
     * a session that died between the event and the read, one belonging to
     * another window — would be forgotten every time and re-trigger on its
     * next chunk, which is a re-list per burst of output from something that
     * will never be found.
     */
    const known = new Set<string>()

    const look = async (): Promise<void> => {
      try {
        const answer = await deck.listSessions?.()
        if (!alive || !Array.isArray(answer)) return
        const all = (answer as LiveSession[]).filter((session) => session != null)
        for (const session of all) known.add(session.id)
        setSessions(all.filter((session) => session.cwd === cwd))
      } catch {
        // Leave it unresolved; the row says "not running" rather than guessing.
      }
    }

    const soon = (): void => {
      if (queued !== null) return
      queued = setTimeout(() => {
        queued = null
        void look()
      }, RESOLVE_COALESCE_MS)
    }

    /** A session this hook has never heard of is a session that just started. */
    const sighting = (id: string): void => {
      if (known.has(id)) return
      known.add(id)
      soon()
    }

    void look()

    const offData = deck.onSessionData?.((id) => sighting(id))
    const offStatus = deck.onSessionStatus?.((id) => sighting(id))
    const offExit = deck.onSessionExit?.((id) => {
      known.delete(id)
      soon()
    })

    return () => {
      alive = false
      if (queued !== null) clearTimeout(queued)
      offData?.()
      offStatus?.()
      offExit?.()
    }
  }, [cwd])

  return sessions
}

/**
 * The id of the pty this conversation is a view of.
 *
 * `sessionId` is the authority whenever a caller knows it. Without a fallback
 * the control row underneath would spend its whole life telling someone who has
 * a session open to open a session. Exactly one live session in the folder
 * counts: two sessions in the same folder are two different terminals, and a
 * slash command typed into the wrong one is a real change made in the wrong
 * place. Ambiguity resolves to "no id", and the row disables itself and says so.
 *
 * Not derived from the transcript's own `sessionId`, which is the agent's id
 * for the conversation and means nothing to the pty registry.
 */
function liveSessionIdOf(sessions: readonly LiveSession[], provided: string | undefined): string | undefined {
  if (provided) return provided
  const live = sessions.filter((session) => session.exitCode === null)
  return live.length === 1 ? live[0].id : undefined
}

/**
 * The start times of the *other* sessions in this folder.
 *
 * Handed to `useSessionTranscript`, which cannot attribute a conversation
 * without them — see the note at the top of `session-transcript.ts`. Exited
 * sessions are included on purpose: the process is gone but its transcript is
 * still lying in the directory, and it is still not this session's.
 *
 * Compared by *time*, not by id, because that is what the attribution uses. A
 * session with the same start time as this one is indistinguishable from it
 * anyway, so excluding by id and excluding by time come to the same answer,
 * and the caller does not always know its own id.
 */
/**
 * Whether the named session's process is gone.
 *
 * Absent from the list is treated as *not* exited: a list that has not arrived
 * yet, or a session belonging to another window, is not evidence of a death,
 * and reading it as one would withdraw a live session's controls.
 */
function exitedIn(sessions: readonly LiveSession[], id: string): boolean {
  const found = sessions.find((session) => session.id === id)
  return found ? found.exitCode !== null : false
}

function siblingStarts(sessions: readonly LiveSession[], self: number | null): number[] {
  const starts: number[] = []
  let skippedSelf = self === null
  for (const session of sessions) {
    if (typeof session.createdAt !== 'number') continue
    if (!skippedSelf && session.createdAt === self) {
      skippedSelf = true
      continue
    }
    starts.push(session.createdAt)
  }
  return starts.sort((a, b) => a - b)
}

/* ---------------------------------------------------------------- the view -- */

export function ChatView({
  cwd,
  session,
  sessionId,
  onSend,
  transcriptPath,
  refreshMs = 2000,
  bridge,
  provider,
}: ChatViewProps) {
  const resolved = bridge ?? resolveBridge()
  const folderSessions = useFolderSessions(cwd)
  const liveSessionId = liveSessionIdOf(folderSessions, sessionId)

  /**
   * What is actually running in the session, as opposed to what was launched.
   *
   * `undefined` where an agent is running in a session this app started as a
   * shell — that is `AgentControls`' own word for "not known", and it is the
   * truth: somebody typed a CLI into a terminal and the app never saw which
   * one. The row then draws its pickers with the agent wording, which is right,
   * instead of withdrawing them because the *pty* is a shell.
   */
  const presence = useAgentPresence(
    sessionId && provider ? { id: sessionId, provider, exited: exitedIn(folderSessions, sessionId) } : null,
  )
  const effectiveProvider = runningProvider(provider, presence.running)
  // Scoped to the session when there is one. An explicit path always wins.
  const scoped = session != null && !transcriptPath
  /**
   * Bumped whenever a transcript in this folder is written to, so the
   * attribution below re-runs then rather than on its own slow backstop timer.
   * The subscription itself is set up further down, once `tail` exists; this is
   * only the counter it feeds.
   */
  const [transcriptRevision, setTranscriptRevision] = useState(0)
  const lookup = useSessionTranscript(scoped ? cwd : null, session ?? null, {
    // Without these, two tabs on one project both resolve to whichever
    // conversation started first — the bug in item 3 of NEXT-UPDATE.md.
    others: siblingStarts(folderSessions, session?.startedAt ?? null),
    revision: transcriptRevision,
  })
  const ownPath = lookup.status === 'ready' ? lookup.choice.path : null
  const [messages, setMessages] = useState<ChatMessage[]>([])
  const [found, setFound] = useState<boolean | null>(null)
  const [behind, setBehind] = useState(false)

  const scrollRef = useRef<HTMLDivElement>(null)
  /** Held in a ref, not state: it changes on every scroll frame. */
  const stickRef = useRef(true)
  const pathRef = useRef('')
  /** So a tail that lands after this pane closed does not write to a dead tree. */
  const mountedRef = useRef(true)
  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])

  /**
   * What to ask the reader for.
   *
   * A scoped view never falls back to `cwd`: "the newest transcript in this
   * folder" is precisely the answer that put another session's conversation in
   * this pane, so with no transcript of its own it asks for nothing and says so.
   */
  const target = transcriptPath ?? (scoped ? ownPath : null)
  const request = useMemo<ChatRequest>(
    () => (target ? { transcriptPath: target } : !scoped && cwd ? { cwd } : {}),
    [cwd, scoped, target],
  )
  const key = target ?? (scoped ? '' : cwd ?? '')

  /**
   * Fold an answer in, defensively.
   *
   * The bridge is a preload boundary, and this component renders against a
   * stubbed one in the harness where an unimplemented method resolves to
   * `null`. Reading `.found` off that throws inside a promise and takes the
   * pane down through the error boundary showing nothing — which reads as a
   * broken feature rather than an unwired one.
   */
  const apply = useCallback((update: ChatUpdate | null): boolean => {
    if (!update || typeof update !== 'object' || !Array.isArray(update.messages)) return false
    setFound(update.found)
    pathRef.current = update.transcriptPath
    setMessages((current) =>
      update.reset ? [...update.messages] : mergeMessages(current, update.messages),
    )
    return true
  }, [])

  useEffect(() => {
    if (!resolved || key === '') return
    let live = true
    setMessages([])
    setFound(null)
    stickRef.current = true
    setBehind(false)

    void resolved
      .loadChat(request)
      .then((update) => {
        if (live && !apply(update)) setFound(false)
      })
      .catch(() => {
        if (live) setFound(false)
      })

    return () => {
      live = false
      // Let the main process drop the reader and its dedup set.
      if (pathRef.current) resolved.closeChat(pathRef.current)
    }
  }, [resolved, key, request, apply])

  /**
   * Read whatever the agent has appended since the last read.
   *
   * Guarded against overlapping itself: a tail that outlives its own trigger
   * must not have a second stacked on top of it, because both would read the
   * same bytes and the dedup happens in the main process.
   */
  const tailing = useRef(false)
  const tail = useCallback(() => {
    if (!resolved || key === '' || tailing.current) return
    tailing.current = true
    void resolved
      .tailChat(request)
      .then((update) => {
        if (mountedRef.current && update && (update.messages?.length > 0 || update.reset)) {
          apply(update)
        }
      })
      .catch(() => {})
      .finally(() => {
        tailing.current = false
      })
  }, [resolved, key, request, apply])

  /**
   * Subscribe rather than poll: the transcript is a file, and the main process
   * is already watching the directory it lives in.
   *
   * This pane used to ask `tailChat` every two seconds — 43,200 IPC round trips
   * a day, almost all of them answering "nothing new", and still up to two
   * seconds late when there was. `cost:watch` puts an `fs.watch` on the
   * project's transcript directory and pushes on every append, so riding it
   * costs nothing while the agent is quiet and arrives within its 300 ms
   * debounce while it is talking.
   *
   * Two things ride it now. Tailing the bound file is the original job. The
   * second is telling the attribution to look again: a session that runs
   * `/clear` starts a *new* file in the same directory, and that push is the
   * first moment anything can know. Subscribed whenever there is a folder —
   * not only once a transcript is bound — because the case that needs it most
   * is the pane that has not managed to bind one yet.
   */
  /**
   * The last time the *attribution* was nudged, as opposed to the file tailed.
   *
   * Tailing on every push is the point of the push. Re-attributing is not: it
   * is a directory listing plus a stat per transcript, and a project this app
   * has been used on for a week has hundreds of them — so doing it on every
   * 300 ms debounce of a streaming reply would be a directory scan three times
   * a second for an answer that changes when somebody runs `/clear`.
   *
   * Three seconds is chosen against what it is for: a new conversation begins
   * with a prompt, which produces pushes for as long as the reply lasts, so the
   * first one past the window rebinds well inside the first answer.
   */
  const nudgedAt = useRef(0)
  const onTranscriptChange = useCallback(() => {
    tail()
    const now = Date.now()
    if (now - nudgedAt.current < REATTRIBUTE_MS) return
    nudgedAt.current = now
    setTranscriptRevision((n) => n + 1)
  }, [tail])
  const watched = useTranscriptChanges(scoped || key !== '' ? cwd : null, onTranscriptChange)

  /**
   * The fallback, for a build with no cost channel or a pane opened on a
   * transcript outside any project — there is no watcher to ride, and the only
   * honest alternative to a stale pane is to look. On the shared tick, so it is
   * not a wake-up of its own, and off entirely while the window is hidden.
   */
  useEvery(!watched && resolved && key !== '' && refreshMs > 0 ? refreshMs : null, tail)

  /** Absent in a window with no clipboard, which draws no copy buttons at all. */
  const copy = useMemo(() => clipboardWriter(), [])

  const jump = useCallback(() => {
    const host = scrollRef.current
    if (!host) return
    host.scrollTop = host.scrollHeight
    stickRef.current = true
    setBehind(false)
  }, [])

  // Follow the newest message, but only while the user is already at the bottom.
  // Yanking the pane down while someone is reading back through the session is
  // the single most annoying thing a live transcript can do.
  useEffect(() => {
    const host = scrollRef.current
    if (!host || messages.length === 0) return
    if (stickRef.current) host.scrollTop = host.scrollHeight
    else setBehind(true)
  }, [messages])

  const onScroll = useCallback(() => {
    const host = scrollRef.current
    if (!host) return
    const distance = host.scrollHeight - host.scrollTop - host.clientHeight
    stickRef.current = distance <= STICK_PX
    if (stickRef.current) setBehind(false)
  }, [])

  // A shell short-circuits every transcript state below it: there is no file to
  // look for, so "Reading…" followed by "nothing yet" would be a search the app
  // knows in advance will fail.
  //
  // "A shell" is not the same as "was started as a shell", and that stopped
  // being a distinction this file could ignore the moment Run Claude existed
  // (NEXT-UPDATE item 1). A shell session with Claude running in it has a real
  // conversation being written, and telling its reader that "a shell just runs
  // what you type, so there is nothing here to read" would be the app arguing
  // with the transcript it is about to find.
  const shell = effectiveProvider === 'shell'

  const state: ChatEmptyState | null =
    shell ? 'shell'
    : !resolved ? 'unwired'
    : scoped && !target
      ? lookup.status === 'loading'
        ? 'loading'
        : lookup.status === 'ambiguous'
          ? 'ambiguous'
          : 'no-session-transcript'
    : key === '' ? 'no-project'
    : found === null ? 'loading'
    : found === false ? 'no-transcript'
    : messages.length === 0 ? 'silent'
    : null

  return (
    <div
      className="chat-view"
      /*
       * Which session this conversation is a view of, written where the answer
       * can be read off the screen rather than out of a state variable.
       *
       * `app.where` is the caller. It answers "what am I looking at" by measuring
       * the DOM — see `driving/where.ts` for why that is the right source and not
       * a shortcut — and until this attribute existed it could name the session
       * behind a *terminal* and not the one behind a conversation, because
       * nothing on this pane carried an id. So the honest answer was "a
       * conversation is in front, and this app cannot say whose", which is a
       * strange thing for an app to say about its own window. Asad asked for the
       * whole capability in one sentence: *"if I ask it where I am right now, it
       * should be able to answer."*
       *
       * `liveSessionId` rather than the `sessionId` prop, deliberately, and the
       * difference is the point: it is the id of the **pty this pane can actually
       * act on**, which is the prop when a caller knows it and the folder's one
       * live session when it does not. Where the folder holds two, it is
       * `undefined` and the attribute is left off entirely — an absent attribute
       * reads as "not known" and a guessed one would read as a fact. The composer
       * two blocks down is handed the same value for the same reason.
       *
       * An attribute rather than a class, on the rule `focus-target.ts` states:
       * a class is styling and belongs to whoever is working on this pane, while
       * an attribute with no CSS attached to it is obviously a contract.
       */
      {...(liveSessionId === undefined ? {} : { [CHAT_SESSION_ATTR]: liveSessionId })}
    >
      {/* The stage is what "Jump to latest" is pinned to. It used to be pinned
          to the whole pane, 20px off the bottom — which is inside the composer,
          and behind it, since a positioned sibling that comes later wins. The
          button was drawn on every scroll-back and could not be seen or
          clicked. Anchoring it to the conversation puts it where it belongs:
          floating over the last message, just above the box. */}
      <div className="cv-stage">
        <div className="cv-scroll" ref={scrollRef} onScroll={onScroll}>
          {state ? (
            <ChatEmpty state={state} />
          ) : (
            /* Resolved once, here, rather than per message: reaching for
               `navigator.clipboard` in every bubble would ask the same question
               a hundred times down a long conversation, and a column where some
               turns had a copy button and some did not would be worse than one
               where none did. */
            <ChatColumn messages={messages} {...(copy ? { onCopy: copy } : {})} />
          )}
        </div>
        {behind ? (
          <button type="button" className="cv-jump" onClick={jump}>
            Jump to latest
          </button>
        ) : null}
      </div>

      {/*
          One box, and only the box.

          Two bands of chrome used to hang under the composer — the agent's
          controls and a usage readout — and then, briefly, they were folded on
          to the composer's own bottom row, which is where he found them:

            > "Options is showing the same options that we already have here…
            > since we have it on top we actually don't need them here. Let's
            > keep them only on top and let's not keep them here — remove them
            > from the chat box side completely, only keep the maybe add files
            > or something."

          He is right that they were the same options: `shell/SessionControls.tsx`
          draws model, effort, fast mode, connectors and the account's usage bar
          in the window's own bar, over the same session, and does it for
          *terminal* sessions too — which is the half the composer's copy could
          never do, because a session shown as a terminal has no composer on
          screen at all. So the copies here were the redundant pair.

          Two things did not simply have a twin up there, and neither was
          dropped:

           * **Permission mode** had no chip in the bar. It was given one
             (`CHROME_CONTROLS`) rather than deleted, and
             `chat/controls/one-home.test.ts` fails if any control ends up with
             no home.
           * **The usage readout** is a different reading from the bar's — this
             session's tokens, cost and context fill, rather than the account's
             five-hour and weekly limits. It lives in the session inspector,
             with the rest of "what has this session done".
      */}
      <ChatComposer
        onSend={onSend}
        cwd={cwd}
        // What pressing Return actually does. For an agent it is a message; for
        // a shell it is a command line, typed into the pty exactly as if it had
        // been typed in the terminal view — so the box must not call it a
        // message to an agent that is not there.
        placeholder={shell ? 'Run a command in this shell…' : undefined}
        // Switches the menu behind the plus from mentions to plain quoted
        // paths. It used to withdraw the menu outright, which left a shell
        // composer with a microphone and a send button — see the `shell` prop.
        shell={shell}
        // Handed over for one question: is this session held inside a folder by
        // the OS? A session a phone or the copilot started is, and it looks like
        // any other tab from here — so the composer has to know before it
        // attaches a file the session cannot read.
        sessionId={liveSessionId}
      />
    </div>
  )
}

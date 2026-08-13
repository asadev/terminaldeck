import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Marked, type Renderer, type Tokens } from 'marked'
import DOMPurify from 'dompurify'
import { ChatComposer } from './ChatComposer'
import { AgentControls } from '../chat/controls/AgentControls'
import { UsageStrip, useTranscriptChanges } from '../chat/usage'
import { useEvery } from '../schedule'
import { useSessionTranscript, type SessionScope } from '../session-transcript'
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

/* ---------------------------------------------------------------- one bubble */

export function ChatBubble({ message, heading }: { message: ChatMessage; heading: string | null }) {
  const html = useMemo(
    () => (message.role === 'agent' ? renderMarkdown(message.text) : null),
    [message.role, message.text],
  )

  return (
    <>
      {heading ? <div className="cv-day"><span>{heading}</span></div> : null}
      <article className={`cv-message cv-${message.role}`}>
        <header className="cv-meta">
          <span className="cv-who">{message.role === 'you' ? 'You' : 'Agent'}</span>
          <time className="cv-time">{formatTime(message.at)}</time>
        </header>
        {html === null ? (
          // Either a prompt — shown verbatim, because a person's typing is not
          // markup — or an environment with no sanitiser, where raw text is the
          // only safe thing to render.
          <div className="cv-body cv-plain">{message.text}</div>
        ) : (
          <div className="cv-body cv-rich" dangerouslySetInnerHTML={{ __html: html }} />
        )}
      </article>
    </>
  )
}

/* ------------------------------------------------------------ empty states -- */

export type ChatEmptyState =
  | 'loading'
  | 'no-transcript'
  | 'no-session-transcript'
  | 'silent'
  | 'no-project'
  | 'unwired'

export function ChatEmpty({ state }: { state: ChatEmptyState }) {
  const copy: Record<typeof state, { title: string; detail: string }> = {
    loading: { title: 'Reading the transcript…', detail: '' },
    'no-project': {
      title: 'No project open',
      detail: 'Open a folder to see the conversation for its sessions.',
    },
    'no-transcript': {
      title: 'No transcript for this project yet',
      detail:
        'Claude Code writes one when a session runs. Send a first message in the terminal and it will appear here.',
    },
    // Deliberately not "no transcript for this project": there may well be
    // several, and one of them may be being written to right now by a `claude`
    // this app did not start. None of them are this session's.
    'no-session-transcript': {
      title: 'Nothing from this session yet',
      detail:
        'Claude Code writes a transcript once a session makes its first request. Send a first message in the terminal and it will appear here.',
    },
    silent: {
      title: 'Nothing said yet',
      detail: 'This session has a transcript but no prompts or replies in it. Type something in the terminal.',
    },
    unwired: {
      title: 'Chat is not wired into this build',
      detail: 'The transcript reader is missing from the preload bridge.',
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
 * The id of the pty this conversation is a view of.
 *
 * `sessionId` is the authority whenever a caller knows it. `App` does not pass
 * it — it renders this view straight from a session record and threads only the
 * project path — so without a fallback the control row underneath spends its
 * whole life telling someone who has a session open to open a session, and
 * nothing under it can be changed. That is the "renders but does nothing"
 * failure, arrived at through a missing prop rather than a missing handler.
 *
 * So the id is resolved by asking the main process which sessions are live and
 * taking the one whose cwd is this project. Exactly one match counts: two
 * sessions in the same folder are two different terminals, and a slash command
 * typed into the wrong one is a real change made in the wrong place. Ambiguity
 * therefore resolves to "no id", and the row disables itself and says so.
 *
 * Not derived from the transcript's own `sessionId`, which is the agent's id
 * for the conversation and means nothing to the pty registry.
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
function useLiveSessionId(cwd: string | null, provided: string | undefined): string | undefined {
  const [found, setFound] = useState<string | undefined>(undefined)

  useEffect(() => {
    if (provided || !cwd) {
      setFound(undefined)
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
        const sessions = (answer as LiveSession[]).filter((session) => session != null)
        for (const session of sessions) known.add(session.id)
        const live = sessions.filter(
          (session) => session.cwd === cwd && session.exitCode === null,
        )
        setFound(live.length === 1 ? live[0].id : undefined)
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
  }, [cwd, provided])

  return provided ?? found
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
}: ChatViewProps) {
  const resolved = bridge ?? resolveBridge()
  const liveSessionId = useLiveSessionId(cwd, sessionId)
  // Scoped to the session when there is one. An explicit path always wins.
  const scoped = session != null && !transcriptPath
  const lookup = useSessionTranscript(scoped ? cwd : null, session ?? null)
  const ownPath = lookup.status === 'ready' ? lookup.choice.path : null
  const [messages, setMessages] = useState<ChatMessage[]>([])
  const [found, setFound] = useState<boolean | null>(null)
  const [path, setPath] = useState('')
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
    setPath(update.transcriptPath)
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
   */
  const watched = useTranscriptChanges(key === '' ? null : cwd, tail)

  /**
   * The fallback, for a build with no cost channel or a pane opened on a
   * transcript outside any project — there is no watcher to ride, and the only
   * honest alternative to a stale pane is to look. On the shared tick, so it is
   * not a wake-up of its own, and off entirely while the window is hidden.
   */
  useEvery(!watched && resolved && key !== '' && refreshMs > 0 ? refreshMs : null, tail)

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

  const state: ChatEmptyState | null =
    !resolved ? 'unwired'
    : scoped && !target ? (lookup.status === 'loading' ? 'loading' : 'no-session-transcript')
    : key === '' ? 'no-project'
    : found === null ? 'loading'
    : found === false ? 'no-transcript'
    : messages.length === 0 ? 'silent'
    : null

  return (
    <div className="chat-view">
      <div className="cv-scroll" ref={scrollRef} onScroll={onScroll}>
        {state ? (
          <ChatEmpty state={state} />
        ) : (
          <div className="cv-column">
            {messages.map((message, i) => (
              <ChatBubble
                key={message.id}
                message={message}
                heading={dayBreak(message.at, i > 0 ? messages[i - 1].at : 0)}
              />
            ))}
            <p className="cv-source" title={path}>
              Read from the session transcript — prompts and replies only.
            </p>
          </div>
        )}
      </div>
      {behind ? (
        <button type="button" className="cv-jump" onClick={jump}>
          Jump to latest
        </button>
      ) : null}
      <ChatComposer onSend={onSend} cwd={cwd} />
      {/* Under the composer, in the CLI's own order of importance: what is
          answering, how hard it thinks, and what it may do without asking. */}
      <AgentControls sessionId={liveSessionId} cwd={cwd} />
      {/* Last line: what this has cost and how close the context is to full.
          It sits below the controls because it reports rather than asks.

          The transcript goes with it. Without one the strip falls back to the
          project's most recently active session, which is how a tab that had
          never been prompted came to report a "Session" spend of $48 and a
          context 47% full — both belonging to somebody else's conversation. */}
      <UsageStrip cwd={cwd} transcriptPath={target ?? undefined} sessionId={sessionId} />
    </div>
  )
}

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Marked, type Renderer, type Tokens } from 'marked'
import DOMPurify from 'dompurify'
import { ChatComposer } from './ChatComposer'
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
  /** Project folder; its newest transcript is the live session. */
  cwd: string | null
  /**
   * Send a typed message to the session. Absent means read-only — the composer
   * says so rather than silently swallowing what you type.
   */
  onSend?: (text: string) => void
  /** A specific transcript. Wins over `cwd`. */
  transcriptPath?: string
  /** Poll interval while the session is live. 0 disables it. Defaults to 2s. */
  refreshMs?: number
  /** Injectable for tests; defaults to the preload bridge on `window.pawl`. */
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
  const host = (window as unknown as { pawl?: Partial<ChatBridge> }).pawl
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

export function ChatEmpty({ state }: { state: 'loading' | 'no-transcript' | 'silent' | 'no-project' | 'unwired' }) {
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

/* ---------------------------------------------------------------- the view -- */

export function ChatView({ cwd, onSend, transcriptPath, refreshMs = 2000, bridge }: ChatViewProps) {
  const resolved = bridge ?? resolveBridge()
  const [messages, setMessages] = useState<ChatMessage[]>([])
  const [found, setFound] = useState<boolean | null>(null)
  const [path, setPath] = useState('')
  const [behind, setBehind] = useState(false)

  const scrollRef = useRef<HTMLDivElement>(null)
  /** Held in a ref, not state: it changes on every scroll frame. */
  const stickRef = useRef(true)
  const pathRef = useRef('')

  const request = useMemo<ChatRequest>(
    () => (transcriptPath ? { transcriptPath } : cwd ? { cwd } : {}),
    [cwd, transcriptPath],
  )
  const key = transcriptPath ?? cwd ?? ''

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

  // Poll rather than subscribe: a chat view is open on one session at a time and
  // a 2s tail of the appended bytes is cheaper than another push channel and its
  // watcher. `tailChat` returns nothing at all when the file has not grown.
  useEffect(() => {
    if (!resolved || key === '' || refreshMs <= 0) return
    let live = true
    let busy = false
    const timer = setInterval(() => {
      if (busy) return
      busy = true
      void resolved
        .tailChat(request)
        .then((update) => {
          if (live && update && (update.messages?.length > 0 || update.reset)) apply(update)
        })
        .catch(() => {})
        .finally(() => {
          busy = false
        })
    }, refreshMs)
    return () => {
      live = false
      clearInterval(timer)
    }
  }, [resolved, key, request, refreshMs, apply])

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

  const state: 'loading' | 'no-transcript' | 'silent' | 'no-project' | 'unwired' | null =
    !resolved ? 'unwired'
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
      <ChatComposer onSend={onSend} />
    </div>
  )
}

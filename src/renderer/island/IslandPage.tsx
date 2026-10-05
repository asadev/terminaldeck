import { useCallback, useEffect, useRef, useState, type KeyboardEvent } from 'react'
import { BRAND } from '../../shared/brand'
import { allSessionsInOrder } from '../../shared/hoot-panel-model'
import { postToNative } from '../../shared/native-shell'
import { sendToTerminal } from '../chat/attach/mentions'
import { HootMark } from '../copilot/HootMark'
import { useCopilot } from '../copilot/useCopilot'
import { AllSessions } from '../hoot-panel/HootPanel'
import {
  hootRunsIn,
  islandCommands,
  mergeIslandMessages,
  openIslandRelay,
  type IslandRelayMessage,
  type IslandSnapshot,
} from './native-island'
import './island.css'

/**
 * What the native island holds when it opens — `/?island=1`.
 *
 * The Electron island's open shape, without its window: Hoot's conversation,
 * one line to ask Hoot something, and every session (the same `AllSessions`
 * list, so a row reads the same in both). The shape, its size and its motion
 * are drawn natively; this page is only what sits inside it, on a transparent
 * ground in the dark scheme the island always wears.
 *
 * Shut, it shows the one line the native pill shows too — so nothing jumps
 * when the shape opens and the page is already there.
 */

interface ChatLine {
  id: string
  role: 'you' | 'agent'
  text: string
}

function linesOf(raw: unknown): { messages: ChatLine[]; reset: boolean } {
  if (typeof raw !== 'object' || raw === null) return { messages: [], reset: false }
  const record = raw as { messages?: unknown; reset?: unknown }
  const messages: ChatLine[] = []
  for (const entry of Array.isArray(record.messages) ? record.messages : []) {
    if (typeof entry !== 'object' || entry === null) continue
    const { id, role, text } = entry as Record<string, unknown>
    if (typeof id !== 'string' || typeof text !== 'string' || text.trim() === '') continue
    if (role !== 'you' && role !== 'agent') continue
    messages.push({ id, role, text })
  }
  return { messages, reset: record.reset === true }
}

function sessionIdOf(raw: unknown): string | null {
  if (typeof raw !== 'object' || raw === null) return null
  const id = (raw as { sessionId?: unknown }).sessionId
  return typeof id === 'string' && id !== '' ? id : null
}

export function IslandPage() {
  const copilot = useCopilot()
  const [expanded, setExpanded] = useState(false)
  const [snapshot, setSnapshot] = useState<IslandSnapshot | null>(null)
  const [messages, setMessages] = useState<ChatLine[]>([])
  const [draft, setDraft] = useState('')
  const [sending, setSending] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)
  const relay = useRef<ReturnType<typeof openIslandRelay> | null>(null)
  const input = useRef<HTMLInputElement>(null)

  // A transparent page in the island's own dark scheme.
  useEffect(() => {
    const root = document.documentElement
    root.classList.add('island-page')
    root.dataset.theme = 'dark'
    return () => root.classList.remove('island-page')
  }, [])

  // The native shape opens and closes it; and says when it is ready to.
  useEffect(() => {
    const host = globalThis as { tdNative?: unknown }
    const previous = host.tdNative
    const commands = islandCommands(setExpanded)
    host.tdNative = commands
    postToNative({ type: 'ready' })
    return () => {
      if (host.tdNative === commands) host.tdNative = previous
    }
  }, [])
  useEffect(() => {
    if (expanded) input.current?.focus()
  }, [expanded])

  // The sessions, from the main window, which has their names.
  useEffect(() => {
    const opened = openIslandRelay()
    relay.current = opened
    const stop = opened.listen((message: IslandRelayMessage) => {
      if (message.type === 'snapshot') setSnapshot(message.snapshot)
    })
    opened.post({ type: 'hello' })
    return () => {
      stop()
      opened.close()
      relay.current = null
    }
  }, [])

  // Hoot's conversation: read whole when Hoot is known, then followed each time
  // Hoot's session changes state — which is when it has written something.
  const hootId = copilot.state?.sessionId ?? null
  // Where Hoot is running, read off its session as Hoot's own window reads it —
  // not the folder it is configured to start in next (`hootRunsIn`).
  const configured = copilot.state?.paths?.root ?? null
  const [hootHome, setHootHome] = useState<string | null>(configured)
  useEffect(() => {
    let live = true
    setHootHome(configured)
    if (hootId === null) return
    void window.deck
      .listSessions()
      .then((list) => {
        if (live) setHootHome(hootRunsIn(list, hootId, configured))
      })
      .catch(() => undefined)
    return () => {
      live = false
    }
  }, [hootId, configured])
  const follow = useCallback(
    (whole: boolean) => {
      if (hootHome === null) return
      const read = whole ? window.deck.loadChat({ cwd: hootHome }) : window.deck.tailChat({ cwd: hootHome })
      void read
        .then((raw) => {
          const update = linesOf(raw)
          setMessages((held) => mergeIslandMessages(held, whole ? { ...update, reset: true } : update))
        })
        .catch(() => undefined)
    },
    [hootHome],
  )
  useEffect(() => follow(true), [follow])
  useEffect(
    () =>
      window.deck.onSessionStatus((id) => {
        if (id === hootId) follow(false)
      }),
    [hootId, follow],
  )

  const ask = useCallback(async () => {
    const text = draft.trim()
    if (text === '' || sending) return
    setSending(true)
    setProblem(null)
    try {
      // Started first when it is not running, exactly as the Electron island does.
      const id = hootId ?? sessionIdOf(await window.deck.ensureCopilot())
      if (id === null) {
        setProblem(`${snapshot?.assistant ?? BRAND.assistant} could not be started.`)
        return
      }
      await sendToTerminal(text, (data) => window.deck.writeToSession(id, data))
      setDraft('')
      follow(false)
    } catch (error) {
      setProblem(error instanceof Error ? error.message : String(error))
    } finally {
      setSending(false)
    }
  }, [draft, sending, hootId, snapshot, follow])

  const onKey = (event: KeyboardEvent<HTMLInputElement>): void => {
    if (event.key !== 'Enter' || event.nativeEvent.isComposing) return
    event.preventDefault()
    void ask()
  }

  const name = snapshot?.assistant ?? BRAND.assistant
  const line = snapshot?.line ?? name
  const stopped = copilot.stage === 'stopped' && !copilot.loading

  return (
    <div className="island" data-expanded={expanded || undefined}>
      <header className="island-head">
        <HootMark size={18} />
        <span className="island-line">{line}</span>
      </header>
      {expanded && (
        <>
          <div className="island-chat" role="log" aria-label={`${name}'s conversation`}>
            {messages.length === 0 ? (
              <p className="hoot-island-quiet">{stopped ? `${name} is not running.` : `Ask ${name} anything.`}</p>
            ) : (
              messages.map((message) => (
                <p key={message.id} className="island-message" data-role={message.role}>
                  {message.text}
                </p>
              ))
            )}
          </div>
          <div className="island-ask">
            {stopped && (
              <button type="button" className="island-start" onClick={() => copilot.ensure()}>
                Start {name}
              </button>
            )}
            <input
              ref={input}
              className="island-input"
              value={draft}
              placeholder={`Ask ${name}`}
              aria-label={`Ask ${name}`}
              disabled={sending}
              onChange={(event) => setDraft(event.target.value)}
              onKeyDown={onKey}
            />
          </div>
          {problem !== null && (
            <p className="island-problem" role="status">
              {problem}
            </p>
          )}
          <AllSessions
            sessions={allSessionsInOrder(snapshot?.sessions ?? [])}
            top={0}
            onOpen={(id) => relay.current?.post({ type: 'show-session', id })}
          />
        </>
      )}
    </div>
  )
}

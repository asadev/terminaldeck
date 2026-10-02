/**
 * Talking to a running session — the copilot included.
 *
 * ## Why this is separate from the composer's microphone
 *
 * Because there is no composer here. Chat mode was deleted from the copilot on
 * 2026-08-26; what is left on that page is a terminal with Claude Code in it,
 * and the only chat *reading* surface in the app is the driving rail. So a
 * voice loop that only lived beside a text box could not reach the one thing
 * Asad asked to talk to.
 *
 * This one goes the way a person does: **the words are typed into the session**,
 * exactly as if they had been typed at the keyboard, and the answer is read out
 * of the transcript Claude Code writes anyway — the same file `ChatView` reads.
 * That is what makes it work on the copilot page and on any ordinary session
 * without either of them growing a chat pane back.
 *
 * ## Why the answer comes from the transcript and not the screen
 *
 * The terminal is a TUI: it redraws, it animates a spinner, it rewrites lines in
 * place. Reading *that* aloud would be gibberish. The transcript is the same
 * conversation as prose, already split into who-said-what, which is why the
 * reading pane was built on it in the first place.
 *
 * ## The one thing that is deliberately not automatic
 *
 * A spoken turn is typed **and submitted**. That is the whole point — *"it can
 * pass commands to copilot and it will do the things"* — but it means a
 * microphone left open in a noisy room can start work. So the loop is a mode
 * somebody switches on, the bar says so for as long as it is on, and every path
 * out of this component closes it.
 */
import { useCallback, useEffect, useRef, useState } from 'react'
import { VoiceBar } from './VoiceBar'
import { speakable, useVoiceLoop } from './useVoiceLoop'

interface Bridge {
  writeToSession?(id: string, data: string): void
  loadChat?(request: { cwd?: string; transcriptPath?: string }): Promise<unknown>
  tailChat?(request: { cwd?: string; transcriptPath?: string }): Promise<unknown>
}

function bridge(): Bridge | undefined {
  return (globalThis as unknown as { deck?: Bridge }).deck
}

interface TranscriptMessage {
  id: string
  role: string
  text: string
}

/** Read the newest agent line out of whatever `chat:load`/`chat:tail` answered. */
export function newestAgentMessage(update: unknown): TranscriptMessage | null {
  if (!update || typeof update !== 'object') return null
  const rows = (update as { messages?: unknown }).messages
  if (!Array.isArray(rows)) return null
  for (let i = rows.length - 1; i >= 0; i -= 1) {
    const row = rows[i] as Partial<TranscriptMessage> | undefined
    if (!row || row.role !== 'agent') continue
    if (typeof row.id !== 'string' || typeof row.text !== 'string') continue
    return { id: row.id, role: row.role, text: row.text }
  }
  return null
}

interface Props {
  sessionId: string | null
  cwd: string | null
}

/** How often the transcript is re-read while the loop is on. */
const WATCH_MS = 1200

/**
 * How long an answer must stop changing before it is read aloud.
 *
 * An agent's reply arrives a piece at a time — the transcript grows under the
 * same message for as long as it is writing. Speaking on every read meant
 * starting the sentence again each time it grew, which is what Asad heard:
 *
 *   > *"voice is flickering a lot"*
 *
 * So a message is spoken once it has held still. Two ticks of quiet is the
 * shortest thing that is reliably the end of a reply rather than a pause
 * between two chunks of one.
 */
const SETTLED_MS = 2600

export function SessionVoice({ sessionId, cwd }: Props) {
  const [problem, setProblem] = useState<string | null>(null)

  /**
   * Type the turn into the session and press Return.
   *
   * `\r`, not `\n`: this is a pty, and Return is a carriage return there. The
   * text is flattened first for the same reason the phone's composer flattens
   * it — a newline mid-sentence would submit half a thought.
   */
  const sendToSession = useCallback(
    (spoken: string) => {
      const write = bridge()?.writeToSession
      if (!write || !sessionId) {
        setProblem('No session is focused, so there is nothing to talk to.')
        return false
      }
      setProblem(null)
      write(sessionId, `${spoken.replace(/[\r\n]+/g, ' ').trim()}\r`)
      return true
    },
    [sessionId],
  )

  const voice = useVoiceLoop({ onTurn: sendToSession })

  // Held in a ref so the watcher below is not rebuilt on every tick.
  const sayRef = useRef(voice.say)
  useEffect(() => {
    sayRef.current = voice.say
  }, [voice.say])

  /**
   * Watch the transcript for the copilot's answer.
   *
   * Polled rather than pushed, and that is a deliberate exception to the
   * events-not-polling rule: `chat:tail` *is* the app's own incremental read —
   * it returns only what is new — and it runs only while the loop is switched
   * on. A watcher that costs nothing when the feature is off is not the kind of
   * poller that rule was written about.
   *
   * The first read after switching on adopts whatever is already there as
   * "already said", so turning voice on in the middle of a conversation does
   * not make it recite the backlog.
   */
  const on = voice.handsFree
  useEffect(() => {
    if (!on || !cwd) return
    let alive = true
    let spokenId: string | null = null
    let adopted = false

    // What the newest answer looked like last tick, and when it last changed.
    let lastText = ''
    let lastChangedAt = 0

    const look = async () => {
      // `loadChat` reads the whole transcript, `tailChat` only what is new. The
      // first call has to be the whole one to know where the conversation
      // already is; every call after is the cheap one.
      const read = adopted ? bridge()?.tailChat : bridge()?.loadChat
      if (!read) return
      let update: unknown
      try {
        update = await read({ cwd })
      } catch {
        return
      }
      if (!alive) return
      const newest = newestAgentMessage(update)
      if (!adopted) {
        adopted = true
        spokenId = newest?.id ?? null
        lastText = newest?.text ?? ''
        return
      }
      if (!newest || newest.id === spokenId) return

      // Still being written: note the change and wait for it to settle.
      if (newest.text !== lastText) {
        lastText = newest.text
        lastChangedAt = performance.now()
        return
      }
      if (lastChangedAt === 0 || performance.now() - lastChangedAt < SETTLED_MS) return

      spokenId = newest.id
      lastChangedAt = 0
      if (!speakable(newest.text)) return
      void sayRef.current(newest.text)
    }

    void look()
    const timer = setInterval(() => void look(), WATCH_MS)
    return () => {
      alive = false
      clearInterval(timer)
    }
  }, [on, cwd])

  const toggle = useCallback(() => {
    if (voice.handsFree) {
      voice.setHandsFree(false)
      void voice.stopEar()
      void voice.hush()
      return
    }
    setProblem(null)
    voice.setHandsFree(true)
    void voice.startEar()
  }, [voice])

  return (
    <VoiceBar
      ready={voice.availability.ready && sessionId !== null}
      reason={voice.availability.reason}
      phase={voice.phase}
      heard={voice.heard}
      problem={problem ?? voice.problem}
      handsFree={voice.handsFree}
      onToggleHandsFree={toggle}
      onStop={() => {
        voice.setHandsFree(false)
        void voice.stopEar()
      }}
      onHush={() => void voice.hush()}
    />
  )
}

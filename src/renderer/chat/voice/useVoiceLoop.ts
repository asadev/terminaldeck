/**
 * The conversation loop: talk, it acts, it answers out loud, it listens again.
 *
 * Asad asked for two things in the same breath — *"can we turn it into
 * interactive one too, maybe it can pass commands to copilot and it will do the
 * things and it will interact with us"* and *"will it be like jarvis"* — and
 * this hook is the difference between a microphone and that. A microphone puts
 * words in a box and stops. This closes the circle: the words are **sent** when
 * the sentence ends, the reply is **spoken**, and the ear reopens for the next
 * thing without a press.
 *
 * ## Why hands-free is a mode and not the behaviour
 *
 * Because a microphone that sends on its own is dangerous on an agent prompt.
 * The composer already refuses to let Return submit for the same reason — *"one
 * thumb-slip away from asking a question that was half typed"* — so plain
 * dictation still fills the box and waits for Send. Hands-free is the deliberate
 * second press, and turning it on says *I am talking to it now*.
 *
 * ## The three rules that make it not step on itself
 *
 *  1. **Never listen while speaking.** The microphone is closed for the whole
 *     sentence and reopened when the main process reports the sentence finished
 *     — which is why `speakNative` resolves on completion rather than on start.
 *     Without this the assistant transcribes its own voice and answers itself.
 *  2. **A pause ends a turn, not a word.** Apple's engine emits `final` per
 *     phrase, so "open the browser" and "and check the build" arrive as two.
 *     Sending on each would be two questions. The turn closes after
 *     `QUIET_MS` of nothing new, which is what a person hears as "he's done".
 *  3. **Silence is not a message.** An empty or whitespace-only turn is
 *     dropped; a room with a fan in it should not send anything at all.
 */
import { useCallback, useEffect, useRef, useState } from 'react'

/** How long a pause has to be before the sentence counts as finished. */
export const QUIET_MS = 1400

export interface VoiceSettings {
  /** An `AVSpeechSynthesisVoice` identifier, or undefined for the system default. */
  voice?: string
  /** 0…1, Apple's own scale. ~0.46 reads as measured rather than hurried. */
  rate: number
  /** 0.5…2. Below 1 is heavier — what "a bit like Jarvis" means in a number. */
  pitch: number
  volume: number
  locale: string
}

/**
 * The voice, chosen rather than hard-coded.
 *
 * ## Why this is a search and not a constant
 *
 * It was a constant first — Daniel, the British male every Mac carries — and
 * Asad's verdict on hearing it was the reason this function exists:
 *
 *   > *"It doesn't look like much realistic the way we have currently Siri and
 *   > all of that… very Classic old version that they had in the beginning."*
 *
 * He was right, and the cause is a tier nobody sees: a stock Mac ships only
 * **super-compact** voices, which are the 2005-sounding concatenative ones.
 * Measured on his machine before any of this changed — 180 voices installed,
 * **every one of them quality 1**. The good voices are free downloads that
 * simply have not been fetched (System Settings → Accessibility → Read & Speak
 * → System voice → the ⓘ), and once fetched they appear here like any other.
 *
 * `Arthur (Enhanced)` is `com.apple.ttsbundle.siri_Arthur_en-GB_premium` — an
 * actual Siri voice bundle, and third-party-visible. That is what "like Siri"
 * turned out to mean in practice, and it is why this ranks by *quality first*:
 * on a machine where somebody has downloaded a better voice, the app should
 * use it without being told, and on a machine where nobody has, it must still
 * have something to say.
 *
 * ## The pitch rule
 *
 * Only the old voices get pitched down. A compact voice is resampled, so
 * dropping the pitch genuinely makes it heavier; a neural voice is *generated*,
 * and shifting it afterwards undoes the thing that makes it sound human. So
 * heaviness comes from the voice, not the dial, wherever there is a real voice
 * to pick.
 */
export interface InstalledVoice {
  id: string
  name: string
  language: string
  /** Apple's tier: 1 default (compact), 2 enhanced, 3 premium. */
  quality: number
}

export function readVoices(value: unknown): InstalledVoice[] {
  if (!value || typeof value !== 'object') return []
  const rows = (value as { voices?: unknown }).voices
  if (!Array.isArray(rows)) return []
  const out: InstalledVoice[] = []
  for (const row of rows) {
    if (!row || typeof row !== 'object') continue
    const v = row as Partial<InstalledVoice>
    if (typeof v.id !== 'string' || typeof v.name !== 'string') continue
    out.push({
      id: v.id,
      name: v.name,
      language: typeof v.language === 'string' ? v.language : '',
      quality: typeof v.quality === 'number' ? v.quality : 1,
    })
  }
  return out
}

/**
 * Score a voice for "a believable male assistant, in English".
 *
 * Quality dominates everything else by an order of magnitude, because the gap
 * between a compact voice and an enhanced one is the entire complaint this
 * function answers — a perfectly-accented compact voice still sounds like a
 * machine, and a slightly-wrong-accent neural one does not.
 *
 * Gender is not a field Apple exposes, so the male voices are named. That is
 * ugly and it is also the only way: the list is short, stable, and every name
 * on it is one Apple ships. An unknown name is not excluded, only unranked —
 * a machine carrying a voice this list has never heard of should still be able
 * to speak.
 */
const MALE_ENGLISH = [
  'arthur', 'aaron', 'daniel', 'gordon', 'oliver', 'alex', 'fred', 'rishi',
  'tom', 'lee', 'xander', 'jamie', 'reed', 'rocko', 'grandpa', 'eddy', 'junior', 'ralph',
]

export function scoreVoice(voice: InstalledVoice): number {
  const name = voice.name.toLowerCase()
  const lang = voice.language.toLowerCase()
  if (!lang.startsWith('en')) return -1
  // Novelty voices are jokes — Bells, Bubbles, Zarvox. They must never win by
  // being the only "male" name left on an otherwise bare machine.
  if (/bells|bubbles|boing|jester|organ|cellos|trinoids|wobble|zarvox|whisper|bad news|good news|bahh|superstar|albert/.test(name)) {
    return -1
  }
  let score = voice.quality * 100
  // A Siri bundle is the modern engine even at the same nominal quality.
  if (voice.id.includes('siri_')) score += 40
  if (MALE_ENGLISH.some((male) => name.startsWith(male))) score += 30
  if (lang.startsWith('en-gb')) score += 8
  else if (lang.startsWith('en-us')) score += 6
  // Eloquence is the 1980s formant synthesiser kept for compatibility.
  if (voice.id.includes('eloquence') || voice.id.includes('speech.synthesis')) score -= 60
  return score
}

export function pickVoice(voices: readonly InstalledVoice[]): InstalledVoice | null {
  const ranked = voices
    .map((voice) => ({ voice, score: scoreVoice(voice) }))
    .filter((row) => row.score >= 0)
    .sort((a, b) => b.score - a.score)
  return ranked[0]?.voice ?? null
}

/** Whether a voice is generated rather than resampled — see the pitch rule. */
export function isNeural(voice: InstalledVoice | null): boolean {
  return voice !== null && (voice.quality > 1 || voice.id.includes('siri_'))
}

/**
 * The starting point, used until the voice list comes back and, on a machine
 * with nothing good installed, for good. The pitch is the compact-voice one;
 * `useVoiceLoop` flattens it the moment it picks a real voice.
 */
export const JARVIS: VoiceSettings = {
  rate: 0.46,
  pitch: 0.9,
  volume: 1,
  locale: 'en-US',
}

interface Bridge {
  nativeSpeechProbe?(): Promise<unknown>
  nativeSpeechVoices?(): Promise<unknown>
  startNativeSpeech?(request: { locale?: string }): Promise<unknown>
  stopNativeSpeech?(): Promise<unknown>
  speakNative?(request: {
    text: string
    voice?: string
    rate?: number
    pitch?: number
    volume?: number
  }): Promise<unknown>
  hushNative?(): Promise<unknown>
  onNativeSpeech?(cb: (line: unknown) => void): () => void
}

function bridge(): Bridge | undefined {
  return (globalThis as unknown as { deck?: Bridge }).deck
}

/** Whether this machine has a free ear, and why not when it does not. */
export interface NativeVoiceAvailability {
  ready: boolean
  reason: string | null
}

export function readAvailability(value: unknown): NativeVoiceAvailability {
  if (!value || typeof value !== 'object') return { ready: false, reason: null }
  const row = value as { listening?: unknown; reason?: unknown }
  return {
    ready: row.listening === true,
    reason: typeof row.reason === 'string' ? row.reason : null,
  }
}

/**
 * Fold a stream of finalised phrases into one turn.
 *
 * Kept separate from the hook so the rule is testable without a microphone: two
 * phrases with a space between them, no double spaces, and a turn that is only
 * whitespace comes back empty so the caller can drop it.
 */
export function joinTurn(phrases: readonly string[]): string {
  return phrases
    .map((phrase) => phrase.trim())
    .filter((phrase) => phrase.length > 0)
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim()
}

/**
 * What of an agent's answer is worth reading out.
 *
 * A copilot reply is written to be *looked* at — fenced code, file paths, a
 * table of what changed — and read aloud verbatim it is unbearable: every
 * backtick, every pipe, every underscore spoken as a word. So the speech gets
 * the prose and is told the rest exists rather than made to perform it.
 *
 * Truncation is on purpose too. Somebody who wants the whole thing is looking at
 * it; the voice is for knowing whether to look.
 */
export function speakable(markdown: string, limit = 700): string {
  let text = markdown
    // Fenced code becomes a mention, not a recital.
    .replace(/```[\s\S]*?```/g, ' … code block … ')
    .replace(/`([^`]+)`/g, '$1')
    // Links read as their words, never their URL.
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/^\s{0,3}#{1,6}\s+/gm, '')
    .replace(/\*\*([^*]+)\*\*/g, '$1')
    .replace(/(^|\s)[*_]([^*_]+)[*_]/g, '$1$2')
    .replace(/^\s*[-*+]\s+/gm, '')
    .replace(/^\s*\|.*\|\s*$/gm, ' … table … ')
    .replace(/\s+/g, ' ')
    .trim()
  if (text.length <= limit) return text
  // Cut at a sentence if there is one near the end, so it does not stop mid-word.
  const cut = text.slice(0, limit)
  const stop = Math.max(cut.lastIndexOf('. '), cut.lastIndexOf('? '), cut.lastIndexOf('! '))
  text = stop > limit * 0.6 ? cut.slice(0, stop + 1) : cut
  return `${text.trim()} … there is more on screen.`
}

export type VoicePhase = 'off' | 'listening' | 'thinking' | 'speaking'

interface Options {
  /** Called with a finished spoken turn. Return true if it was sent. */
  onTurn: (text: string) => boolean
  /** Live text as it is being said, for the box to show. */
  onPartial?: (text: string) => void
  settings?: VoiceSettings
}

export function useVoiceLoop({ onTurn, onPartial, settings = JARVIS }: Options) {
  const [availability, setAvailability] = useState<NativeVoiceAvailability>({ ready: false, reason: null })
  const [phase, setPhase] = useState<VoicePhase>('off')
  const [handsFree, setHandsFree] = useState(false)
  const [heard, setHeard] = useState('')
  const [problem, setProblem] = useState<string | null>(null)
  /** The settings actually in use — `settings` until a better voice is found. */
  const [chosen, setChosen] = useState<VoiceSettings>(settings)

  // Refs, not state, for everything the IPC callback reads: that callback is
  // registered once and would otherwise close over the first render's values.
  const phrases = useRef<string[]>([])
  const quietTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const handsFreeRef = useRef(false)
  const onTurnRef = useRef(onTurn)
  const settingsRef = useRef(settings)
  const wantsEar = useRef(false)
  /**
   * Deafness, in two forms, and both are needed.
   *
   * `speakingRef` covers the sentence itself. `deafUntil` covers the moment
   * after it: the speakers are still settling, the room still has the tail of
   * the voice in it, and the recogniser will happily turn that into a phrase.
   * Asad heard exactly this — *"its listening to him self while speaking and
   * sending back to him self his own answers"* — and one guard alone did not
   * close it, because the microphone's own shutdown emits a final phrase on the
   * way out, after the speaking has already started.
   */
  const speakingRef = useRef(false)
  const deafUntil = useRef(0)

  useEffect(() => {
    onTurnRef.current = onTurn
  }, [onTurn])
  useEffect(() => {
    settingsRef.current = chosen
  }, [chosen])
  useEffect(() => {
    handsFreeRef.current = handsFree
  }, [handsFree])

  useEffect(() => {
    let alive = true
    void (async () => {
      const probe = bridge()?.nativeSpeechProbe
      if (!probe) return
      const answer = readAvailability(await probe())
      if (!alive) return
      setAvailability(answer)
      if (!answer.ready) return
      // The voice list is asked for once, after the probe says there is an
      // engine — on a machine without one there is nothing to rank.
      const list = bridge()?.nativeSpeechVoices
      if (!list) return
      const best = pickVoice(readVoices(await list()))
      if (!alive || !best) return
      setChosen((current) => ({
        ...current,
        voice: best.id,
        // Neural voices are ruined by pitch shifting; compact ones are helped.
        pitch: isNeural(best) ? 1 : current.pitch,
        rate: isNeural(best) ? 0.5 : current.rate,
      }))
    })()
    return () => {
      alive = false
    }
  }, [])

  const startEar = useCallback(async () => {
    const start = bridge()?.startNativeSpeech
    if (!start) return
    phrases.current = []
    setHeard('')
    wantsEar.current = true
    setPhase('listening')
    await start({ locale: settingsRef.current.locale })
  }, [])

  const stopEar = useCallback(async () => {
    wantsEar.current = false
    if (quietTimer.current) {
      clearTimeout(quietTimer.current)
      quietTimer.current = null
    }
    await bridge()?.stopNativeSpeech?.()
    setPhase('off')
    setHeard('')
  }, [])

  /**
   * Say something, with the ear shut for the whole sentence.
   *
   * The reopen is conditional on hands-free still being on *at the moment the
   * sentence ends*, not when it started — somebody who switches it off while
   * the assistant is mid-paragraph has said stop, and reopening the microphone
   * on them would be the app arguing.
   */
  const say = useCallback(async (text: string) => {
    const speak = bridge()?.speakNative
    const spoken = speakable(text)
    if (!speak || !spoken) return
    // Deaf *before* the ear is even asked to close, because closing takes a
    // moment and whatever is heard in that moment is not a person talking.
    speakingRef.current = true
    setPhase('speaking')
    phrases.current = []
    setHeard('')
    if (quietTimer.current) {
      clearTimeout(quietTimer.current)
      quietTimer.current = null
    }
    // Awaited: the main process resolves this only when the microphone process
    // has actually exited. See `stopListening` for why that matters.
    await bridge()?.stopNativeSpeech?.()
    wantsEar.current = false

    const s = settingsRef.current
    await speak({ text: spoken, voice: s.voice, rate: s.rate, pitch: s.pitch, volume: s.volume })

    // The tail of the room, and the speakers settling.
    deafUntil.current = Date.now() + 500
    speakingRef.current = false
    if (handsFreeRef.current) {
      await startEar()
    } else {
      setPhase('off')
    }
  }, [startEar])

  const hush = useCallback(async () => {
    await bridge()?.hushNative?.()
  }, [])

  // The stream from the helper. Registered once for the life of the component.
  useEffect(() => {
    const subscribe = bridge()?.onNativeSpeech
    if (!subscribe) return
    return subscribe((raw) => {
      if (!raw || typeof raw !== 'object') return
      const line = raw as { kind?: string; text?: string; message?: string }

      if (line.kind === 'error') {
        setProblem(line.message ?? 'The microphone stopped.')
        setPhase('off')
        wantsEar.current = false
        return
      }
      if (line.kind === 'closed') {
        if (wantsEar.current) setPhase('off')
        return
      }
      // Deaf while speaking, and briefly after. Dropped outright rather than
      // buffered: a phrase heard here is the assistant's own voice, and keeping
      // it for later would send it as the next turn a moment afterwards.
      if (speakingRef.current || Date.now() < deafUntil.current) {
        phrases.current = []
        if (quietTimer.current) {
          clearTimeout(quietTimer.current)
          quietTimer.current = null
        }
        return
      }

      if (line.kind === 'partial' && typeof line.text === 'string') {
        const live = joinTurn([...phrases.current, line.text])
        setHeard(live)
        onPartial?.(live)
        return
      }
      if (line.kind !== 'final' || typeof line.text !== 'string') return

      phrases.current = [...phrases.current, line.text]
      const live = joinTurn(phrases.current)
      setHeard(live)
      onPartial?.(live)

      // Rule 2: the turn closes on a pause, not on a phrase.
      if (quietTimer.current) clearTimeout(quietTimer.current)
      quietTimer.current = setTimeout(() => {
        quietTimer.current = null
        const turn = joinTurn(phrases.current)
        phrases.current = []
        setHeard('')
        if (!turn) return // Rule 3: silence is not a message.
        const sent = onTurnRef.current(turn)
        if (sent && handsFreeRef.current) setPhase('thinking')
      }, QUIET_MS)
    })
  }, [onPartial])

  // Nothing may outlive the component: a microphone held by a unmounted pane is
  // a recording light with no window behind it.
  useEffect(
    () => () => {
      void bridge()?.stopNativeSpeech?.()
      void bridge()?.hushNative?.()
    },
    [],
  )

  return {
    availability,
    phase,
    heard,
    problem,
    handsFree,
    setHandsFree,
    startEar,
    stopEar,
    say,
    hush,
    listening: phase === 'listening',
  }
}

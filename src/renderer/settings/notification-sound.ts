/**
 * The notification sounds, synthesised.
 *
 * The app ships no audio files — `src/renderer/assets` holds two fonts and
 * nothing else — and adding one would mean a binary asset nobody can review in
 * a diff, plus a licence to track. Three short tones out of an oscillator cost
 * about forty lines, are inspectable, and cannot be a licence problem.
 *
 * The recipes are data so the picker and the player cannot disagree: the schema
 * lists the ids, this module holds the recipe for each, and a test asserts the
 * two sets are identical. A picker offering a sound that will not play is worse
 * than a picker with fewer sounds in it.
 *
 * Nothing here touches an AudioContext at import time. Chromium refuses to
 * start one before a user gesture, and a module that built one on load would
 * log a warning on every launch for a feature most users leave off.
 */

export type SoundId = 'chime' | 'blip' | 'knock'

export interface Tone {
  /** Hz. */
  frequency: number
  /** Seconds from the start of the sound. */
  at: number
  /** Seconds. */
  duration: number
  /** 0–1, before the shared master gain. */
  gain: number
  type: OscillatorType
}

export interface SoundRecipe {
  id: SoundId
  tones: readonly Tone[]
}

/**
 * Frequencies are notes rather than round numbers — 880 and 1174.7 are A5 and
 * D6, a fourth apart, which reads as "finished" rather than as an alarm. The
 * knock is a detuned low sine because a square wave down there sounds broken on
 * laptop speakers.
 */
export const SOUNDS: Readonly<Record<SoundId, SoundRecipe>> = {
  chime: {
    id: 'chime',
    tones: [
      { frequency: 880, at: 0, duration: 0.12, gain: 0.5, type: 'sine' },
      { frequency: 1174.7, at: 0.1, duration: 0.22, gain: 0.42, type: 'sine' },
    ],
  },
  blip: {
    id: 'blip',
    tones: [{ frequency: 987.8, at: 0, duration: 0.09, gain: 0.45, type: 'triangle' }],
  },
  knock: {
    id: 'knock',
    tones: [
      { frequency: 196, at: 0, duration: 0.09, gain: 0.6, type: 'sine' },
      { frequency: 146.8, at: 0.075, duration: 0.12, gain: 0.5, type: 'sine' },
    ],
  },
}

export const SOUND_IDS: readonly SoundId[] = Object.keys(SOUNDS) as SoundId[]

export function isSoundId(value: unknown): value is SoundId {
  return typeof value === 'string' && value in SOUNDS
}

/** How long a recipe rings for, so a caller can close the context afterwards. */
export function soundDuration(recipe: SoundRecipe): number {
  return recipe.tones.reduce((longest, tone) => Math.max(longest, tone.at + tone.duration), 0)
}

/* ------------------------------------------------------------- playback -- */

/** The slice of the Web Audio API this module uses, so tests can supply a stub. */
export interface AudioHost {
  currentTime: number
  destination: AudioNode
  createOscillator(): OscillatorNode
  createGain(): GainNode
  close?(): Promise<void>
}

type AudioHostFactory = () => AudioHost | null

function browserAudioHost(): AudioHost | null {
  const Ctor = (globalThis as { AudioContext?: new () => AudioContext }).AudioContext
  return Ctor ? new Ctor() : null
}

/**
 * Play one sound. Returns false when there is no audio output to play it on —
 * a headless test, or a build with the API missing — so a caller can say so
 * instead of pretending it worked.
 *
 * Each tone gets its own gain node with an exponential release. A bare
 * oscillator that stops at full amplitude clicks, and the click is louder than
 * the note.
 */
export function playSound(id: SoundId, volume = 0.6, host: AudioHostFactory = browserAudioHost): boolean {
  // The id is typed, but it reaches here from a stored settings value that a
  // hand-edited file can make anything at all. An unknown one is a silent no —
  // reading `.tones` off undefined would take the click handler down with it.
  const recipe = SOUNDS[id] as SoundRecipe | undefined
  if (!recipe) return false

  const context = host()
  if (!context) return false

  const start = context.currentTime
  const master = context.createGain()
  master.gain.value = Math.min(1, Math.max(0, volume))
  master.connect(context.destination)

  for (const tone of recipe.tones) {
    const oscillator = context.createOscillator()
    const envelope = context.createGain()
    oscillator.type = tone.type
    oscillator.frequency.value = tone.frequency

    const at = start + tone.at
    // Never exactly zero: exponentialRampToValueAtTime throws on a zero target,
    // and 0.0001 is inaudible.
    envelope.gain.setValueAtTime(tone.gain, at)
    envelope.gain.exponentialRampToValueAtTime(0.0001, at + tone.duration)

    oscillator.connect(envelope)
    envelope.connect(master)
    oscillator.start(at)
    oscillator.stop(at + tone.duration)
  }

  // The context holds an audio device open; leaving one per test click behind
  // is how an app ends up with a dozen of them and a warning in the console.
  const total = soundDuration(recipe)
  if (context.close) {
    setTimeout(() => void context.close?.().catch(() => undefined), (total + 0.2) * 1000)
  }
  return true
}

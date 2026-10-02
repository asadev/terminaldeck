/**
 * The Mac's own ear and voice, owned by the main process.
 *
 * ## Why this is not in the window
 *
 * `src/renderer/chat/voice/dictation.ts` holds the measurement: the Web Speech
 * API inside this Electron starts and then emits nothing — no result, no end,
 * and no error — because the recogniser compiled into Chromium talks to
 * Google's private endpoint and Electron carries none of Google's keys. A
 * control whose failure is indistinguishable from listening cannot be made
 * honest, so the window is not asked to hear.
 *
 * macOS 26 added an on-device engine that is free, needs no key and no account,
 * and never leaves the machine. It is reachable only from native code, so it is
 * reached the way everything native here is reached: a child process on a pipe,
 * `native/deck-speech`. A native Node addon would be compiled per Electron ABI
 * and would take the window down with it when Apple moves something; a child
 * process cannot, and when it dies it dies alone with a printable line.
 *
 * ## What this file guarantees to the renderer
 *
 * One microphone per window, and it is *this* file that holds it — not the
 * renderer, which can be reloaded mid-sentence, and not the helper, which
 * cannot know about the second one. `stop()` is therefore idempotent and is
 * called on every path out, including window close.
 *
 * ## The rule about the paid key
 *
 * Nothing here touches `src/main/voice.ts`. That path exists, still works, and
 * still gates the microphone on a proved key — it is the only ear on Windows
 * and Linux, and the only one that transcribes a language this Mac has not
 * installed. This is a *better* ear where it exists, offered first; the key is
 * what answers when it does not.
 */
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import type { BrowserWindow, IpcMain } from 'electron'

/** A line off the helper's stdout. Anything unrecognised is dropped, not thrown. */
export interface SpeechLine {
  kind: string
  text?: string
  message?: string
  /** The ticket a `serve` sentence was given, echoed back on `done`. */
  id?: number
  listening?: boolean
  locales?: string[]
  voices?: unknown
}

/**
 * Where the helper lives, dev and packaged.
 *
 * In development it is the build output beside its source, because that is what
 * `native/deck-speech/build.sh` writes and a developer who has just run it
 * should not also have to package. In a packaged app it is an extra resource;
 * `process.resourcesPath` is the folder electron-builder puts those in.
 */
export function speechBinary(resourcesPath: string, appPath: string): string | null {
  const candidates = [
    join(resourcesPath, 'deck-speech'),
    join(appPath, 'native', 'deck-speech', 'bin', 'deck-speech'),
    join(process.cwd(), 'native', 'deck-speech', 'bin', 'deck-speech'),
  ]
  return candidates.find((path) => existsSync(path)) ?? null
}

/** Split a stdout chunk stream into whole JSON lines. A partial tail is kept. */
export function makeLineReader(onLine: (line: SpeechLine) => void): (chunk: string) => void {
  let held = ''
  return (chunk: string) => {
    held += chunk
    let cut = held.indexOf('\n')
    while (cut >= 0) {
      const raw = held.slice(0, cut).trim()
      held = held.slice(cut + 1)
      cut = held.indexOf('\n')
      if (!raw) continue
      try {
        const parsed: unknown = JSON.parse(raw)
        if (parsed && typeof parsed === 'object' && typeof (parsed as SpeechLine).kind === 'string') {
          onLine(parsed as SpeechLine)
        }
      } catch {
        // A line that is not JSON is the helper's own crash output. Dropping it
        // keeps a malformed byte from stopping the words either side of it.
      }
    }
  }
}

interface Session {
  child: ChildProcessWithoutNullStreams
  window: BrowserWindow
}

let listening: Session | null = null

/**
 * The speaker, kept warm.
 *
 * A neural voice is a model that has to be paged in — `Arthur (Enhanced)` is
 * 162 MB — and a process spawned per sentence pays that every time. Measured:
 * **23 seconds** for the first sentence and 4.5–7.8 for each one after, of
 * which only about three were speech. In a conversation that delay lands
 * between every question and its answer, and the restarts are what Asad heard
 * as *"voice is flickering a lot"*.
 *
 * So one process lives for the window's lifetime, loads the voice once, and
 * takes sentences on stdin. Each carries a ticket, and `done` carries it back:
 * without that, a sentence cut short by the next one would settle the wrong
 * promise and the microphone would reopen into speech still playing.
 */
interface Speaker {
  child: ChildProcessWithoutNullStreams
  voice: string | undefined
  ticket: number
  waiting: Map<number, () => void>
  /**
   * Settles when the helper has said `ready` — the voice loaded, its queue
   * empty, and its stdin actually being read.
   *
   * Waiting on this is not politeness, it is required. A sentence written into
   * the pipe *before* the helper reached its read loop was measured to vanish:
   * the write succeeded, `ready` arrived afterwards, and no `done` ever came.
   * The warm-up spins a run loop for a second or so while a 162 MB voice pages
   * in, and anything posted into that window is lost.
   */
  ready: Promise<void>
}

let speaker: Speaker | null = null

function send(window: BrowserWindow, channel: string, payload: unknown): void {
  if (!window.isDestroyed()) window.webContents.send(channel, payload)
}

/**
 * Stop the microphone, and **resolve only when it is actually shut**.
 *
 * This used to return the instant it had asked. That was the bug behind the
 * worst thing the loop ever did — Asad, on the first real conversation:
 *
 *   > *"its listening to him self while speaking and sending back to him self
 *   > his own answers"*
 *
 * The caller closes the ear, then speaks. If closing is only a request, the
 * microphone is still open for the first second of the sentence, the assistant
 * transcribes its own voice, and the loop sends that back as the next turn —
 * a machine talking to itself, for as long as somebody lets it.
 *
 * Worse, the helper *finalises the last phrase on the way out*, so the closing
 * itself emits one more `final` after the speaking has begun. Waiting for the
 * process to exit is what makes "the ear is shut" a fact rather than an
 * intention; `useVoiceLoop` also ignores anything heard while speaking, because
 * one guarantee at one layer is not enough for a feedback loop.
 */
export function stopListening(): Promise<void> {
  const held = listening
  listening = null
  if (!held) return Promise.resolve()
  const child = held.child
  return new Promise<void>((resolve) => {
    let settled = false
    const finish = () => {
      if (settled) return
      settled = true
      resolve()
    }
    child.once('close', finish)
    try {
      child.stdin.end()
    } catch {
      finish()
      return
    }
    // The backstop, for a helper that has wedged rather than exited.
    setTimeout(() => {
      if (!child.killed && child.exitCode === null) child.kill('SIGTERM')
      setTimeout(finish, 300)
    }, 1200)
  })
}

/** Stop talking, immediately — what a person pressing Stop expects. */
export function stopSpeaking(): void {
  if (!speaker) return
  try {
    speaker.child.stdin.write(`${JSON.stringify({ stop: true })}\n`)
  } catch {
    /* the speaker has gone; nothing is being said */
  }
  // Settle everything outstanding: a cut-off sentence is finished as far as the
  // caller is concerned, and leaving a promise pending would strand the loop.
  for (const done of speaker.waiting.values()) done()
  speaker.waiting.clear()
}

/** Retire the speaker, so the next sentence starts a fresh one. */
function dropSpeaker(): void {
  const held = speaker
  speaker = null
  if (!held) return
  for (const done of held.waiting.values()) done()
  held.waiting.clear()
  if (!held.child.killed) held.child.kill('SIGTERM')
}

/**
 * The warm speaker for a given voice, started if needed.
 *
 * A voice change restarts it rather than switching in place: the warm-up that
 * makes the first sentence fast is a *load of one voice*, and a process asked
 * to switch would pay that cost mid-conversation with no warning.
 */
function ensureSpeaker(binary: string, voice: string | undefined, settings: SpeakSettings): Speaker | null {
  if (speaker && speaker.voice === voice && speaker.child.exitCode === null) return speaker
  if (speaker) dropSpeaker()

  const args = ['serve']
  if (voice) args.push('--voice', voice)
  if (typeof settings.rate === 'number') args.push('--rate', String(settings.rate))
  if (typeof settings.pitch === 'number') args.push('--pitch', String(settings.pitch))
  if (typeof settings.volume === 'number') args.push('--volume', String(settings.volume))

  let child: ChildProcessWithoutNullStreams
  try {
    child = spawn(binary, args, { stdio: ['pipe', 'pipe', 'pipe'] })
  } catch {
    return null
  }
  let announceReady: () => void = () => {}
  const made: Speaker = {
    child,
    voice,
    ticket: 0,
    waiting: new Map(),
    ready: new Promise<void>((resolve) => {
      announceReady = resolve
      // A helper that never says ready must not wedge the feature for good.
      setTimeout(resolve, 15000)
    }),
  }
  const read = makeLineReader((line) => {
    if (line.kind === 'ready') {
      announceReady()
      return
    }
    if (line.kind !== 'done') return
    const id = typeof line.id === 'number' ? line.id : 0
    const done = made.waiting.get(id)
    if (done) {
      made.waiting.delete(id)
      done()
    }
  })
  child.stdout.on('data', (d: Buffer) => {
    if (process.env.DECK_SPEECH_DEBUG) console.log('[speaker]', d.toString('utf8').trim())
    read(d.toString('utf8'))
  })
  child.stderr.on('data', (d: Buffer) => {
    if (process.env.DECK_SPEECH_DEBUG) console.log('[speaker:err]', d.toString('utf8').trim())
  })
  child.on('error', () => {
    if (speaker === made) dropSpeaker()
  })
  child.on('close', () => {
    // Unblock anybody waiting on a helper that died before it was ready.
    announceReady()
    if (speaker === made) {
      for (const done of made.waiting.values()) done()
      made.waiting.clear()
      speaker = null
    }
  })
  speaker = made
  return made
}

interface SpeakSettings {
  rate?: number
  pitch?: number
  volume?: number
}

export function registerNativeSpeechIpc(
  ipcMain: IpcMain,
  binary: () => string | null,
  windowFor: (event: { sender: Electron.WebContents }) => BrowserWindow | null,
): void {
  /**
   * Whether this machine can hear at all, answered by asking the helper rather
   * than by testing the platform. A Mac too old for the on-device engine and a
   * Mac whose helper was never built are the same answer to the caller — *no
   * free ear here* — and both must fall through to the key.
   */
  ipcMain.handle('nspeech:probe', async () => {
    const path = binary()
    if (process.platform !== 'darwin' || !path) {
      return { listening: false, reason: 'This machine has no built-in speech engine we can use.' }
    }
    return await new Promise((resolve) => {
      const child = spawn(path, ['probe'], { stdio: ['ignore', 'pipe', 'pipe'] })
      let answer: unknown = { listening: false, reason: 'The speech helper did not answer.' }
      const read = makeLineReader((line) => {
        if (line.kind === 'probe') answer = line
        if (line.kind === 'error') answer = { listening: false, reason: line.message }
      })
      child.stdout.on('data', (d: Buffer) => read(d.toString('utf8')))
      child.on('error', () => resolve({ listening: false, reason: 'The speech helper could not be started.' }))
      child.on('close', () => resolve(answer))
      setTimeout(() => child.kill('SIGTERM'), 8000)
    })
  })

  ipcMain.handle('nspeech:voices', async () => {
    const path = binary()
    if (!path) return { voices: [] }
    return await new Promise((resolve) => {
      const child = spawn(path, ['voices'], { stdio: ['ignore', 'pipe', 'pipe'] })
      let answer: unknown = { voices: [] }
      const read = makeLineReader((line) => {
        if (line.kind === 'voices') answer = { voices: line.voices ?? [] }
      })
      child.stdout.on('data', (d: Buffer) => read(d.toString('utf8')))
      child.on('error', () => resolve({ voices: [] }))
      child.on('close', () => resolve(answer))
      setTimeout(() => child.kill('SIGTERM'), 8000)
    })
  })

  /**
   * Open the microphone.
   *
   * Starting while one is already open stops the old one first rather than
   * refusing: a renderer that reloaded mid-sentence has no way to know it left
   * a microphone behind, and two taps on one input device is the bug that would
   * follow.
   */
  ipcMain.handle('nspeech:start', (event, request: { locale?: string } = {}) => {
    const path = binary()
    const window = windowFor(event)
    if (!path || !window) return { ok: false, message: 'No speech helper on this machine.' }
    void stopListening()

    const child = spawn(path, ['listen', '--locale', request.locale || 'en-US'], {
      stdio: ['pipe', 'pipe', 'pipe'],
    })
    listening = { child, window }

    const read = makeLineReader((line) => {
      send(window, 'nspeech:event', line)
    })
    child.stdout.on('data', (d: Buffer) => read(d.toString('utf8')))
    child.stderr.on('data', (d: Buffer) => {
      const text = d.toString('utf8').trim()
      if (text) send(window, 'nspeech:event', { kind: 'note', message: text })
    })
    child.on('error', (error: Error) => {
      send(window, 'nspeech:event', { kind: 'error', message: error.message })
      listening = null
    })
    child.on('close', () => {
      if (listening?.child === child) listening = null
      send(window, 'nspeech:event', { kind: 'closed' })
    })
    return { ok: true }
  })

  ipcMain.handle('nspeech:stop', async () => {
    // Awaited, so a caller that is about to speak knows the ear is really shut.
    await stopListening()
    return { ok: true }
  })

  /**
   * Say something.
   *
   * The promise settles when the sentence finishes, which is the property the
   * hands-free loop is built on: the microphone reopens on this resolving, so
   * the app never transcribes its own voice.
   */
  /**
   * Say something, and resolve when the sentence has actually finished.
   *
   * That property is what the hands-free loop is built on: the microphone
   * reopens on this resolving, so resolving early is the same bug as not
   * closing the ear at all.
   */
  ipcMain.handle(
    'nspeech:speak',
    async (_event, request: { text?: string; voice?: string; rate?: number; pitch?: number; volume?: number } = {}) => {
      const path = binary()
      const text = typeof request.text === 'string' ? request.text.trim() : ''
      if (!path || !text) return { ok: false }
      const warm = ensureSpeaker(path, request.voice, request)
      if (!warm) return { ok: false }

      warm.ticket += 1
      const ticket = warm.ticket
      const line: Record<string, unknown> = { id: ticket, say: text }
      if (typeof request.rate === 'number') line.rate = request.rate
      if (typeof request.pitch === 'number') line.pitch = request.pitch
      if (typeof request.volume === 'number') line.volume = request.volume

      // The helper must be reading its stdin before anything is posted to it.
      await warm.ready
      return await new Promise((resolve) => {
        warm.waiting.set(ticket, () => resolve({ ok: true }))
        try {
          if (process.env.DECK_SPEECH_DEBUG) console.log('[speaker:write]', JSON.stringify(line))
          warm.child.stdin.write(`${JSON.stringify(line)}\n`)
        } catch {
          warm.waiting.delete(ticket)
          resolve({ ok: false })
        }
      })
    },
  )

  ipcMain.handle('nspeech:hush', () => {
    stopSpeaking()
    return { ok: true }
  })
}

/** Everything this module holds, released. Called when the app is quitting. */
export function shutdownNativeSpeech(): void {
  void stopListening()
  dropSpeaker()
}

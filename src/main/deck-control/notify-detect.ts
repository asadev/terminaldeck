/**
 * Turning what sessions do into notifications, and deciding whose each one is.
 *
 * ## Whose a notification is
 *
 * Exactly one access key, and the rule has three lines:
 *
 *  1. **A turn another key triggered is that key's.** When an AI app sends into
 *     a session — its own, or one it was allowed into — the turn that message
 *     starts, and the question it stops at, are told to that app. Never to the
 *     app that started the session, never to anybody else. Two agents sharing
 *     one session through two keys each hear about their own turns.
 *  2. **Otherwise it is the starter's.** A turn nobody known triggered — the
 *     brief a session was started with, a line the owner typed straight into
 *     the terminal — and an exit or a crash go to the key that started it.
 *  3. **The copilot and the owner never notify an app.** A turn the copilot or
 *     the person triggered is nobody's notification, and a session the copilot
 *     or the person started has no app to tell.
 *
 * Who started a session is `DeckControl`'s `starterOf`, the same per-caller
 * record that decides whether typing into it is `act` or `alter`. Who triggered
 * a turn is read off the action log as rows are written: an `ok`
 * `sessions.send` or `sessions.keys` names its session and its caller. Neither
 * is a guess and neither is a second record of the same fact.
 *
 * ## When
 *
 * Told by the main process on every status change and every exit — the same
 * events that colour the dot in the sidebar — never polled. A session moves
 * through `working` and back; the move back is a finished turn, `input` is a
 * question, an exit is an exit. A hook's `completed` is definitive and fires at
 * once. A calm status read off the screen waits {@link SETTLE_MS} first, because
 * a screen classifier flickers between frames and one finished turn must be one
 * notification, not three — that settle is the only timer here, and it exists
 * only while a session is between `working` and calm.
 *
 * Nothing is built for a session nobody would be told about: the recipient is
 * decided first, and a session the copilot or the person owns costs one map
 * lookup per status change.
 */

import { randomUUID } from 'node:crypto'
import type { SessionMeta, SessionStatus } from '../../shared/types'
import type { ActionRow } from './action-log'
import type { NotificationEvent, NotificationType } from './notify-hub'
import { latestAnswerOn } from './session-more-tools'
import type { DeckSurface } from './surface'

/** How long a calm status read off the screen must hold before a turn counts as finished. */
export const SETTLE_MS = 1_500

/** Longest answer carried in a notification. Room for a real reply, not a transcript. */
export const MAX_NOTIFY_ANSWER = 2_000

/** Longest screen excerpt carried with a question: the bottom of the terminal, where the menu is. */
export const MAX_NOTIFY_SCREEN = 1_500

/** The tools whose `ok` row means "this caller started a turn in that session". */
const TRIGGERS: readonly string[] = ['sessions.send', 'sessions.keys']

type Phase = 'quiet' | 'turn' | 'asked' | 'settling'

interface SessionTrack {
  phase: Phase
  /** Who started the turn in progress: `key:<id>`, `copilot`, or null when nobody known did. */
  trigger: string | null
  settle: unknown
}

export interface DetectClock {
  now(): number
  setTimeout(run: () => void, ms: number): unknown
  clearTimeout(handle: unknown): void
}

export interface NotifyDetectDeps {
  surface: Pick<
    DeckSurface,
    'listSessions' | 'sessionScreen' | 'transcriptsIn' | 'transcriptBytes' | 'readTranscriptFrom'
  >
  /** Who started a session: `key:<id>`, `copilot`, or null. `DeckControl.starterOf`. */
  starterOf(sessionId: string): string | null
  /** Queue one notification for one key. `NotificationHub.enqueue`. */
  enqueue(keyId: string, event: NotificationEvent): boolean
  clock: DetectClock
}

/** `key:<id>` → `<id>`, anything else → null. */
function keyIdOf(starter: string | null): string | null {
  return starter !== null && starter.startsWith('key:') ? starter.slice(4) : null
}

function cap(text: string, max: number, fromEnd = false): { text: string; truncated: boolean } {
  const trimmed = text.replace(/\s+$/u, '')
  if (trimmed.length <= max) return { text: trimmed, truncated: false }
  return { text: fromEnd ? `…${trimmed.slice(-max)}` : `${trimmed.slice(0, max)}…`, truncated: true }
}

export class NotifyDetector {
  private readonly tracks = new Map<string, SessionTrack>()

  constructor(private readonly deps: NotifyDetectDeps) {}

  /** An action-log row was written. A send or a keypress names the turn's trigger. */
  noteRow(row: ActionRow): void {
    if (row.outcome !== 'ok' || !TRIGGERS.includes(row.tool) || row.sessionId === undefined) return
    const trigger = row.caller?.kind === 'key' && row.caller.keyId !== undefined ? `key:${row.caller.keyId}` : 'copilot'
    this.track(row.sessionId).trigger = trigger
  }

  /** A session's status changed. */
  noteStatus(sessionId: string, status: SessionStatus): void {
    const track = this.track(sessionId)
    switch (status) {
      case 'working':
        this.cancelSettle(track)
        track.phase = 'turn'
        return
      case 'input':
        this.cancelSettle(track)
        if (track.phase === 'asked') return
        track.phase = 'asked'
        this.emit(sessionId, 'needs-input', track.trigger)
        return
      case 'completed':
        // A hook saying the turn is over. Definitive, so no settle.
        if (track.phase === 'quiet') return
        this.finish(sessionId, track)
        return
      case 'waiting':
      case 'idle':
        if (track.phase !== 'turn' && track.phase !== 'asked') return
        track.phase = 'settling'
        this.cancelSettle(track)
        track.settle = this.deps.clock.setTimeout(() => {
          track.settle = null
          if (track.phase === 'settling') this.finish(sessionId, track)
        }, SETTLE_MS)
        return
      default:
        return
    }
  }

  /** A session's process ended. Told to the starter — or the app whose turn was running, when no app started it. */
  noteExit(sessionId: string, exitCode: number): void {
    const track = this.tracks.get(sessionId)
    if (track) this.cancelSettle(track)
    this.tracks.delete(sessionId)
    const starter = keyIdOf(this.deps.starterOf(sessionId))
    const keyId = starter ?? keyIdOf(track?.trigger ?? null)
    if (keyId === null) return
    void this.build(sessionId, 'exited', exitCode).then((event) => {
      if (event !== null) this.deps.enqueue(keyId, event)
    })
  }

  /** Forget everything. Called at quit. */
  stop(): void {
    for (const track of this.tracks.values()) this.cancelSettle(track)
    this.tracks.clear()
  }

  /* ------------------------------------------------------------ inside -- */

  private finish(sessionId: string, track: SessionTrack): void {
    this.cancelSettle(track)
    const trigger = track.trigger
    track.phase = 'quiet'
    // The turn is over; the next one has no known trigger until a row names one.
    track.trigger = null
    this.emit(sessionId, 'finished', trigger)
  }

  /** Decide the recipient, then — only then — build and queue the notification. */
  private emit(sessionId: string, type: NotificationType, trigger: string | null): void {
    const keyId = trigger !== null ? keyIdOf(trigger) : keyIdOf(this.deps.starterOf(sessionId))
    if (keyId === null) return
    void this.build(sessionId, type).then((event) => {
      if (event !== null) this.deps.enqueue(keyId, event)
    })
  }

  private async build(sessionId: string, type: NotificationType, exitCode?: number): Promise<NotificationEvent | null> {
    const meta: SessionMeta | undefined = this.deps.surface.listSessions().find((session) => session.id === sessionId)
    const base = {
      id: randomUUID(),
      type,
      sessionId,
      sessionName: meta?.title ?? sessionId,
      at: this.deps.clock.now(),
    }
    try {
      if (type === 'exited') {
        const code = exitCode ?? meta?.exitCode ?? 0
        return {
          ...base,
          exitCode: code,
          crashed: code !== 0,
          suggestedTool: 'sessions_result',
          note:
            code === 0
              ? 'The session ended on its own. sessions_result reports what it did.'
              : `The session stopped with exit code ${code}. sessions_result reports what it did before it stopped.`,
        }
      }
      if (type === 'needs-input') {
        const screen = cap((await this.deps.surface.sessionScreen(sessionId)) ?? '', MAX_NOTIFY_SCREEN, true)
        return {
          ...base,
          screen,
          suggestedTool: 'sessions_keys',
          note:
            'The session stopped to ask something — a permission prompt, a menu or a question. The screen shows it. ' +
            'Answer with sessions_keys (for example ["1"] or ["enter"]) or type a reply with sessions_send.',
        }
      }
      const answer =
        meta === undefined
          ? null
          : await latestAnswerOn(this.deps.surface as DeckSurface, { ...meta, resumed: meta.resumed === true })
      if (answer !== null) {
        return {
          ...base,
          answer: cap(answer.text, MAX_NOTIFY_ANSWER),
          suggestedTool: 'sessions_send',
          note: 'The session finished its turn. answer is the newest thing it said; sessions_transcript has the rest.',
        }
      }
      // No transcript — a shell, or an agent this app cannot read — so the screen is the answer.
      const screen = cap((await this.deps.surface.sessionScreen(sessionId)) ?? '', MAX_NOTIFY_SCREEN, true)
      return {
        ...base,
        screen,
        suggestedTool: 'sessions_screen',
        note: 'The session finished its turn. It keeps no transcript, so screen shows its last lines.',
      }
    } catch (error) {
      console.error('[notify] could not build a notification:', error instanceof Error ? error.message : String(error))
      return { ...base, suggestedTool: 'sessions_get', note: 'Something changed in this session; sessions_get shows its state.' }
    }
  }

  private track(sessionId: string): SessionTrack {
    let track = this.tracks.get(sessionId)
    if (!track) {
      track = { phase: 'quiet', trigger: null, settle: null }
      this.tracks.set(sessionId, track)
    }
    return track
  }

  private cancelSettle(track: SessionTrack): void {
    if (track.settle === null) return
    this.deps.clock.clearTimeout(track.settle)
    track.settle = null
  }
}

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
 *
 * ## What is not a finished turn
 *
 * The screen classifier reads `working` then calm whenever the screen redraws,
 * not only when a turn ends. Two things seen in his queue on 2026-10-04 are
 * therefore refused here, each by a fact rather than a timer:
 *
 *  - **An answer already told.** Every `finished` names its turn by the answer
 *    it ended on — the transcript entry's time and a hash of its text — and the
 *    queue keeps those names on disk, so a redraw minutes, hours or a restart
 *    later re-reads the same answer and is refused (`NotificationHub.enqueue`).
 *  - **A Claude Code session starting up.** It has written no transcript yet,
 *    and its banner reads as `working` then calm several times. A session whose
 *    agent keeps a transcript, with no answer in it, in a turn nobody sent, is
 *    its screen redrawing — not a turn. A turn an app sent still falls back to
 *    the screen when its transcript cannot be found.
 *  - **An answer older than the turn.** The newest answer was written before
 *    this turn began, so nothing new was said: a redraw.
 *
 * The other side of that: the hook that ends a turn can reach this app before
 * the answer's line reaches the transcript. So when an answer is expected — an
 * app sent the turn, or a hook ended it — and the newest one is missing or older
 * than the turn, it is read again, {@link ANSWER_LAG_RETRIES} times
 * {@link ANSWER_LAG_MS} apart, before deciding. Those waits exist only while one
 * notification is being built.
 */

import { createHash, randomUUID } from 'node:crypto'
import type { SessionMeta, SessionStatus } from '../../shared/types'
import type { ActionRow } from './action-log'
import type { NotificationEvent, NotificationType } from './notify-hub'
import { latestAnswerOn, type Answer } from './session-more-tools'
import type { DeckSurface } from './surface'
import { writesTranscripts } from './transcript-match'

/** How long a calm status read off the screen must hold before a turn counts as finished. */
export const SETTLE_MS = 1_500

/** Longest answer carried in a notification. Room for a real reply, not a transcript. */
export const MAX_NOTIFY_ANSWER = 2_000

/** Longest screen excerpt carried with a question: the bottom of the terminal, where the menu is. */
export const MAX_NOTIFY_SCREEN = 1_500

/** How often, and how far apart, a missing or older answer is read again before a turn is decided. */
export const ANSWER_LAG_RETRIES = 3
export const ANSWER_LAG_MS = 1_000

/** How much earlier than the turn's first `working` an answer may be stamped and still be this turn's. */
export const ANSWER_SLACK_MS = 2_000

/** The tools whose `ok` row means "this caller started a turn in that session". */
const TRIGGERS: readonly string[] = ['sessions.send', 'sessions.keys']

type Phase = 'quiet' | 'turn' | 'asked' | 'settling'

interface SessionTrack {
  phase: Phase
  /** Who started the turn in progress: `key:<id>`, `copilot`, or null when nobody known did. */
  trigger: string | null
  settle: unknown
  /** When the turn in progress was first seen, or null when none is. */
  startedAt: number | null
}

/** What is known about a finished turn when its notification is built. */
interface TurnFacts {
  trigger: string | null
  startedAt: number | null
  /** An app sent it or a hook ended it, so an answer should be in the transcript. */
  expectAnswer: boolean
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
  /** Queue one notification for one key, naming the turn it is about. `NotificationHub.enqueue`. */
  enqueue(keyId: string, event: NotificationEvent, turn?: string): boolean
  clock: DetectClock
  /** The newest thing the session's agent said. `latestAnswerOn`, unless a test hands one in. */
  answer?(meta: SessionMeta): Promise<Answer | null>
}

interface Built {
  event: NotificationEvent
  /** What the turn was, for a `finished`: no two notifications are sent for one. */
  turn?: string
}

function digest(text: string): string {
  return createHash('sha256').update(text).digest('base64url').slice(0, 22)
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
        if (track.phase === 'quiet') track.startedAt = this.deps.clock.now()
        track.phase = 'turn'
        return
      case 'input':
        this.cancelSettle(track)
        if (track.phase === 'quiet') track.startedAt = this.deps.clock.now()
        if (track.phase === 'asked') return
        track.phase = 'asked'
        this.emit(sessionId, 'needs-input', track.trigger)
        return
      case 'completed':
        // A hook saying the turn is over. Definitive, so no settle.
        if (track.phase === 'quiet') return
        this.finish(sessionId, track, true)
        return
      case 'waiting':
      case 'idle':
        if (track.phase !== 'turn' && track.phase !== 'asked') return
        track.phase = 'settling'
        this.cancelSettle(track)
        track.settle = this.deps.clock.setTimeout(() => {
          track.settle = null
          if (track.phase === 'settling') this.finish(sessionId, track, false)
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
    void this.build(sessionId, 'exited', null, exitCode).then((built) => {
      if (built !== null) this.deps.enqueue(keyId, built.event)
    })
  }

  /** Forget everything. Called at quit. */
  stop(): void {
    for (const track of this.tracks.values()) this.cancelSettle(track)
    this.tracks.clear()
  }

  /* ------------------------------------------------------------ inside -- */

  /** `definitive`: a hook ended the turn, rather than a calm screen. */
  private finish(sessionId: string, track: SessionTrack, definitive: boolean): void {
    this.cancelSettle(track)
    const facts: TurnFacts = {
      trigger: track.trigger,
      startedAt: track.startedAt,
      expectAnswer: track.trigger !== null || definitive,
    }
    track.phase = 'quiet'
    // The turn is over; the next one has no known trigger until a row names one.
    track.trigger = null
    track.startedAt = null
    this.emit(sessionId, 'finished', facts.trigger, facts)
  }

  /** Decide the recipient, then — only then — build and queue the notification. */
  private emit(sessionId: string, type: NotificationType, trigger: string | null, facts: TurnFacts | null = null): void {
    const keyId = trigger !== null ? keyIdOf(trigger) : keyIdOf(this.deps.starterOf(sessionId))
    if (keyId === null) return
    void this.build(sessionId, type, facts).then((built) => {
      if (built !== null) this.deps.enqueue(keyId, built.event, built.turn)
    })
  }

  private async build(
    sessionId: string,
    type: NotificationType,
    facts: TurnFacts | null,
    exitCode?: number,
  ): Promise<Built | null> {
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
        const event: NotificationEvent = {
          ...base,
          exitCode: code,
          crashed: code !== 0,
          suggestedTool: 'sessions_result',
          note:
            code === 0
              ? 'The session ended on its own. sessions_result reports what it did.'
              : `The session stopped with exit code ${code}. sessions_result reports what it did before it stopped.`,
        }
        return { event }
      }
      if (type === 'needs-input') {
        const screen = cap((await this.deps.surface.sessionScreen(sessionId)) ?? '', MAX_NOTIFY_SCREEN, true)
        const event: NotificationEvent = {
          ...base,
          screen,
          suggestedTool: 'sessions_keys',
          note:
            'The session stopped to ask something — a permission prompt, a menu or a question. The screen shows it. ' +
            'Answer with sessions_keys (for example ["1"] or ["enter"]) or type a reply with sessions_send.',
        }
        return { event }
      }
      const since = facts?.startedAt ?? null
      const fresh = (said: Answer | null): said is Answer =>
        said !== null && (since === null || said.at >= since - ANSWER_SLACK_MS)
      let answer = meta === undefined ? null : await this.answerOf(meta)
      if (meta !== undefined && facts?.expectAnswer === true) {
        for (let tries = 0; tries < ANSWER_LAG_RETRIES && !fresh(answer); tries += 1) {
          await this.pause(ANSWER_LAG_MS)
          answer = await this.answerOf(meta)
        }
      }
      if (fresh(answer)) {
        return {
          event: {
            ...base,
            answer: cap(answer.text, MAX_NOTIFY_ANSWER),
            suggestedTool: 'sessions_send',
            note: 'The session finished its turn. answer is the newest thing it said; sessions_transcript has the rest.',
          },
          turn: `answer:${answer.at}:${digest(answer.text)}`,
        }
      }
      // An agent that keeps a transcript, nothing in it, and no app sent this
      // turn: the screen redrawing — a Claude Code banner at start-up — not a turn.
      // An answer older than the turn is the last turn's, so it counts as none.
      if (meta !== undefined && (facts?.trigger ?? null) === null && writesTranscripts(meta.provider)) return null
      // No transcript — a shell, or an agent this app cannot read — so the screen is the answer.
      const screen = cap((await this.deps.surface.sessionScreen(sessionId)) ?? '', MAX_NOTIFY_SCREEN, true)
      return {
        event: {
          ...base,
          screen,
          suggestedTool: 'sessions_screen',
          note: 'The session finished its turn. It keeps no transcript, so screen shows its last lines.',
        },
        turn: `screen:${sessionId}:${digest(screen.text)}`,
      }
    } catch (error) {
      console.error('[notify] could not build a notification:', error instanceof Error ? error.message : String(error))
      return {
        event: { ...base, suggestedTool: 'sessions_get', note: 'Something changed in this session; sessions_get shows its state.' },
      }
    }
  }

  private pause(ms: number): Promise<void> {
    return new Promise((resolve) => this.deps.clock.setTimeout(resolve, ms))
  }

  private answerOf(meta: SessionMeta): Promise<Answer | null> {
    if (this.deps.answer) return this.deps.answer(meta)
    return latestAnswerOn(this.deps.surface as DeckSurface, { ...meta, resumed: meta.resumed === true })
  }

  private track(sessionId: string): SessionTrack {
    let track = this.tracks.get(sessionId)
    if (!track) {
      track = { phase: 'quiet', trigger: null, settle: null, startedAt: null }
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

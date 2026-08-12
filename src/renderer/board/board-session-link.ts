/**
 * Rules binding a kanban card to a session.
 *
 * A card can start a session and move itself to Done when that session
 * finishes. Everything here is pure: events in, `{ board, links, effects }`
 * out. The component that owns the board applies the new state and performs
 * the effects, which keeps every awkward transition — a session that dies
 * badly, a card deleted mid-run, a duplicated link — testable without a PTY.
 *
 * Three facts about this app shape the rules, and all three were established
 * by reading the code that actually emits the signals:
 *
 * 1. `SessionStatus` has a `'completed'` member, but `classify()` in
 *    `src/main/session-activity.ts` never returns it — it only ever produces
 *    idle / working / waiting / input / exited. A link that waited for
 *    `'completed'` would never fire, so completion is taken from the process
 *    exit instead.
 * 2. `'waiting'` is not "finished". Claude Code returns to its `❯` prompt after
 *    *every* reply, so a card that advanced on `'waiting'` would land in Done
 *    the moment the agent said hello. Only a clean process exit moves a card.
 * 3. A status event carries no exit code. `'exited'` therefore says a session
 *    ended but not whether it worked, so it is deliberately inert here: the
 *    `session-exit` event, which carries the code, is what resolves a link.
 *
 * The headline rule: a failure never moves a card to Done. A card that quietly
 * advanced on a crashed session is worse than no automation at all, because the
 * board would then be confidently wrong about what is finished.
 */

import type { SessionStatus } from '@shared/types'
import {
  columnOf,
  editCard,
  moveCard,
  removeCard,
  type BoardCard,
  type BoardState,
} from './board-state'

/* ------------------------------------------------------------------ types -- */

export type LinkPhase =
  /** Spawn requested; no session id yet. */
  | 'starting'
  /** A live session is working on the card. */
  | 'running'
  /** The session is asking the user something — the card wants attention. */
  | 'attention'
  /** Exited cleanly. This is the only phase that moves a card to Done. */
  | 'succeeded'
  /** Exited non-zero, or never started. The card is left exactly where it was. */
  | 'failed'
  /** The user closed the session. Not a success and not a failure. */
  | 'cancelled'

/** Phases that can no longer change. Reaching one is one-way. */
export const TERMINAL_PHASES: readonly LinkPhase[] = ['succeeded', 'failed', 'cancelled']

export function isTerminalPhase(phase: LinkPhase): boolean {
  return TERMINAL_PHASES.includes(phase)
}

export interface SessionLink {
  cardId: string
  /** Null while a spawn is in flight, and kept after the end as the record of
   *  which session this was — the card's own `sessionId` is cleared. */
  sessionId: string | null
  phase: LinkPhase
  exitCode: number | null
  error: string | null
  startedAt: number
  /** Set when the phase became terminal. */
  endedAt: number | null
  /** Guards against a replayed exit moving an already-advanced card twice. */
  movedToDone: boolean
}

/**
 * Live link state, keyed by card id.
 *
 * Deliberately not persisted: it describes processes, and no process survives
 * a restart — `App.tsx` restores the project list and explicitly not the
 * sessions. Writing this to the board file would resurrect "running" cards
 * pointing at sessions that died with the last window.
 */
export type LinkRegistry = Readonly<Record<string, SessionLink>>

export const EMPTY_REGISTRY: LinkRegistry = {}

export type LinkEvent =
  /** The user pressed run on a card. */
  | { type: 'start-requested'; cardId: string; resume?: boolean }
  /** The spawn returned a session id. */
  | { type: 'session-started'; cardId: string; sessionId: string }
  /** The spawn threw before any process existed. */
  | { type: 'start-failed'; cardId: string; error: string }
  | { type: 'session-status'; sessionId: string; status: SessionStatus }
  | { type: 'session-exit'; sessionId: string; exitCode: number }
  /** The user closed the tab. Distinct from an exit: it is nobody's failure. */
  | { type: 'session-closed'; sessionId: string }
  /** Removes the card *and* resolves its link. See `applyLinkEvent`. */
  | { type: 'card-deleted'; cardId: string }
  /** Detach without touching the session. */
  | { type: 'unlink'; cardId: string }

export type LinkEffect =
  | { type: 'spawn-session'; cardId: string; projectPath: string; title: string; resume: boolean }
  | { type: 'focus-session'; sessionId: string }
  /**
   * Its card is gone but the process is still alive — never killed silently.
   * `cardTitle` is null when the card was already deleted by the time the
   * session existed, so there is no longer a title to name it by.
   */
  | { type: 'session-orphaned'; sessionId: string; cardTitle: string | null }
  | { type: 'announce'; level: 'info' | 'warn' | 'error'; cardId: string; message: string }

export interface LinkResult {
  board: BoardState
  links: LinkRegistry
  effects: LinkEffect[]
}

/* ---------------------------------------------------------------- helpers -- */

/**
 * Own-property registry lookup, for the same reason `board-state` does it:
 * card ids come out of a board file, so `links['constructor']` is otherwise
 * truthy on an empty registry and every field read off it throws.
 */
function getLink(links: LinkRegistry, cardId: string): SessionLink | undefined {
  return Object.prototype.hasOwnProperty.call(links, cardId) ? links[cardId] : undefined
}

function withLink(links: LinkRegistry, link: SessionLink): LinkRegistry {
  // Assigning `__proto__` calls the inherited setter instead of creating an own
  // property: the link would vanish while re-parenting the registry.
  if (!link.cardId || link.cardId === '__proto__') return links
  return { ...links, [link.cardId]: link }
}

function withoutLink(links: LinkRegistry, cardId: string): LinkRegistry {
  if (!getLink(links, cardId)) return links
  const next = { ...links }
  delete next[cardId]
  return next
}

function findCard(board: BoardState, cardId: string): BoardCard | undefined {
  return Object.prototype.hasOwnProperty.call(board.cards, cardId) ? board.cards[cardId] : undefined
}

/** Cards carrying a session id, in board order (todo → doing → done, top down). */
export function linkedCards(board: BoardState): BoardCard[] {
  const out: BoardCard[] = []
  for (const column of board.columns) {
    for (const id of column.cardIds) {
      const card = findCard(board, id)
      if (card?.sessionId) out.push(card)
    }
  }
  return out
}

/**
 * Which card a session belongs to.
 *
 * Board order decides, so the answer is stable rather than dependent on object
 * key ordering. Two cards *can* claim one session — a board file edited by
 * hand, or a card duplicated while its session ran — and the first one owns it.
 * `duplicateLinks` surfaces the rest rather than letting them rot unseen.
 */
export function findCardForSession(board: BoardState, sessionId: string): BoardCard | null {
  if (!sessionId) return null
  return linkedCards(board).find((card) => card.sessionId === sessionId) ?? null
}

/** Session ids claimed by more than one card, with every claimant in board order. */
export function duplicateLinks(board: BoardState): Array<{ sessionId: string; cardIds: string[] }> {
  const bySession = new Map<string, string[]>()
  for (const card of linkedCards(board)) {
    const sessionId = card.sessionId as string
    const ids = bySession.get(sessionId)
    if (ids) ids.push(card.id)
    else bySession.set(sessionId, [card.id])
  }
  return [...bySession.entries()]
    .filter(([, ids]) => ids.length > 1)
    .map(([sessionId, cardIds]) => ({ sessionId, cardIds }))
}

export function linkFor(links: LinkRegistry, cardId: string): SessionLink | null {
  return getLink(links, cardId) ?? null
}

/** A link with a session that has not finished — something is still running. */
export function isLive(link: SessionLink | null | undefined): boolean {
  return link !== null && link !== undefined && !isTerminalPhase(link.phase)
}

/** What the card's run button should offer right now. */
export function cardAction(
  board: BoardState,
  links: LinkRegistry,
  cardId: string,
): 'start' | 'open' | 'retry' | 'none' {
  if (!findCard(board, cardId)) return 'none'
  const link = getLink(links, cardId)
  if (isLive(link)) return 'open'
  if (link?.phase === 'failed' || link?.phase === 'cancelled') return 'retry'
  return 'start'
}

/** One line of status for the card, in the user's terms rather than ours. */
export function describeLink(link: SessionLink): string {
  switch (link.phase) {
    case 'starting':
      return 'Starting a session…'
    case 'running':
      return 'Session running'
    case 'attention':
      return 'Session needs you'
    case 'succeeded':
      return 'Session finished — moved to Done'
    case 'cancelled':
      return 'Session closed before it finished'
    case 'failed':
      return link.exitCode !== null && link.exitCode !== 0
        ? `Session failed (exit ${link.exitCode})`
        : `Session failed${link.error ? ` — ${link.error}` : ''}`
  }
}

function result(board: BoardState, links: LinkRegistry, effects: LinkEffect[] = []): LinkResult {
  return { board, links, effects }
}

/**
 * Finish a link without moving the card.
 *
 * Also clears the card's `sessionId`: a Deck session id is a handle on a live
 * process, so once that process is gone the id points at nothing and the chip
 * on the card would be a button that cannot do anything. The registry keeps the
 * id so the outcome can still be explained.
 */
function settle(
  board: BoardState,
  links: LinkRegistry,
  link: SessionLink,
  patch: Partial<SessionLink>,
  now: number,
): { board: BoardState; links: LinkRegistry } {
  const next: SessionLink = { ...link, ...patch, endedAt: now }
  return {
    board: editCard(board, link.cardId, { sessionId: null }),
    links: withLink(links, next),
  }
}

/* --------------------------------------------------------------- reducer -- */

/**
 * Apply one event.
 *
 * `card-deleted` is handled here rather than by the caller calling `removeCard`
 * first, because the link can only be read off a card that still exists — do
 * the removal outside and the session id is already gone by the time this runs,
 * which is precisely how a session ends up orphaned with nothing reporting it.
 */
export function applyLinkEvent(
  board: BoardState,
  links: LinkRegistry,
  event: LinkEvent,
  now: number = Date.now(),
): LinkResult {
  switch (event.type) {
    case 'start-requested': {
      const card = findCard(board, event.cardId)
      if (!card) return result(board, links)

      const existing = getLink(links, event.cardId)
      // A live session is not restarted — focus it. Running a second agent in
      // the same folder for the same card is how two sessions end up editing
      // the same files without knowing about each other.
      if (isLive(existing)) {
        // A spawn already in flight has no id to focus yet. It still counts as
        // live: gating on the id let a second press — a double click, or a
        // re-render that re-dispatched — through, and the card spawned twice.
        // The first process would then be orphaned by its own card.
        return existing?.sessionId
          ? result(board, links, [{ type: 'focus-session', sessionId: existing.sessionId }])
          : result(board, links)
      }

      const link: SessionLink = {
        cardId: card.id,
        sessionId: null,
        phase: 'starting',
        exitCode: null,
        error: null,
        startedAt: now,
        endedAt: null,
        movedToDone: false,
      }
      return result(board, withLink(links, link), [
        {
          type: 'spawn-session',
          cardId: card.id,
          projectPath: board.projectPath,
          title: card.title,
          // Resuming asks the provider to continue the last session in this
          // folder (`claude --continue`), which is what a retry wants.
          resume: event.resume ?? false,
        },
      ])
    }

    case 'session-started': {
      if (!event.sessionId) return result(board, links)
      const card = findCard(board, event.cardId)
      // The card was deleted while its spawn was still in flight. The process
      // is real and running; without this it would be left with nothing
      // pointing at it and no way for the user to learn it exists.
      if (!card) {
        return result(board, withoutLink(links, event.cardId), [
          { type: 'session-orphaned', sessionId: event.sessionId, cardTitle: null },
        ])
      }

      const effects: LinkEffect[] = []
      const previous = getLink(links, event.cardId)
      // Re-linking a card that still has a live session leaves that process
      // running with nothing pointing at it. Say so; never kill it from here.
      if (isLive(previous) && previous?.sessionId && previous.sessionId !== event.sessionId) {
        effects.push({ type: 'session-orphaned', sessionId: previous.sessionId, cardTitle: card.title })
      }

      const link: SessionLink = {
        cardId: card.id,
        sessionId: event.sessionId,
        phase: 'running',
        exitCode: null,
        error: null,
        startedAt: previous?.startedAt ?? now,
        endedAt: null,
        movedToDone: false,
      }

      let next = editCard(board, card.id, { sessionId: event.sessionId })
      // Work has started, so the card belongs in Doing. Only from Todo: a card
      // the user has already filed elsewhere is theirs to place.
      if (columnOf(next, card.id) === 'todo') next = moveCard(next, card.id, 'doing', 0)

      return result(next, withLink(links, link), effects)
    }

    case 'start-failed': {
      const card = findCard(board, event.cardId)
      if (!card) return result(board, links)
      const link = getLink(links, event.cardId) ?? {
        cardId: card.id,
        sessionId: null,
        phase: 'starting' as LinkPhase,
        exitCode: null,
        error: null,
        startedAt: now,
        endedAt: null,
        movedToDone: false,
      }
      const settled = settle(board, links, link, { phase: 'failed', error: event.error }, now)
      return result(settled.board, settled.links, [
        { type: 'announce', level: 'error', cardId: card.id, message: event.error },
      ])
    }

    case 'session-status': {
      const card = findCardForSession(board, event.sessionId)
      if (!card) return result(board, links)
      const link = getLink(links, card.id)
      if (!link || isTerminalPhase(link.phase)) return result(board, links)

      // 'exited' is intentionally inert: it says a session ended, not whether
      // it worked, and acting on it would resolve every link as a success.
      const phase: LinkPhase | null =
        event.status === 'input' ? 'attention' : event.status === 'exited' ? null : 'running'
      if (phase === null || phase === link.phase) return result(board, links)

      return result(board, withLink(links, { ...link, phase }))
    }

    case 'session-exit': {
      // Resolved from the board, not the registry: an exit can land before the
      // `session-started` bookkeeping does, and a card whose session already
      // finished must still advance.
      const card = findCardForSession(board, event.sessionId)
      if (!card) return result(board, links)

      const link: SessionLink = getLink(links, card.id) ?? {
        cardId: card.id,
        sessionId: event.sessionId,
        phase: 'running',
        exitCode: null,
        error: null,
        startedAt: now,
        endedAt: null,
        movedToDone: false,
      }
      // Terminal phases are sticky. Closing a tab emits `session-closed` and
      // then, moments later, the process's own non-zero exit — without this a
      // deliberate close would be reported to the user as a crash.
      if (isTerminalPhase(link.phase)) return result(board, links)

      if (event.exitCode !== 0) {
        const settled = settle(
          board,
          links,
          link,
          { phase: 'failed', exitCode: event.exitCode },
          now,
        )
        return result(settled.board, settled.links, [
          {
            type: 'announce',
            level: 'error',
            cardId: card.id,
            message: `“${card.title}” did not finish — its session exited with code ${event.exitCode}.`,
          },
        ])
      }

      const alreadyDone = columnOf(board, card.id) === 'done'
      const settled = settle(
        board,
        links,
        link,
        { phase: 'succeeded', exitCode: 0, movedToDone: !alreadyDone },
        now,
      )
      // Top of Done, so the thing that just finished is the thing you see.
      const moved = alreadyDone ? settled.board : moveCard(settled.board, card.id, 'done', 0)
      return result(moved, settled.links, [
        {
          type: 'announce',
          level: 'info',
          cardId: card.id,
          message: `“${card.title}” finished.`,
        },
      ])
    }

    case 'session-closed': {
      const card = findCardForSession(board, event.sessionId)
      if (!card) return result(board, links)
      const link = getLink(links, card.id)
      if (!link || isTerminalPhase(link.phase)) {
        // No registry entry, but the card still points at a dead session; clear
        // the stale id so the card offers to start again instead of nothing.
        return result(editCard(board, card.id, { sessionId: null }), links)
      }
      const settled = settle(board, links, link, { phase: 'cancelled' }, now)
      return result(settled.board, settled.links)
    }

    case 'card-deleted': {
      const card = findCard(board, event.cardId)
      if (!card) return result(board, links)

      const link = getLink(links, card.id)
      const effects: LinkEffect[] = []
      // The card is the user's; the process is the agent's. Deleting the card
      // must not take a running agent down with it, so the session is reported
      // as orphaned and left for the user to close.
      const runningSessionId = isLive(link) ? (link?.sessionId ?? card.sessionId) : null
      if (runningSessionId) {
        effects.push({ type: 'session-orphaned', sessionId: runningSessionId, cardTitle: card.title })
      }

      // The registry entry goes with the card: it is keyed by card id, so
      // keeping it would leave a record nothing can ever reach or clear.
      return result(removeCard(board, card.id), withoutLink(links, card.id), effects)
    }

    case 'unlink': {
      const card = findCard(board, event.cardId)
      if (!card) return result(board, links)
      const link = getLink(links, card.id)
      const effects: LinkEffect[] = []
      const runningSessionId = isLive(link) ? (link?.sessionId ?? card.sessionId) : null
      if (runningSessionId) {
        effects.push({ type: 'session-orphaned', sessionId: runningSessionId, cardTitle: card.title })
      }
      return result(
        editCard(board, card.id, { sessionId: null }),
        withoutLink(links, card.id),
        effects,
      )
    }
  }
}

/** Fold a batch of events, threading board and registry through each one. */
export function applyLinkEvents(
  board: BoardState,
  links: LinkRegistry,
  events: readonly LinkEvent[],
  now: number = Date.now(),
): LinkResult {
  let state = result(board, links)
  for (const event of events) {
    const next = applyLinkEvent(state.board, state.links, event, now)
    state = result(next.board, next.links, [...state.effects, ...next.effects])
  }
  return state
}

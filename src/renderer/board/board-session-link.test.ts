import { describe, expect, it } from 'vitest'
import { addCard, columnOf, createBoard, moveCard, type BoardState, type ColumnId } from './board-state'
import {
  applyLinkEvent,
  applyLinkEvents,
  cardAction,
  describeLink,
  duplicateLinks,
  EMPTY_REGISTRY,
  findCardForSession,
  isLive,
  isTerminalPhase,
  linkedCards,
  linkFor,
  type LinkEvent,
  type LinkRegistry,
  type LinkResult,
  type SessionLink,
} from './board-session-link'

const PROJECT = '/Users/asad/Projects/pawl'
const T0 = 1_700_000_000_000

function seed(cards: Array<{ id: string; column?: ColumnId; sessionId?: string }>): BoardState {
  let state = createBoard(PROJECT)
  for (const card of cards) {
    state = addCard(state, {
      id: card.id,
      title: card.id.toUpperCase(),
      columnId: card.column ?? 'todo',
      sessionId: card.sessionId ?? null,
      createdAt: 1,
    })
  }
  return state
}

/** Run a script of events from an empty registry. */
function run(board: BoardState, events: LinkEvent[], links: LinkRegistry = EMPTY_REGISTRY): LinkResult {
  return applyLinkEvents(board, links, events, T0)
}

/** Get a card to a live linked session in one step, the way the app does. */
function started(board: BoardState, cardId: string, sessionId: string): LinkResult {
  return run(board, [
    { type: 'start-requested', cardId },
    { type: 'session-started', cardId, sessionId },
  ])
}

function link(result: LinkResult, cardId: string): SessionLink {
  const found = linkFor(result.links, cardId)
  if (!found) throw new Error(`no link for ${cardId}`)
  return found
}

describe('selectors', () => {
  it('finds the card a session belongs to', () => {
    const board = seed([{ id: 'a' }, { id: 'b', sessionId: 's1' }])
    expect(findCardForSession(board, 's1')?.id).toBe('b')
    expect(findCardForSession(board, 'nope')).toBeNull()
    expect(findCardForSession(board, '')).toBeNull()
  })

  it('lists linked cards in board order, not key order', () => {
    let board = seed([
      { id: 'a', sessionId: 's1' },
      { id: 'b', sessionId: 's2' },
      { id: 'c' },
    ])
    board = moveCard(board, 'b', 'todo', 0)
    expect(linkedCards(board).map((c) => c.id)).toEqual(['b', 'a'])
  })

  it('gives one session to the first claiming card and reports the rest', () => {
    const board = seed([
      { id: 'a', sessionId: 'dupe' },
      { id: 'b', sessionId: 'dupe' },
      { id: 'c', sessionId: 'own' },
    ])
    expect(findCardForSession(board, 'dupe')?.id).toBe('a')
    expect(duplicateLinks(board)).toEqual([{ sessionId: 'dupe', cardIds: ['a', 'b'] }])
  })

  it('survives a card id that collides with Object.prototype', () => {
    const board = seed([{ id: 'constructor' }, { id: 'toString', sessionId: 's1' }])
    expect(findCardForSession(board, 's1')?.id).toBe('toString')
    expect(cardAction(board, EMPTY_REGISTRY, 'constructor')).toBe('start')
    // A registry that has never seen this id must not hand back a function.
    expect(linkFor(EMPTY_REGISTRY, 'constructor')).toBeNull()
    expect(linkFor(EMPTY_REGISTRY, 'valueOf')).toBeNull()
  })

  it('knows which phases can still change', () => {
    expect(isTerminalPhase('running')).toBe(false)
    expect(isTerminalPhase('attention')).toBe(false)
    expect(isTerminalPhase('starting')).toBe(false)
    expect(isTerminalPhase('succeeded')).toBe(true)
    expect(isTerminalPhase('failed')).toBe(true)
    expect(isTerminalPhase('cancelled')).toBe(true)
    expect(isLive(null)).toBe(false)
  })
})

describe('starting a session', () => {
  it('asks for a spawn carrying the project and the card title', () => {
    const board = seed([{ id: 'a' }])
    const out = run(board, [{ type: 'start-requested', cardId: 'a' }])
    expect(out.effects).toEqual([
      { type: 'spawn-session', cardId: 'a', projectPath: PROJECT, title: 'A', resume: false },
    ])
    expect(link(out, 'a').phase).toBe('starting')
    // Nothing has actually started, so the card must not claim a session yet.
    expect(out.board.cards.a.sessionId).toBeNull()
  })

  it('passes resume through for a retry', () => {
    const out = run(seed([{ id: 'a' }]), [{ type: 'start-requested', cardId: 'a', resume: true }])
    expect(out.effects[0]).toMatchObject({ type: 'spawn-session', resume: true })
  })

  it('focuses a live session instead of spawning a second one', () => {
    const first = started(seed([{ id: 'a' }]), 'a', 's1')
    const out = applyLinkEvent(first.board, first.links, { type: 'start-requested', cardId: 'a' }, T0)
    expect(out.effects).toEqual([{ type: 'focus-session', sessionId: 's1' }])
    expect(out.board).toBe(first.board)
  })

  it('does not spawn a second session while the first spawn is still in flight', () => {
    // Regression: the guard also required a session id, and a card that has
    // only just been asked to start has none yet — so a double click, or a
    // re-render that re-dispatched, spawned two agents in the same folder.
    const out = run(seed([{ id: 'a' }]), [
      { type: 'start-requested', cardId: 'a' },
      { type: 'start-requested', cardId: 'a' },
      { type: 'start-requested', cardId: 'a', resume: true },
    ])
    expect(out.effects.filter((e) => e.type === 'spawn-session')).toHaveLength(1)
    expect(link(out, 'a').phase).toBe('starting')
    expect(link(out, 'a').startedAt).toBe(T0)

    // …and the first process is still the one the card ends up holding.
    const settled = applyLinkEvent(
      out.board,
      out.links,
      { type: 'session-started', cardId: 'a', sessionId: 's1' },
      T0,
    )
    expect(settled.effects).toEqual([])
    expect(settled.board.cards.a.sessionId).toBe('s1')
  })

  it('starts again once the previous run has finished', () => {
    // The guard is about live links only — a settled one must not wedge the
    // card so it can never be run a second time.
    const done = run(seed([{ id: 'a' }]), [
      { type: 'start-requested', cardId: 'a' },
      { type: 'session-started', cardId: 'a', sessionId: 's1' },
      { type: 'session-exit', sessionId: 's1', exitCode: 1 },
    ])
    const out = applyLinkEvent(done.board, done.links, { type: 'start-requested', cardId: 'a', resume: true }, T0)
    expect(out.effects).toEqual([
      { type: 'spawn-session', cardId: 'a', projectPath: PROJECT, title: 'A', resume: true },
    ])
  })

  it('moves the card from Todo into Doing once the session exists', () => {
    const out = started(seed([{ id: 'a' }]), 'a', 's1')
    expect(columnOf(out.board, 'a')).toBe('doing')
    expect(out.board.cards.a.sessionId).toBe('s1')
    expect(link(out, 'a').phase).toBe('running')
  })

  it('leaves a card the user already filed where it is', () => {
    const out = started(seed([{ id: 'a', column: 'done' }]), 'a', 's1')
    expect(columnOf(out.board, 'a')).toBe('done')
  })

  it('ignores events for a card that does not exist', () => {
    const board = seed([{ id: 'a' }])
    for (const event of [
      { type: 'start-requested', cardId: 'ghost' },
      { type: 'start-failed', cardId: 'ghost', error: 'boom' },
      { type: 'card-deleted', cardId: 'ghost' },
      { type: 'unlink', cardId: 'ghost' },
    ] satisfies LinkEvent[]) {
      const out = applyLinkEvent(board, EMPTY_REGISTRY, event, T0)
      expect(out.board).toBe(board)
      expect(out.links).toBe(EMPTY_REGISTRY)
      expect(out.effects).toEqual([])
    }
  })

  it('reports a session whose card was deleted while the spawn was in flight', () => {
    const board = seed([{ id: 'a' }])
    const requested = applyLinkEvent(board, EMPTY_REGISTRY, { type: 'start-requested', cardId: 'a' }, T0)
    const deleted = applyLinkEvent(requested.board, requested.links, { type: 'card-deleted', cardId: 'a' }, T0)
    // The spawn promise resolves after the card is gone. The process is real.
    const out = applyLinkEvent(
      deleted.board,
      deleted.links,
      { type: 'session-started', cardId: 'a', sessionId: 's1' },
      T0,
    )
    expect(out.effects).toEqual([{ type: 'session-orphaned', sessionId: 's1', cardTitle: null }])
    expect(linkFor(out.links, 'a')).toBeNull()
  })

  it('reports the old session as orphaned when a card is re-linked mid-run', () => {
    const first = started(seed([{ id: 'a' }]), 'a', 's1')
    const out = applyLinkEvent(
      first.board,
      first.links,
      { type: 'session-started', cardId: 'a', sessionId: 's2' },
      T0,
    )
    expect(out.effects).toEqual([{ type: 'session-orphaned', sessionId: 's1', cardTitle: 'A' }])
    expect(out.board.cards.a.sessionId).toBe('s2')
    expect(link(out, 'a').sessionId).toBe('s2')
  })

  it('records a spawn that never produced a process as failed, not done', () => {
    const out = run(seed([{ id: 'a' }]), [
      { type: 'start-requested', cardId: 'a' },
      { type: 'start-failed', cardId: 'a', error: 'claude: command not found' },
    ])
    expect(link(out, 'a').phase).toBe('failed')
    expect(columnOf(out.board, 'a')).toBe('todo')
    expect(out.effects.at(-1)).toEqual({
      type: 'announce',
      level: 'error',
      cardId: 'a',
      message: 'claude: command not found',
    })
  })
})

describe('status while running', () => {
  it('raises the card to attention when the agent asks a question', () => {
    const live = started(seed([{ id: 'a' }]), 'a', 's1')
    const out = applyLinkEvent(
      live.board,
      live.links,
      { type: 'session-status', sessionId: 's1', status: 'input' },
      T0,
    )
    expect(link(out, 'a').phase).toBe('attention')
    expect(cardAction(out.board, out.links, 'a')).toBe('open')
  })

  it('does not treat a return to the prompt as completion', () => {
    // Claude Code sits at its ❯ prompt after every reply, so `waiting` arrives
    // constantly. Advancing on it would file every card under Done immediately.
    const live = started(seed([{ id: 'a' }]), 'a', 's1')
    for (const status of ['waiting', 'idle', 'working'] as const) {
      const out = applyLinkEvent(
        live.board,
        live.links,
        { type: 'session-status', sessionId: 's1', status },
        T0,
      )
      expect(columnOf(out.board, 'a')).toBe('doing')
      expect(link(out, 'a').phase).toBe('running')
    }
  })

  it('ignores the exited status, which carries no exit code', () => {
    const live = started(seed([{ id: 'a' }]), 'a', 's1')
    const out = applyLinkEvent(
      live.board,
      live.links,
      { type: 'session-status', sessionId: 's1', status: 'exited' },
      T0,
    )
    expect(link(out, 'a').phase).toBe('running')
    expect(columnOf(out.board, 'a')).toBe('doing')
  })

  it('ignores status for an unknown or already finished session', () => {
    const done = run(seed([{ id: 'a' }]), [
      { type: 'start-requested', cardId: 'a' },
      { type: 'session-started', cardId: 'a', sessionId: 's1' },
      { type: 'session-exit', sessionId: 's1', exitCode: 0 },
    ])
    const out = applyLinkEvent(
      done.board,
      done.links,
      { type: 'session-status', sessionId: 's1', status: 'working' },
      T0,
    )
    expect(out.board).toBe(done.board)
    expect(link(out, 'a').phase).toBe('succeeded')
  })
})

describe('completion', () => {
  it('moves the card to the top of Done on a clean exit', () => {
    let board = seed([{ id: 'a' }, { id: 'old', column: 'done' }])
    const live = started(board, 'a', 's1')
    const out = applyLinkEvent(
      live.board,
      live.links,
      { type: 'session-exit', sessionId: 's1', exitCode: 0 },
      T0 + 5,
    )
    board = out.board
    expect(board.columns[2].cardIds).toEqual(['a', 'old'])
    const l = link(out, 'a')
    expect(l.phase).toBe('succeeded')
    expect(l.exitCode).toBe(0)
    expect(l.endedAt).toBe(T0 + 5)
    expect(l.movedToDone).toBe(true)
    // The process is gone, so the handle on it is worthless.
    expect(board.cards.a.sessionId).toBeNull()
  })

  it('resolves a card even when the exit beats the session-started bookkeeping', () => {
    // The board already carries the id (the spawn wrote it) but the registry
    // has no entry yet. Resolving from the registry alone would drop this.
    const board = seed([{ id: 'a', column: 'doing', sessionId: 's1' }])
    const out = applyLinkEvent(board, EMPTY_REGISTRY, { type: 'session-exit', sessionId: 's1', exitCode: 0 }, T0)
    expect(columnOf(out.board, 'a')).toBe('done')
    expect(link(out, 'a').phase).toBe('succeeded')
  })

  it('does not move a card twice when the exit is replayed', () => {
    const live = started(seed([{ id: 'a' }, { id: 'b', column: 'done' }]), 'a', 's1')
    const first = applyLinkEvent(
      live.board,
      live.links,
      { type: 'session-exit', sessionId: 's1', exitCode: 0 },
      T0,
    )
    const second = applyLinkEvent(
      first.board,
      first.links,
      { type: 'session-exit', sessionId: 's1', exitCode: 0 },
      T0,
    )
    // The card's session id was cleared, so the replay resolves to nothing.
    expect(second.board).toBe(first.board)
    expect(first.board.columns[2].cardIds).toEqual(['a', 'b'])
  })

  it('leaves a card the user already dragged to Done alone', () => {
    const live = started(seed([{ id: 'a', column: 'done' }]), 'a', 's1')
    const out = applyLinkEvent(
      live.board,
      live.links,
      { type: 'session-exit', sessionId: 's1', exitCode: 0 },
      T0,
    )
    expect(out.board.columns[2].cardIds).toEqual(['a'])
    expect(link(out, 'a').movedToDone).toBe(false)
  })

  it('only moves the first card when two claim the same session', () => {
    const board = seed([
      { id: 'a', column: 'doing', sessionId: 'dupe' },
      { id: 'b', column: 'doing', sessionId: 'dupe' },
    ])
    const out = applyLinkEvent(board, EMPTY_REGISTRY, { type: 'session-exit', sessionId: 'dupe', exitCode: 0 }, T0)
    expect(columnOf(out.board, 'a')).toBe('done')
    expect(columnOf(out.board, 'b')).toBe('doing')
  })
})

describe('failure', () => {
  it('never moves a card to Done on a non-zero exit', () => {
    const live = started(seed([{ id: 'a' }]), 'a', 's1')
    const out = applyLinkEvent(
      live.board,
      live.links,
      { type: 'session-exit', sessionId: 's1', exitCode: 1 },
      T0 + 9,
    )
    expect(columnOf(out.board, 'a')).toBe('doing')
    const l = link(out, 'a')
    expect(l.phase).toBe('failed')
    expect(l.exitCode).toBe(1)
    expect(l.movedToDone).toBe(false)
    expect(l.endedAt).toBe(T0 + 9)
    expect(out.effects.at(-1)).toMatchObject({ type: 'announce', level: 'error', cardId: 'a' })
    expect(cardAction(out.board, out.links, 'a')).toBe('retry')
  })

  it('does not drag a card back out of Done when a later session fails', () => {
    // The user moved it themselves; a failed run does not overrule that.
    const live = started(seed([{ id: 'a', column: 'done' }]), 'a', 's1')
    const out = applyLinkEvent(
      live.board,
      live.links,
      { type: 'session-exit', sessionId: 's1', exitCode: 137 },
      T0,
    )
    expect(columnOf(out.board, 'a')).toBe('done')
    expect(link(out, 'a').phase).toBe('failed')
  })

  it('reads a signal-shaped exit code as a failure, not a success', () => {
    const live = started(seed([{ id: 'a' }]), 'a', 's1')
    const out = applyLinkEvent(
      live.board,
      live.links,
      { type: 'session-exit', sessionId: 's1', exitCode: 129 },
      T0,
    )
    expect(link(out, 'a').phase).toBe('failed')
    expect(columnOf(out.board, 'a')).not.toBe('done')
  })
})

describe('closing a session', () => {
  it('records a user close as cancelled rather than failed', () => {
    const live = started(seed([{ id: 'a' }]), 'a', 's1')
    const out = applyLinkEvent(live.board, live.links, { type: 'session-closed', sessionId: 's1' }, T0)
    expect(link(out, 'a').phase).toBe('cancelled')
    expect(columnOf(out.board, 'a')).toBe('doing')
    expect(out.board.cards.a.sessionId).toBeNull()
    expect(describeLink(link(out, 'a'))).toBe('Session closed before it finished')
  })

  it('does not let the kill signal that follows a close report as a crash', () => {
    // `killSession` kills the process, so a non-zero exit arrives right after
    // the close. Terminal phases are sticky precisely for this ordering.
    const live = started(seed([{ id: 'a' }]), 'a', 's1')
    const closed = applyLinkEvent(live.board, live.links, { type: 'session-closed', sessionId: 's1' }, T0)
    const after = applyLinkEvent(
      closed.board,
      closed.links,
      { type: 'session-exit', sessionId: 's1', exitCode: 129 },
      T0,
    )
    expect(link(after, 'a').phase).toBe('cancelled')
    expect(after.effects).toEqual([])
  })

  it('clears a stale session id even with no registry entry', () => {
    const board = seed([{ id: 'a', column: 'doing', sessionId: 's1' }])
    const out = applyLinkEvent(board, EMPTY_REGISTRY, { type: 'session-closed', sessionId: 's1' }, T0)
    expect(out.board.cards.a.sessionId).toBeNull()
    expect(cardAction(out.board, out.links, 'a')).toBe('start')
  })
})

describe('deleting a card mid-run', () => {
  it('removes the card and reports the still-running session', () => {
    const live = started(seed([{ id: 'a' }, { id: 'b' }]), 'a', 's1')
    const out = applyLinkEvent(live.board, live.links, { type: 'card-deleted', cardId: 'a' }, T0)

    expect(out.board.cards.a).toBeUndefined()
    expect(out.board.columns.flatMap((c) => c.cardIds)).toEqual(['b'])
    expect(out.effects).toEqual([{ type: 'session-orphaned', sessionId: 's1', cardTitle: 'A' }])
    // Nothing can reach a link keyed by a card that no longer exists.
    expect(linkFor(out.links, 'a')).toBeNull()
  })

  it('says nothing about a session that had already finished', () => {
    const done = run(seed([{ id: 'a' }]), [
      { type: 'start-requested', cardId: 'a' },
      { type: 'session-started', cardId: 'a', sessionId: 's1' },
      { type: 'session-exit', sessionId: 's1', exitCode: 0 },
    ])
    const out = applyLinkEvent(done.board, done.links, { type: 'card-deleted', cardId: 'a' }, T0)
    expect(out.effects).toEqual([])
  })

  it('does not invent an orphan from a session id left in the board file', () => {
    // `sessionId` is persisted, so after a restart every card that ever ran
    // still carries one — for a process that died with the last window. Only
    // the registry knows what is actually running.
    const board = seed([{ id: 'a', column: 'doing', sessionId: 's1' }])
    const out = applyLinkEvent(board, EMPTY_REGISTRY, { type: 'card-deleted', cardId: 'a' }, T0)
    expect(out.effects).toEqual([])
    expect(out.board.cards.a).toBeUndefined()
  })

  it('is a no-op for the session events that arrive after the card is gone', () => {
    const live = started(seed([{ id: 'a' }]), 'a', 's1')
    const deleted = applyLinkEvent(live.board, live.links, { type: 'card-deleted', cardId: 'a' }, T0)

    for (const event of [
      { type: 'session-status', sessionId: 's1', status: 'working' },
      { type: 'session-exit', sessionId: 's1', exitCode: 0 },
      { type: 'session-closed', sessionId: 's1' },
    ] satisfies LinkEvent[]) {
      const out = applyLinkEvent(deleted.board, deleted.links, event, T0)
      expect(out.board).toBe(deleted.board)
      expect(out.links).toBe(deleted.links)
      expect(out.effects).toEqual([])
    }
  })
})

describe('unlinking', () => {
  it('detaches the card and flags the session it left running', () => {
    const live = started(seed([{ id: 'a' }]), 'a', 's1')
    const out = applyLinkEvent(live.board, live.links, { type: 'unlink', cardId: 'a' }, T0)
    expect(out.board.cards.a.sessionId).toBeNull()
    expect(out.board.cards.a.title).toBe('A')
    expect(columnOf(out.board, 'a')).toBe('doing')
    expect(out.effects).toEqual([{ type: 'session-orphaned', sessionId: 's1', cardTitle: 'A' }])
    expect(cardAction(out.board, out.links, 'a')).toBe('start')
  })
})

describe('purity', () => {
  it('never mutates the board or registry it was handed', () => {
    const board = seed([{ id: 'a' }])
    const snapshot = JSON.stringify(board)
    const links: LinkRegistry = EMPTY_REGISTRY
    const out = run(board, [
      { type: 'start-requested', cardId: 'a' },
      { type: 'session-started', cardId: 'a', sessionId: 's1' },
      { type: 'session-exit', sessionId: 's1', exitCode: 0 },
    ])
    expect(JSON.stringify(board)).toBe(snapshot)
    expect(links).toEqual({})
    expect(out.board).not.toBe(board)
  })

  it('describes every phase without falling through', () => {
    const base: SessionLink = {
      cardId: 'a',
      sessionId: 's1',
      phase: 'running',
      exitCode: null,
      error: null,
      startedAt: T0,
      endedAt: null,
      movedToDone: false,
    }
    expect(describeLink({ ...base, phase: 'starting' })).toMatch(/Starting/)
    expect(describeLink({ ...base, phase: 'running' })).toBe('Session running')
    expect(describeLink({ ...base, phase: 'attention' })).toMatch(/needs you/)
    expect(describeLink({ ...base, phase: 'succeeded' })).toMatch(/Done/)
    expect(describeLink({ ...base, phase: 'failed', exitCode: 2 })).toBe('Session failed (exit 2)')
    expect(describeLink({ ...base, phase: 'failed', error: 'no such CLI' })).toBe(
      'Session failed — no such CLI',
    )
  })
})

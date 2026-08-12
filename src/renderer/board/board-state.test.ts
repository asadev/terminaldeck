import { describe, expect, it } from 'vitest'
import {
  addCard,
  allTags,
  cardsInColumn,
  columnOf,
  countCards,
  createBoard,
  editCard,
  filterBoard,
  indexOf,
  isFilterActive,
  matchesFilter,
  moveCard,
  moveCardBefore,
  normaliseTags,
  nudgeCard,
  parseBoard,
  parseCardInput,
  removeCard,
  shiftCardColumn,
  type BoardState,
  type ColumnId,
} from './board-state'

/** Build a board with deterministic ids so assertions can read as `['a','b','c']`. */
function seed(
  todo: string[] = [],
  doing: string[] = [],
  done: string[] = [],
): BoardState {
  let state = createBoard('/Users/asad/Projects/terminaldeck')
  const fill = (ids: string[], columnId: ColumnId) => {
    for (const id of ids) {
      state = addCard(state, { id, title: id.toUpperCase(), columnId, createdAt: 1 })
    }
  }
  fill(todo, 'todo')
  fill(doing, 'doing')
  fill(done, 'done')
  return state
}

/** Compact view of the whole board, for readable order assertions. */
function order(state: BoardState): Record<ColumnId, string[]> {
  return {
    todo: state.columns[0].cardIds,
    doing: state.columns[1].cardIds,
    done: state.columns[2].cardIds,
  }
}

describe('createBoard', () => {
  it('starts with three empty columns in order', () => {
    const board = createBoard('/p')
    expect(board.columns.map((c) => c.id)).toEqual(['todo', 'doing', 'done'])
    expect(board.columns.map((c) => c.title)).toEqual(['Todo', 'Doing', 'Done'])
    expect(countCards(board)).toBe(0)
  })

  it('round-trips through JSON unchanged', () => {
    const board = seed(['a'], ['b'])
    expect(JSON.parse(JSON.stringify(board))).toEqual(board)
  })
})

describe('addCard', () => {
  it('appends to Todo by default and fills in the blanks', () => {
    const board = addCard(createBoard('/p'), { id: 'a', title: '  Ship it  ', createdAt: 7 })
    expect(order(board).todo).toEqual(['a'])
    expect(board.cards.a).toEqual({
      id: 'a',
      title: 'Ship it',
      notes: '',
      tags: [],
      createdAt: 7,
      sessionId: null,
    })
  })

  it('honours an explicit column and index', () => {
    const board = addCard(seed(['a', 'b']), { id: 'x', title: 'X', columnId: 'todo', index: 1 })
    expect(order(board).todo).toEqual(['a', 'x', 'b'])
  })

  it('clamps an index past the end instead of leaving a hole', () => {
    const board = addCard(seed(['a']), { id: 'x', title: 'X', index: 99 })
    expect(order(board).todo).toEqual(['a', 'x'])
  })

  it('clamps a negative index to the top', () => {
    const board = addCard(seed(['a']), { id: 'x', title: 'X', index: -4 })
    expect(order(board).todo).toEqual(['x', 'a'])
  })

  it('rejects a blank title', () => {
    const before = seed(['a'])
    expect(addCard(before, { title: '   ' })).toBe(before)
  })

  it('ignores a duplicate id, so a double submit cannot clone a card', () => {
    const before = seed(['a'])
    expect(addCard(before, { id: 'a', title: 'Different' })).toBe(before)
  })

  it('generates an id when none is given', () => {
    const board = addCard(createBoard('/p'), { title: 'Auto' })
    const [id] = board.columns[0].cardIds
    expect(id).toBeTruthy()
    expect(board.cards[id].title).toBe('Auto')
  })

  it('does not mutate the board it was given', () => {
    const before = seed(['a'])
    const snapshot = structuredClone(before)
    addCard(before, { id: 'x', title: 'X' })
    expect(before).toEqual(snapshot)
  })
})

describe('removeCard', () => {
  it('drops the card and its place in the column', () => {
    const board = removeCard(seed(['a', 'b', 'c']), 'b')
    expect(order(board).todo).toEqual(['a', 'c'])
    expect(board.cards.b).toBeUndefined()
  })

  it('is a no-op for an unknown id', () => {
    const before = seed(['a'])
    expect(removeCard(before, 'nope')).toBe(before)
  })
})

describe('editCard', () => {
  it('patches only the keys given', () => {
    const board = editCard(seed(['a']), 'a', { notes: '  check the retry path  ' })
    expect(board.cards.a.title).toBe('A')
    expect(board.cards.a.notes).toBe('check the retry path')
  })

  it('keeps the old title when the new one is blank', () => {
    const board = editCard(seed(['a']), 'a', { title: '   ' })
    expect(board.cards.a.title).toBe('A')
  })

  it('normalises tags on the way in', () => {
    const board = editCard(seed(['a']), 'a', { tags: [' Auth ', '#bug', 'auth', ''] })
    expect(board.cards.a.tags).toEqual(['Auth', 'bug'])
  })

  it('stores a session id without touching anything else', () => {
    const board = editCard(seed(['a']), 'a', { sessionId: 's-1' })
    expect(board.cards.a.sessionId).toBe('s-1')
    expect(order(board)).toEqual(order(seed(['a'])))
  })

  it('returns the same state when the patch changes nothing', () => {
    const before = seed(['a'])
    expect(editCard(before, 'a', { title: 'A', notes: '' })).toBe(before)
  })

  it('is a no-op for an unknown id', () => {
    const before = seed(['a'])
    expect(editCard(before, 'ghost', { title: 'X' })).toBe(before)
  })
})

describe('moveCard — within a column', () => {
  it('moves a card to the top', () => {
    expect(order(moveCard(seed(['a', 'b', 'c']), 'c', 'todo', 0)).todo).toEqual(['c', 'a', 'b'])
  })

  /**
   * The remove-then-insert convention in one assertion: with `a` lifted out
   * the column is `[b, c]`, so index 2 is past `c` — the bottom.
   */
  it('moves a card to the bottom using the post-removal length', () => {
    expect(order(moveCard(seed(['a', 'b', 'c']), 'a', 'todo', 2)).todo).toEqual(['b', 'c', 'a'])
  })

  it('moves a card down by exactly one', () => {
    expect(order(moveCard(seed(['a', 'b', 'c']), 'a', 'todo', 1)).todo).toEqual(['b', 'a', 'c'])
  })

  it('moves a card up by exactly one', () => {
    expect(order(moveCard(seed(['a', 'b', 'c']), 'c', 'todo', 1)).todo).toEqual(['a', 'c', 'b'])
  })

  it('clamps an index beyond the end', () => {
    expect(order(moveCard(seed(['a', 'b', 'c']), 'a', 'todo', 99)).todo).toEqual(['b', 'c', 'a'])
  })

  it('clamps a negative index', () => {
    expect(order(moveCard(seed(['a', 'b', 'c']), 'c', 'todo', -3)).todo).toEqual(['c', 'a', 'b'])
  })

  it('ignores a non-finite index rather than corrupting the order', () => {
    expect(order(moveCard(seed(['a', 'b']), 'b', 'todo', Number.NaN)).todo).toEqual(['b', 'a'])
  })

  it('returns the same state when the card is already there', () => {
    const before = seed(['a', 'b', 'c'])
    expect(moveCard(before, 'b', 'todo', 1)).toBe(before)
  })

  it('never duplicates or loses a card', () => {
    const before = seed(['a', 'b', 'c', 'd'])
    const after = moveCard(before, 'b', 'todo', 3)
    expect(after.columns[0].cardIds).toEqual(['a', 'c', 'd', 'b'])
    expect(countCards(after)).toBe(4)
    expect(new Set(after.columns[0].cardIds).size).toBe(4)
  })
})

describe('moveCard — across columns', () => {
  it('inserts at the requested index in the destination', () => {
    const after = moveCard(seed(['a'], ['x', 'y']), 'a', 'doing', 1)
    expect(order(after)).toEqual({ todo: [], doing: ['x', 'a', 'y'], done: [] })
  })

  it('appends when the index is the destination length', () => {
    const after = moveCard(seed(['a'], ['x', 'y']), 'a', 'doing', 2)
    expect(order(after).doing).toEqual(['x', 'y', 'a'])
  })

  /**
   * Cross-column moves must NOT get the same -1 adjustment as same-column
   * ones: the dragged card was never in the destination, so no index shifts.
   */
  it('does not shift the destination index for a card that came from elsewhere', () => {
    const after = moveCard(seed(['a'], ['x', 'y', 'z']), 'a', 'doing', 2)
    expect(order(after).doing).toEqual(['x', 'y', 'a', 'z'])
  })

  it('leaves the source column intact around the hole', () => {
    const after = moveCard(seed(['a', 'b', 'c']), 'b', 'done', 0)
    expect(order(after)).toEqual({ todo: ['a', 'c'], doing: [], done: ['b'] })
  })

  it('moves into an empty column', () => {
    expect(order(moveCard(seed(['a']), 'a', 'done', 0)).done).toEqual(['a'])
  })

  it('is a no-op for an unknown card', () => {
    const before = seed(['a'])
    expect(moveCard(before, 'ghost', 'done', 0)).toBe(before)
  })

  it('is a no-op for an unknown column', () => {
    const before = seed(['a'])
    expect(moveCard(before, 'a', 'archive' as ColumnId, 0)).toBe(before)
  })
})

describe('moveCardBefore', () => {
  /**
   * Regression guard for the classic off-by-one. Dragging `a` onto `c` inside
   * its own column must land it *above* `c`. Naive code reads `indexOf(c)` in
   * the untouched column (2) and drops `a` at the bottom instead.
   */
  it('drops above the target when dragging downwards in the same column', () => {
    expect(order(moveCardBefore(seed(['a', 'b', 'c']), 'a', 'todo', 'c')).todo).toEqual([
      'b',
      'a',
      'c',
    ])
  })

  it('drops above the target when dragging upwards in the same column', () => {
    expect(order(moveCardBefore(seed(['a', 'b', 'c']), 'c', 'todo', 'b')).todo).toEqual([
      'a',
      'c',
      'b',
    ])
  })

  it('drops above the target across columns without any shift', () => {
    const after = moveCardBefore(seed(['a'], ['x', 'y']), 'a', 'doing', 'y')
    expect(order(after).doing).toEqual(['x', 'a', 'y'])
  })

  it('appends when the target is null', () => {
    expect(order(moveCardBefore(seed(['a', 'b', 'c']), 'a', 'todo', null)).todo).toEqual([
      'b',
      'c',
      'a',
    ])
  })

  it('appends when the target card is not in that column', () => {
    const after = moveCardBefore(seed(['a'], ['x']), 'a', 'doing', 'ghost')
    expect(order(after).doing).toEqual(['x', 'a'])
  })

  it('is a no-op when dropped on itself', () => {
    const before = seed(['a', 'b'])
    expect(moveCardBefore(before, 'a', 'todo', 'a')).toBe(before)
  })

  it('is a no-op when the card is already directly above the target', () => {
    const before = seed(['a', 'b', 'c'])
    expect(moveCardBefore(before, 'a', 'todo', 'b')).toBe(before)
  })

  it('survives a full round trip back to the start', () => {
    const before = seed(['a', 'b', 'c'])
    const moved = moveCardBefore(before, 'a', 'todo', null)
    expect(order(moveCardBefore(moved, 'a', 'todo', 'b')).todo).toEqual(['a', 'b', 'c'])
  })
})

describe('nudgeCard and shiftCardColumn', () => {
  it('nudges down one slot', () => {
    expect(order(nudgeCard(seed(['a', 'b', 'c']), 'a', 1)).todo).toEqual(['b', 'a', 'c'])
  })

  it('nudges up one slot', () => {
    expect(order(nudgeCard(seed(['a', 'b', 'c']), 'c', -1)).todo).toEqual(['a', 'c', 'b'])
  })

  it('stays put at the top of the column', () => {
    const before = seed(['a', 'b'])
    expect(nudgeCard(before, 'a', -1)).toBe(before)
  })

  it('shifts to the next column keeping its row', () => {
    const after = shiftCardColumn(seed(['a', 'b'], ['x', 'y', 'z']), 'b', 1)
    expect(order(after)).toEqual({ todo: ['a'], doing: ['x', 'b', 'y', 'z'], done: [] })
  })

  it('lands at the bottom when the next column is shorter than its row', () => {
    const after = shiftCardColumn(seed(['a', 'b', 'c'], ['x']), 'c', 1)
    expect(order(after).doing).toEqual(['x', 'c'])
  })

  it('refuses to shift past the last column', () => {
    const before = seed([], [], ['a'])
    expect(shiftCardColumn(before, 'a', 1)).toBe(before)
  })

  it('refuses to shift before the first column', () => {
    const before = seed(['a'])
    expect(shiftCardColumn(before, 'a', -1)).toBe(before)
  })
})

describe('selectors', () => {
  it('reports the column and index of a card', () => {
    const board = seed(['a', 'b'], ['x'])
    expect(columnOf(board, 'b')).toBe('todo')
    expect(indexOf(board, 'b')).toBe(1)
    expect(columnOf(board, 'x')).toBe('doing')
    expect(columnOf(board, 'ghost')).toBeNull()
    expect(indexOf(board, 'ghost')).toBe(-1)
  })

  it('returns cards in board order', () => {
    expect(cardsInColumn(seed(['a', 'b']), 'todo').map((c) => c.id)).toEqual(['a', 'b'])
  })

  it('collects tags case-insensitively, alphabetically', () => {
    let board = createBoard('/p')
    board = addCard(board, { id: 'a', title: 'A', tags: ['ui', 'Auth'] })
    board = addCard(board, { id: 'b', title: 'B', tags: ['AUTH', 'perf'] })
    expect(allTags(board)).toEqual(['Auth', 'perf', 'ui'])
  })
})

describe('normaliseTags and parseCardInput', () => {
  it('strips hashes, blanks and case-insensitive duplicates', () => {
    expect(normaliseTags([' #auth ', 'AUTH', '', '  ', 'ui', 42])).toEqual(['auth', 'ui'])
  })

  it('pulls trailing hashtags out of a composer line', () => {
    expect(parseCardInput('Fix OAuth refresh #auth #bug')).toEqual({
      title: 'Fix OAuth refresh',
      tags: ['auth', 'bug'],
    })
  })

  it('leaves a leading hashtag in the title', () => {
    expect(parseCardInput('#1 priority rewrite')).toEqual({
      title: '#1 priority rewrite',
      tags: [],
    })
  })

  it('never eats the whole line when it is all tags', () => {
    expect(parseCardInput('#auth')).toEqual({ title: '#auth', tags: [] })
  })

  it('collapses runs of whitespace', () => {
    expect(parseCardInput('  spaced   out  ').title).toBe('spaced out')
  })
})

describe('filtering', () => {
  function filterBoardFixture(): BoardState {
    let board = createBoard('/p')
    board = addCard(board, {
      id: 'a',
      title: 'Fix OAuth refresh',
      notes: 'token expires early',
      tags: ['auth'],
    })
    board = addCard(board, { id: 'b', title: 'Polish the empty state', tags: ['ui'], columnId: 'doing' })
    board = addCard(board, { id: 'c', title: 'Auth audit', tags: ['auth', 'ui'], columnId: 'done' })
    return board
  }

  it('matches on the title', () => {
    const view = filterBoard(filterBoardFixture(), { text: 'oauth' })
    expect(view.columns.flatMap((c) => c.cards.map((card) => card.id))).toEqual(['a'])
  })

  it('matches on notes', () => {
    expect(matchesFilter(filterBoardFixture().cards.a, { text: 'expires' })).toBe(true)
  })

  it('matches on a tag through free text', () => {
    const view = filterBoard(filterBoardFixture(), { text: 'ui' })
    expect(view.visible).toBe(2)
  })

  it('requires every search term', () => {
    const card = filterBoardFixture().cards.a
    expect(matchesFilter(card, { text: 'oauth token' })).toBe(true)
    expect(matchesFilter(card, { text: 'oauth banana' })).toBe(false)
  })

  it('ignores case and surrounding whitespace', () => {
    expect(matchesFilter(filterBoardFixture().cards.a, { text: '  FIX  ' })).toBe(true)
  })

  it('filters by any of the selected tags by default', () => {
    const view = filterBoard(filterBoardFixture(), { tags: ['auth', 'ui'] })
    expect(view.visible).toBe(3)
  })

  it('requires all selected tags when asked', () => {
    const view = filterBoard(filterBoardFixture(), { tags: ['auth', 'ui'], matchAllTags: true })
    expect(view.columns.flatMap((c) => c.cards.map((card) => card.id))).toEqual(['c'])
  })

  it('combines text and tag filters', () => {
    const view = filterBoard(filterBoardFixture(), { text: 'audit', tags: ['auth'] })
    expect(view.visible).toBe(1)
  })

  it('keeps column shape and reports pre-filter totals', () => {
    const view = filterBoard(filterBoardFixture(), { text: 'auth' })
    expect(view.columns.map((c) => c.id)).toEqual(['todo', 'doing', 'done'])
    expect(view.columns[1]).toMatchObject({ cards: [], total: 1 })
    expect(view.total).toBe(3)
    expect(view.visible).toBe(2)
  })

  it('shows everything when the filter is empty', () => {
    expect(filterBoard(filterBoardFixture()).visible).toBe(3)
  })

  it('knows whether a filter is doing anything', () => {
    expect(isFilterActive({})).toBe(false)
    expect(isFilterActive({ text: '   ' })).toBe(false)
    expect(isFilterActive({ text: 'x' })).toBe(true)
    expect(isFilterActive({ tags: ['ui'] })).toBe(true)
  })
})

describe('parseBoard', () => {
  it('returns an empty board for junk', () => {
    expect(countCards(parseBoard(null, '/p'))).toBe(0)
    expect(countCards(parseBoard('nope', '/p'))).toBe(0)
    expect(countCards(parseBoard(42, '/p'))).toBe(0)
  })

  it('round-trips a real board unchanged', () => {
    const board = seed(['a', 'b'], ['x'], ['z'])
    expect(parseBoard(JSON.parse(JSON.stringify(board)), board.projectPath)).toEqual(board)
  })

  it('drops column entries pointing at missing cards', () => {
    const raw = {
      columns: [{ id: 'todo', cardIds: ['a', 'ghost'] }],
      cards: { a: { title: 'A', createdAt: 1 } },
    }
    expect(order(parseBoard(raw, '/p')).todo).toEqual(['a'])
  })

  it('keeps only the first home of a card listed in two columns', () => {
    const raw = {
      columns: [
        { id: 'todo', cardIds: ['a'] },
        { id: 'doing', cardIds: ['a'] },
      ],
      cards: { a: { title: 'A', createdAt: 1 } },
    }
    const parsed = parseBoard(raw, '/p')
    expect(order(parsed)).toEqual({ todo: ['a'], doing: [], done: [] })
    expect(countCards(parsed)).toBe(1)
  })

  it('re-attaches orphaned cards to the first column rather than losing them', () => {
    const raw = { columns: [], cards: { a: { title: 'A', createdAt: 1 } } }
    expect(order(parseBoard(raw, '/p')).todo).toEqual(['a'])
  })

  it('drops cards with no usable title', () => {
    const raw = { columns: [{ id: 'todo', cardIds: ['a'] }], cards: { a: { title: '   ' } } }
    expect(countCards(parseBoard(raw, '/p'))).toBe(0)
  })

  it('repairs missing fields with a supplied clock', () => {
    const raw = { columns: [{ id: 'todo', cardIds: ['a'] }], cards: { a: { title: 'A' } } }
    expect(parseBoard(raw, '/p', 999).cards.a).toEqual({
      id: 'a',
      title: 'A',
      notes: '',
      tags: [],
      createdAt: 999,
      sessionId: null,
    })
  })

  it('trusts the record key over a mismatched id inside the card', () => {
    const raw = {
      columns: [{ id: 'todo', cardIds: ['a'] }],
      cards: { a: { id: 'stale', title: 'A', createdAt: 1 } },
    }
    expect(parseBoard(raw, '/p').cards.a.id).toBe('a')
  })

  it('rebuilds unknown or reordered columns into the canonical three', () => {
    const raw = { columns: [{ id: 'archive', cardIds: [] }, { id: 'done', cardIds: [] }], cards: {} }
    expect(parseBoard(raw, '/p').columns.map((c) => c.id)).toEqual(['todo', 'doing', 'done'])
  })

  it('takes the project path from the caller, never from the file', () => {
    const raw = { projectPath: '/somewhere/else', columns: [], cards: {} }
    expect(parseBoard(raw, '/p').projectPath).toBe('/p')
  })

  it('keeps a stored session id', () => {
    const raw = {
      columns: [{ id: 'doing', cardIds: ['a'] }],
      cards: { a: { title: 'A', createdAt: 1, sessionId: 's-9' } },
    }
    expect(parseBoard(raw, '/p').cards.a.sessionId).toBe('s-9')
  })
})

/**
 * Regressions for a corrupt file being able to take the whole board down.
 * `parseBoard`'s contract is that nothing on disk can stop the app opening, so
 * each of these used to end in a thrown TypeError somewhere downstream.
 */
describe('parseBoard — hostile input', () => {
  it('does not mistake inherited object members for cards', () => {
    // `cards['constructor']` is truthy on every object, so a column listing it
    // used to be accepted and then handed `Object` itself out as a card.
    const raw = {
      columns: [{ id: 'todo', cardIds: ['constructor', 'toString', 'hasOwnProperty', 'a'] }],
      cards: { a: { title: 'A', createdAt: 1 } },
    }
    const parsed = parseBoard(raw, '/p')
    expect(order(parsed).todo).toEqual(['a'])
    expect(countCards(parsed)).toBe(1)
    expect(cardsInColumn(parsed, 'todo').map((c) => c.title)).toEqual(['A'])
    expect(allTags(parsed)).toEqual([])
  })

  it('survives a card keyed __proto__ without corrupting the map', () => {
    // Parsed from text so the key is a real own property, which is what a
    // hand-edited file would produce.
    const raw: unknown = JSON.parse(
      '{"columns":[{"id":"todo","cardIds":["__proto__","a"]}],' +
        '"cards":{"__proto__":{"title":"EVIL"},"a":{"title":"A","createdAt":1}}}',
    )
    const parsed = parseBoard(raw, '/p')
    expect(order(parsed).todo).toEqual(['a'])
    expect(Object.getPrototypeOf(parsed.cards)).toBe(Object.prototype)
    expect(cardsInColumn(parsed, 'todo').map((c) => c.title)).toEqual(['A'])
    expect(allTags(parsed)).toEqual([])
  })

  it('leaves transitions inert for an id that only exists on the prototype', () => {
    const before = seed(['a'])
    expect(removeCard(before, 'constructor')).toBe(before)
    expect(editCard(before, 'toString', { title: 'X' })).toBe(before)
    expect(moveCard(before, 'valueOf', 'done', 0)).toBe(before)
    expect(moveCardBefore(before, 'constructor', 'done', null)).toBe(before)
    expect(nudgeCard(before, 'constructor', 1)).toBe(before)
  })

  it('still lets a real card use one of those names as its id', () => {
    const board = addCard(seed(['a']), { id: 'constructor', title: 'Real card' })
    expect(order(board).todo).toEqual(['a', 'constructor'])
    expect(cardsInColumn(board, 'todo').map((c) => c.title)).toEqual(['A', 'Real card'])
    expect(removeCard(board, 'constructor').columns[0].cardIds).toEqual(['a'])
  })

  it('re-attaches a huge orphan set without overflowing the stack', () => {
    // `push(...orphans)` spreads into arguments and throws well before this
    // many. A file this size is absurd, but throwing here means the board
    // cannot be opened at all, which is the one outcome ruled out.
    const cards: Record<string, unknown> = {}
    for (let i = 0; i < 200_000; i += 1) cards[`c${i}`] = { title: `t${i}`, createdAt: 1 }
    const parsed = parseBoard({ columns: [], cards }, '/p')
    expect(parsed.columns[0].cardIds).toHaveLength(200_000)
    expect(countCards(parsed)).toBe(200_000)
  })
})

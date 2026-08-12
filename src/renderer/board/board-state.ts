/**
 * Pure state model for the per-project kanban board.
 *
 * Every exported transition is pure: it never mutates its arguments, never
 * touches the DOM or the filesystem, and returns plain JSON-serialisable data.
 * That is what lets the main process reuse this module to validate whatever
 * the renderer hands it before writing to disk (see `src/main/board-store.ts`),
 * and it keeps the interesting logic — index arithmetic — testable in isolation.
 *
 * Transitions return the *same* state object when nothing would change, so a
 * React consumer can rely on reference equality to skip work.
 */

export type ColumnId = 'todo' | 'doing' | 'done'

/** Left-to-right column order. The board never has any other columns. */
export const COLUMN_IDS: readonly ColumnId[] = ['todo', 'doing', 'done']

export const COLUMN_TITLES: Readonly<Record<ColumnId, string>> = {
  todo: 'Todo',
  doing: 'Doing',
  done: 'Done',
}

/** Bumped only when a migration is needed; `parseBoard` handles older files. */
export const BOARD_VERSION = 1

export interface BoardCard {
  id: string
  title: string
  notes: string
  /** Display case is preserved; comparison and de-duplication are case-insensitive. */
  tags: string[]
  createdAt: number
  /**
   * The session this card refers to, once something has linked the two.
   * This module only carries the id — spawning or resuming that session is a
   * separate concern and is deliberately not implemented here.
   */
  sessionId: string | null
}

export interface BoardColumn {
  id: ColumnId
  title: string
  /** Card ids, top to bottom. The single source of truth for order. */
  cardIds: string[]
}

export interface BoardState {
  version: number
  /** Absolute path of the project this board belongs to. */
  projectPath: string
  columns: BoardColumn[]
  cards: Record<string, BoardCard>
}

export interface CardDraft {
  title: string
  notes?: string
  tags?: string[]
  sessionId?: string | null
  /** Defaults to the first column. */
  columnId?: ColumnId
  /** Insert position within the column; appended when omitted. */
  index?: number
  /** Supplied by tests and replays; generated when absent. */
  id?: string
  createdAt?: number
}

export interface CardPatch {
  title?: string
  notes?: string
  tags?: string[]
  sessionId?: string | null
}

export interface BoardFilter {
  /** Free text; every whitespace-separated term must match. */
  text?: string
  tags?: string[]
  /** Require every selected tag rather than any one of them. */
  matchAllTags?: boolean
}

export interface BoardColumnView {
  id: ColumnId
  title: string
  cards: BoardCard[]
  /** Cards in the column before filtering, so the UI can show "3 of 8". */
  total: number
}

export interface BoardView {
  columns: BoardColumnView[]
  visible: number
  total: number
}

// ---------------------------------------------------------------- helpers --

let idCounter = 0

/**
 * Card id. Not pure — the only such export here, and every transition accepts
 * an explicit id so tests never depend on it. Avoids `crypto.randomUUID` so
 * this module stays importable from the main process, whose lib has no DOM.
 */
export function makeCardId(): string {
  idCounter += 1
  const rand = Math.random().toString(36).slice(2, 8)
  return `c${Date.now().toString(36)}${idCounter.toString(36)}${rand}`
}

function clamp(value: number, min: number, max: number): number {
  if (!Number.isFinite(value)) return min
  return Math.min(max, Math.max(min, Math.trunc(value)))
}

/** Trim, drop blanks, and de-duplicate case-insensitively keeping first spelling. */
export function normaliseTags(tags: readonly unknown[]): string[] {
  const seen = new Set<string>()
  const out: string[] = []
  for (const raw of tags) {
    if (typeof raw !== 'string') continue
    const tag = raw.trim().replace(/^#+/, '').trim()
    if (!tag) continue
    const key = tag.toLowerCase()
    if (seen.has(key)) continue
    seen.add(key)
    out.push(tag)
  }
  return out
}

/**
 * Split a composer line into a title and its inline `#tags`.
 * "Fix OAuth refresh #auth #bug" → { title: 'Fix OAuth refresh', tags: ['auth', 'bug'] }
 * Only trailing hashes are treated as tags, so "#1 priority" stays in the title.
 */
export function parseCardInput(raw: string): { title: string; tags: string[] } {
  const words = raw.trim().split(/\s+/).filter(Boolean)
  const tags: string[] = []
  while (words.length > 1) {
    const last = words[words.length - 1]
    if (!/^#[^\s#]+$/.test(last)) break
    tags.unshift(last.slice(1))
    words.pop()
  }
  return { title: words.join(' '), tags: normaliseTags(tags) }
}

/**
 * Own-property card lookup.
 *
 * Card ids come out of a board file, so they can be any string — including
 * `constructor`, `toString` or `valueOf`. A plain `cards[id]` walks the
 * prototype chain and hands back `Object.prototype.constructor` for those,
 * which is truthy, so a corrupt file could smuggle a function into a column
 * and every consumer would then read `card.tags` off it and throw. Every
 * lookup in this module goes through here instead.
 */
function getCard(cards: Record<string, BoardCard>, id: string): BoardCard | undefined {
  return Object.prototype.hasOwnProperty.call(cards, id) ? cards[id] : undefined
}

function sameOrder(a: BoardColumn[], b: BoardColumn[]): boolean {
  return a.every((column, i) => {
    const other = b[i]
    return (
      other !== undefined &&
      other.id === column.id &&
      other.cardIds.length === column.cardIds.length &&
      other.cardIds.every((id, j) => id === column.cardIds[j])
    )
  })
}

function sameTags(a: readonly string[], b: readonly string[]): boolean {
  return a.length === b.length && a.every((tag, i) => tag === b[i])
}

// ------------------------------------------------------------ constructors --

export function createBoard(projectPath: string): BoardState {
  return {
    version: BOARD_VERSION,
    projectPath,
    columns: COLUMN_IDS.map((id) => ({ id, title: COLUMN_TITLES[id], cardIds: [] })),
    cards: {},
  }
}

// -------------------------------------------------------------- selectors --

export function columnOf(state: BoardState, cardId: string): ColumnId | null {
  const column = state.columns.find((c) => c.cardIds.includes(cardId))
  return column ? column.id : null
}

export function indexOf(state: BoardState, cardId: string): number {
  const column = state.columns.find((c) => c.cardIds.includes(cardId))
  return column ? column.cardIds.indexOf(cardId) : -1
}

/** Cards of one column in board order. Ids with no card are skipped defensively. */
export function cardsInColumn(state: BoardState, columnId: ColumnId): BoardCard[] {
  const column = state.columns.find((c) => c.id === columnId)
  if (!column) return []
  const out: BoardCard[] = []
  for (const id of column.cardIds) {
    const card = getCard(state.cards, id)
    if (card) out.push(card)
  }
  return out
}

export function countCards(state: BoardState): number {
  return state.columns.reduce((n, column) => n + column.cardIds.length, 0)
}

/** Every tag on the board, de-duplicated case-insensitively, alphabetical. */
export function allTags(state: BoardState): string[] {
  const seen = new Map<string, string>()
  for (const column of state.columns) {
    for (const id of column.cardIds) {
      const card = getCard(state.cards, id)
      if (!card) continue
      for (const tag of card.tags) {
        const key = tag.toLowerCase()
        if (!seen.has(key)) seen.set(key, tag)
      }
    }
  }
  return [...seen.values()].sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()))
}

// ------------------------------------------------------------ transitions --

/**
 * Add a card. A blank title is rejected (returns the state untouched) and so
 * is an id that already exists, so a double-submit cannot duplicate a card.
 */
export function addCard(state: BoardState, draft: CardDraft): BoardState {
  const title = draft.title.trim()
  if (!title) return state

  const id = draft.id ?? makeCardId()
  if (getCard(state.cards, id)) return state

  const columnId = draft.columnId ?? COLUMN_IDS[0]
  const destIndex = state.columns.findIndex((c) => c.id === columnId)
  if (destIndex === -1) return state

  const card: BoardCard = {
    id,
    title,
    notes: draft.notes?.trim() ?? '',
    tags: normaliseTags(draft.tags ?? []),
    createdAt: draft.createdAt ?? Date.now(),
    sessionId: draft.sessionId ?? null,
  }

  const dest = state.columns[destIndex]
  const at = draft.index === undefined ? dest.cardIds.length : clamp(draft.index, 0, dest.cardIds.length)

  return {
    ...state,
    cards: { ...state.cards, [id]: card },
    columns: state.columns.map((column, i) =>
      i === destIndex
        ? { ...column, cardIds: [...column.cardIds.slice(0, at), id, ...column.cardIds.slice(at)] }
        : column,
    ),
  }
}

export function removeCard(state: BoardState, cardId: string): BoardState {
  if (!getCard(state.cards, cardId)) return state
  const cards = { ...state.cards }
  delete cards[cardId]
  return {
    ...state,
    cards,
    columns: state.columns.map((column) =>
      column.cardIds.includes(cardId)
        ? { ...column, cardIds: column.cardIds.filter((id) => id !== cardId) }
        : column,
    ),
  }
}

/**
 * Patch a card's content. Only the keys present in `patch` are touched, and a
 * title that trims to empty is ignored rather than blanking the card.
 */
export function editCard(state: BoardState, cardId: string, patch: CardPatch): BoardState {
  const card = getCard(state.cards, cardId)
  if (!card) return state

  const title = patch.title === undefined ? card.title : patch.title.trim() || card.title
  const notes = patch.notes === undefined ? card.notes : patch.notes.trim()
  const tags = patch.tags === undefined ? card.tags : normaliseTags(patch.tags)
  const sessionId = patch.sessionId === undefined ? card.sessionId : patch.sessionId

  const unchanged =
    title === card.title &&
    notes === card.notes &&
    sessionId === card.sessionId &&
    sameTags(tags, card.tags)
  if (unchanged) return state

  return {
    ...state,
    cards: { ...state.cards, [cardId]: { ...card, title, notes, tags, sessionId } },
  }
}

/**
 * Move a card to `toIndex` of `toColumnId`.
 *
 * The index is interpreted against the destination column *after the card has
 * been taken out of wherever it was* — the remove-then-insert convention. Any
 * other reading is ambiguous for a same-column move: with `[a, b, c]`, "move
 * `a` to index 2" is either `[b, a, c]` or `[b, c, a]` depending on whether
 * `a` is still counted. Here it is `[b, c, a]`, and callers that think in
 * terms of "drop it above card X" should use `moveCardBefore`, which does the
 * arithmetic for them.
 *
 * Out-of-range indices clamp instead of throwing; unknown ids are no-ops.
 */
export function moveCard(
  state: BoardState,
  cardId: string,
  toColumnId: ColumnId,
  toIndex: number,
): BoardState {
  if (!getCard(state.cards, cardId)) return state
  const destIndex = state.columns.findIndex((c) => c.id === toColumnId)
  if (destIndex === -1) return state

  const stripped = state.columns.map((column) =>
    column.cardIds.includes(cardId)
      ? { ...column, cardIds: column.cardIds.filter((id) => id !== cardId) }
      : column,
  )

  const dest = stripped[destIndex]
  const at = clamp(toIndex, 0, dest.cardIds.length)
  const columns = stripped.map((column, i) =>
    i === destIndex
      ? {
          ...column,
          cardIds: [...column.cardIds.slice(0, at), cardId, ...column.cardIds.slice(at)],
        }
      : column,
  )

  if (sameOrder(state.columns, columns)) return state
  return { ...state, columns }
}

/**
 * Move a card so it sits directly above `beforeCardId`, or at the bottom of
 * the column when that is null. This is the shape a drag-and-drop layer wants:
 * it knows which card it is hovering, not what index that will become.
 *
 * Dragging a card *downwards within its own column* is where naive code goes
 * wrong — the target's index shifts by one once the dragged card is lifted
 * out. That subtraction happens here, once.
 */
export function moveCardBefore(
  state: BoardState,
  cardId: string,
  toColumnId: ColumnId,
  beforeCardId: string | null,
): BoardState {
  if (cardId === beforeCardId) return state
  if (!getCard(state.cards, cardId)) return state
  const dest = state.columns.find((c) => c.id === toColumnId)
  if (!dest) return state

  const remaining = dest.cardIds.filter((id) => id !== cardId)
  const at = beforeCardId === null ? remaining.length : remaining.indexOf(beforeCardId)
  return moveCard(state, cardId, toColumnId, at === -1 ? remaining.length : at)
}

/** Move a card one slot up or down inside its own column. */
export function nudgeCard(state: BoardState, cardId: string, delta: number): BoardState {
  const columnId = columnOf(state, cardId)
  if (!columnId) return state
  const from = indexOf(state, cardId)
  return moveCard(state, cardId, columnId, from + delta)
}

/** Move a card to the adjacent column, keeping its vertical position if it fits. */
export function shiftCardColumn(state: BoardState, cardId: string, delta: number): BoardState {
  const columnId = columnOf(state, cardId)
  if (!columnId) return state
  const next = COLUMN_IDS[COLUMN_IDS.indexOf(columnId) + delta]
  if (!next) return state
  return moveCard(state, cardId, next, indexOf(state, cardId))
}

// ----------------------------------------------------------------- filter --

/** Case-insensitive; a card matches when every search term appears somewhere. */
export function matchesFilter(card: BoardCard, filter: BoardFilter): boolean {
  const terms = (filter.text ?? '').toLowerCase().split(/\s+/).filter(Boolean)
  if (terms.length > 0) {
    const haystack = `${card.title} ${card.notes} ${card.tags.join(' ')}`.toLowerCase()
    if (!terms.every((term) => haystack.includes(term))) return false
  }

  const wanted = (filter.tags ?? []).map((t) => t.toLowerCase()).filter(Boolean)
  if (wanted.length > 0) {
    const own = new Set(card.tags.map((t) => t.toLowerCase()))
    const test = filter.matchAllTags
      ? wanted.every((tag) => own.has(tag))
      : wanted.some((tag) => own.has(tag))
    if (!test) return false
  }

  return true
}

export function isFilterActive(filter: BoardFilter): boolean {
  return (filter.text ?? '').trim().length > 0 || (filter.tags ?? []).length > 0
}

/** Read-only projection of the board for rendering. Never mutates state. */
export function filterBoard(state: BoardState, filter: BoardFilter = {}): BoardView {
  let visible = 0
  let total = 0

  const columns = state.columns.map((column) => {
    const cards = cardsInColumn(state, column.id)
    const kept = cards.filter((card) => matchesFilter(card, filter))
    visible += kept.length
    total += cards.length
    return { id: column.id, title: column.title, cards: kept, total: cards.length }
  })

  return { columns, visible, total }
}

// ------------------------------------------------------------------ parse --

function parseCard(key: string, raw: unknown, now: number): BoardCard | null {
  if (typeof raw !== 'object' || raw === null) return null
  const source = raw as Record<string, unknown>
  const title = typeof source.title === 'string' ? source.title.trim() : ''
  if (!title) return null
  return {
    // The record key wins: it is what the column lists point at.
    id: key,
    title,
    notes: typeof source.notes === 'string' ? source.notes : '',
    tags: Array.isArray(source.tags) ? normaliseTags(source.tags) : [],
    createdAt: typeof source.createdAt === 'number' && Number.isFinite(source.createdAt)
      ? source.createdAt
      : now,
    sessionId: typeof source.sessionId === 'string' && source.sessionId ? source.sessionId : null,
  }
}

/**
 * Rebuild a board from untrusted JSON — a file written by an older version, a
 * hand-edited one, or an IPC payload. Anything unrecognisable is dropped
 * rather than thrown on, because a corrupt board must never stop the app
 * opening. Cards that survive but have lost their column are re-attached to
 * the first column instead of vanishing.
 *
 * `projectPath` always comes from the caller; a path baked into the file is
 * ignored so a board can never claim to belong to a different project.
 */
export function parseBoard(raw: unknown, projectPath: string, now = Date.now()): BoardState {
  const empty = createBoard(projectPath)
  if (typeof raw !== 'object' || raw === null) return empty

  const source = raw as Record<string, unknown>
  const rawCards = typeof source.cards === 'object' && source.cards !== null
    ? (source.cards as Record<string, unknown>)
    : {}

  const cards: Record<string, BoardCard> = {}
  for (const [key, value] of Object.entries(rawCards)) {
    // `cards['__proto__'] = card` is a call to the inherited setter, not an own
    // property: the card would vanish from the map while leaving it with a
    // card for a prototype. There is no sane board with a card keyed that way.
    if (!key || key === '__proto__') continue
    const card = parseCard(key, value, now)
    if (card) cards[key] = card
  }

  const rawColumns = Array.isArray(source.columns) ? source.columns : []
  const placed = new Set<string>()

  const columns: BoardColumn[] = COLUMN_IDS.map((id) => {
    const match = rawColumns.find(
      (c): c is Record<string, unknown> =>
        typeof c === 'object' && c !== null && (c as Record<string, unknown>).id === id,
    )
    const ids = Array.isArray(match?.cardIds) ? match.cardIds : []
    const cardIds: string[] = []
    for (const value of ids) {
      // Drop dangling ids, and keep only the first home of a card that somehow
      // ended up listed in two columns. The lookup must be an own-property one:
      // `cards['constructor']` is otherwise truthy on any board.
      if (typeof value !== 'string' || !getCard(cards, value) || placed.has(value)) continue
      placed.add(value)
      cardIds.push(value)
    }
    return { id, title: COLUMN_TITLES[id], cardIds }
  })

  // Appended one at a time rather than with `push(...orphans)`: spreading a
  // large array into arguments overflows the stack, and this is exactly the
  // path a huge corrupt file takes, so it must not be the thing that throws.
  for (const id of Object.keys(cards)) {
    if (!placed.has(id)) columns[0].cardIds.push(id)
  }

  return { version: BOARD_VERSION, projectPath, columns, cards }
}

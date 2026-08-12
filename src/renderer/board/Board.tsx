import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  addCard,
  allTags,
  createBoard,
  editCard,
  filterBoard,
  isFilterActive,
  moveCardBefore,
  nudgeCard,
  parseBoard,
  parseCardInput,
  removeCard,
  shiftCardColumn,
  type BoardCard,
  type BoardState,
  type ColumnId,
} from './board-state'
import './Board.css'

/**
 * Persistence contract. Declared locally rather than imported from the shared
 * bridge type, so this component can be tested and reused without the preload
 * layer — and so wiring it up is one line in the orchestrator.
 */
export interface BoardBridge {
  loadBoard(projectPath: string): Promise<unknown>
  saveBoard(projectPath: string, state: BoardState): Promise<unknown>
}

export interface BoardProps {
  /** Absolute path of the project whose board this is. */
  projectPath: string
  /** Defaults to the preload bridge; pass one in tests or for a memory board. */
  bridge?: BoardBridge
}

/** Where a dragged card would land: above `beforeCardId`, or at the bottom. */
interface DropTarget {
  columnId: ColumnId
  beforeCardId: string | null
}

interface EditDraft {
  title: string
  notes: string
  tags: string
}

const SAVE_DEBOUNCE_MS = 400

/**
 * Resolve the preload bridge at call time. The board must not hard-fail when
 * the main process hasn't registered its channels yet — it degrades to an
 * in-memory board instead of throwing on mount.
 */
function windowBridge(): BoardBridge | null {
  const api = (globalThis as unknown as { deck?: Record<string, unknown> }).deck
  const load = api?.loadBoard
  const save = api?.saveBoard
  if (typeof load !== 'function' || typeof save !== 'function') return null
  return {
    loadBoard: (path) => (load as (p: string) => Promise<unknown>)(path),
    saveBoard: (path, state) =>
      (save as (p: string, s: BoardState) => Promise<unknown>)(path, state),
  }
}

function tagsToInput(tags: readonly string[]): string {
  return tags.join(', ')
}

function inputToTags(raw: string): string[] {
  return raw.split(',').map((t) => t.trim())
}

export function Board({ projectPath, bridge }: BoardProps) {
  const [board, setBoard] = useState<BoardState>(() => createBoard(projectPath))
  const [loaded, setLoaded] = useState(false)

  const [query, setQuery] = useState('')
  const [activeTags, setActiveTags] = useState<string[]>([])

  const [dragId, setDragId] = useState<string | null>(null)
  const [dropTarget, setDropTarget] = useState<DropTarget | null>(null)

  const [composerColumn, setComposerColumn] = useState<ColumnId | null>(null)
  const [composerText, setComposerText] = useState('')
  const [editingId, setEditingId] = useState<string | null>(null)
  const [draft, setDraft] = useState<EditDraft>({ title: '', notes: '', tags: '' })

  const resolvedBridge = useMemo(() => bridge ?? windowBridge(), [bridge])
  const saveTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)
  /** The edit the debounce timer is still holding, so teardown can flush it. */
  const pendingSave = useRef<{ projectPath: string; board: BoardState } | null>(null)
  const composerRef = useRef<HTMLInputElement>(null)

  // Load whenever the project changes. `stale` guards against a slow load for
  // project A landing after the user has already switched to project B.
  useEffect(() => {
    let stale = false
    setLoaded(false)
    setBoard(createBoard(projectPath))

    if (!resolvedBridge) {
      setLoaded(true)
      return
    }

    void resolvedBridge
      .loadBoard(projectPath)
      .then((raw) => {
        // The store hands back whatever was on disk, including null on first
        // run — repair and migration are this module's job, not the store's.
        if (stale) return
        setBoard(parseBoard(raw, projectPath))
        // Saving is armed here and nowhere else: only a read that actually
        // came back means the board on screen is the board on disk.
        setLoaded(true)
      })
      .catch((err: unknown) => {
        // `loaded` deliberately stays false. Arming saves after a failed read
        // would let the empty placeholder board be written over the file 400ms
        // later and silently delete every card the user had.
        console.error('[board] load failed — persistence stays off:', err)
      })

    return () => {
      stale = true
    }
  }, [projectPath, resolvedBridge])

  // Debounced save. Skipped until the initial load has settled, otherwise the
  // empty placeholder board would overwrite the file before it arrives.
  useEffect(() => {
    if (!loaded || !resolvedBridge) {
      pendingSave.current = null
      return
    }
    pendingSave.current = { projectPath, board }
    clearTimeout(saveTimer.current)
    saveTimer.current = setTimeout(() => {
      const pending = pendingSave.current
      pendingSave.current = null
      if (!pending) return
      void resolvedBridge
        .saveBoard(pending.projectPath, pending.board)
        .catch((err: unknown) => console.error('[board] save failed:', err))
    }, SAVE_DEBOUNCE_MS)
    return () => clearTimeout(saveTimer.current)
  }, [board, loaded, projectPath, resolvedBridge])

  // Flush on unmount and on a project switch. The effect above cancels its own
  // timer on teardown, so without this the last edit before closing the board —
  // or before switching project, which is when people tidy up — is thrown away.
  // Declared after it so this cleanup runs second, once the timer is dead.
  useEffect(() => {
    return () => {
      const pending = pendingSave.current
      pendingSave.current = null
      if (!pending || !resolvedBridge) return
      void resolvedBridge
        .saveBoard(pending.projectPath, pending.board)
        .catch((err: unknown) => console.error('[board] final save failed:', err))
    }
  }, [projectPath, resolvedBridge])

  const filter = useMemo(() => ({ text: query, tags: activeTags }), [query, activeTags])
  const view = useMemo(() => filterBoard(board, filter), [board, filter])
  const tags = useMemo(() => allTags(board), [board])
  const filtering = isFilterActive(filter)

  const toggleTag = useCallback((tag: string) => {
    setActiveTags((current) =>
      current.includes(tag) ? current.filter((t) => t !== tag) : [...current, tag],
    )
  }, [])

  const clearFilters = useCallback(() => {
    setQuery('')
    setActiveTags([])
  }, [])

  const openComposer = useCallback((columnId: ColumnId) => {
    setComposerColumn(columnId)
    setComposerText('')
    // The input mounts in this same commit, so focus after paint.
    requestAnimationFrame(() => composerRef.current?.focus())
  }, [])

  const commitComposer = useCallback(
    (columnId: ColumnId, keepOpen: boolean) => {
      const { title, tags: parsed } = parseCardInput(composerText)
      if (title) setBoard((state) => addCard(state, { title, tags: parsed, columnId }))
      setComposerText('')
      if (!keepOpen) setComposerColumn(null)
    },
    [composerText],
  )

  const startEditing = useCallback((card: BoardCard) => {
    setEditingId(card.id)
    setDraft({ title: card.title, notes: card.notes, tags: tagsToInput(card.tags) })
  }, [])

  const commitEditing = useCallback(() => {
    if (!editingId) return
    const id = editingId
    setBoard((state) =>
      editCard(state, id, {
        title: draft.title,
        notes: draft.notes,
        tags: inputToTags(draft.tags),
      }),
    )
    setEditingId(null)
  }, [draft, editingId])

  const endDrag = useCallback(() => {
    setDragId(null)
    setDropTarget(null)
  }, [])

  const handleDrop = useCallback(
    (event: React.DragEvent, columnId: ColumnId) => {
      event.preventDefault()
      // Fall back to the payload: a drag can outlive the React state on
      // some platforms, and it is the only thing set for a cross-window drag.
      const id = dragId ?? event.dataTransfer.getData('text/plain')
      const before = dropTarget && dropTarget.columnId === columnId ? dropTarget.beforeCardId : null
      if (id) setBoard((state) => moveCardBefore(state, id, columnId, before))
      endDrag()
    },
    [dragId, dropTarget, endDrag],
  )

  /** Above or below the hovered card, decided by which half the pointer is in. */
  const handleCardDragOver = useCallback(
    (event: React.DragEvent, columnId: ColumnId, card: BoardCard, next: BoardCard | undefined) => {
      if (!dragId) return
      event.preventDefault()
      event.stopPropagation() // Otherwise the column would overwrite this with "append".
      event.dataTransfer.dropEffect = 'move'
      const box = event.currentTarget.getBoundingClientRect()
      const below = event.clientY > box.top + box.height / 2
      setDropTarget({ columnId, beforeCardId: below ? (next?.id ?? null) : card.id })
    },
    [dragId],
  )

  const handleColumnDragOver = useCallback(
    (event: React.DragEvent, columnId: ColumnId) => {
      if (!dragId) return
      event.preventDefault()
      event.dataTransfer.dropEffect = 'move'
      setDropTarget({ columnId, beforeCardId: null })
    },
    [dragId],
  )

  const handleCardKeyDown = useCallback(
    (event: React.KeyboardEvent, card: BoardCard) => {
      if (event.key === 'Enter') {
        event.preventDefault()
        startEditing(card)
        return
      }
      // Alt-arrows reorder without a mouse — drag and drop alone is not
      // reachable by keyboard or by anyone who cannot hold a pointer down.
      if (!event.altKey) return
      const moves: Record<string, (state: BoardState) => BoardState> = {
        ArrowUp: (state) => nudgeCard(state, card.id, -1),
        ArrowDown: (state) => nudgeCard(state, card.id, 1),
        ArrowLeft: (state) => shiftCardColumn(state, card.id, -1),
        ArrowRight: (state) => shiftCardColumn(state, card.id, 1),
      }
      const move = moves[event.key]
      if (!move) return
      event.preventDefault()
      setBoard(move)
      // The node is re-created at its new position, so restore focus to it.
      const id = card.id
      requestAnimationFrame(() => {
        // Ids come from a board file, so they are not guaranteed to be safe to
        // interpolate — an unescaped quote throws a SyntaxError in this frame.
        const el = document.querySelector<HTMLElement>(`[data-card-id="${CSS.escape(id)}"]`)
        el?.focus()
      })
    },
    [startEditing],
  )

  return (
    <section className="board" aria-label="Task board">
      <header className="board-bar">
        <div className="board-search">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor">
            <circle cx="11" cy="11" r="7" strokeWidth="2" />
            <path d="M16.5 16.5L21 21" strokeWidth="2" strokeLinecap="round" />
          </svg>
          <input
            type="search"
            value={query}
            placeholder="Search cards"
            aria-label="Search cards"
            onChange={(e) => setQuery(e.target.value)}
          />
        </div>

        {tags.length > 0 && (
          <div className="board-tags" role="group" aria-label="Filter by tag">
            {tags.map((tag) => (
              <button
                key={tag}
                type="button"
                className={`tag-chip${activeTags.includes(tag) ? ' on' : ''}`}
                aria-pressed={activeTags.includes(tag)}
                onClick={() => toggleTag(tag)}
              >
                {tag}
              </button>
            ))}
          </div>
        )}

        {filtering && (
          <button type="button" className="board-clear" onClick={clearFilters}>
            {view.visible} of {view.total} · clear
          </button>
        )}
      </header>

      <div className="board-columns">
        {view.columns.map((column) => (
          <section key={column.id} className="board-column" aria-label={column.title}>
            <header className="column-head">
              <span className={`column-dot ${column.id}`} aria-hidden="true" />
              <h2>{column.title}</h2>
              <span className="column-count">
                {filtering && column.cards.length !== column.total
                  ? `${column.cards.length}/${column.total}`
                  : column.total}
              </span>
              <button
                type="button"
                className="icon-btn small"
                title={`Add card to ${column.title}`}
                aria-label={`Add card to ${column.title}`}
                onClick={() => openComposer(column.id)}
              >
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor">
                  <path d="M12 5v14M5 12h14" strokeWidth="2" strokeLinecap="round" />
                </svg>
              </button>
            </header>

            <div
              className={`column-body${dropTarget?.columnId === column.id ? ' over' : ''}`}
              onDragOver={(e) => handleColumnDragOver(e, column.id)}
              onDrop={(e) => handleDrop(e, column.id)}
            >
              {column.cards.length === 0 && (
                <p className="column-empty">{filtering ? 'No matches' : 'Nothing here'}</p>
              )}

              {column.cards.map((card, i) => {
                const showLine =
                  dropTarget?.columnId === column.id && dropTarget.beforeCardId === card.id
                return (
                  <div key={card.id} className="card-slot">
                    {showLine && <div className="drop-line" aria-hidden="true" />}
                    {editingId === card.id ? (
                      <div className="card editing">
                        <input
                          className="card-input"
                          value={draft.title}
                          aria-label="Card title"
                          autoFocus
                          onChange={(e) => setDraft({ ...draft, title: e.target.value })}
                          onKeyDown={(e) => {
                            if (e.key === 'Enter') commitEditing()
                            if (e.key === 'Escape') setEditingId(null)
                          }}
                        />
                        <textarea
                          className="card-notes-input"
                          value={draft.notes}
                          rows={3}
                          placeholder="Notes"
                          aria-label="Card notes"
                          onChange={(e) => setDraft({ ...draft, notes: e.target.value })}
                          onKeyDown={(e) => {
                            if (e.key === 'Escape') setEditingId(null)
                          }}
                        />
                        <input
                          className="card-input"
                          value={draft.tags}
                          placeholder="Tags, comma separated"
                          aria-label="Card tags"
                          onChange={(e) => setDraft({ ...draft, tags: e.target.value })}
                          onKeyDown={(e) => {
                            if (e.key === 'Enter') commitEditing()
                            if (e.key === 'Escape') setEditingId(null)
                          }}
                        />
                        <div className="card-edit-actions">
                          <button type="button" className="btn-ghost" onClick={() => setEditingId(null)}>
                            Cancel
                          </button>
                          <button type="button" className="btn-small" onClick={commitEditing}>
                            Save
                          </button>
                        </div>
                      </div>
                    ) : (
                      <article
                        className={`card${dragId === card.id ? ' dragging' : ''}`}
                        data-card-id={card.id}
                        draggable
                        tabIndex={0}
                        title="Drag to move · Enter to edit · Alt+arrows to reorder"
                        onDragStart={(e) => {
                          e.dataTransfer.setData('text/plain', card.id)
                          e.dataTransfer.effectAllowed = 'move'
                          setDragId(card.id)
                        }}
                        onDragEnd={endDrag}
                        onDragOver={(e) =>
                          handleCardDragOver(e, column.id, card, column.cards[i + 1])
                        }
                        onDoubleClick={() => startEditing(card)}
                        onKeyDown={(e) => handleCardKeyDown(e, card)}
                      >
                        <div className="card-top">
                          <p className="card-title">{card.title}</p>
                          <button
                            type="button"
                            className="card-remove"
                            title="Delete card"
                            aria-label={`Delete ${card.title}`}
                            onClick={() => setBoard((state) => removeCard(state, card.id))}
                          >
                            <svg
                              width="12"
                              height="12"
                              viewBox="0 0 24 24"
                              fill="none"
                              stroke="currentColor"
                            >
                              <path d="M6 6l12 12M18 6L6 18" strokeWidth="2" strokeLinecap="round" />
                            </svg>
                          </button>
                        </div>

                        {card.notes && <p className="card-notes">{card.notes}</p>}

                        {(card.tags.length > 0 || card.sessionId) && (
                          <div className="card-meta">
                            {card.tags.map((tag) => (
                              <span key={tag} className="card-tag">
                                {tag}
                              </span>
                            ))}
                            {card.sessionId && (
                              <span className="card-session" title="Linked to a session">
                                session
                              </span>
                            )}
                          </div>
                        )}
                      </article>
                    )}
                  </div>
                )
              })}

              {dropTarget?.columnId === column.id && dropTarget.beforeCardId === null && (
                <div className="drop-line" aria-hidden="true" />
              )}

              {composerColumn === column.id ? (
                <div className="composer">
                  <input
                    ref={composerRef}
                    value={composerText}
                    placeholder="Title, then #tags"
                    aria-label={`New card in ${column.title}`}
                    onChange={(e) => setComposerText(e.target.value)}
                    onKeyDown={(e) => {
                      // Shift+Enter keeps the composer open for a run of cards.
                      if (e.key === 'Enter') commitComposer(column.id, e.shiftKey)
                      // Clear before closing: removing a focused input can fire
                      // blur, which would otherwise commit the cancelled text.
                      if (e.key === 'Escape') {
                        setComposerText('')
                        setComposerColumn(null)
                      }
                    }}
                    onBlur={() => commitComposer(column.id, false)}
                  />
                </div>
              ) : (
                <button
                  type="button"
                  className="composer-open"
                  onClick={() => openComposer(column.id)}
                >
                  + Add card
                </button>
              )}
            </div>
          </section>
        ))}
      </div>
    </section>
  )
}

import { useEffect, useId, useMemo, useRef, useState } from 'react'
import { Modal } from './Modal'
import {
  detectMac,
  formatBinding,
  groupedKeymap,
  KEYMAP,
  searchKeymap,
  type KeyBinding,
} from '../keymap'
import './ShortcutsSheet.css'

/**
 * The shortcut reference, rendered from the keymap itself.
 *
 * Nothing here is typed out by hand. The previous list lived in the
 * preferences dialog as six literal rows, which is a copy of the truth, and a
 * printed copy of the truth is the one that rots unnoticed — nothing fails
 * when a hand-written sheet describes a shortcut that no longer exists.
 *
 * `handled` closes the remaining gap. The keymap says what a chord *means*;
 * only the app knows which meanings it has actually wired up. Pass the command
 * ids it dispatches and any binding without a handler is shown as unassigned
 * rather than quietly presented as working.
 *
 * `ShortcutsList` is exported separately because `Modal` renders through a
 * portal into `document.body`, which this project's test setup has no document
 * for — the same split `SessionInspector` uses.
 */

export interface ShortcutsListProps {
  /** Defaults to the app keymap. */
  bindings?: readonly KeyBinding[]
  /** Command ids the app dispatches. Omit to trust every binding. */
  handled?: readonly string[]
  /** Defaults to sniffing the platform. */
  isMac?: boolean
}

export function ShortcutsList({
  bindings = KEYMAP,
  handled,
  isMac = detectMac(),
}: ShortcutsListProps) {
  const [query, setQuery] = useState('')
  const searchRef = useRef<HTMLInputElement>(null)
  const ids = useId()

  // Mounted fresh on every open — Modal renders nothing while closed — so the
  // filter starts empty without needing to be reset. A stale filter would look
  // like a sheet that had lost half its shortcuts.
  useEffect(() => {
    // Modal moves focus to its own panel first, so this has to land after it.
    const frame = requestAnimationFrame(() => searchRef.current?.focus())
    return () => cancelAnimationFrame(frame)
  }, [])

  const matches = useMemo(() => searchKeymap(query, bindings, isMac), [query, bindings, isMac])
  const groups = useMemo(() => groupedKeymap(matches), [matches])

  const wired = useMemo(() => (handled ? new Set(handled) : null), [handled])
  const searching = query.trim().length > 0

  return (
    <div className="sheet">
      <div className="sheet-search">
        <svg
          width="13"
          height="13"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          aria-hidden="true"
        >
          <circle cx="11" cy="11" r="7" strokeWidth="2" />
          <path d="M16.5 16.5L21 21" strokeWidth="2" strokeLinecap="round" />
        </svg>
        <input
          ref={searchRef}
          type="search"
          className="sheet-input"
          value={query}
          placeholder="Search shortcuts"
          aria-label="Search shortcuts"
          aria-describedby={`${ids}-count`}
          onChange={(event) => setQuery(event.target.value)}
        />
        {/* Announced politely so a screen reader hears the count settle rather
            than every keystroke's worth of it. */}
        <span className="sheet-count" id={`${ids}-count`} role="status" aria-live="polite">
          {searching ? `${matches.length} of ${bindings.length}` : `${bindings.length}`}
        </span>
      </div>

      {groups.length === 0 ? (
        // An empty keymap is not a failed search: `Nothing matches “”` reads
        // like a bug in the filter rather than a sheet with nothing to show.
        <p className="sheet-empty">
          {searching ? `Nothing matches “${query.trim()}”.` : 'No shortcuts to show.'}
        </p>
      ) : (
        groups.map((group) => (
          <section
            key={group.scope}
            className="sheet-group"
            aria-labelledby={`${ids}-${group.scope}`}
          >
            <header className="sheet-group-head">
              <h3 className="sheet-group-title" id={`${ids}-${group.scope}`}>
                {group.title}
              </h3>
              <p className="sheet-group-hint">{group.hint}</p>
            </header>

            <ul className="sheet-rows">
              {group.bindings.map((binding) => {
                const unassigned = wired !== null && !binding.passthrough && !wired.has(binding.id)
                return (
                  <li
                    key={binding.id}
                    className="sheet-row"
                    data-unassigned={unassigned || undefined}
                  >
                    <span className="sheet-label">
                      {binding.label}
                      {binding.passthrough && (
                        <span className="sheet-flag" title="Deck never intercepts this">
                          passes through
                        </span>
                      )}
                      {unassigned && (
                        <span
                          className="sheet-flag warn"
                          title="No handler is wired to this command"
                        >
                          unassigned
                        </span>
                      )}
                    </span>
                    <span className="sheet-keys">
                      {formatBinding(binding, isMac).map((chord, index) => (
                        <span key={chord} className="sheet-chord">
                          {index > 0 && <span className="sheet-or">or</span>}
                          <kbd>{chord}</kbd>
                        </span>
                      ))}
                    </span>
                  </li>
                )
              })}
            </ul>
          </section>
        ))
      )}
    </div>
  )
}

export interface ShortcutsSheetProps extends ShortcutsListProps {
  open: boolean
  onClose(): void
}

export function ShortcutsSheet({ open, onClose, ...list }: ShortcutsSheetProps) {
  return (
    <Modal
      open={open}
      title="Keyboard shortcuts"
      description="Every shortcut the app knows about, straight from its keymap."
      onClose={onClose}
      size="lg"
    >
      <ShortcutsList {...list} />
    </Modal>
  )
}

import {
  useCallback,
  useEffect,
  useId,
  useMemo,
  useReducer,
  useRef,
  type CSSProperties,
  type KeyboardEvent as ReactKeyboardEvent,
} from 'react'
import './FileTree.css'

/**
 * Mirrors the shapes returned by `src/main/fs-tree.ts`. Declared locally
 * because `shared/types.ts` is owned by the orchestrator — fold these in there
 * when the IPC is wired and delete the copies.
 */
export interface FsEntry {
  name: string
  /** POSIX-separated path relative to the project root. */
  relPath: string
  kind: 'dir' | 'file'
  symlink: boolean
  /** Refused: a link out of the project, a loop, a broken link or a device. */
  blocked: boolean
}

export interface DirListing {
  relPath: string
  entries: FsEntry[]
  truncated: boolean
}

interface FsBridge {
  listDir(root: string, relDir: string, options?: { showIgnored?: boolean }): Promise<DirListing>
}

function listDir(root: string, relDir: string, showIgnored: boolean): Promise<DirListing> {
  const api = (window as unknown as { pawl?: Partial<FsBridge> }).pawl
  if (!api?.listDir) {
    return Promise.reject(new Error('preload bridge is missing pawl.listDir'))
  }
  return api.listDir(root, relDir, { showIgnored })
}

/** Electron wraps IPC rejections; the prefix is noise in a tree row. */
function messageOf(err: unknown): string {
  const raw = err instanceof Error ? err.message : String(err)
  return raw.replace(/^Error invoking remote method '[^']*':\s*/, '')
}

const ROOT = ''

function parentOf(relPath: string): string {
  const cut = relPath.lastIndexOf('/')
  return cut === -1 ? ROOT : relPath.slice(0, cut)
}

/* --------------------------------------------------------------- state -- */

interface TreeState {
  /** Children by directory, keyed on relative path; '' is the project root. */
  children: Map<string, FsEntry[]>
  expanded: Set<string>
  loading: Set<string>
  errors: Map<string, string>
  truncated: Set<string>
  focused: string | null
}

type TreeAction =
  | { type: 'reset' }
  | { type: 'expand'; dir: string }
  | { type: 'collapse'; dir: string }
  | { type: 'load-start'; dir: string }
  | { type: 'load-ok'; dir: string; listing: DirListing }
  | { type: 'load-fail'; dir: string; message: string }
  | { type: 'focus'; relPath: string | null }

const EMPTY: TreeState = {
  children: new Map(),
  expanded: new Set(),
  loading: new Set(),
  errors: new Map(),
  truncated: new Set(),
  focused: null,
}

function withAdded<T>(set: Set<T>, value: T): Set<T> {
  const next = new Set(set)
  next.add(value)
  return next
}

function withRemoved<T>(set: Set<T>, value: T): Set<T> {
  const next = new Set(set)
  next.delete(value)
  return next
}

function reducer(state: TreeState, action: TreeAction): TreeState {
  switch (action.type) {
    case 'reset':
      return EMPTY

    case 'expand':
      return { ...state, expanded: withAdded(state.expanded, action.dir) }

    case 'collapse':
      return { ...state, expanded: withRemoved(state.expanded, action.dir) }

    case 'load-start': {
      const errors = new Map(state.errors)
      errors.delete(action.dir)
      return {
        ...state,
        errors,
        expanded: action.dir === ROOT ? state.expanded : withAdded(state.expanded, action.dir),
        loading: withAdded(state.loading, action.dir),
      }
    }

    case 'load-ok': {
      const children = new Map(state.children)
      children.set(action.dir, action.listing.entries)
      return {
        ...state,
        children,
        loading: withRemoved(state.loading, action.dir),
        truncated: action.listing.truncated
          ? withAdded(state.truncated, action.dir)
          : withRemoved(state.truncated, action.dir),
        // Land the cursor on the first row so the keyboard works immediately.
        focused:
          state.focused ?? (action.dir === ROOT ? (action.listing.entries[0]?.relPath ?? null) : null),
      }
    }

    case 'load-fail': {
      const errors = new Map(state.errors)
      errors.set(action.dir, action.message)
      return {
        ...state,
        errors,
        loading: withRemoved(state.loading, action.dir),
        expanded: withRemoved(state.expanded, action.dir),
      }
    }

    case 'focus':
      return { ...state, focused: action.relPath }
  }
}

/* --------------------------------------------------------------- icons -- */

function Chevron() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
      <path d="M9 5l7 7-7 7" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}

function FolderIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
      <path
        d="M3 6.5A1.5 1.5 0 0 1 4.5 5h4l2 2.5h9a1.5 1.5 0 0 1 1.5 1.5v9a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 18z"
        strokeWidth="1.6"
        strokeLinejoin="round"
      />
    </svg>
  )
}

function FileIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
      <path d="M13 3H6.5A1.5 1.5 0 0 0 5 4.5v15A1.5 1.5 0 0 0 6.5 21h11a1.5 1.5 0 0 0 1.5-1.5V9z" strokeWidth="1.6" strokeLinejoin="round" />
      <path d="M13 3v6h6" strokeWidth="1.6" strokeLinejoin="round" />
    </svg>
  )
}

/* ------------------------------------------------------------ component -- */

interface Row {
  entry: FsEntry
  depth: number
}

interface Props {
  /** Absolute path of the project root. Changing it reloads the whole tree. */
  root: string
  /** Relative path to highlight — normally whatever the viewer has open. */
  selected?: string | null
  /**
   * Fired when a row is activated by click or Enter, for directories as well
   * as files. Filter on `entry.kind` if only files are interesting.
   */
  onSelect?(entry: FsEntry): void
  /** Show entries the ignore files hide. node_modules and .git stay hidden. */
  showIgnored?: boolean
  className?: string
}

/**
 * Lazy project tree: one directory level is fetched per expand, so opening a
 * large repo costs a single readdir rather than a full walk.
 *
 * Focus is virtual — the container is the only tab stop and
 * `aria-activedescendant` points at the current row. Moving focus between rows
 * with real DOM focus would fight the roving-tabindex expectations of a tree
 * and steal focus from the terminal on every arrow key.
 */
export function FileTree({ root, selected, onSelect, showIgnored = false, className }: Props) {
  const [state, dispatch] = useReducer(reducer, EMPTY)
  const listRef = useRef<HTMLDivElement>(null)
  const baseId = useId()

  // Bumped whenever the tree is rebuilt, so a slow reply for the previous root
  // cannot overwrite the new one.
  const genRef = useRef(0)

  const load = useCallback(
    async (dir: string) => {
      const gen = genRef.current
      dispatch({ type: 'load-start', dir })
      try {
        const listing = await listDir(root, dir, showIgnored)
        if (genRef.current === gen) dispatch({ type: 'load-ok', dir, listing })
      } catch (err) {
        if (genRef.current === gen) dispatch({ type: 'load-fail', dir, message: messageOf(err) })
      }
    },
    [root, showIgnored],
  )

  useEffect(() => {
    genRef.current += 1
    dispatch({ type: 'reset' })
    void load(ROOT)
  }, [load])

  const rows = useMemo(() => {
    const out: Row[] = []
    const walk = (dir: string, depth: number) => {
      for (const entry of state.children.get(dir) ?? []) {
        out.push({ entry, depth })
        if (entry.kind === 'dir' && state.expanded.has(entry.relPath)) {
          walk(entry.relPath, depth + 1)
        }
      }
    }
    walk(ROOT, 0)
    return out
  }, [state.children, state.expanded])

  const focusedIndex = useMemo(
    () => rows.findIndex((row) => row.entry.relPath === state.focused),
    [rows, state.focused],
  )

  // Keep the virtual cursor on screen without yanking the page around.
  useEffect(() => {
    listRef.current?.querySelector('[data-focused="true"]')?.scrollIntoView({ block: 'nearest' })
  }, [state.focused, rows])

  const toggle = useCallback(
    (entry: FsEntry) => {
      if (entry.kind !== 'dir' || entry.blocked) return
      if (state.expanded.has(entry.relPath)) {
        dispatch({ type: 'collapse', dir: entry.relPath })
      } else if (state.children.has(entry.relPath)) {
        dispatch({ type: 'expand', dir: entry.relPath })
      } else {
        void load(entry.relPath)
      }
    },
    [load, state.children, state.expanded],
  )

  const activate = useCallback(
    (entry: FsEntry) => {
      // The cursor still lands on a blocked row — keyboard navigation must not
      // dead-end on one — but nothing else happens: the row says aria-disabled
      // and cursor:not-allowed, and selecting it only buys the viewer a
      // guaranteed read error on a broken link, a device or an escaping symlink.
      dispatch({ type: 'focus', relPath: entry.relPath })
      if (entry.blocked) return
      toggle(entry)
      onSelect?.(entry)
    },
    [onSelect, toggle],
  )

  const moveTo = useCallback(
    (index: number) => {
      const row = rows[Math.max(0, Math.min(index, rows.length - 1))]
      if (row) dispatch({ type: 'focus', relPath: row.entry.relPath })
    },
    [rows],
  )

  function onKeyDown(event: ReactKeyboardEvent<HTMLDivElement>) {
    if (rows.length === 0) return
    const current = focusedIndex >= 0 ? rows[focusedIndex] : undefined
    const entry = current?.entry

    switch (event.key) {
      case 'ArrowDown':
        moveTo(focusedIndex + 1)
        break

      case 'ArrowUp':
        moveTo(focusedIndex === -1 ? 0 : focusedIndex - 1)
        break

      case 'ArrowRight':
        if (!entry || entry.kind !== 'dir' || entry.blocked) return
        if (state.expanded.has(entry.relPath)) moveTo(focusedIndex + 1)
        else toggle(entry)
        break

      case 'ArrowLeft':
        if (!entry) return
        if (entry.kind === 'dir' && state.expanded.has(entry.relPath)) {
          dispatch({ type: 'collapse', dir: entry.relPath })
        } else {
          const parent = parentOf(entry.relPath)
          if (parent !== ROOT) dispatch({ type: 'focus', relPath: parent })
        }
        break

      case 'Home':
        moveTo(0)
        break

      case 'End':
        moveTo(rows.length - 1)
        break

      case 'Enter':
      case ' ':
        if (entry) activate(entry)
        break

      default:
        return
    }

    event.preventDefault()
  }

  const rootError = state.errors.get(ROOT)
  const rootLoading = state.loading.has(ROOT)

  return (
    <div
      ref={listRef}
      className={`file-tree${className ? ` ${className}` : ''}`}
      role="tree"
      aria-label="Project files"
      aria-activedescendant={focusedIndex >= 0 ? `${baseId}-${focusedIndex}` : undefined}
      tabIndex={0}
      onKeyDown={onKeyDown}
    >
      {rootError && <p className="file-tree-msg error">{rootError}</p>}
      {!rootError && rootLoading && rows.length === 0 && <p className="file-tree-msg">Loading…</p>}
      {!rootError && !rootLoading && rows.length === 0 && (
        <p className="file-tree-msg">Nothing to show.</p>
      )}

      {rows.map((row, index) => {
        const { entry, depth } = row
        const isDir = entry.kind === 'dir'
        const isExpanded = isDir && state.expanded.has(entry.relPath)
        const error = state.errors.get(entry.relPath)

        return (
          // role="none" keeps the wrapper out of the accessibility tree, so the
          // treeitem below stays an owned child of role="tree" rather than being
          // buried under a generic div that breaks the ownership chain.
          <div key={entry.relPath} className="file-tree-branch" role="none">
            <div
              id={`${baseId}-${index}`}
              role="treeitem"
              aria-level={depth + 1}
              aria-expanded={isDir && !entry.blocked ? isExpanded : undefined}
              aria-selected={entry.relPath === selected}
              aria-disabled={entry.blocked || undefined}
              data-focused={index === focusedIndex}
              data-kind={entry.kind}
              className={`file-tree-row${entry.relPath === selected ? ' selected' : ''}${
                entry.blocked ? ' blocked' : ''
              }`}
              style={{ '--depth': String(depth) } as CSSProperties}
              title={entry.blocked ? `${entry.name} — link leaves the project, or loops` : entry.relPath}
              onClick={() => activate(entry)}
            >
              <span className={`file-tree-twisty${isExpanded ? ' open' : ''}`} aria-hidden="true">
                {isDir && !entry.blocked && <Chevron />}
              </span>
              <span className="file-tree-icon" aria-hidden="true">
                {isDir ? <FolderIcon /> : <FileIcon />}
              </span>
              <span className="file-tree-name">{entry.name}</span>
              {entry.symlink && <span className="file-tree-tag">link</span>}
              {state.loading.has(entry.relPath) && <span className="file-tree-tag">…</span>}
            </div>

            {error && (
              <p
                className="file-tree-msg error"
                style={{ '--depth': String(depth + 1) } as CSSProperties}
              >
                {error}
              </p>
            )}

            {state.truncated.has(entry.relPath) && isExpanded && (
              <p
                className="file-tree-msg"
                style={{ '--depth': String(depth + 1) } as CSSProperties}
              >
                Too many entries — list shortened.
              </p>
            )}
          </div>
        )
      })}

      {state.truncated.has(ROOT) && <p className="file-tree-msg">Too many entries — list shortened.</p>}
    </div>
  )
}

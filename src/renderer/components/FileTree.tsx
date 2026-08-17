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
import { readFailure, withDeadline } from '../deadline'
import { recall, remember } from '../panel-cache'
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
  /** Only when the level was listed `withStats` — the root level is. */
  modifiedAt?: number
  bytes?: number
}

export interface DirListing {
  relPath: string
  entries: FsEntry[]
  truncated: boolean
  /**
   * The file this level would open first, chosen in `src/main/fs-tree.ts`.
   * Present on the root listing only, because that is the only level this tree
   * asks for stats on. Never re-derived here — see `pickDefaultFile`.
   */
  defaultFile?: string | null
}

interface FsBridge {
  listDir(
    root: string,
    relDir: string,
    options?: { showIgnored?: boolean; withStats?: boolean },
  ): Promise<DirListing>
}

/**
 * How long one directory listing has to come back.
 *
 * A `readdir` plus a `stat` per row on a local disk is milliseconds. Ten
 * seconds is not a performance budget, it is the line past which the read has
 * plainly not happened at all — an unreachable network mount, a channel this
 * build never registered, a handler awaiting something that never finishes —
 * and the tree has to say so rather than print "Loading…" until the app is
 * quit. The whole file panel used to have no such line.
 */
const LIST_DEADLINE_MS = 10_000

function listDir(
  root: string,
  relDir: string,
  options: { showIgnored: boolean; withStats: boolean },
): Promise<DirListing> {
  const api = (window as unknown as { deck?: Partial<FsBridge> }).deck
  if (!api?.listDir) {
    return Promise.reject(new Error('preload bridge is missing terminaldeck.listDir'))
  }
  return withDeadline(
    api.listDir(root, relDir, options),
    relDir === '' ? 'Reading this folder' : `Reading ${relDir}`,
    LIST_DEADLINE_MS,
  )
}

const ROOT = ''

/**
 * How long a tree that has already been read stays good for.
 *
 * The shell unmounts a view the moment a session takes the window back, so
 * every trip out and in used to re-`readdir` the project and flash "Loading…"
 * over a list that had not changed. Ten seconds covers going to a terminal and
 * coming back — the thing Asad was doing when he watched the page thrash — and
 * is short enough that a file an agent wrote a moment ago still turns up.
 * Past it the tree is still painted from what it had; the re-read happens
 * underneath, with no spinner, and lands when it lands.
 */
export const TREE_FRESH_MS = 10_000

/** What the cache holds for one tree, in a shape that survives a round trip. */
interface CachedTree {
  children: Array<[string, FsEntry[]]>
  expanded: string[]
  truncated: string[]
  focused: string | null
  /** The root listing's own answer to "what should open first". */
  defaultFile: string | null
}

function treeKey(root: string, showIgnored: boolean): string {
  return `files:tree:${root}|${showIgnored ? 'all' : 'visible'}`
}

function parentOf(relPath: string): string {
  const cut = relPath.lastIndexOf('/')
  return cut === -1 ? ROOT : relPath.slice(0, cut)
}

/**
 * May this listing open a file on the reader's behalf?
 *
 * A named rule rather than three conditions inside a callback, because all
 * three exist to stop the same thing — the tree taking the selection away from
 * somebody who is using it — and each one is a bug if it goes missing:
 *
 *  - **root only.** Expanding `src/` must not jump the viewer to `src/index.ts`.
 *  - **nothing open.** Arriving at Files from Source control, with a changed
 *    file already open, must show that file and not the README.
 *  - **once per project.** The listing is re-fetched when an ignore file is
 *    edited or `showIgnored` is toggled, and each of those would otherwise drag
 *    the reader back to the README from whatever they had opened.
 */
export function shouldAutoOpen(params: {
  autoSelect: boolean
  /** The directory that was just listed. */
  dir: string
  root: string
  /** The root this tree has already opened a file for, if any. */
  openedFor: string | null
  selected: string | null | undefined
}): boolean {
  if (!params.autoSelect) return false
  if (params.dir !== ROOT) return false
  if (params.openedFor === params.root) return false
  return !params.selected
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
  | { type: 'hydrate'; cached: CachedTree }
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

/**
 * What the whole tree amounts to, for whoever is drawing the page around it.
 *
 * The Files page is a tree and a viewer side by side, and they used to resolve
 * independently: the left column said *"Nothing to show."* while the right one
 * headed a `README.md` over a blank body, at the same moment, on the same
 * screen. Two components each telling the truth about themselves is not the
 * same as a page telling the truth, and this type is how the page gets one
 * answer to reconcile against.
 *
 * `error` carries the reason, because "it failed" with no reason is the state
 * this pass exists to delete.
 */
export type TreeRootState =
  | { status: 'loading' }
  | { status: 'ready'; count: number }
  | { status: 'empty' }
  | { status: 'error'; message: string }

/** The one place the tree's overall condition is decided. Pure, so it is pinned. */
export function rootStateOf(state: TreeState): TreeRootState {
  const message = state.errors.get(ROOT)
  if (message !== undefined) return { status: 'error', message }
  const entries = state.children.get(ROOT)
  // Nothing listed yet is "loading" whether or not a request is in flight this
  // millisecond: the first render happens before the effect that starts one,
  // and a page that flashed "empty" in that gap and then filled in would be
  // lying for a frame. Once there *are* entries the answer never goes back to
  // loading — a background re-read must not blank a list somebody is using.
  if (entries === undefined) return { status: 'loading' }
  if (entries.length === 0) return { status: 'empty' }
  return { status: 'ready', count: entries.length }
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

    /**
     * The tree this page had the last time it was open.
     *
     * Not an optimisation for its own sake: the shell unmounts a view whenever
     * a session takes the window, so without this every visit to Files started
     * from a blank pane with every folder collapsed, however many the reader
     * had opened a second earlier.
     */
    case 'hydrate':
      return {
        children: new Map(action.cached.children),
        expanded: new Set(action.cached.expanded),
        loading: new Set(),
        errors: new Map(),
        truncated: new Set(action.cached.truncated),
        focused: action.cached.focused,
      }

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
  /**
   * Open a file by itself when the tree first lands and nothing is selected.
   *
   * On by default, and the reason this page stopped opening on an instruction.
   * Off is for a tree used as a picker inside a dialog, where choosing
   * something on the user's behalf would answer a question they were asked.
   */
  autoSelect?: boolean
  /**
   * Told whenever the tree's overall condition changes — loading, ready, empty
   * or failed with a reason.
   *
   * Optional, because a tree inside a picker is the whole of its own page. The
   * Files page passes one because it draws a *viewer* beside this, and the two
   * used to contradict each other on screen: "Nothing to show." on the left and
   * a file header on the right, at the same instant. See `TreeRootState`.
   */
  onRootState?(state: TreeRootState): void
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
export function FileTree({
  root,
  selected,
  onSelect,
  showIgnored = false,
  autoSelect = true,
  onRootState,
  className,
}: Props) {
  const [state, dispatch] = useReducer(reducer, EMPTY)
  const listRef = useRef<HTMLDivElement>(null)
  const baseId = useId()

  // Bumped whenever the tree is rebuilt, so a slow reply for the previous root
  // cannot overwrite the new one.
  const genRef = useRef(0)

  /*
   * Read through refs inside `load`, never closed over.
   *
   * `onSelect` is an inline arrow at every call site, so depending on it would
   * rebuild `load` on every render of the parent and re-fetch the whole root
   * listing with it. `selected` changes the moment the auto-selection lands,
   * which would do the same thing and then immediately auto-select again.
   */
  const onSelectRef = useRef(onSelect)
  onSelectRef.current = onSelect
  const selectedRef = useRef(selected)
  selectedRef.current = selected
  /** The root this tree has already opened a file for. Once per project. */
  const openedFor = useRef<string | null>(null)
  /** The root listing as last read, so it can be cached on the way out. */
  const rootListing = useRef<DirListing | null>(null)

  /**
   * Open the file this listing nominates, if the tree is allowed to.
   *
   * Lifted out of `load` because a listing now arrives two ways — read from
   * disk, or recalled from the last time this page was open — and both have to
   * make the same decision. Missing it on the cached path would mean returning
   * to Files after a trip to a terminal and finding the viewer empty, which is
   * the very "the page shows nothing" report `shouldAutoOpen` was written for.
   */
  const autoOpen = useCallback(
    (dir: string, listing: Pick<DirListing, 'entries' | 'defaultFile'>) => {
      if (
        !shouldAutoOpen({
          autoSelect,
          dir,
          root,
          openedFor: openedFor.current,
          selected: selectedRef.current,
        })
      ) {
        return
      }
      openedFor.current = root
      const first = listing.defaultFile
        ? listing.entries.find((entry) => entry.relPath === listing.defaultFile)
        : undefined
      if (!first) return
      dispatch({ type: 'focus', relPath: first.relPath })
      onSelectRef.current?.(first)
    },
    [autoSelect, root],
  )

  const load = useCallback(
    /**
     * `silent` is a re-read behind a tree that is already on screen: the cache
     * gave us something stale, we are checking it, and the reader must not
     * watch their list turn into the word "Loading…" while we do.
     */
    async (dir: string, silent = false) => {
      const gen = genRef.current
      if (!silent) dispatch({ type: 'load-start', dir })
      try {
        // Stats on the root level only. They cost a `stat` per row, they are
        // what `defaultFile` is decided from, and no other level needs them.
        const listing = await listDir(root, dir, { showIgnored, withStats: dir === ROOT })
        if (genRef.current !== gen) return
        dispatch({ type: 'load-ok', dir, listing })
        if (dir === ROOT) rootListing.current = listing
        /*
         * Open something.
         *
         * The Files page was reported as showing nothing: the tree was there,
         * and the whole right-hand pane said "pick something from the tree and
         * it opens here". A file browser that has read the folder already
         * knows what to show — `pickDefaultFile` in `src/main/fs-tree.ts`
         * chooses it, and `shouldAutoOpen` above says when this is allowed to.
         */
        autoOpen(dir, listing)
      } catch (err) {
        if (genRef.current !== gen) return
        // A silent re-read that fails leaves the tree the reader is looking at
        // exactly where it was. Replacing a working list with an error because
        // a background check went wrong would be the refresh doing damage.
        if (silent) return
        dispatch({ type: 'load-fail', dir, message: readFailure(err) })
      }
    },
    [root, showIgnored, autoOpen],
  )

  useEffect(() => {
    genRef.current += 1
    rootListing.current = null

    /*
     * The tree this page had last time, before anything is asked for.
     *
     * Without it, every trip to a session and back re-read the project and
     * flashed "Loading…" over a list that had not changed — see `TREE_FRESH_MS`.
     * A fresh entry is the whole answer; a stale one is still painted, and the
     * re-read that follows is silent.
     */
    const held = recall<CachedTree>(treeKey(root, showIgnored), TREE_FRESH_MS)
    if (!held) {
      dispatch({ type: 'reset' })
      void load(ROOT)
      return
    }

    dispatch({ type: 'hydrate', cached: held.value })
    rootListing.current = {
      relPath: ROOT,
      entries: held.value.children.find(([dir]) => dir === ROOT)?.[1] ?? [],
      truncated: held.value.truncated.includes(ROOT),
      defaultFile: held.value.defaultFile,
    }
    autoOpen(ROOT, rootListing.current)
    if (!held.fresh) void load(ROOT, true)
  }, [load, autoOpen, root, showIgnored])

  /**
   * Hand the tree back to the cache on the way out.
   *
   * On unmount rather than on every change: the state is a set of Maps that
   * turn over on each expand, and writing on every one of them would be a
   * serialisation per keystroke of arrow-key travel. Leaving the page is the
   * only moment the value is actually wanted.
   */
  const stateRef = useRef(state)
  stateRef.current = state
  useEffect(() => {
    const key = treeKey(root, showIgnored)
    return () => {
      const current = stateRef.current
      // Nothing was ever read — an error, or an unmount mid-flight. Caching an
      // empty tree would make the next visit paint "Nothing to show." for a
      // project that has plenty in it.
      if (!current.children.has(ROOT)) return
      remember<CachedTree>(key, {
        children: [...current.children],
        expanded: [...current.expanded],
        truncated: [...current.truncated],
        focused: current.focused,
        defaultFile: rootListing.current?.defaultFile ?? null,
      })
    }
  }, [root, showIgnored])

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

  const rootState = rootStateOf(state)

  /*
   * Tell the page what this tree amounts to.
   *
   * In an effect and guarded by a comparison, because the callback is an inline
   * arrow at the call site and `rootStateOf` builds a fresh object every
   * render: calling it unguarded would set state in the parent on every frame
   * and loop. Only a genuine change in the tree's condition travels.
   */
  const reportRef = useRef(onRootState)
  reportRef.current = onRootState
  const reported = useRef<string>('')
  useEffect(() => {
    const encoded = JSON.stringify(rootState)
    if (encoded === reported.current) return
    reported.current = encoded
    reportRef.current?.(rootState)
  }, [rootState])

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
      {/*
        One message at a time, chosen by one function.

        These were three independent conditions over two pieces of state, and
        two of them could disagree: `!rootLoading && rows.length === 0` printed
        "Nothing to show." during the frame between the reducer's `reset` and
        the request that follows it, and again for the whole of a re-read whose
        reply was dropped by the generation guard. A tree that says a project is
        empty when it has not finished looking is the same class of lie as a
        spinner that never stops.
      */}
      {rootState.status === 'error' && <p className="file-tree-msg error">{rootState.message}</p>}
      {rootState.status === 'loading' && <p className="file-tree-msg">Loading…</p>}
      {rootState.status === 'empty' && <p className="file-tree-msg">Nothing to show.</p>}

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

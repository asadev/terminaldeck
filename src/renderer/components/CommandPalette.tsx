import {
  useCallback,
  useDeferredValue,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent as ReactKeyboardEvent,
  type MouseEvent as ReactMouseEvent,
  type ReactNode,
} from 'react'
import {
  basenameStart,
  clampRanges,
  rankMatches,
  segmentByRanges,
  type MatchRange,
} from '../fuzzy'
import './CommandPalette.css'

/**
 * Quick open and the command palette are the same surface. They share a text
 * field, a ranked list, the same keys and the same highlighting; the only
 * difference is where the rows come from. Building them as two components
 * meant two sets of keyboard bugs, so this is one component with two row
 * sources, switched by a leading `>` exactly like the editors people already
 * have muscle memory for.
 */

export interface PaletteCommand {
  id: string
  /** What the user sees, and the text that gets highlighted. */
  title: string
  /** Category shown ahead of the title. Searchable, never highlighted. */
  group?: string
  /** Right-aligned hint, e.g. '⌘T'. */
  shortcut?: string
  /** Extra words that should find this command without cluttering its label. */
  keywords?: string
  /** Hidden from the list when false. */
  enabled?: boolean
  run(): void | Promise<void>
}

export interface FileSelection {
  /** Absolute project root the path is relative to. */
  root: string
  /** Project-relative, forward slashes. */
  path: string
  /** Present when the query ended in `:42`. */
  line?: number
}

export type PaletteMode = 'files' | 'commands'

export interface CommandPaletteProps {
  open: boolean
  /** Which mode to open in. Quick open → 'files', command palette → 'commands'. */
  mode?: PaletteMode
  commands: readonly PaletteCommand[]
  /** Project to search. Null pins the palette to command mode. */
  projectRoot: string | null
  onClose(): void
  onOpenFile(selection: FileSelection): void
  /**
   * Override where the file list comes from. Defaults to the preload bridge;
   * supply this to drive the palette from an existing list or in a test.
   */
  loadFiles?(root: string, signal: AbortSignal): Promise<string[]>
}

/** Rows past this point are noise — nobody scrolls a fuzzy list to 200. */
const MAX_RESULTS = 60
const PAGE_JUMP = 8
const MAX_RECENTS = 12

const IS_MAC = typeof navigator !== 'undefined' && /Mac|iPhone|iPad/.test(navigator.userAgent)

/**
 * File lists survive closing the palette. Re-fetching a 10,000-path list every
 * time ⌘P is pressed adds a visible stall to an interaction whose entire point
 * is that it feels instant.
 */
const fileListCache = new Map<string, string[]>()
const recentFiles = new Map<string, string[]>()
/** Shared empty array — a fresh `[]` per render would invalidate every memo. */
const NO_RECENTS: readonly string[] = []

/** Discard a cached list — call when the project's files change on disk. */
export function invalidatePaletteFiles(root?: string): void {
  if (root === undefined) fileListCache.clear()
  else fileListCache.delete(root)
}

type SearchResponse = { ok: true; files: string[] } | { ok: false; error: string }

interface FileSearchBridge {
  searchProjectFiles(request: { root: string; refresh?: boolean }): Promise<SearchResponse>
}

/**
 * The preload bridge is typed in shared/types.ts, which this feature does not
 * own. Until the search methods are declared there, they are reached through a
 * narrow local shape and a feature check, so the palette degrades to command
 * mode instead of throwing when the bridge has not been wired yet.
 */
function fileSearchBridge(): FileSearchBridge | null {
  if (typeof window === 'undefined') return null
  const api = (window as unknown as { deck?: Partial<FileSearchBridge> }).deck
  return api && typeof api.searchProjectFiles === 'function' ? (api as FileSearchBridge) : null
}

async function loadFilesFromBridge(root: string): Promise<string[]> {
  const bridge = fileSearchBridge()
  if (!bridge) throw new Error('file search bridge unavailable')
  const response = await bridge.searchProjectFiles({ root })
  if (!response.ok) throw new Error(`file search failed: ${response.error}`)
  return response.files
}

/** Editors count lines from 1, and none of them has a billionth line. Digits
 *  outside that are part of the name, not a jump target. */
const MAX_LINE = 1_000_000_000

/** `src/main/index.ts:42` — the trailing line number is not part of the name. */
export function parseFileQuery(raw: string): { text: string; line?: number } {
  const match = /^(.*?):(\d+)\s*$/.exec(raw)
  if (!match || match[1] === '') return { text: raw }
  const line = Number(match[2])
  // `:0` and `:99999999999999999999` are not line numbers. Treating them as
  // one hands the opener a line it cannot scroll to and, worse, silently drops
  // the digits from the name being searched for.
  if (!Number.isSafeInteger(line) || line < 1 || line > MAX_LINE) return { text: raw }
  return { text: match[1], line }
}

/**
 * Where the selection lands after a move.
 *
 * Arrows and Tab wrap: a list that dead-ends at the bottom makes people hold
 * the key to get back to the top. Page jumps clamp — wrapping a jump of eight
 * through a five-row list lands on row three, which is neither end and reads
 * as a bug rather than as navigation.
 */
export function nextIndex(current: number, count: number, delta: number, wrap: boolean): number {
  if (count <= 0) return 0
  const from = Math.max(0, Math.min(current, count - 1))
  const target = from + delta
  if (!wrap) return Math.max(0, Math.min(count - 1, target))
  return ((target % count) + count) % count
}

/** Everything a command should be findable by; the title stays first so its
 *  highlight ranges line up with what is rendered. */
function commandSearchText(command: PaletteCommand): string {
  return [command.title, command.group, command.keywords].filter(Boolean).join(' ')
}

function rememberRecent(root: string, path: string): void {
  const previous = recentFiles.get(root) ?? []
  recentFiles.set(root, [path, ...previous.filter((p) => p !== path)].slice(0, MAX_RECENTS))
}

/** With no query there is nothing to rank, so the last files opened lead. */
function recentsFirst(files: readonly string[], recents: readonly string[]): string[] {
  if (recents.length === 0) return files as string[]
  const known = new Set(files)
  const lead = recents.filter((path) => known.has(path))
  if (lead.length === 0) return files as string[]
  const leadSet = new Set(lead)
  return [...lead, ...files.filter((path) => !leadSet.has(path))]
}

type PaletteRow =
  | { kind: 'file'; key: string; path: string; ranges: MatchRange[] }
  | { kind: 'command'; key: string; command: PaletteCommand; ranges: MatchRange[] }

function Highlight({ text, ranges }: { text: string; ranges: readonly MatchRange[] }): ReactNode {
  if (ranges.length === 0) return text
  return segmentByRanges(text, ranges).map((segment, i) =>
    segment.matched ? (
      <mark key={i} className="palette-hit">
        {segment.text}
      </mark>
    ) : (
      <span key={i}>{segment.text}</span>
    ),
  )
}

/**
 * Loads a project's file list once and keeps it. The signal aborts a load that
 * is superseded by another project, so a fast ⌘P–Escape–⌘P cannot leave a
 * stale list attached to the wrong root.
 */
function useProjectFiles(
  root: string | null,
  active: boolean,
  loader: CommandPaletteProps['loadFiles'],
): { files: string[]; loading: boolean; unavailable: boolean } {
  const [files, setFiles] = useState<string[]>([])
  const [loading, setLoading] = useState(false)
  const [unavailable, setUnavailable] = useState(false)

  // Held in a ref so an inline `loadFiles` prop does not restart the load on
  // every render of the parent.
  const loaderRef = useRef(loader)
  loaderRef.current = loader

  useEffect(() => {
    if (!active || !root) return

    const cached = fileListCache.get(root)
    if (cached) {
      setFiles(cached)
      setUnavailable(false)
      setLoading(false)
      return
    }

    const controller = new AbortController()
    setLoading(true)
    setUnavailable(false)

    void (async () => {
      try {
        const load = loaderRef.current
        const list = load ? await load(root, controller.signal) : await loadFilesFromBridge(root)
        if (controller.signal.aborted) return
        fileListCache.set(root, list)
        setFiles(list)
      } catch {
        if (controller.signal.aborted) return
        setFiles([])
        setUnavailable(true)
      } finally {
        if (!controller.signal.aborted) setLoading(false)
      }
    })()

    return () => controller.abort()
  }, [root, active])

  return { files, loading, unavailable }
}

export function CommandPalette({
  open,
  mode = 'files',
  commands,
  projectRoot,
  onClose,
  onOpenFile,
  loadFiles,
}: CommandPaletteProps) {
  // The mode the caller asked for, expressed the only way the palette stores
  // mode: as the query's prefix.
  const seedQuery = mode === 'commands' || projectRoot === null ? '>' : ''
  const [query, setQuery] = useState(seedQuery)
  const [activeIndex, setActiveIndex] = useState(0)
  const inputRef = useRef<HTMLInputElement>(null)
  const listRef = useRef<HTMLUListElement>(null)
  const restoreFocusTo = useRef<HTMLElement | null>(null)
  /** Set by keyboard navigation only — the mouse already knows where it is. */
  const scrollPending = useRef(false)

  const baseId = useId()
  const listId = `${baseId}-list`
  const optionId = (index: number): string => `${baseId}-option-${index}`

  // Seeding the field in an effect renders one full frame of the wrong
  // palette: ⌘K with a project open paints quick open — wrong label, wrong
  // placeholder, wrong glyph, "No files found." — before the effect corrects
  // it. Deriving it during render commits the right mode on the first paint.
  const [openedWith, setOpenedWith] = useState({ open, mode, projectRoot })
  if (
    openedWith.open !== open ||
    openedWith.mode !== mode ||
    openedWith.projectRoot !== projectRoot
  ) {
    setOpenedWith({ open, mode, projectRoot })
    if (open) {
      setQuery(seedQuery)
      setActiveIndex(0)
    }
  }

  // Command mode is a `>` prefix, so switching modes is just editing the
  // query — one piece of state, and the field always shows the true mode.
  const commandMode = query.startsWith('>') || projectRoot === null
  const rawTerm = commandMode ? query.replace(/^>/, '') : query
  const { text: fileTerm, line } = commandMode ? { text: rawTerm, line: undefined } : parseFileQuery(rawTerm)
  const term = commandMode ? rawTerm : fileTerm
  // Ranking runs on every keystroke over the whole project. Deferring it keeps
  // the field itself responsive when the list is large.
  const deferredTerm = useDeferredValue(term)

  const { files, loading, unavailable } = useProjectFiles(projectRoot, open, loadFiles)
  const recents = (projectRoot ? recentFiles.get(projectRoot) : undefined) ?? NO_RECENTS

  // `recents` is a stable reference: the map only ever hands back a new array
  // when a file is actually opened, so it is safe as a dependency.
  const candidates = useMemo(
    () => (deferredTerm.trim() === '' ? recentsFirst(files, recents) : files),
    [files, deferredTerm, recents],
  )

  const rows = useMemo<PaletteRow[]>(() => {
    if (commandMode) {
      const selectable = commands.filter((command) => command.enabled !== false)
      return rankMatches(selectable, deferredTerm, commandSearchText, {
        limit: MAX_RESULTS,
      }).map(({ item, ranges }) => ({
        kind: 'command',
        key: item.id,
        command: item,
        // Ranges beyond the title landed in the group or keywords, which are
        // matched but not highlighted.
        ranges: clampRanges(ranges, 0, item.title.length),
      }))
    }

    return rankMatches(candidates, deferredTerm, (path) => path, {
      limit: MAX_RESULTS,
      path: true,
    }).map(({ item, ranges }) => ({ kind: 'file', key: item, path: item, ranges }))
  }, [commandMode, commands, candidates, deferredTerm])

  const active = rows.length === 0 ? 0 : Math.min(activeIndex, rows.length - 1)

  // Keyed on `open` alone. Folding the mode into this effect would run the
  // cleanup — and hand focus back to the terminal — every time the mode changed
  // while the palette was still on screen.
  useEffect(() => {
    if (!open) return
    restoreFocusTo.current =
      document.activeElement instanceof HTMLElement ? document.activeElement : null
    inputRef.current?.focus()
    return () => {
      // Whatever had focus gets it back — usually a terminal, which is inert
      // until it does.
      restoreFocusTo.current?.focus()
      restoreFocusTo.current = null
    }
  }, [open])

  useEffect(() => {
    setActiveIndex(0)
  }, [deferredTerm, commandMode])

  useEffect(() => {
    if (!scrollPending.current) return
    scrollPending.current = false
    const list = listRef.current
    list?.children[active]?.scrollIntoView({ block: 'nearest' })
  }, [active, rows.length])

  const move = useCallback(
    (delta: number, wrap: boolean) => {
      scrollPending.current = true
      setActiveIndex((current) => nextIndex(current, rows.length, delta, wrap))
    },
    [rows.length],
  )

  const moveTo = useCallback(
    (index: number) => {
      scrollPending.current = true
      setActiveIndex(() => nextIndex(index, rows.length, 0, false))
    },
    [rows.length],
  )

  const activate = useCallback(
    (index: number) => {
      const row = rows[index]
      if (!row) return
      onClose()
      if (row.kind === 'command') {
        // A command that throws — or rejects — must not take the app's error
        // channel with it; the palette is already closed either way.
        try {
          const running = row.command.run()
          if (running) {
            void running.catch((error: unknown) => {
              console.error('[palette] command failed:', row.command.id, error)
            })
          }
        } catch (error) {
          console.error('[palette] command failed:', row.command.id, error)
        }
        return
      }
      if (!projectRoot) return
      rememberRecent(projectRoot, row.path)
      onOpenFile({ root: projectRoot, path: row.path, line })
    },
    [rows, onClose, onOpenFile, projectRoot, line],
  )

  const onKeyDown = useCallback(
    (event: ReactKeyboardEvent<HTMLDivElement>) => {
      switch (event.key) {
        case 'ArrowDown':
          event.preventDefault()
          move(1, true)
          break
        case 'ArrowUp':
          event.preventDefault()
          move(-1, true)
          break
        case 'PageDown':
          event.preventDefault()
          move(PAGE_JUMP, false)
          break
        case 'PageUp':
          event.preventDefault()
          move(-PAGE_JUMP, false)
          break
        case 'Home':
          event.preventDefault()
          moveTo(0)
          break
        case 'End':
          event.preventDefault()
          moveTo(rows.length - 1)
          break
        case 'Tab':
          // Focus never leaves the dialog; Tab cycles the list instead.
          event.preventDefault()
          move(event.shiftKey ? -1 : 1, true)
          break
        case 'Enter':
          event.preventDefault()
          activate(active)
          break
        case 'Escape':
          event.preventDefault()
          event.stopPropagation()
          onClose()
          break
        case 'n':
        case 'p':
          // Terminal muscle memory, and this app is full of terminals.
          if (event.ctrlKey && !event.metaKey && !event.altKey) {
            event.preventDefault()
            move(event.key === 'n' ? 1 : -1, true)
          }
          break
        default:
          break
      }
    },
    [move, moveTo, activate, active, rows.length, onClose],
  )

  const onBackdropMouseDown = useCallback(
    (event: ReactMouseEvent<HTMLDivElement>) => {
      if (event.target === event.currentTarget) onClose()
    },
    [onClose],
  )

  if (!open) return null

  const placeholder = commandMode
    ? 'Run a command…'
    : projectRoot
      ? 'Search files by name — add :42 for a line'
      : 'Open a project to search files'
  const label = commandMode ? 'Command palette' : 'Quick open'

  let emptyMessage: string | null = null
  if (rows.length === 0) {
    if (!commandMode && unavailable) emptyMessage = 'Could not read this project’s files.'
    else if (!commandMode && loading) emptyMessage = 'Reading project files…'
    else if (term.trim() === '') emptyMessage = commandMode ? 'No commands available.' : 'No files found.'
    else emptyMessage = `No matches for “${term.trim()}”.`
  }

  return (
    <div className="palette-backdrop" role="presentation" onMouseDown={onBackdropMouseDown}>
      {/* Keys are caught on the dialog, not the input: every one of them is a
          dialog concern, and the input is the only focusable child anyway. */}
      <div className="palette" role="dialog" aria-modal="true" aria-label={label} onKeyDown={onKeyDown}>
        <div className="palette-field">
          <span className="palette-glyph" aria-hidden="true">
            {commandMode ? (
              <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor">
                <path d="M8 9l3 3-3 3M13 15h4" strokeWidth="1.8" strokeLinecap="round" />
                <rect x="3" y="4" width="18" height="16" rx="3" strokeWidth="1.5" />
              </svg>
            ) : (
              <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor">
                <circle cx="11" cy="11" r="6.5" strokeWidth="1.7" />
                <path d="M16 16l4.5 4.5" strokeWidth="1.7" strokeLinecap="round" />
              </svg>
            )}
          </span>

          <input
            ref={inputRef}
            className="palette-input"
            type="text"
            role="combobox"
            aria-expanded={rows.length > 0}
            aria-controls={listId}
            aria-activedescendant={rows.length > 0 ? optionId(active) : undefined}
            aria-autocomplete="list"
            aria-label={label}
            placeholder={placeholder}
            value={query}
            spellCheck={false}
            autoComplete="off"
            autoCorrect="off"
            onChange={(event) => setQuery(event.target.value)}
          />

          {!commandMode && files.length > 0 && (
            <span className="palette-count" aria-hidden="true">
              {rows.length}/{files.length}
            </span>
          )}
        </div>

        <ul ref={listRef} className="palette-list" id={listId} role="listbox" aria-label={label}>
          {rows.map((row, index) => (
            <li
              key={row.key}
              id={optionId(index)}
              role="option"
              aria-selected={index === active}
              className={`palette-row${index === active ? ' is-active' : ''}`}
              onMouseMove={() => {
                if (index !== active) setActiveIndex(index)
              }}
              onClick={() => activate(index)}
            >
              {row.kind === 'file' ? <FileRow path={row.path} ranges={row.ranges} /> : (
                <CommandRow command={row.command} ranges={row.ranges} />
              )}
            </li>
          ))}
        </ul>

        {emptyMessage && <p className="palette-empty">{emptyMessage}</p>}

        <div className="palette-footer">
          <span>
            <kbd>↑</kbd>
            <kbd>↓</kbd> navigate
          </span>
          <span>
            <kbd>⏎</kbd> {commandMode ? 'run' : 'open'}
          </span>
          <span>
            <kbd>esc</kbd> close
          </span>
          {!commandMode && (
            <span className="palette-footer-hint">
              <kbd>&gt;</kbd> for commands
            </span>
          )}
        </div>

        {/* Screen readers get the result count; sighted users get the list. */}
        <div className="palette-status" role="status" aria-live="polite">
          {rows.length === 1 ? '1 result' : `${rows.length} results`}
        </div>
      </div>
    </div>
  )
}

function FileRow({ path, ranges }: { path: string; ranges: MatchRange[] }) {
  const nameFrom = basenameStart(path)
  const directory = path.slice(0, nameFrom)
  const name = path.slice(nameFrom)

  return (
    <>
      <span className="palette-name">
        <Highlight text={name} ranges={clampRanges(ranges, nameFrom, path.length)} />
      </span>
      {directory !== '' && (
        <span className="palette-dir" title={path}>
          {/* The inner wrapper is load-bearing — see .palette-dir-text. */}
          <span className="palette-dir-text">
            <Highlight text={directory} ranges={clampRanges(ranges, 0, nameFrom)} />
          </span>
        </span>
      )}
    </>
  )
}

function CommandRow({ command, ranges }: { command: PaletteCommand; ranges: MatchRange[] }) {
  return (
    <>
      {command.group && <span className="palette-group">{command.group}</span>}
      <span className="palette-name">
        <Highlight text={command.title} ranges={ranges} />
      </span>
      {command.shortcut && <kbd className="palette-shortcut">{command.shortcut}</kbd>}
    </>
  )
}

export interface PaletteShortcutHandlers {
  /** ⌘P on macOS, Ctrl+P elsewhere. */
  onQuickOpen(): void
  /** ⌘K on macOS, Ctrl+Shift+P elsewhere. */
  onCommands(): void
}

/**
 * Global palette shortcuts.
 *
 * Registered in the capture phase because xterm consumes keystrokes on its own
 * textarea before they ever bubble — a bubble-phase listener never sees ⌘K
 * while a terminal has focus.
 */
export function usePaletteShortcuts(handlers: PaletteShortcutHandlers): void {
  const handlersRef = useRef(handlers)
  handlersRef.current = handlers

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent): void => {
      if (event.altKey) return
      const key = event.key.toLowerCase()

      if (IS_MAC) {
        if (!event.metaKey) return
        if (key === 'p' && !event.shiftKey) {
          event.preventDefault()
          handlersRef.current.onQuickOpen()
        } else if (key === 'k' || (key === 'p' && event.shiftKey)) {
          event.preventDefault()
          handlersRef.current.onCommands()
        }
        return
      }

      if (!event.ctrlKey || event.metaKey) return
      // Ctrl+K and Ctrl+P belong to the shell on other platforms, so the
      // command palette takes the shifted variant instead.
      if (key === 'p' && event.shiftKey) {
        event.preventDefault()
        handlersRef.current.onCommands()
      } else if (key === 'o' && event.shiftKey) {
        event.preventDefault()
        handlersRef.current.onQuickOpen()
      }
    }

    window.addEventListener('keydown', onKeyDown, true)
    return () => window.removeEventListener('keydown', onKeyDown, true)
  }, [])
}

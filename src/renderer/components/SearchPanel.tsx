import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent as ReactKeyboardEvent,
} from 'react'
import './SearchPanel.css'

/* ------------------------------------------------------------------ types -- */

/**
 * Mirrors of the types in `src/main/session-search.ts`, duplicated rather than
 * imported because the renderer tsconfig does not include `src/main`. The same
 * arrangement is used by `ReadinessPanel`; when the orchestrator lifts these
 * into `src/shared/types.ts` this block goes away and the imports point there.
 */
export type SearchRole = 'user' | 'assistant' | 'thinking' | 'tool' | 'system'

export type SearchScope = 'project' | 'all'

export interface MatchRange {
  start: number
  length: number
}

export interface Snippet {
  text: string
  ranges: MatchRange[]
  truncatedStart: boolean
  truncatedEnd: boolean
}

export interface SearchHit {
  sessionId: string
  transcriptPath: string
  cwd: string
  projectName: string
  at: number
  role: SearchRole
  tool?: string
  isSidechain: boolean
  score: number
  matches: number
  snippet: Snippet
}

export interface SearchResult {
  query: string
  scope: SearchScope
  hits: SearchHit[]
  sessionsScanned: number
  sessionsSkipped: number
  bytesScanned: number
  totalHits: number
  truncated: boolean
  cancelled: boolean
  tookMs: number
}

export interface SessionSearchRequest {
  cwd: string
  query: string
  scope?: SearchScope
  roles?: SearchRole[]
  caseSensitive?: boolean
  regex?: boolean
  maxHits?: number
}

export type SearchResponse =
  | ({ ok: true } & SearchResult)
  | { ok: false; error: string; message: string }

/** The slice of the preload bridge this panel needs. */
export interface SearchBridge {
  searchSessions(request: SessionSearchRequest): Promise<SearchResponse>
  cancelSessionSearch(): Promise<void>
}

export interface SearchPanelProps {
  /** Absolute path of the project to search. */
  projectPath: string
  /** Opens a hit — the session inspector is the natural destination. */
  onOpenHit?: (hit: SearchHit) => void
  /** Injectable for tests; defaults to the preload bridge on `window.deck`. */
  bridge?: SearchBridge
  /** Prefilled query, e.g. from a right-click "search for this". */
  initialQuery?: string
}

/* ---------------------------------------------------------------- helpers -- */

/**
 * Read defensively: search is wired into the preload separately, so the panel
 * has to explain itself rather than crash if it mounts first.
 */
function resolveBridge(): SearchBridge | null {
  // Tests render this to static markup, where there is no window at all.
  if (typeof window === 'undefined') return null
  const host = (window as unknown as { deck?: Partial<SearchBridge> }).deck
  if (!host || typeof host.searchSessions !== 'function') return null
  return host as SearchBridge
}

/**
 * Ask the main process to drop whatever it is scanning, and never throw doing it.
 *
 * Two ways this bites otherwise: the preload bridge may predate the cancel
 * channel, so the method is missing; and a window that is closing rejects every
 * in-flight `invoke`. Neither deserves an unhandled rejection, and the caller
 * is usually a cleanup function that has nowhere to report one.
 */
export function cancelQuietly(bridge: SearchBridge | null): void {
  void bridge?.cancelSessionSearch?.()?.catch(() => undefined)
}

export const ROLE_LABEL: Record<SearchRole, string> = {
  user: 'You',
  assistant: 'Reply',
  thinking: 'Thinking',
  tool: 'Tools',
  system: 'System',
}

export const SELECTABLE_ROLES: readonly SearchRole[] = ['user', 'assistant', 'thinking', 'tool', 'system']

export interface SnippetSegment {
  text: string
  match: boolean
}

/**
 * Split a snippet into plain and highlighted runs.
 *
 * Overlapping ranges are merged first: two query terms can match overlapping
 * text ("session" and "sessions"), and rendering both would emit a segment of
 * negative length and silently drop characters from the snippet.
 */
export function snippetSegments(snippet: Snippet): SnippetSegment[] {
  const sorted = [...snippet.ranges]
    .filter((range) => range.length > 0 && range.start >= 0 && range.start < snippet.text.length)
    .sort((a, b) => a.start - b.start)

  const merged: MatchRange[] = []
  for (const range of sorted) {
    const last = merged[merged.length - 1]
    const end = Math.min(snippet.text.length, range.start + range.length)
    if (last && range.start <= last.start + last.length) {
      last.length = Math.max(last.length, end - last.start)
      continue
    }
    merged.push({ start: range.start, length: end - range.start })
  }

  const segments: SnippetSegment[] = []
  let cursor = 0
  for (const range of merged) {
    if (range.start > cursor) segments.push({ text: snippet.text.slice(cursor, range.start), match: false })
    segments.push({ text: snippet.text.slice(range.start, range.start + range.length), match: true })
    cursor = range.start + range.length
  }
  if (cursor < snippet.text.length) segments.push({ text: snippet.text.slice(cursor), match: false })
  return segments
}

export interface HitGroup {
  sessionId: string
  transcriptPath: string
  cwd: string
  projectName: string
  /** Most recent hit in the group — what the header dates itself by. */
  at: number
  hits: SearchHit[]
}

/**
 * Group hits by session, keeping the ranking order.
 *
 * A session appears where its *best* hit ranked, not where its first-read line
 * happened to fall, so the strongest result stays at the top of the list.
 */
export function groupHits(hits: SearchHit[]): HitGroup[] {
  const groups = new Map<string, HitGroup>()
  for (const hit of hits) {
    const existing = groups.get(hit.sessionId)
    if (existing) {
      existing.hits.push(hit)
      if (hit.at > existing.at) existing.at = hit.at
      continue
    }
    groups.set(hit.sessionId, {
      sessionId: hit.sessionId,
      transcriptPath: hit.transcriptPath,
      cwd: hit.cwd,
      projectName: hit.projectName,
      at: hit.at,
      hits: [hit],
    })
  }
  return [...groups.values()]
}

const MINUTE = 60_000
const HOUR = 60 * MINUTE
const DAY = 24 * HOUR

export function relativeTime(at: number, now: number): string {
  if (!at) return ''
  const delta = now - at
  if (delta < MINUTE) return 'just now'
  if (delta < HOUR) return `${Math.round(delta / MINUTE)}m ago`
  if (delta < DAY) return `${Math.round(delta / HOUR)}h ago`
  if (delta < 30 * DAY) return `${Math.round(delta / DAY)}d ago`
  return new Date(at).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' })
}

export function formatBytes(bytes: number): string {
  if (bytes >= 1e9) return `${(bytes / 1e9).toFixed(1)} GB`
  if (bytes >= 1e6) return `${Math.round(bytes / 1e6)} MB`
  if (bytes >= 1e3) return `${Math.round(bytes / 1e3)} KB`
  return `${bytes} B`
}

/** The one-line summary under the input. Exported because it is the fiddliest part. */
export function summarize(result: SearchResult, sessions: number): string {
  if (result.hits.length === 0) {
    return `No matches in ${result.sessionsScanned} session${result.sessionsScanned === 1 ? '' : 's'}.`
  }
  const parts = [
    `${result.hits.length} hit${result.hits.length === 1 ? '' : 's'} in ${sessions} session${sessions === 1 ? '' : 's'}`,
    `${formatBytes(result.bytesScanned)} scanned in ${result.tookMs} ms`,
  ]
  if (result.truncated) parts.push('more remain — narrow the query')
  return parts.join(' · ')
}

/* ------------------------------------------------------------ sub-elements -- */

export function HighlightedSnippet({ snippet }: { snippet: Snippet }) {
  const segments = snippetSegments(snippet)
  return (
    <p className="search-snippet">
      {snippet.truncatedStart ? <span className="search-ellipsis">…</span> : null}
      {segments.map((segment, index) =>
        segment.match ? (
          <mark className="search-mark" key={index}>
            {segment.text}
          </mark>
        ) : (
          <span key={index}>{segment.text}</span>
        ),
      )}
      {snippet.truncatedEnd ? <span className="search-ellipsis">…</span> : null}
    </p>
  )
}

export function HitRow({
  hit,
  now,
  selected,
  onOpen,
}: {
  hit: SearchHit
  now: number
  selected: boolean
  onOpen?: (hit: SearchHit) => void
}) {
  return (
    <li className="search-hit" data-selected={selected ? 'true' : undefined}>
      <button
        type="button"
        className="search-hit-button"
        onClick={() => onOpen?.(hit)}
        title={`Open session ${hit.sessionId}`}
      >
        <span className="search-hit-head">
          <span className="search-role" data-role={hit.role}>
            {hit.tool ?? ROLE_LABEL[hit.role]}
          </span>
          {hit.isSidechain ? <span className="search-tag">sub-agent</span> : null}
          {hit.matches > 1 ? <span className="search-tag">{hit.matches} matches</span> : null}
          <span className="search-when">{relativeTime(hit.at, now)}</span>
        </span>
        <HighlightedSnippet snippet={hit.snippet} />
      </button>
    </li>
  )
}

/* ------------------------------------------------------------------ panel -- */

const DEBOUNCE_MS = 260

export function SearchPanel({
  projectPath,
  onOpenHit,
  bridge,
  initialQuery = '',
}: SearchPanelProps) {
  const [query, setQuery] = useState(initialQuery)
  const [scope, setScope] = useState<SearchScope>('project')
  const [roles, setRoles] = useState<SearchRole[]>(['user', 'assistant'])
  const [caseSensitive, setCaseSensitive] = useState(false)
  const [regex, setRegex] = useState(false)
  const [result, setResult] = useState<SearchResult | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [selected, setSelected] = useState(0)

  const host = useMemo(() => bridge ?? resolveBridge(), [bridge])
  /** Guards against a slow earlier search overwriting a newer one's results. */
  const runId = useRef(0)
  const now = Date.now()

  const run = useCallback(
    async (text: string) => {
      if (!host) return
      const id = runId.current + 1
      runId.current = id

      if (text.trim().length < 2) {
        setResult(null)
        setError(null)
        setBusy(false)
        // The main process cancels the previous pass anyway, but asking keeps a
        // 700 MB all-projects scan from running for a box the user just emptied.
        cancelQuietly(host)
        return
      }

      setBusy(true)
      try {
        const response = await host.searchSessions({
          cwd: projectPath,
          query: text,
          scope,
          roles,
          caseSensitive,
          regex,
        })
        if (runId.current !== id) return
        if (response.ok) {
          setResult(response)
          setError(null)
        } else if (response.error !== 'cancelled') {
          setResult(null)
          setError(response.message)
        }
      } catch (err) {
        if (runId.current !== id) return
        setResult(null)
        setError(err instanceof Error ? err.message : 'Search failed.')
      } finally {
        if (runId.current === id) setBusy(false)
      }
    },
    [host, projectPath, scope, roles, caseSensitive, regex],
  )

  useEffect(() => {
    const timer = setTimeout(() => void run(query), DEBOUNCE_MS)
    return () => clearTimeout(timer)
  }, [query, run])

  useEffect(() => {
    // Closing the panel used to leave the scan running: `runId` stops a stale
    // result being *shown*, but it does not stop the main process streaming
    // every transcript in every project for a panel nobody is looking at.
    return () => {
      runId.current += 1
      cancelQuietly(host)
    }
  }, [host])

  useEffect(() => {
    setSelected(0)
  }, [result])

  const groups = useMemo(() => (result ? groupHits(result.hits) : []), [result])
  const flat = useMemo(() => groups.flatMap((group) => group.hits), [groups])

  const onKeyDown = (event: ReactKeyboardEvent<HTMLDivElement>): void => {
    if (flat.length === 0) return
    if (event.key === 'ArrowDown') {
      event.preventDefault()
      setSelected((index) => Math.min(flat.length - 1, index + 1))
    } else if (event.key === 'ArrowUp') {
      event.preventDefault()
      setSelected((index) => Math.max(0, index - 1))
    } else if (event.key === 'Enter') {
      event.preventDefault()
      const hit = flat[selected]
      if (hit) onOpenHit?.(hit)
    }
  }

  const toggleRole = (role: SearchRole): void => {
    setRoles((current) => {
      const next = current.includes(role) ? current.filter((item) => item !== role) : [...current, role]
      // An empty role set would silently search nothing; keep the last one on.
      return next.length > 0 ? next : current
    })
  }

  return (
    <section className="session-search" aria-label="Session search" onKeyDown={onKeyDown}>
      <header className="search-head">
        <input
          className="search-input"
          type="search"
          value={query}
          placeholder="Search every past session…"
          aria-label="Search past sessions"
          spellCheck={false}
          autoComplete="off"
          onChange={(event) => setQuery(event.target.value)}
        />
        <div className="search-scope" role="group" aria-label="Search scope">
          <button
            type="button"
            className="search-chip"
            data-on={scope === 'project' ? 'true' : undefined}
            aria-pressed={scope === 'project'}
            onClick={() => setScope('project')}
          >
            This project
          </button>
          <button
            type="button"
            className="search-chip"
            data-on={scope === 'all' ? 'true' : undefined}
            aria-pressed={scope === 'all'}
            onClick={() => setScope('all')}
          >
            Everywhere
          </button>
        </div>
      </header>

      <div className="search-filters" role="group" aria-label="Search filters">
        {SELECTABLE_ROLES.map((role) => (
          <button
            type="button"
            key={role}
            className="search-chip"
            data-on={roles.includes(role) ? 'true' : undefined}
            aria-pressed={roles.includes(role)}
            onClick={() => toggleRole(role)}
          >
            {ROLE_LABEL[role]}
          </button>
        ))}
        <span className="search-filler" />
        <button
          type="button"
          className="search-chip search-chip-mono"
          data-on={caseSensitive ? 'true' : undefined}
          aria-pressed={caseSensitive}
          title="Match case"
          onClick={() => setCaseSensitive((on) => !on)}
        >
          Aa
        </button>
        <button
          type="button"
          className="search-chip search-chip-mono"
          data-on={regex ? 'true' : undefined}
          aria-pressed={regex}
          title="Regular expression"
          onClick={() => setRegex((on) => !on)}
        >
          .*
        </button>
      </div>

      <p className="search-status" role="status" aria-live="polite">
        {!host
          ? 'Search is not connected to the main process yet.'
          : error
            ? error
            : busy
              ? 'Searching…'
              : result
                ? summarize(result, groups.length)
                : 'Quoted "phrases" and -exclusions work. Every term has to appear in the same message.'}
      </p>

      <div className="search-results">
        {groups.map((group) => {
          const offset = flat.indexOf(group.hits[0])
          return (
            <article className="search-group" key={group.sessionId}>
              <h3 className="search-group-head">
                <span className="search-session">{group.sessionId.slice(0, 8)}</span>
                {scope === 'all' && group.projectName ? (
                  <span className="search-project">{group.projectName}</span>
                ) : null}
                <span className="search-when">{relativeTime(group.at, now)}</span>
              </h3>
              <ul className="search-list">
                {group.hits.map((hit, index) => (
                  <HitRow
                    key={`${hit.sessionId}-${hit.at}-${index}`}
                    hit={hit}
                    now={now}
                    selected={offset + index === selected}
                    onOpen={onOpenHit}
                  />
                ))}
              </ul>
            </article>
          )
        })}
      </div>
    </section>
  )
}

export default SearchPanel

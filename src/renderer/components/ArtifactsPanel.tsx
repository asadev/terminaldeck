import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { PageEmpty, PageNote } from './PageEmpty'
import { formatBytes, relativeTime } from './relative-time'
import './ArtifactsPanel.css'

/**
 * Artifacts — the files an agent actually produced in this project.
 *
 * Every row on this page comes from one place: a `Write`, `Edit` or
 * `NotebookEdit` tool call recorded in a session transcript, whose file path
 * landed inside this project. See `src/main/artifacts.ts` for why that is the
 * only honest definition of the word here, and for what is deliberately *not*
 * counted — a `Bash` line that may or may not have redirected into a file is a
 * command string, not evidence.
 *
 * The page therefore never shows a category it cannot fill. There is no
 * "Images" tab that is always empty and no "Build output" section built on a
 * guess: there is a list of files, when each was touched, and — the part that
 * makes it a review surface rather than a report — the actual text of every
 * change, taken from the same record.
 */

/* ------------------------------------------------------------------ types -- */

/**
 * Mirrors of the types in `src/main/artifacts.ts`, duplicated rather than
 * imported because the renderer tsconfig does not include `src/main`. The same
 * arrangement is used by `ReadinessPanel` and was used by `SearchPanel`; when
 * the orchestrator lifts these into `src/shared/types.ts` this block goes away
 * and the imports point there.
 */
export type ArtifactScope = 'project' | 'all'
export type ArtifactAction = 'write' | 'edit'

export interface Artifact {
  relPath: string
  name: string
  firstAt: number
  lastAt: number
  writes: number
  edits: number
  lastChars: number
  lastTool: string
  sessionIds: string[]
  onDisk: { bytes: number; modifiedAt: number } | null
}

export interface ArtifactSession {
  sessionId: string
  at: number
  files: number
}

export interface ArtifactList {
  root: string
  scope: ArtifactScope
  artifacts: Artifact[]
  sessions: ArtifactSession[]
  sessionsScanned: number
  outsideProject: number
  truncated: boolean
  cancelled: boolean
  tookMs: number
}

export interface ArtifactChange {
  at: number
  sessionId: string
  action: ArtifactAction
  tool: string
  before: string
  after: string
  replaceAll: boolean
  clipped: boolean
}

export interface ArtifactHistory {
  root: string
  relPath: string
  changes: ArtifactChange[]
  totalChanges: number
  truncated: boolean
  cancelled: boolean
  tookMs: number
}

type Failure = { ok: false; error: string; message: string }
export type ArtifactsListResponse = ({ ok: true } & ArtifactList) | Failure
export type ArtifactsChangesResponse = ({ ok: true } & ArtifactHistory) | Failure

/**
 * The slice of the preload bridge this panel needs.
 *
 * ## If `preload/contract.test.ts` is failing on these two names, that is this
 * comment's fault and not a bug — the wiring below has not been applied yet.
 *
 * `src/preload/index.ts` may not be edited while several agents are working in
 * this tree (see CLAUDE.md → Working in parallel), so this panel is complete
 * and its channels are registered, and the two lines that join them are handed
 * back. Beside `searchSessions` in the preload:
 *
 *     listArtifacts: (request: { cwd: string; scope?: 'project' | 'all' }): Promise<unknown> =>
 *       ipcRenderer.invoke('artifacts:list', request),
 *     artifactChanges: (request: { cwd: string; relPath: string; scope?: 'project' | 'all' }): Promise<unknown> =>
 *       ipcRenderer.invoke('artifacts:changes', request),
 *
 * and in `src/main/index.ts`, beside `registerSessionSearchIpc(ipcMain)`:
 *
 *     registerArtifactsIpc(ipcMain)
 *
 * The contract test is doing its job by refusing until then: a component that
 * declares a bridge nobody exposes is a page that renders and does nothing,
 * which is the exact defect this whole page exists to replace.
 */
export interface ArtifactsBridge {
  listArtifacts(request: { cwd: string; scope?: ArtifactScope }): Promise<ArtifactsListResponse>
  artifactChanges(request: {
    cwd: string
    relPath: string
    scope?: ArtifactScope
  }): Promise<ArtifactsChangesResponse>
}

export interface ArtifactsPanelProps {
  /** Absolute path of the project whose artifacts are shown. */
  projectPath: string
  /**
   * Opens a file on the Files page. Optional, and when it is absent the button
   * is not drawn at all — a disabled "Open in Files" teaches nothing, and a
   * live one that goes nowhere is worse.
   */
  onOpenFile?(relPath: string): void
  /** Injectable for tests; defaults to the preload bridge on `window.deck`. */
  bridge?: ArtifactsBridge
  /** Injected in tests so relative times are deterministic. */
  now?: number
}

/** Drawn on the 24×24 grid the rest of the app uses, at 1.5 stroke. */
export const ARTIFACTS_ICON =
  'M5 4.5h9L19 9v10.5H5zM14 4.5V9h5M8.5 13h7M8.5 16.5h4.5'

/* ---------------------------------------------------------------- helpers -- */

/**
 * Read defensively: the panel may mount before the artifact channels are wired
 * into the preload, and a page that throws in that window takes its whole view
 * down rather than explaining itself.
 */
function resolveBridge(): ArtifactsBridge | null {
  // Tests render this to static markup, where there is no window at all.
  if (typeof window === 'undefined') return null
  const host = (window as unknown as { deck?: Partial<ArtifactsBridge> }).deck
  if (!host || typeof host.listArtifacts !== 'function') return null
  return host as ArtifactsBridge
}

export function directoryOf(relPath: string): string {
  const cut = relPath.lastIndexOf('/')
  return cut === -1 ? '' : relPath.slice(0, cut)
}

/**
 * The one-line summary under the controls.
 *
 * Exported because it is the sentence that has to stay truthful: it says how
 * many files, from how many sessions, and — when a cap bit — that there are
 * more. A list that quietly stops at four hundred is a list that lies.
 */
export function summarize(list: ArtifactList, shown: number): string {
  if (list.artifacts.length === 0) {
    return list.sessionsScanned === 0
      ? 'No sessions recorded for this project yet.'
      : `Nothing written or edited in ${list.sessionsScanned} session${list.sessionsScanned === 1 ? '' : 's'}.`
  }
  const parts: string[] = []
  parts.push(
    shown === list.artifacts.length
      ? `${list.artifacts.length} file${list.artifacts.length === 1 ? '' : 's'}`
      : `${shown} of ${list.artifacts.length} files`,
  )
  parts.push(
    `${list.sessions.length} session${list.sessions.length === 1 ? '' : 's'}`,
  )
  if (list.truncated) parts.push('older work not read')
  return parts.join(' · ')
}

/** "2 writes · 5 edits", with the halves that are zero left out. */
export function changeSummary(artifact: Artifact): string {
  const parts: string[] = []
  if (artifact.writes > 0) parts.push(`${artifact.writes} write${artifact.writes === 1 ? '' : 's'}`)
  if (artifact.edits > 0) parts.push(`${artifact.edits} edit${artifact.edits === 1 ? '' : 's'}`)
  return parts.join(' · ')
}

/* ------------------------------------------------------------------- diff -- */

export type DiffKind = 'same' | 'add' | 'del'

export interface DiffLine {
  kind: DiffKind
  text: string
}

/**
 * Lines past this on either side of one change are not diffed.
 *
 * The comparison below is O(n×m), and the recorded sides of an `Edit` are
 * normally a handful of lines. A `replace_all` across a generated file is the
 * exception, and 600×600 is already 360,000 cells of work for a hunk nobody
 * reads line by line — past it the change is shown as a block removed and a
 * block added, which is what it is.
 */
export const MAX_DIFF_LINES = 600

/**
 * Split text into lines the way a diff counts them: a trailing newline
 * terminates the last line rather than starting an empty one.
 */
export function splitLines(text: string): string[] {
  if (text === '') return []
  const lines = text.split('\n')
  if (lines[lines.length - 1] === '') lines.pop()
  return lines
}

/**
 * A line-level diff of the two halves an `Edit` recorded.
 *
 * This is not a re-derivation of anything — the transcript stores the exact
 * text that was replaced and the exact text that replaced it, so the two sides
 * are facts and only their *alignment* is computed. Common prefix and suffix
 * are stripped first, which on a real edit usually leaves a handful of lines
 * for the quadratic part to work on.
 */
export function diffLines(before: string, after: string): { lines: DiffLine[]; truncated: boolean } {
  const a = splitLines(before)
  const b = splitLines(after)

  if (a.length > MAX_DIFF_LINES || b.length > MAX_DIFF_LINES) {
    return {
      lines: [
        ...a.slice(0, MAX_DIFF_LINES).map((text): DiffLine => ({ kind: 'del', text })),
        ...b.slice(0, MAX_DIFF_LINES).map((text): DiffLine => ({ kind: 'add', text })),
      ],
      truncated: true,
    }
  }

  let head = 0
  while (head < a.length && head < b.length && a[head] === b[head]) head += 1
  let tail = 0
  while (
    tail < a.length - head &&
    tail < b.length - head &&
    a[a.length - 1 - tail] === b[b.length - 1 - tail]
  ) {
    tail += 1
  }

  const midA = a.slice(head, a.length - tail)
  const midB = b.slice(head, b.length - tail)

  // Longest common subsequence over the part that actually differs.
  const rows = midA.length + 1
  const cols = midB.length + 1
  const table = new Uint32Array(rows * cols)
  for (let i = midA.length - 1; i >= 0; i -= 1) {
    for (let j = midB.length - 1; j >= 0; j -= 1) {
      table[i * cols + j] =
        midA[i] === midB[j]
          ? table[(i + 1) * cols + j + 1] + 1
          : Math.max(table[(i + 1) * cols + j], table[i * cols + j + 1])
    }
  }

  const lines: DiffLine[] = a.slice(0, head).map((text) => ({ kind: 'same', text }))
  let i = 0
  let j = 0
  while (i < midA.length && j < midB.length) {
    if (midA[i] === midB[j]) {
      lines.push({ kind: 'same', text: midA[i] })
      i += 1
      j += 1
    } else if (table[(i + 1) * cols + j] >= table[i * cols + j + 1]) {
      lines.push({ kind: 'del', text: midA[i] })
      i += 1
    } else {
      lines.push({ kind: 'add', text: midB[j] })
      j += 1
    }
  }
  while (i < midA.length) {
    lines.push({ kind: 'del', text: midA[i] })
    i += 1
  }
  while (j < midB.length) {
    lines.push({ kind: 'add', text: midB[j] })
    j += 1
  }
  for (const text of a.slice(a.length - tail)) lines.push({ kind: 'same', text })

  return { lines, truncated: false }
}

const DIFF_MARK: Record<DiffKind, string> = { same: ' ', add: '+', del: '-' }

/** Lines of one change rendered on screen before the rest is folded away. */
export const MAX_RENDERED_LINES = 300

export function ChangeBody({ change }: { change: ArtifactChange }) {
  // A write replaces the whole file, so there is no "before" to align against —
  // showing its content as three hundred added lines would colour the whole
  // pane green and say nothing the header did not.
  if (change.action === 'write') {
    const lines = splitLines(change.after)
    const shown = lines.slice(0, MAX_RENDERED_LINES)
    return (
      <div className="artifact-diff" data-write="true">
        <pre className="artifact-diff-body">
          <code>{shown.join('\n')}</code>
        </pre>
        {lines.length > shown.length && (
          <p className="artifact-diff-more">
            {(lines.length - shown.length).toLocaleString()} more line
            {lines.length - shown.length === 1 ? '' : 's'} not shown.
          </p>
        )}
      </div>
    )
  }

  const { lines, truncated } = diffLines(change.before, change.after)
  const shown = lines.slice(0, MAX_RENDERED_LINES)
  return (
    <div className="artifact-diff">
      {shown.map((line, index) => (
        <div className="artifact-diff-line" data-kind={line.kind} key={index}>
          <span className="artifact-diff-mark" aria-hidden="true">
            {DIFF_MARK[line.kind]}
          </span>
          <span className="artifact-diff-text">{line.text}</span>
        </div>
      ))}
      {(truncated || lines.length > shown.length) && (
        <p className="artifact-diff-more">
          {truncated
            ? 'Too long to line up — shown as one block removed and one added.'
            : `${(lines.length - shown.length).toLocaleString()} more lines not shown.`}
        </p>
      )}
    </div>
  )
}

/* --------------------------------------------------------------- sections -- */

export function ArtifactRow({
  artifact,
  now,
  selected,
  onSelect,
}: {
  artifact: Artifact
  now: number
  selected: boolean
  onSelect(relPath: string): void
}) {
  const directory = directoryOf(artifact.relPath)
  return (
    <li className="artifact-row" data-selected={selected ? 'true' : undefined}>
      <button
        type="button"
        className="artifact-row-button"
        aria-current={selected || undefined}
        title={artifact.relPath}
        onClick={() => onSelect(artifact.relPath)}
      >
        <span className="artifact-row-head">
          <span className="artifact-row-name">{artifact.name}</span>
          <span className="artifact-row-when">{relativeTime(artifact.lastAt, now)}</span>
        </span>
        <span className="artifact-row-meta">
          {directory && (
            <span className="artifact-row-dir">
              {/* The inner wrapper is load-bearing — see `.artifact-row-dir-text`. */}
              <span className="artifact-row-dir-text">{directory}</span>
            </span>
          )}
          <span className="artifact-row-counts">{changeSummary(artifact)}</span>
          {/* Not a warning, a fact: agents write scratch files and delete them,
              and a row that offered to open one would offer a read error. */}
          {!artifact.onDisk && <span className="artifact-tag">not on disk</span>}
        </span>
      </button>
    </li>
  )
}

function ChangeCard({ change, now }: { change: ArtifactChange; now: number }) {
  return (
    <article className="artifact-change">
      <header className="artifact-change-head">
        <span className="artifact-change-action" data-action={change.action}>
          {change.action === 'write' ? 'Wrote' : 'Edited'}
        </span>
        <span className="artifact-change-tool">{change.tool}</span>
        {change.replaceAll && <span className="artifact-tag">every occurrence</span>}
        {change.clipped && <span className="artifact-tag">shortened</span>}
        <span className="artifact-change-when">{relativeTime(change.at, now)}</span>
      </header>
      <ChangeBody change={change} />
    </article>
  )
}

/* ------------------------------------------------------------------ panel -- */

interface ListState {
  status: 'loading' | 'ready' | 'error'
  list: ArtifactList | null
  message: string | null
}

interface HistoryState {
  status: 'loading' | 'ready' | 'error'
  relPath: string
  history: ArtifactHistory | null
  message: string | null
}

function messageOf(error: unknown): string {
  const raw = error instanceof Error ? error.message : String(error)
  return raw.replace(/^Error invoking remote method '[^']*':\s*/, '')
}

export function ArtifactsPanel({ projectPath, onOpenFile, bridge, now }: ArtifactsPanelProps) {
  const [scope, setScope] = useState<ArtifactScope>('project')
  const [filter, setFilter] = useState('')
  const [session, setSession] = useState<string | null>(null)
  const [selected, setSelected] = useState<string | null>(null)
  const [list, setList] = useState<ListState>({ status: 'loading', list: null, message: null })
  const [history, setHistory] = useState<HistoryState | null>(null)

  const host = useMemo(() => bridge ?? resolveBridge(), [bridge])
  const clock = now ?? Date.now()
  /** Guards against a slow earlier scan overwriting a newer one's answer. */
  const listRun = useRef(0)
  const historyRun = useRef(0)

  useEffect(() => {
    if (!host) {
      setList({
        status: 'error',
        list: null,
        message: 'Artifacts are not connected to the main process yet.',
      })
      return
    }

    const id = listRun.current + 1
    listRun.current = id
    setList({ status: 'loading', list: null, message: null })
    setSelected(null)
    setSession(null)
    setHistory(null)

    void (async () => {
      try {
        const response = await host.listArtifacts({ cwd: projectPath, scope })
        if (listRun.current !== id) return
        if (response.ok) setList({ status: 'ready', list: response, message: null })
        else if (response.error !== 'cancelled') {
          setList({ status: 'error', list: null, message: response.message })
        }
      } catch (error) {
        if (listRun.current !== id) return
        setList({ status: 'error', list: null, message: messageOf(error) })
      }
    })()
  }, [host, projectPath, scope])

  const visible = useMemo(() => {
    const artifacts = list.list?.artifacts ?? []
    const needle = filter.trim().toLowerCase()
    return artifacts.filter((artifact) => {
      if (session && !artifact.sessionIds.includes(session)) return false
      if (needle === '') return true
      return artifact.relPath.toLowerCase().includes(needle)
    })
  }, [list.list, filter, session])

  /*
   * The page opens on content, not on an instruction.
   *
   * This is the same defect the Files page was reported for — "pick something
   * from the tree and it opens here" filling a whole pane — and it is the same
   * fix: the newest artifact is the one somebody arriving here wants, so it is
   * already open. Only when the current selection has been filtered away, so
   * that typing in the filter box does not yank the pane around underneath a
   * selection that is still visible.
   */
  useEffect(() => {
    if (visible.length === 0) {
      if (selected !== null) setSelected(null)
      return
    }
    if (selected && visible.some((artifact) => artifact.relPath === selected)) return
    setSelected(visible[0].relPath)
  }, [visible, selected])

  useEffect(() => {
    if (!host || selected === null) {
      setHistory(null)
      return
    }

    const id = historyRun.current + 1
    historyRun.current = id
    setHistory({ status: 'loading', relPath: selected, history: null, message: null })

    void (async () => {
      try {
        const response = await host.artifactChanges({ cwd: projectPath, relPath: selected, scope })
        if (historyRun.current !== id) return
        if (response.ok) {
          setHistory({ status: 'ready', relPath: selected, history: response, message: null })
        } else if (response.error !== 'cancelled') {
          setHistory({ status: 'error', relPath: selected, history: null, message: response.message })
        }
      } catch (error) {
        if (historyRun.current !== id) return
        setHistory({ status: 'error', relPath: selected, history: null, message: messageOf(error) })
      }
    })()
  }, [host, projectPath, scope, selected])

  const current = useMemo(
    () => visible.find((artifact) => artifact.relPath === selected) ?? null,
    [visible, selected],
  )

  const onSelect = useCallback((relPath: string) => setSelected(relPath), [])

  const sessions = (list.list?.sessions ?? []).slice(0, 5)

  return (
    <section className="artifacts" aria-label="Artifacts">
      <header className="artifacts-head">
        <input
          className="artifacts-filter"
          type="search"
          value={filter}
          placeholder="Filter by path…"
          aria-label="Filter artifacts by path"
          spellCheck={false}
          autoComplete="off"
          onChange={(event) => setFilter(event.target.value)}
        />
        <div className="artifacts-scope" role="group" aria-label="Which sessions to read">
          {/* Words, not glyphs, and the widened one says what it costs. The
              default is this project's own sessions; an agent launched from a
              parent workspace records its writes under *that* folder, which is
              the whole reason the second chip exists. */}
          <button
            type="button"
            className="artifacts-chip"
            data-on={scope === 'project' ? 'true' : undefined}
            aria-pressed={scope === 'project'}
            onClick={() => setScope('project')}
          >
            This project’s sessions
          </button>
          <button
            type="button"
            className="artifacts-chip"
            data-on={scope === 'all' ? 'true' : undefined}
            aria-pressed={scope === 'all'}
            title="Also read sessions started elsewhere that wrote into this folder"
            onClick={() => setScope('all')}
          >
            Every session
          </button>
        </div>
      </header>

      {sessions.length > 1 && (
        <div className="artifacts-sessions" role="group" aria-label="Filter by session">
          <button
            type="button"
            className="artifacts-chip"
            data-on={session === null ? 'true' : undefined}
            aria-pressed={session === null}
            onClick={() => setSession(null)}
          >
            All sessions
          </button>
          {sessions.map((entry) => (
            <button
              type="button"
              key={entry.sessionId}
              className="artifacts-chip"
              data-on={session === entry.sessionId ? 'true' : undefined}
              aria-pressed={session === entry.sessionId}
              title={entry.sessionId}
              onClick={() => setSession(session === entry.sessionId ? null : entry.sessionId)}
            >
              {relativeTime(entry.at, clock)} · {entry.files} file{entry.files === 1 ? '' : 's'}
            </button>
          ))}
        </div>
      )}

      <p className="artifacts-status" role="status" aria-live="polite">
        {list.status === 'loading'
          ? 'Reading this project’s history…'
          : list.status === 'error'
            ? list.message
            : list.list
              ? summarize(list.list, visible.length)
              : ''}
      </p>

      {list.status === 'ready' && list.list && list.list.artifacts.length === 0 ? (
        <PageEmpty
          icon={ARTIFACTS_ICON}
          title="Nothing produced here yet"
          action={
            scope === 'project'
              ? { label: 'Read every session', onClick: () => setScope('all') }
              : undefined
          }
        >
          {scope === 'project'
            ? 'No agent has written or edited a file in this project from a session started here. If you run your agents from a parent folder, read every session instead.'
            : 'No session on this machine has written or edited a file inside this folder.'}
        </PageEmpty>
      ) : (
        <div className="artifacts-body">
          <ul className="artifacts-list" aria-label="Files this project’s agents produced">
            {visible.map((artifact) => (
              <ArtifactRow
                key={artifact.relPath}
                artifact={artifact}
                now={clock}
                selected={artifact.relPath === selected}
                onSelect={onSelect}
              />
            ))}
            {list.status === 'ready' && visible.length === 0 && (
              <li className="artifacts-none">
                <PageNote>Nothing matches that filter.</PageNote>
              </li>
            )}
          </ul>

          <div className="artifacts-detail">
            {current && (
              <header className="artifacts-detail-head">
                <h3 className="artifacts-detail-path" title={current.relPath}>
                  {current.relPath}
                </h3>
                <p className="artifacts-detail-meta">
                  {[
                    changeSummary(current),
                    `last ${relativeTime(current.lastAt, clock)}`,
                    current.onDisk
                      ? `${formatBytes(current.onDisk.bytes)} on disk`
                      : 'no longer on disk',
                  ]
                    .filter(Boolean)
                    .join(' · ')}
                </p>
                {onOpenFile && current.onDisk && (
                  <button
                    type="button"
                    className="artifacts-open"
                    onClick={() => onOpenFile(current.relPath)}
                  >
                    Open in Files
                  </button>
                )}
              </header>
            )}

            {history?.status === 'loading' && <PageNote busy>Reading the changes…</PageNote>}
            {history?.status === 'error' && <PageNote>{history.message}</PageNote>}
            {history?.status === 'ready' &&
              history.history &&
              (history.history.changes.length === 0 ? (
                <PageNote>No recorded changes for this file.</PageNote>
              ) : (
                <div className="artifacts-changes">
                  {history.history.changes.map((change, index) => (
                    <ChangeCard key={`${change.at}-${index}`} change={change} now={clock} />
                  ))}
                  {history.history.truncated && (
                    <PageNote>
                      Older changes to this file were not read — the scan stops at the newest
                      sessions.
                    </PageNote>
                  )}
                </div>
              ))}
          </div>
        </div>
      )}
    </section>
  )
}

export default ArtifactsPanel

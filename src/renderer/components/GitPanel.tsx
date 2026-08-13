import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { panelSpec } from '../shell/panels'
import { PageEmpty } from './PageEmpty'
import './GitPanel.css'

/* ------------------------------------------------------------------ types -- */

/**
 * Mirrors of the types in `src/main/git.ts`. They are duplicated rather than
 * imported because the renderer tsconfig does not include `src/main` — once
 * the orchestrator lifts them into `src/shared/types.ts`, this block goes away
 * and the imports point there instead.
 */
export type GitFileGroup = 'staged' | 'unstaged' | 'untracked' | 'conflicted'

export type GitChangeKind =
  | 'added'
  | 'modified'
  | 'deleted'
  | 'renamed'
  | 'copied'
  | 'typechange'
  | 'untracked'
  | 'conflicted'
  | 'unknown'

export interface GitFile {
  path: string
  origPath: string | null
  group: GitFileGroup
  code: string
  kind: GitChangeKind
  score: number | null
  insertions: number | null
  deletions: number | null
  binary: boolean
}

export interface GitBranch {
  name: string | null
  detached: boolean
  oid: string | null
  upstream: string | null
  ahead: number
  behind: number
}

export interface GitRepoStatus {
  repo: true
  cwd: string
  root: string
  branch: GitBranch
  staged: GitFile[]
  unstaged: GitFile[]
  untracked: GitFile[]
  conflicted: GitFile[]
  clean: boolean
}

export type GitUnavailableReason = 'not-a-repo' | 'git-missing' | 'no-such-folder' | 'error'

export interface GitNotRepo {
  repo: false
  cwd: string
  reason: GitUnavailableReason
  message: string
}

export type GitStatusResult = GitRepoStatus | GitNotRepo

/** The slice of the preload bridge this panel needs. */
export interface GitBridge {
  gitStatus(cwd: string): Promise<GitStatusResult>
  watchGit(cwd: string): Promise<GitStatusResult>
  unwatchGit(cwd: string): void
  onGitStatus(cb: (cwd: string, status: GitStatusResult) => void): () => void
}

export interface GitPanelProps {
  /** Absolute path of the project folder to report on. */
  cwd: string
  /** Fired when a row is clicked — the host decides what to show. */
  onSelectFile?(file: GitFile): void
  /** Path of the row to highlight, when the host is showing a diff beside it. */
  selectedPath?: string | null
  /** Injectable for tests; defaults to the preload bridge on `window.deck`. */
  bridge?: GitBridge
}

/* ---------------------------------------------------------------- helpers -- */

/**
 * The bridge is read defensively: git is wired into the preload separately, so
 * the panel has to render something sane rather than crash if it is mounted
 * before those methods exist.
 */
function resolveBridge(): GitBridge | null {
  const host = (window as unknown as { deck?: Partial<GitBridge> }).deck
  if (
    !host ||
    typeof host.watchGit !== 'function' ||
    typeof host.unwatchGit !== 'function' ||
    typeof host.onGitStatus !== 'function' ||
    typeof host.gitStatus !== 'function'
  ) {
    return null
  }
  return host as GitBridge
}

function baseName(path: string): string {
  const trimmed = path.endsWith('/') ? path.slice(0, -1) : path
  const cut = trimmed.lastIndexOf('/')
  return cut === -1 ? path : `${trimmed.slice(cut + 1)}${path.endsWith('/') ? '/' : ''}`
}

function dirName(path: string): string {
  const trimmed = path.endsWith('/') ? path.slice(0, -1) : path
  const cut = trimmed.lastIndexOf('/')
  return cut === -1 ? '' : trimmed.slice(0, cut)
}

function describe(file: GitFile): string {
  if (file.origPath) return `${file.origPath} → ${file.path}`
  return file.path
}

const UNAVAILABLE_COPY: Record<GitUnavailableReason, string> = {
  'not-a-repo': 'This folder is not a git repository.',
  'git-missing': 'git was not found on your PATH.',
  'no-such-folder': 'This folder no longer exists.',
  error: 'git could not read this folder.',
}

/** The same four states as a heading: what is wrong, before why. */
const UNAVAILABLE_TITLE: Record<GitUnavailableReason, string> = {
  'not-a-repo': 'Nothing to track here',
  'git-missing': 'git is not installed',
  'no-such-folder': 'That folder is gone',
  error: 'Source control is unavailable',
}

interface Group {
  key: GitFileGroup
  label: string
  files: GitFile[]
}

/**
 * A checkout across a large refactor, or a build directory that slipped past
 * .gitignore, can put tens of thousands of entries in one group. Every row is
 * a button with its own listeners, so rendering the list unbounded is how this
 * panel turns a big-but-normal repo into a frozen window. The overflow is
 * stated on screen rather than silently dropped.
 */
export const MAX_ROWS_PER_GROUP = 500

/* -------------------------------------------------------------- component -- */

export function GitPanel({ cwd, onSelectFile, selectedPath, bridge }: GitPanelProps) {
  const api = useMemo(() => bridge ?? resolveBridge(), [bridge])
  const [status, setStatus] = useState<GitStatusResult | null>(null)
  const [loading, setLoading] = useState(true)
  /** The folder currently on screen, so a slow reply for an old one is dropped. */
  const shownCwd = useRef<string | null>(null)

  useEffect(() => {
    if (!api) {
      setLoading(false)
      return
    }

    let live = true
    shownCwd.current = cwd
    setLoading(true)
    setStatus(null)

    // Subscribed before the first read, so a change landing during that read
    // is not dropped in the gap.
    const off = api.onGitStatus((path, next) => {
      if (live && path === cwd) setStatus(next)
    })

    api
      .watchGit(cwd)
      .then((first) => {
        if (!live) return
        setStatus(first)
        setLoading(false)
      })
      .catch(() => {
        if (live) setLoading(false)
      })

    return () => {
      live = false
      shownCwd.current = null
      off()
      api.unwatchGit(cwd)
    }
  }, [api, cwd])

  // The reply is checked against the folder still on screen: a manual refresh
  // that is still in flight when the user switches projects (or closes the
  // panel) must not paint one project's status over another's.
  const refresh = useCallback(() => {
    if (!api) return
    const asked = cwd
    void api
      .gitStatus(cwd)
      .then((next) => {
        if (shownCwd.current === asked) setStatus(next)
      })
      .catch(() => undefined)
  }, [api, cwd])

  const groups = useMemo<Group[]>(() => {
    if (!status?.repo) return []
    return (
      [
        { key: 'conflicted', label: 'Conflicts', files: status.conflicted },
        { key: 'staged', label: 'Staged', files: status.staged },
        { key: 'unstaged', label: 'Changes', files: status.unstaged },
        { key: 'untracked', label: 'Untracked', files: status.untracked },
      ] as Group[]
    ).filter((group) => group.files.length > 0)
  }, [status])

  if (!api) {
    return (
      <section className="git-panel" aria-label="Git status">
        <p className="git-message">Git is not available in this build.</p>
      </section>
    )
  }

  if (loading && !status) {
    return (
      <section className="git-panel" aria-label="Git status" aria-busy="true">
        <p className="git-message">Reading repository…</p>
      </section>
    )
  }

  if (!status || !status.repo) {
    return (
      <section className="git-panel" aria-label="Git status">
        <PageEmpty icon={panelSpec('git').icon} title={UNAVAILABLE_TITLE[status?.reason ?? 'error']}>
          {status ? UNAVAILABLE_COPY[status.reason] : UNAVAILABLE_COPY.error}
        </PageEmpty>
      </section>
    )
  }

  const { branch } = status
  const branchLabel = branch.detached
    ? `detached at ${branch.oid ? branch.oid.slice(0, 7) : 'unknown'}`
    : (branch.name ?? 'no branch')
  const changeCount =
    status.staged.length + status.unstaged.length + status.untracked.length + status.conflicted.length

  return (
    <section className="git-panel" aria-label="Git status">
      <header className="git-head">
        <svg
          className="git-head-icon"
          width="13"
          height="13"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.8"
          strokeLinecap="round"
          aria-hidden="true"
        >
          <circle cx="7" cy="5" r="2.4" />
          <circle cx="7" cy="19" r="2.4" />
          <circle cx="17" cy="9" r="2.4" />
          <path d="M7 7.4v9.2M17 11.4c0 3.2-3.4 3.6-6.6 4.2" />
        </svg>

        <span className="git-branch" data-detached={branch.detached} title={branch.upstream ?? undefined}>
          {branchLabel}
        </span>

        {branch.ahead > 0 && (
          <span className="git-track" title={`${branch.ahead} commit(s) to push`}>
            ↑{branch.ahead}
          </span>
        )}
        {branch.behind > 0 && (
          <span className="git-track" title={`${branch.behind} commit(s) to pull`}>
            ↓{branch.behind}
          </span>
        )}

        <span className="git-head-spacer" />

        {changeCount > 0 && <span className="git-count">{changeCount}</span>}

        <button
          type="button"
          className="git-refresh"
          onClick={refresh}
          title="Refresh"
          aria-label="Refresh git status"
        >
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
            <path d="M20 12a8 8 0 1 1-2.6-5.9" />
            <path d="M20 4v4.4h-4.4" />
          </svg>
        </button>
      </header>

      {status.clean ? (
        <p className="git-message">Working tree clean.</p>
      ) : (
        <div className="git-groups">
          {groups.map((group) => (
            <div className="git-group" key={group.key}>
              <div className="git-group-head">
                <span className="git-group-label">{group.label}</span>
                <span className="git-group-count">{group.files.length}</span>
              </div>
              <ul className="git-list">
                {group.files.slice(0, MAX_ROWS_PER_GROUP).map((file) => (
                  <li key={`${group.key}:${file.path}`}>
                    <button
                      type="button"
                      className="git-row"
                      data-selected={file.path === selectedPath}
                      onClick={() => onSelectFile?.(file)}
                      title={describe(file)}
                    >
                      <span className="git-code" data-kind={file.kind} aria-hidden="true">
                        {file.code}
                      </span>
                      <span className="git-name">{baseName(file.path)}</span>
                      <span className="git-dir">
                        {file.origPath ? `← ${file.origPath}` : dirName(file.path)}
                      </span>
                      {file.binary ? (
                        <span className="git-stat git-binary">bin</span>
                      ) : (
                        <span className="git-stat">
                          {file.insertions ? <span className="git-plus">+{file.insertions}</span> : null}
                          {file.deletions ? <span className="git-minus">−{file.deletions}</span> : null}
                        </span>
                      )}
                    </button>
                  </li>
                ))}
                {group.files.length > MAX_ROWS_PER_GROUP && (
                  <li className="git-overflow">
                    {group.files.length - MAX_ROWS_PER_GROUP} more not shown
                  </li>
                )}
              </ul>
            </div>
          ))}
        </div>
      )}
    </section>
  )
}

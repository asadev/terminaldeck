import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { clampRanges, rankMatches, segmentByRanges, type MatchRange } from '../../fuzzy'
import { foldersFrom, isImagePath, type Attachment } from './mentions'

/**
 * Choosing what to attach, from inside the project.
 *
 * This is a project-scoped picker rather than a native open dialog, and that is
 * a decision rather than a shortcut. A folder mention only behaves when the
 * folder is inside the session's project — pointed outside it, the listing the
 * CLI injects reads to the agent as an injection attempt and gets refused —
 * so "inside the project" is not a policy bolted onto the feature, it is the
 * boundary where the feature works. Offering only valid paths beats offering
 * everything and rejecting most of it after the click.
 *
 * It also costs no new IPC: `search:files` already enumerates the project for
 * quick open, honouring .gitignore and skipping node_modules, and the renderer
 * ranks locally on every keystroke the way the palette does.
 */

/** Channels this surface needs. Both are already on the bridge. */
export interface AttachPickerBridge {
  searchProjectFiles(request: { root: string; refresh?: boolean; limit?: number }): Promise<unknown>
}

export type PickerMode = 'file' | 'folder' | 'image'

export interface PickerRow {
  /** Project-relative, forward slashes. */
  relPath: string
  isDirectory: boolean
}

interface Props {
  root: string
  mode: PickerMode
  attachments: readonly Attachment[]
  onPick: (relPath: string, isDirectory: boolean) => void
  onBack: () => void
  bridge?: AttachPickerBridge
}

type Load =
  | { state: 'loading' }
  | { state: 'ready'; files: string[]; truncated: boolean }
  | { state: 'failed'; message: string }

const LIMIT = 400

const COPY: Record<PickerMode, { title: string; placeholder: string; empty: string }> = {
  file: {
    title: 'Add files',
    placeholder: 'Search files in this project…',
    empty: 'No file matches that.',
  },
  folder: {
    title: 'Add folder',
    placeholder: 'Search folders in this project…',
    empty: 'No folder matches that.',
  },
  image: {
    title: 'Add an image',
    placeholder: 'Search images in this project…',
    empty:
      'No images in this project yet. Take a screenshot with ⇧⌘4, save it inside the project folder, and it will appear here.',
  },
}

/**
 * Read the file index defensively.
 *
 * `searchProjectFiles` crosses the preload as `unknown`, and in the harness an
 * unimplemented method resolves to `null`. Reading `.files` off that throws
 * inside a promise and takes the composer down through the error boundary,
 * which reads as a broken feature rather than an unwired one.
 */
function readFiles(response: unknown): Load {
  if (!response || typeof response !== 'object') {
    return { state: 'failed', message: 'The project file list is not available in this build.' }
  }
  const body = response as { ok?: unknown; files?: unknown; truncated?: unknown; error?: unknown }
  if (body.ok !== true || !Array.isArray(body.files)) {
    const why = body.error === 'invalid-root' ? 'This folder is not an open project.' : 'The project could not be read.'
    return { state: 'failed', message: why }
  }
  return {
    state: 'ready',
    files: body.files.filter((f): f is string => typeof f === 'string'),
    truncated: body.truncated === true,
  }
}

function resolveBridge(injected?: AttachPickerBridge): AttachPickerBridge | null {
  if (injected) return injected
  if (typeof window === 'undefined') return null
  const host = (window as unknown as { deck?: Partial<AttachPickerBridge> }).deck
  return host && typeof host.searchProjectFiles === 'function' ? (host as AttachPickerBridge) : null
}

export function AttachPicker({ root, mode, attachments, onPick, onBack, bridge }: Props) {
  const resolved = resolveBridge(bridge)
  const [load, setLoad] = useState<Load>({ state: 'loading' })
  const [query, setQuery] = useState('')
  const [cursor, setCursor] = useState(0)
  const searchRef = useRef<HTMLInputElement>(null)
  const listRef = useRef<HTMLUListElement>(null)

  useEffect(() => {
    // Two different failures that look identical if they share a sentence:
    // a build with no file-search channel is ours to fix, an unopened project
    // is the user's. Saying "open a project" to someone who has one open is
    // how a wiring bug gets mistaken for a working feature.
    if (!resolved) {
      setLoad({ state: 'failed', message: 'File search is not wired into this build.' })
      return
    }
    if (root === '') {
      setLoad({ state: 'failed', message: 'Open a project to attach files from it.' })
      return
    }
    let live = true
    setLoad({ state: 'loading' })
    void resolved
      .searchProjectFiles({ root })
      .then((response) => {
        if (live) setLoad(readFiles(response))
      })
      .catch(() => {
        if (live) setLoad({ state: 'failed', message: 'The project could not be read.' })
      })
    return () => {
      live = false
    }
  }, [resolved, root])

  // The search box is the point of the panel, so it takes focus on open.
  useEffect(() => {
    searchRef.current?.focus()
  }, [mode])

  const rows = useMemo<PickerRow[]>(() => {
    if (load.state !== 'ready') return []
    if (mode === 'folder') return foldersFrom(load.files).map((relPath) => ({ relPath, isDirectory: true }))
    const files = mode === 'image' ? load.files.filter(isImagePath) : load.files
    return files.map((relPath) => ({ relPath, isDirectory: false }))
  }, [load, mode])

  const attached = useMemo(() => new Set(attachments.map((a) => a.relPath)), [attachments])

  const ranked = useMemo(
    () => rankMatches(rows, query, (row) => row.relPath, { limit: LIMIT, path: true }),
    [rows, query],
  )

  useEffect(() => {
    setCursor(0)
  }, [query, mode])

  const choose = useCallback(
    (index: number) => {
      const hit = ranked[index]
      if (hit) onPick(hit.item.relPath, hit.item.isDirectory)
    },
    [ranked, onPick],
  )

  const onKeyDown = (event: React.KeyboardEvent): void => {
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault()
      const step = event.key === 'ArrowDown' ? 1 : -1
      setCursor((c) => Math.min(Math.max(c + step, 0), Math.max(ranked.length - 1, 0)))
      return
    }
    if (event.key === 'Enter') {
      event.preventDefault()
      choose(cursor)
      return
    }
    // Backspace on an empty box goes back to the menu rather than trapping the
    // user in a panel whose only exit is a mouse.
    if (event.key === 'Backspace' && query === '') {
      event.preventDefault()
      onBack()
    }
  }

  // Keep the highlighted row on screen when the arrows move past the fold.
  useEffect(() => {
    const list = listRef.current
    const row = list?.children[cursor]
    if (row instanceof HTMLElement) row.scrollIntoView({ block: 'nearest' })
  }, [cursor])

  const copy = COPY[mode]

  return (
    <div className="at-panel">
      <div className="at-head">
        <button type="button" className="at-back" onClick={onBack} aria-label="Back to the attach menu">
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
            <path d="M15 6l-6 6 6 6" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </button>
        <span className="at-title">{copy.title}</span>
      </div>

      <input
        ref={searchRef}
        className="at-search"
        type="text"
        value={query}
        spellCheck={false}
        placeholder={copy.placeholder}
        aria-label={copy.placeholder}
        onChange={(event) => setQuery(event.target.value)}
        onKeyDown={onKeyDown}
      />

      {load.state === 'loading' ? <p className="at-note">Reading the project…</p> : null}
      {load.state === 'failed' ? <p className="at-note">{load.message}</p> : null}

      {load.state === 'ready' ? (
        ranked.length === 0 ? (
          <p className="at-note">{query === '' ? copy.empty : COPY[mode].empty}</p>
        ) : (
          <ul className="at-list" ref={listRef} role="listbox" aria-label={copy.title}>
            {ranked.map((hit, index) => {
              const { relPath, isDirectory } = hit.item
              const already = attached.has(relPath)
              const cut = relPath.lastIndexOf('/')
              return (
                <li key={relPath}>
                  <button
                    type="button"
                    role="option"
                    aria-selected={index === cursor}
                    className={`at-row${index === cursor ? ' at-row-on' : ''}${already ? ' at-row-had' : ''}`}
                    onMouseEnter={() => setCursor(index)}
                    onClick={() => choose(index)}
                  >
                    <RowIcon isDirectory={isDirectory} isImage={isImagePath(relPath)} />
                    {/* Name and folder are two elements so the name survives a
                        deep path being clipped. One match spans both, which is
                        what `clampRanges` re-bases the highlight for. */}
                    <span className="at-row-name">
                      <Highlight
                        text={relPath.slice(cut + 1)}
                        ranges={clampRanges(hit.ranges, cut + 1, relPath.length)}
                      />
                    </span>
                    {cut > 0 ? (
                      <span className="at-row-dir">
                        <Highlight text={relPath.slice(0, cut)} ranges={clampRanges(hit.ranges, 0, cut)} />
                      </span>
                    ) : null}
                    {already ? <span className="at-row-tag">added</span> : null}
                  </button>
                </li>
              )
            })}
          </ul>
        )
      ) : null}

      {load.state === 'ready' && load.truncated ? (
        <p className="at-note at-note-quiet">This project is large; the list is capped. Type to narrow it.</p>
      ) : null}
    </div>
  )
}

function Highlight({ text, ranges }: { text: string; ranges: readonly MatchRange[] }) {
  return (
    <>
      {segmentByRanges(text, ranges).map((segment, i) =>
        segment.matched ? <mark key={i}>{segment.text}</mark> : <span key={i}>{segment.text}</span>,
      )}
    </>
  )
}

function RowIcon({ isDirectory, isImage }: { isDirectory: boolean; isImage: boolean }) {
  if (isDirectory) {
    return (
      <svg className="at-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
        <path d="M3 7a2 2 0 0 1 2-2h3.6l1.8 2H19a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" strokeWidth="1.6" strokeLinejoin="round" />
      </svg>
    )
  }
  if (isImage) {
    return (
      <svg className="at-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
        <rect x="3" y="5" width="18" height="14" rx="2" strokeWidth="1.6" />
        <path d="M3 16l5-4 4 3 3-2 6 4" strokeWidth="1.6" strokeLinejoin="round" />
      </svg>
    )
  }
  return (
    <svg className="at-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
      <path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z" strokeWidth="1.6" strokeLinejoin="round" />
      <path d="M14 3v5h5" strokeWidth="1.6" strokeLinejoin="round" />
    </svg>
  )
}

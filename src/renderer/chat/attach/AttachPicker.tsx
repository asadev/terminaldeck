import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { clampRanges, rankMatches, segmentByRanges, type MatchRange } from '../../fuzzy'
import { foldersFrom, isImagePath, type Attachment } from './mentions'
import { detectPlatform, screenshotShortcut, type UiPlatform } from '../../platform'
import { browseLabel } from './outside'

/**
 * Choosing what to attach, from inside the project — and, one row up, from
 * anywhere else.
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
 *
 * ## What was wrong with that, and what changed
 *
 * Every word above is still true and none of it was the problem. The problem is
 * that it was the *only* door, so there was no way at all to attach a screenshot
 * on the desktop, a PDF in Downloads, or a file from a second checkout:
 *
 *   > "I should be able to take anything from my PC to paste here… If I just
 *   > click, it should just open browse my file manager of the PC or Windows or
 *   > MacBook, and I should be able to just choose something from there instead
 *   > of opening something inside. I don't know — it doesn't make any sense to
 *   > me."
 *
 * And, about this panel specifically: *"Add an image also keeps me in the same
 * folder."*
 *
 * So the argument above kept its conclusion — the project list is what opens,
 * and it is still the fast path — and lost its exclusivity. `Browse…` sits
 * between the search box and the list, in all three modes, and opens the real
 * open panel. The one measured caveat travels with the pick rather than being
 * enforced by hiding the button: a *folder* from outside the project is the case
 * that gets refused by the model, and `OUTSIDE_FOLDER_CAUTION` in `mentions.ts`
 * is what the composer says about it. A *file* from outside expands normally —
 * measured against the CLI, and recorded at the top of `mentions.ts`.
 *
 * The one case where the row is genuinely offered and does not work is a session
 * held inside a folder by the operating system, and there it is disabled with
 * the reason on it rather than quietly missing. `browseRefusal` carries that
 * sentence; `main/session-boundary.ts` explains where it comes from.
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
  /**
   * A pick, as an **absolute** path.
   *
   * It used to be project-relative, and the composer joined it back onto the
   * root. That stopped working the day a pick could come from outside the
   * project: there is no relative form of `/Users/apple/Desktop/shot.png` from a
   * project in `~/Projects`, and inventing one with `../../..` would be a path
   * that means something different if the session ever changes directory.
   * Absolute is the form the mention needs anyway — see `mentionFor`.
   */
  onPick: (path: string, isDirectory: boolean) => void
  /** Open the real file browser. The menu owns the call; this row is the door. */
  onBrowse: () => void
  /**
   * Why browsing is refused, when it is. Null means it is not.
   *
   * A sentence rather than a boolean, because the only reason it is ever
   * refused is specific enough to be worth saying: the session is held inside a
   * folder by the OS and could not read the file. A greyed-out button with no
   * explanation is the thing this project keeps finding people stuck on.
   */
  browseRefusal?: string | null
  onBack: () => void
  bridge?: AttachPickerBridge
  /** Injected only so the browse label can be asserted for both platforms. */
  platform?: UiPlatform
}

type Load =
  | { state: 'loading' }
  | { state: 'ready'; files: string[]; truncated: boolean }
  | { state: 'failed'; message: string }

const LIMIT = 400

/**
 * Two different empty lists that must not share a sentence.
 *
 * `empty` is "the project contains none of this kind"; `noMatch` is "your query
 * excluded them all". Saying the first while the user is looking at a query is
 * a statement about their project that the component can see is false — the
 * image panel claimed "No images in this project yet" with three of them one
 * keystroke away.
 */
const COPY: Record<PickerMode, { title: string; placeholder: string; empty: string; noMatch: string }> = {
  file: {
    title: 'Add files',
    placeholder: 'Search files in this project…',
    empty: 'No files in this project.',
    noMatch: 'No file matches that.',
  },
  folder: {
    title: 'Add folder',
    placeholder: 'Search folders in this project…',
    empty: 'No folders in this project — every file sits at the top level.',
    noMatch: 'No folder matches that.',
  },
  image: {
    title: 'Add an image',
    placeholder: 'Search images in this project…',
    // The screenshot chord is filled in per platform at render — see
    // `copyFor`. Writing ⇧⌘4 here told a Windows user to press two keys their
    // keyboard does not have.
    empty:
      'No images in this project yet. Take a screenshot with {shot}, save it inside the project folder, and it will appear here.',
    noMatch: 'No image matches that.',
  },
}

/**
 * The copy for a mode, with the one platform-dependent hole filled.
 *
 * A placeholder rather than a second `COPY` table: exactly one sentence in this
 * component differs between platforms, and forking the whole table for it is
 * how `tailnet.ts` ended up with two nearly identical reason lists.
 */
export function copyFor(
  mode: PickerMode,
  platform: UiPlatform = detectPlatform(),
): { title: string; placeholder: string; empty: string; noMatch: string } {
  const copy = COPY[mode]
  return { ...copy, empty: copy.empty.replace('{shot}', screenshotShortcut(platform)) }
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

/**
 * A project-relative row, as the absolute path the rest of the feature wants.
 *
 * The guard on a trailing separator is not hypothetical: a project opened at a
 * volume root is `/Volumes/Work/`, and `${root}/${rel}` there produces a double
 * slash. POSIX collapses it and the CLI's mention parser is not POSIX.
 */
export function joinRoot(root: string, relPath: string): string {
  const base = root.endsWith('/') ? root.slice(0, -1) : root
  return `${base}/${relPath}`
}

/**
 * What the browse row says in each mode.
 *
 * The hint is not decoration — it is the one place the panel admits that the two
 * halves of it produce different things. The list above hands the agent a short
 * relative path inside the project; this hands it an absolute path from
 * somewhere else, which is fine for a file and is the measured exception for a
 * folder.
 */
const BROWSE_HINT: Record<PickerMode, string> = {
  file: 'Any file on this machine, not only this project',
  folder: 'Any folder on this machine',
  image: 'A screenshot on the desktop, a photo, anywhere',
}

function resolveBridge(injected?: AttachPickerBridge): AttachPickerBridge | null {
  if (injected) return injected
  if (typeof window === 'undefined') return null
  const host = (window as unknown as { deck?: Partial<AttachPickerBridge> }).deck
  return host && typeof host.searchProjectFiles === 'function' ? (host as AttachPickerBridge) : null
}

export function AttachPicker({
  root,
  mode,
  attachments,
  onPick,
  onBrowse,
  browseRefusal = null,
  onBack,
  bridge,
  platform,
}: Props) {
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
      // Joined here rather than in the composer, because this component is the
      // one that knows these rows are relative to `root` — the other two routes
      // into the same callback carry absolute paths already.
      if (hit) onPick(joinRoot(root, hit.item.relPath), hit.item.isDirectory)
    },
    [ranked, onPick, root],
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

  const copy = useMemo(() => copyFor(mode), [mode])

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

      {/*
        The escape hatch, above the list rather than under it.

        Under the list it would be below the fold on any project with more than
        nine files in it, which is every project — and "I couldn't find a way to
        attach anything from outside" is the report this row exists to answer, so
        it has to be visible without scrolling. It is still second: the search box
        has focus, Enter still takes the highlighted project row, and reaching
        this one costs a deliberate click or a Tab.

        It is drawn even when it is refused. `browseRefusal` disables it and puts
        the reason on it, because a row that vanishes on some sessions teaches the
        reader that the app cannot do the thing at all.
      */}
      <button
        type="button"
        className="at-browse"
        onClick={onBrowse}
        disabled={browseRefusal !== null}
        title={browseRefusal ?? BROWSE_HINT[mode]}
        aria-label={browseRefusal ?? browseLabel(platform ?? detectPlatform())}
      >
        <svg className="at-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
          <path
            d="M3 7a2 2 0 0 1 2-2h3.6l1.8 2H19a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"
            strokeWidth="1.6"
            strokeLinejoin="round"
          />
          <path d="M12 10v6M9 13h6" strokeWidth="1.6" strokeLinecap="round" />
        </svg>
        <span className="at-browse-text">
          <span className="at-browse-label">{browseLabel(platform ?? detectPlatform())}</span>
          <span className="at-browse-hint">{browseRefusal ?? BROWSE_HINT[mode]}</span>
        </span>
      </button>

      {load.state === 'loading' ? <p className="at-note">Reading the project…</p> : null}
      {load.state === 'failed' ? <p className="at-note">{load.message}</p> : null}

      {load.state === 'ready' ? (
        ranked.length === 0 ? (
          <p className="at-note">{query === '' ? copy.empty : copy.noMatch}</p>
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

      {/* Two ways to be looking at a partial list: the main process stopped
          walking, or the ranking hit its own ceiling. Either way the row you
          want may not be on screen, and silence about that reads as "not in
          this project". */}
      {load.state === 'ready' && (load.truncated || ranked.length >= LIMIT) ? (
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

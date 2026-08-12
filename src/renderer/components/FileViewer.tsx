import { useEffect, useMemo, useRef, useState } from 'react'
import './FileViewer.css'

/**
 * Mirrors the result of `readTextFile` in `src/main/fs-tree.ts`. Declared
 * locally because `shared/types.ts` is owned by the orchestrator — fold this in
 * there when the IPC is wired and delete the copy.
 */
export type FileRead =
  | { kind: 'text'; relPath: string; text: string; bytes: number; lines: number }
  | { kind: 'binary'; relPath: string; bytes: number }
  | { kind: 'too-large'; relPath: string; bytes: number; limit: number }

interface FsBridge {
  readFile(root: string, relPath: string): Promise<FileRead>
}

function readFile(root: string, relPath: string): Promise<FileRead> {
  const api = (window as unknown as { deck?: Partial<FsBridge> }).deck
  if (!api?.readFile) {
    return Promise.reject(new Error('preload bridge is missing terminaldeck.readFile'))
  }
  return api.readFile(root, relPath)
}

/** Electron wraps IPC rejections; the prefix is noise on screen. */
function messageOf(err: unknown): string {
  const raw = err instanceof Error ? err.message : String(err)
  return raw.replace(/^Error invoking remote method '[^']*':\s*/, '')
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

function extensionOf(relPath: string): string {
  const name = relPath.slice(relPath.lastIndexOf('/') + 1)
  const dot = name.lastIndexOf('.')
  return dot > 0 ? name.slice(dot + 1).toUpperCase() : ''
}

/**
 * Hard cap on rendered lines. `MAX_FILE_BYTES` in the main process bounds
 * *bytes*, not lines: 2 MB of short rows — a CSV, a log, a newline-dense
 * fixture — is 130,000 to 2,000,000 lines. Numbering every one of those cost
 * ~130 MB of heap and produced a 15 M-character text node that wedged layout,
 * so the byte cap alone never protected the renderer.
 */
export const MAX_VIEW_LINES = 50_000

/** Lines in text whose trailing newline has already been removed. */
function lineCount(text: string): number {
  if (text === '') return 1
  let lines = 1
  for (let i = text.indexOf('\n'); i !== -1; i = text.indexOf('\n', i + 1)) lines++
  return lines
}

/** Offset of the newline ending line `n`, or -1 when fewer than `n` lines exist. */
function endOfLine(text: string, n: number): number {
  let idx = -1
  for (let i = 0; i < n; i++) {
    idx = text.indexOf('\n', idx + 1)
    if (idx === -1) return -1
  }
  return idx
}

/** Built by concatenation — `Array.from({ length: count })` is the memory spike. */
function buildGutter(count: number): string {
  let out = '1'
  for (let n = 2; n <= count; n++) out += `\n${n}`
  return out
}

type ViewState =
  | { status: 'empty' }
  | { status: 'loading'; path: string }
  | { status: 'error'; path: string; message: string }
  | { status: 'ready'; path: string; read: FileRead }

interface Props {
  /** Absolute path of the project root. */
  root: string
  /** Relative path of the file to show, or null for the empty state. */
  path: string | null
  className?: string
}

/**
 * Read-only file display with a line-number gutter.
 *
 * The gutter and the body are two `<pre>` blocks, not one row per line: a
 * 2 MB source file is ~40,000 lines, and 40,000 row elements make scrolling
 * crawl. Two text nodes in the same monospace metrics stay aligned for free.
 */
export function FileViewer({ root, path, className }: Props) {
  const [view, setView] = useState<ViewState>({ status: 'empty' })
  const bodyRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!path) {
      setView({ status: 'empty' })
      return
    }

    let live = true
    setView({ status: 'loading', path })

    readFile(root, path)
      .then((read) => {
        if (live) setView({ status: 'ready', path, read })
      })
      .catch((err: unknown) => {
        if (live) setView({ status: 'error', path, message: messageOf(err) })
      })

    // A slower reply for the previous file must not land after this one.
    return () => {
      live = false
    }
  }, [root, path])

  // Start each file at the top rather than wherever the last one was scrolled.
  useEffect(() => {
    bodyRef.current?.scrollTo({ top: 0, left: 0 })
  }, [view])

  const text = view.status === 'ready' && view.read.kind === 'text' ? view.read.text : null

  const doc = useMemo(() => {
    if (text === null) return null
    // A trailing newline terminates the last line; keeping it would render a
    // phantom line the gutter has no number for.
    const trimmed = text.endsWith('\n') ? text.slice(0, -1) : text
    const count = lineCount(trimmed)
    const shown = Math.min(count, MAX_VIEW_LINES)
    // shown < count guarantees at least `shown` newlines, so this never returns -1.
    const cut = shown < count ? endOfLine(trimmed, shown) : -1
    return {
      source: cut === -1 ? trimmed : trimmed.slice(0, cut),
      count,
      shown,
      gutter: buildGutter(shown),
    }
  }, [text])

  const name = path ? path.slice(path.lastIndexOf('/') + 1) : ''
  const extension = path ? extensionOf(path) : ''

  return (
    <section className={`file-viewer${className ? ` ${className}` : ''}`} aria-label="File viewer">
      {path && (
        <header className="file-viewer-head">
          <span className="file-viewer-name" title={path}>
            {name}
          </span>
          {extension && <span className="file-viewer-badge">{extension}</span>}
          <span className="file-viewer-meta">
            {view.status === 'ready' && view.read.kind === 'text' && doc
              ? `${doc.count.toLocaleString()} lines · ${formatBytes(view.read.bytes)}`
              : view.status === 'loading'
                ? 'Loading…'
                : ''}
          </span>
        </header>
      )}

      <div
        ref={bodyRef}
        className="file-viewer-body"
        tabIndex={0}
        role="region"
        aria-label={path ? `Contents of ${name}` : 'No file open'}
      >
        {view.status === 'empty' && (
          <p className="file-viewer-notice">Select a file to view it here.</p>
        )}

        {view.status === 'loading' && <p className="file-viewer-notice">Loading…</p>}

        {view.status === 'error' && (
          <p className="file-viewer-notice error">Could not open this file — {view.message}</p>
        )}

        {view.status === 'ready' && view.read.kind === 'too-large' && (
          <p className="file-viewer-notice">
            This file is {formatBytes(view.read.bytes)}, over the{' '}
            {formatBytes(view.read.limit)} viewer limit. Open it in your editor instead.
          </p>
        )}

        {view.status === 'ready' && view.read.kind === 'binary' && (
          <p className="file-viewer-notice">
            Binary file — {formatBytes(view.read.bytes)}. Nothing readable to show.
          </p>
        )}

        {view.status === 'ready' && view.read.kind === 'text' && doc && (
          <>
            {doc.shown < doc.count && (
              <p className="file-viewer-notice">
                Showing the first {doc.shown.toLocaleString()} of{' '}
                {doc.count.toLocaleString()} lines. Open it in your editor to see the rest.
              </p>
            )}
            <div className="file-viewer-doc">
              <pre className="file-viewer-gutter" aria-hidden="true">
                {doc.gutter}
              </pre>
              <pre className="file-viewer-code">
                <code>{doc.source}</code>
              </pre>
            </div>
          </>
        )}
      </div>
    </section>
  )
}

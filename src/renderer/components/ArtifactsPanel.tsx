import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { readFailure, withDeadline } from '../deadline'
import { recall, remember } from '../panel-cache'
import { renderMarkdown } from './ChatView'
import { PageEmpty, PageNote } from './PageEmpty'
import { Pill } from './Pill'
import { HoverNote } from './HoverNote'
import { formatBytes, relativeTime } from './relative-time'
import './ArtifactsPanel.css'

/**
 * Artifacts — the things an agent made in this project.
 *
 * ## Read this before changing what a row is
 *
 * This page has now been reported twice, in the same words both times:
 *
 *   > *"Artifacts are still again showing something like before. This issue has
 *   > been reported to you before too. Now again they are showing some kind of
 *   > **files** instead of artifacts."*
 *
 * It came back because nothing in the code held the *meaning* of the word. The
 * data underneath — `Write`/`Edit`/`NotebookEdit` calls recorded in a session
 * transcript — is a list of file paths, so every rewrite that started from the
 * data arrived back at a file browser, and the second version wrote the
 * reasoning down as if it were settled: *"the only honest definition"*. It was
 * honest about the evidence and wrong about the page. What he asked for, the
 * first time, was: *"bring artifacts over here… they can review artifacts and
 * browse."* Review, and browse — not audit a path list.
 *
 * So the meaning is pinned here, and by `default-scope.test` in
 * `ArtifactsPanel.test.tsx`, which fails if the default list goes back to being
 * every touched file:
 *
 * **An artifact is a file the agent produced whole.** At least one recorded
 * `Write` — it put the entire contents there. Those are the documents, plans,
 * notes, pages and scripts somebody would call "what it made".
 *
 * **A file it only edited is not an artifact.** It patched something that
 * already existed; that is a change to your project, and Source control and
 * Files are the pages for it. Those files are still reachable here, one chip
 * away, under the word that describes them — nothing is hidden, and the split
 * is between two honest words rather than between shown and dropped.
 *
 * And the second half of "it looks like Files" was the *presentation*: a
 * path-shaped list beside a pane of raw monospace source. A row is a thing now
 * — its name, what kind of thing it is, when, how big — and the pane shows the
 * artifact **rendered**, with the change record behind a History switch rather
 * than in front of it.
 *
 * The page still never shows a category it cannot fill. There is no "Images"
 * tab that is always empty and no "Build output" section built on a guess: a
 * `Bash` line that may or may not have redirected into a file is a command
 * string, not evidence. See `src/main/artifacts.ts` for what is enumerable.
 *
 * ## Opening the thing, which this page could name and not do
 *
 * > *"The artifact page should be able to drive the artifacts actually — to show
 * > the visual artifacts, files and things. Artifacts like prototypes: in
 * > artifacts it will be most probably for prototypes, whatever Claude will
 * > make. … Including desktop application also is for prototypes."*
 *
 * Two of the three things an agent actually produces ended here as a sentence
 * about themselves. A **picture** said *"An image, 41 KB. Open it in Files to
 * look at it."* — and Files is a text viewer, so that instruction led to the
 * same sentence one page over. A **prototype** — an `index.html`, which is what
 * an agent writes when it is asked for something to look at — was shown as its
 * own markup, in monospace, which is the difference between reviewing a page and
 * auditing it.
 *
 * Both are now openable, through `window.deck.openLinkExternally` and a
 * `file:` URL. That is not a hole cut in anything: `main/link-open.ts` routes a
 * link from **this app's own renderer** to the system deliberately, and says so
 * — *"Code we wrote asking for a `mailto:` or a `file://` reveal means it"* —
 * while the same file refuses `file:` from a **guest page** in three separate
 * places. The asymmetry is the security posture and this is the trusted side of
 * it.
 *
 * ### Why the system browser and not this app's own
 *
 * Because the app's browser is the guest side. `browser-url.ts` allow-lists
 * `http:` and `https:` and refuses everything else on `will-navigate`,
 * `will-frame-navigate` and `will-redirect`, precisely so a page cannot walk
 * that view onto the user's disk — so an artifact opened there would be refused
 * by design. And the real browser is the better answer anyway for the thing this
 * is for: a prototype opened in it gets devtools, the profile the person is
 * signed into, and a `file:` origin from which every relative `src`, `href` and
 * `fetch` in the page resolves out of the folder it lives in.
 *
 * A CSP is the other half of the same wall. The window runs under
 * `img-src 'self' data:` and `script-src 'self'` (see `applySecurityPolicy` in
 * `src/main/index.ts`), so an `<img src="file://…">` is blocked and an
 * `<iframe srcdoc>` would load a prototype with its own inline script disabled —
 * a page that renders and does nothing, which is worse than not offering it. The
 * preview pane therefore keeps saying what a file is, and the *opening* is done
 * by the machine.
 *
 * The phone reaches the same two artifacts by a different road, for a reason
 * that is worth knowing when reading both: it has no machine to hand the file
 * to, so the host serves the project over HTTP and the phone tunnels to it. See
 * `src/main/artifact-preview.ts`.
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
  /**
   * The window's own sessions, read for one purpose: to put a name on a chip.
   *
   * Optional, and never required by `resolveBridge`, so a build without it
   * shows the same chips it always did with a time on them instead of a name.
   * Nothing on this page depends on the answer arriving.
   */
  listSessions?(): Promise<unknown>
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
  /**
   * Hands a `file:` URL to the machine — the real browser for a page, Preview
   * for a picture, whatever the person has chosen for everything else.
   *
   * Defaults to `window.deck.openLinkExternally`, which already exists and
   * already routes a link from this app's own renderer to the system. Optional
   * for the same reason `onOpenFile` is: a build without it draws no button
   * rather than a button that cannot act. Returns whether the machine took it,
   * so a refusal can be said out loud — a silent one is indistinguishable from
   * a broken button.
   */
  openExternally?(url: string): Promise<boolean>
  /** Injectable for tests; defaults to the preload bridge on `window.deck`. */
  bridge?: ArtifactsBridge
  /** Injected in tests so relative times are deterministic. */
  now?: number
  /** Reads an artifact's current contents. Defaults to the preload bridge. */
  fs?: FsReadBridge
  /**
   * Markdown → sanitised HTML. Injected so this panel can be rendered without a
   * DOM: `renderMarkdown` refuses (returns null) outside a browser, and the
   * preview falls back to plain text, which is the behaviour a static render
   * should see rather than a throw.
   */
  renderDocument?: (text: string) => string | null
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

/** Same defensive read, for the channel that hands over a file's contents. */
function resolveFsBridge(): FsReadBridge | null {
  if (typeof window === 'undefined') return null
  const host = (window as unknown as { deck?: { readFile?: unknown } }).deck
  if (!host || typeof host.readFile !== 'function') return null
  return host as FsReadBridge
}

/** And for the one that hands a URL to the machine. See `openExternally`. */
function resolveOpener(): ((url: string) => Promise<boolean>) | null {
  if (typeof window === 'undefined') return null
  const host = (window as unknown as {
    deck?: { openLinkExternally?: (url: string) => Promise<boolean> }
  }).deck
  if (!host || typeof host.openLinkExternally !== 'function') return null
  return (url: string) => host.openLinkExternally!(url)
}

/**
 * A project-relative path, as a `file:` URL the machine will accept.
 *
 * Three things here are the reason this is a function rather than a template
 * string, and each of them was got wrong by one at some point in some codebase:
 *
 *  - **Windows.** `C:\\Users\\asad\\deck` has to become
 *    `file:///C:/Users/asad/deck` — three slashes, forward separators, and the
 *    drive letter kept. A root beginning with a drive letter is detected rather
 *    than the platform being asked, because the renderer has no `process` and
 *    the root is a string the main process produced.
 *  - **Encoding.** A space, a `#` or a `?` in a filename all mean something else
 *    in a URL. Every segment goes through `encodeURIComponent` separately, so
 *    the separators survive and everything inside them is escaped.
 *  - **Trailing separators.** A root that ends in one would produce `//` in the
 *    middle of the path, which some openers follow and others do not.
 */
export function fileUrl(root: string, relPath: string): string {
  const trimmed = root.replace(/[\\/]+$/, '')
  const windows = /^[a-zA-Z]:/.test(trimmed)
  const parts = [
    ...trimmed.split(/[\\/]/).filter((part) => part !== ''),
    ...relPath.split('/').filter((part) => part !== ''),
  ]
  // A drive letter is not a path segment and must not be escaped — the colon is
  // part of it, and `C%3A` is not a path any opener resolves.
  const head = windows ? `${parts[0]}/` : ''
  const rest = (windows ? parts.slice(1) : parts).map(encodeURIComponent).join('/')
  return `file:///${head}${rest}`
}

export function directoryOf(relPath: string): string {
  const cut = relPath.lastIndexOf('/')
  return cut === -1 ? '' : relPath.slice(0, cut)
}

/* ------------------------------------------------------------ what it is -- */

/**
 * Which half of the page a file belongs on.
 *
 * `made` is the default and the whole point — see the header comment. The test
 * that pins it is the guard against this page becoming a file browser for a
 * third time.
 */
export type ArtifactScopeKind = 'made' | 'changed'

/**
 * A file the agent produced whole at least once.
 *
 * `writes` counts recorded `Write` (and `NotebookEdit` with a whole-cell
 * rewrite) calls. One is enough: an agent that wrote a file and then refined it
 * with three edits still *made* that file, and putting it under "changed"
 * because it was touched again would move an artifact off the page the moment
 * it got better.
 */
export function wasMade(artifact: Artifact): boolean {
  return artifact.writes > 0
}

/**
 * What kind of thing this is, in one word a person already knows.
 *
 * Extension-based, deliberately. The alternative — sniffing the content — costs
 * a read of every file to answer a question the name answers, and would still
 * be a guess. Anything unrecognised falls through to "File", which is the one
 * case where the vaguest word is the true one.
 *
 * The list is short on purpose. A vocabulary of twenty kinds is a legend
 * somebody has to learn; six is a glance.
 */
const KIND_BY_EXTENSION: Record<string, string> = {
  md: 'Document', markdown: 'Document', txt: 'Document', rtf: 'Document', pdf: 'Document',
  doc: 'Document', docx: 'Document',
  html: 'Web page', htm: 'Web page', xhtml: 'Web page',
  css: 'Style sheet', scss: 'Style sheet', sass: 'Style sheet', less: 'Style sheet',
  png: 'Image', jpg: 'Image', jpeg: 'Image', gif: 'Image', webp: 'Image', svg: 'Image',
  avif: 'Image', ico: 'Image', bmp: 'Image',
  csv: 'Data', tsv: 'Data', json: 'Data', jsonl: 'Data', ndjson: 'Data', xml: 'Data',
  yaml: 'Data', yml: 'Data', toml: 'Data', sql: 'Data', geojson: 'Data', parquet: 'Data',
  ts: 'Code', tsx: 'Code', js: 'Code', jsx: 'Code', mjs: 'Code', cjs: 'Code', py: 'Code',
  rb: 'Code', go: 'Code', rs: 'Code', java: 'Code', kt: 'Code', swift: 'Code', c: 'Code',
  h: 'Code', cpp: 'Code', hpp: 'Code', cs: 'Code', php: 'Code', sh: 'Code', bash: 'Code',
  zsh: 'Code', ps1: 'Code', lua: 'Code', vue: 'Code', svelte: 'Code', ipynb: 'Notebook',
}

export function kindOf(relPath: string): string {
  const name = relPath.slice(relPath.lastIndexOf('/') + 1)
  // A dotfile with no second dot — `.gitignore`, `.claudeignore`, `.env` — has
  // no extension at all; its whole name is the type. Calling those "File" would
  // be right and useless, and calling `.gitignore` a "Document" would be wrong.
  if (name.startsWith('.') && !name.slice(1).includes('.')) return 'Setting'
  const dot = name.lastIndexOf('.')
  if (dot <= 0) return 'File'
  return KIND_BY_EXTENSION[name.slice(dot + 1).toLowerCase()] ?? 'File'
}

/** Which artifacts a preview can actually render, rather than describe. */
export type PreviewKind = 'document' | 'text' | 'image' | 'page' | 'none'

/**
 * How the pane should show this artifact.
 *
 * `document` is the one that matters: a markdown file rendered as prose is the
 * difference between reviewing what the agent wrote and reading its source. The
 * page showed markdown as monospace source before, which is most of the reason
 * it read as a file browser.
 *
 * `page` is its own answer rather than `text`, and the difference is one line on
 * screen. A prototype's markup is worth reading and is **not** the thing — so
 * the pane still shows it, with a sentence above it saying that opening it is
 * what makes it a page. Calling it `text` said neither.
 */
export function previewKindOf(relPath: string): PreviewKind {
  const kind = kindOf(relPath)
  if (kind === 'Web page') return 'page'
  if (kind === 'Document') {
    const lower = relPath.toLowerCase()
    // Only the ones this app can actually turn into prose. A PDF or a .docx is
    // a document nobody here can render, and a preview that shows its bytes is
    // worse than one that says what it is and offers to open it.
    return lower.endsWith('.md') || lower.endsWith('.markdown') ? 'document' : 'text'
  }
  if (kind === 'Image') return 'image'
  if (kind === 'File' || kind === 'Notebook') return 'none'
  return 'text'
}

/**
 * What the page says when the scan found nothing — every fact it has, in one
 * line.
 *
 * ## The report
 *
 * Asad, on this page, 2026-08-21:
 *
 *   > *"No artifacts are still. I don't know. We don't have artifacts maybe."*
 *
 * "I don't know" is the finding. The page said *"Nothing written or edited in
 * 15 sessions."* and stopped, which leaves a reader with no way to tell a
 * correct zero from a broken page — and his was almost certainly correct: the
 * folder was `~/Templates`, which is not even a git repository. A zero has to
 * carry its own evidence.
 *
 * Three facts make it checkable, and all three were already in the answer and
 * thrown away:
 *
 *  - **the folder**, `list.root`. Nothing on the page named it, so "no
 *    artifacts here" and "the wrong here" read identically. The same defect the
 *    MCP page had, fixed the same way.
 *  - **how many sessions were read**, which was the only fact it did print.
 *  - **`outsideProject`** — tool calls that named a file *outside* the folder,
 *    counted by `main/artifacts.ts` since it was written and never once shown.
 *    This is the interesting zero: an agent launched from a parent workspace
 *    writes into that parent, so "15 sessions, 40 files, none of them in this
 *    folder" is a complete explanation where "nothing in 15 sessions" is a
 *    shrug. It is also what makes the *Every session* chip beside it worth
 *    pressing rather than a guess.
 */
export function nothingFound(list: ArtifactList): string {
  const where = `Nothing written or edited in ${list.root}`
  if (list.sessionsScanned === 0) return `${where} — no sessions have been recorded for it yet.`
  const read = `${list.sessionsScanned} session${list.sessionsScanned === 1 ? '' : 's'} read`
  // Only when there were some. A zero here is not evidence of anything, and a
  // clause saying "0 files elsewhere" is furniture.
  const elsewhere =
    list.outsideProject > 0
      ? `, ${list.outsideProject} change${list.outsideProject === 1 ? '' : 's'} to files outside it`
      : ''
  return `${where} — ${read}${elsewhere}.`
}

/**
 * The one-line summary under the controls.
 *
 * Exported because it is the sentence that has to stay truthful: it says how
 * many files, from how many sessions, and — when a cap bit — that there are
 * more. A list that quietly stops at four hundred is a list that lies.
 */
export function summarize(list: ArtifactList, shown: number, kind: ArtifactScopeKind): string {
  if (list.artifacts.length === 0) return nothingFound(list)
  // Counted against the half of the list that is on screen, not against every
  // file found — "12 of 33" under a Made chip showing 12 of 12 was the page
  // reporting a filter as if it were a shortfall.
  const total = list.artifacts.filter((artifact) => wasMade(artifact) === (kind === 'made')).length
  const noun = kind === 'made' ? 'made here' : 'changed'
  const parts: string[] = []
  parts.push(shown === total ? `${total} ${noun}` : `${shown} of ${total} ${noun}`)
  parts.push(`${list.sessions.length} session${list.sessions.length === 1 ? '' : 's'}`)
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

/**
 * One artifact, as a thing rather than as a path.
 *
 * What the row says, in order: its **name**, when it last changed, what **kind
 * of thing** it is, and how big it is. The folder is a trailing note in the
 * quietest ink on the page, because it is how you tell two files of the same
 * name apart and nothing more — it used to be the second line of every row,
 * directly under the name, which made a list of paths out of a list of things.
 */
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
          <span className="artifact-row-kind">{kindOf(artifact.relPath)}</span>
          {artifact.onDisk ? (
            <span className="artifact-row-size">{formatBytes(artifact.onDisk.bytes)}</span>
          ) : (
            /* Not a warning, a fact: agents write scratch files and delete
               them, and a row that offered to open one would offer a read
               error. */
            <span className="artifact-tag">not on disk</span>
          )}
          {directory && (
            <span className="artifact-row-dir">
              {/* The inner wrapper is load-bearing — see `.artifact-row-dir-text`. */}
              <span className="artifact-row-dir-text">{directory}</span>
            </span>
          )}
        </span>
      </button>
    </li>
  )
}

/* ---------------------------------------------------------------- preview -- */

/**
 * The artifact itself, as it stands now.
 *
 * This is the half that was missing, and its absence is most of why the page
 * read as a file browser: the pane showed a *diff of a change*, in monospace,
 * as the first and only thing. A person arriving at "Artifacts" wants to see
 * the thing — the note, the plan, the page — and only then how it got there.
 *
 * It reads the file off disk rather than replaying the transcript's `after`
 * text, because those are two different facts and only one of them is what the
 * artifact *is*: an agent writes a file and then edits it four times, and the
 * newest recorded write is several revisions stale. `onDisk` is checked by the
 * caller, so a file the agent made and later deleted never reaches here.
 */
interface FsReadBridge {
  readFile(root: string, relPath: string): Promise<unknown>
}

type ReadState =
  | { status: 'loading' }
  | { status: 'text'; text: string }
  | { status: 'note'; message: string }
  | { status: 'error'; message: string }

/** How long one artifact read has to come back. Same budget as the Files pane. */
const READ_DEADLINE_MS = 10_000

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * Turn `fs:read`'s reply into something to show.
 *
 * Exported and pure so the three answers can be pinned without a filesystem:
 * this project's tests render to static markup and never run an effect, so a
 * component that reads a file can otherwise only ever be tested in its loading
 * state.
 */
export function describeRead(reply: unknown, bytes: number | null): ReadState {
  if (!isRecord(reply)) return { status: 'error', message: 'That file could not be read.' }
  if (reply.kind === 'text' && typeof reply.text === 'string') {
    return reply.text.trim() === ''
      ? { status: 'note', message: 'This file is empty.' }
      : { status: 'text', text: reply.text }
  }
  if (reply.kind === 'too-large') {
    const limit = typeof reply.limit === 'number' ? formatBytes(reply.limit) : 'the preview limit'
    return { status: 'note', message: `Too big to preview here — over ${limit}. Open it in Files.` }
  }
  if (reply.kind === 'binary') {
    const size = bytes === null ? '' : ` (${formatBytes(bytes)})`
    return { status: 'note', message: `Not text${size}, so there is nothing to show inline.` }
  }
  return { status: 'error', message: 'That file could not be read.' }
}

function ArtifactPreview({
  root,
  artifact,
  bridge,
  renderDocument,
}: {
  root: string
  artifact: Artifact
  bridge: FsReadBridge | null
  /** Markdown → HTML, injected so the panel can be rendered without a DOM. */
  renderDocument: (text: string) => string | null
}) {
  const [state, setState] = useState<ReadState>({ status: 'loading' })
  const run = useRef(0)
  const kind = previewKindOf(artifact.relPath)
  const bytes = artifact.onDisk?.bytes ?? null

  useEffect(() => {
    if (!bridge) {
      setState({ status: 'note', message: 'This window cannot read files.' })
      return
    }
    if (kind === 'image') {
      /*
       * Honest rather than empty: nothing in this pane can turn a path into
       * pixels. The window runs under `img-src 'self' data:`, so an
       * `<img src="file://…">` is refused by the CSP — and cutting a hole in it
       * would be the escape hatch this app has spent effort closing.
       *
       * What changed is the sentence. It used to say *"Open it in Files"*, and
       * Files is a text viewer, so following that instruction produced the same
       * note one page over. The button beside this one hands the file to the
       * machine, which does have something that draws pictures.
       */
      setState({
        status: 'note',
        message: `An image${bytes === null ? '' : `, ${formatBytes(bytes)}`}. Open it to look at it.`,
      })
      return
    }
    if (kind === 'none') {
      setState({
        status: 'note',
        message: `${kindOf(artifact.relPath)}${bytes === null ? '' : `, ${formatBytes(bytes)}`}. Open it to look at it on this machine.`,
      })
      return
    }

    const id = run.current + 1
    run.current = id
    setState({ status: 'loading' })
    void withDeadline(bridge.readFile(root, artifact.relPath), 'Reading this file', READ_DEADLINE_MS)
      .then((reply) => {
        if (run.current !== id) return
        setState(describeRead(reply, bytes))
      })
      .catch((error: unknown) => {
        if (run.current !== id) return
        setState({ status: 'error', message: readFailure(error) })
      })
  }, [bridge, root, artifact.relPath, kind, bytes])

  if (state.status === 'loading') return <PageNote busy>Opening it…</PageNote>
  if (state.status === 'note') return <PageNote>{state.message}</PageNote>
  if (state.status === 'error') return <PageNote>{state.message}</PageNote>

  if (kind === 'page') {
    // The markup, with the one fact the markup does not carry: this is a thing
    // that runs, and running it is a press away. Said above the source rather
    // than instead of it — a prototype's source is worth reading and is not
    // what somebody came to Artifacts for first.
    return (
      <>
        <PageNote>
          A page. Open it and your browser runs it — its stylesheet, its script
          and its relative links all resolve from the folder it lives in.
        </PageNote>
        <pre className="artifact-plain">
          <code>{state.text}</code>
        </pre>
      </>
    )
  }

  if (kind === 'document') {
    const html = renderDocument(state.text)
    // `renderMarkdown` returns null when DOMPurify is not initialised, which is
    // every non-browser render. Falling back to the raw text is the whole point
    // of that contract: unsanitised HTML never reaches the DOM.
    if (html !== null) {
      return (
        <div
          className="artifact-doc"
          // Sanitised by `renderMarkdown` — see its contract. This is the same
          // arrangement the chat view uses for the same reason.
          dangerouslySetInnerHTML={{ __html: html }}
        />
      )
    }
  }

  return (
    <pre className="artifact-plain">
      <code>{state.text}</code>
    </pre>
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

/**
 * How long a scan has to answer.
 *
 * The main process gives itself eight seconds of walking transcripts
 * (`DEFAULT_TIME_BUDGET_MS` in `src/main/artifacts.ts`) and then returns what
 * it has, so a deadline under that would turn a working scan into a timeout on
 * any large project. Twenty leaves room for the budget plus the disk under it.
 */
const SCAN_DEADLINE_MS = 20_000

/**
 * How long a completed scan stays good for.
 *
 * Longer than anything else in this app, because it is by far the most
 * expensive read here: the answer is produced by walking every transcript in
 * the project, and a project with a hundred sessions is tens of megabytes of
 * JSONL. Leaving this page and coming back re-ran the whole thing from scratch
 * — Asad watched it do exactly that, repeatedly, in the recording. Two minutes
 * covers a working session of flipping between the page and a terminal;
 * anything older is re-read silently, under the list that is already drawn.
 */
export const SCAN_FRESH_MS = 120_000

function listKey(root: string, scope: ArtifactScope): string {
  return `artifacts:list:${root}|${scope}`
}

/**
 * What a reply means for the page.
 *
 * Pulled out and exported because of the arm that was missing. The panel used
 * to read:
 *
 *     if (response.ok) setList(ready)
 *     else if (response.error !== 'cancelled') setList(error)
 *
 * — so a `cancelled` reply set **nothing at all**, and the page stayed on
 * "Reading this project’s history…" or "Reading the changes…" for the rest of
 * the session. That is not hypothetical: the main process cancels a scan
 * whenever the same window starts another one, and until the fix beside this
 * one a *changes* request cancelled an in-flight *list* request. Toggling the
 * scope on this page wedged it permanently, every time.
 *
 * The generation guard above this already drops replies the page has moved on
 * from, so anything that reaches here is a reply the page is still waiting for
 * — and every one of them has to leave the page in a state it can recover from.
 */
export function scanOutcome<T extends { ok: true }>(
  response: T | { ok: false; error: string; message: string },
): { done: T } | { failed: string } {
  if (response.ok) return { done: response }
  if (response.error === 'cancelled') {
    // Deliberately worded as a fact rather than an apology, and it is offered
    // with a Retry: a scan the app cancelled on itself is worth trying again,
    // and a scan the *window* cancelled is one whose newer request already
    // owns the page and never reaches this line.
    return { failed: 'That scan was stopped before it finished. Read it again?' }
  }
  return { failed: response.message }
}

/**
 * What the Open button says, which is what the thing *is*.
 *
 * *"Open it"* on a prototype undersells the one case he asked about by name, and
 * *"Run it"* on a `.zip` would be a lie. The word follows the kind, which the
 * pane has already worked out for its own preview.
 */
export function openLabel(kind: PreviewKind): string {
  switch (kind) {
    case 'page':
      return 'Run it in your browser'
    case 'image':
      return 'Open the picture'
    default:
      return 'Open it on this machine'
  }
}

export function ArtifactsPanel({
  projectPath,
  onOpenFile,
  openExternally,
  bridge,
  now,
  fs,
  renderDocument = renderMarkdown,
}: ArtifactsPanelProps) {
  /*
   * Every session that wrote into this folder, not only the ones started in it.
   *
   * Asad, walking this page: *"on the sessions here, would be better if you
   * show the other ones also, not the local only."*
   *
   * The narrow scope reads the transcripts filed under *this* folder. On this
   * repository that is 16 transcripts holding **zero** file writes, while 193
   * real writes into the same folder are filed under the parent workspace the
   * orchestrator was launched from — `src/main/artifacts.ts` measured it and
   * wrote the numbers down. So the default was a session row that listed the
   * sessions local to the folder and left out the ones that did the work, with
   * nothing on screen saying a chip would widen it.
   *
   * `main/artifacts.ts` calls the wide scan the expensive one, which is why it
   * was not the default. It is bounded — a session cap, an age cap and a time
   * budget — and he asked to see the other ones. The narrow scope keeps its
   * chip, one press away, for the visit where this folder's own history is the
   * question.
   */
  const [scope, setScope] = useState<ArtifactScope>('all')
  /** Made or changed. See the header comment — this is the fix that has to hold. */
  const [made, setMade] = useState<ArtifactScopeKind>('made')
  /** Whether the pane is showing the artifact or how it got that way. */
  const [showHistory, setShowHistory] = useState(false)
  const [filter, setFilter] = useState('')
  const [session, setSession] = useState<string | null>(null)
  const [selected, setSelected] = useState<string | null>(null)
  const [list, setList] = useState<ListState>({ status: 'loading', list: null, message: null })
  const [history, setHistory] = useState<HistoryState | null>(null)

  const host = useMemo(() => bridge ?? resolveBridge(), [bridge])
  const fsHost = useMemo(() => fs ?? resolveFsBridge(), [fs])
  const opener = useMemo(() => openExternally ?? resolveOpener(), [openExternally])
  /**
   * Said when the machine would not take the file.
   *
   * `openSystemUrl` answers `false` rather than throwing, and a button whose
   * only outcome is a silent refusal is indistinguishable from a broken one.
   * Cleared on the next selection, because it belongs to one press.
   */
  const [openFailed, setOpenFailed] = useState<string | null>(null)
  const clock = now ?? Date.now()
  /** Guards against a slow earlier scan overwriting a newer one's answer. */
  const listRun = useRef(0)
  const historyRun = useRef(0)

  /**
   * Bumped to ask for the scan again after one failed or was cut short. Held
   * as state rather than called directly so the effect below stays the one
   * place a scan is started — two entry points into a scan is how the two
   * requests that cancel each other happened in the first place.
   */
  const [listAttempt, setListAttempt] = useState(0)

  /**
   * Conversation id → the name this window shows that session by.
   *
   * The chips in the session row were a timestamp and a file count — "3h ago ·
   * 4 files" — which identifies a session only to somebody who already knows
   * when they ran it. The app does know the names: `SessionMeta.agentSessionId`
   * is the conversation id this app handed the CLI at spawn, and it is the same
   * id `main/artifacts.ts` reads off the transcript. So the two lists join, and
   * a chip can say which session it is.
   *
   * Read once, and its failure is silent: this is a nicety on a page about
   * files, and a session with no name — one this app did not start, one running
   * another agent — keeps the time it always had.
   */
  const [sessionNames, setSessionNames] = useState<ReadonlyMap<string, string>>(new Map())

  useEffect(() => {
    const list = host?.listSessions
    if (!list) return
    let live = true
    void list().then(
      (raw) => {
        if (!live || !Array.isArray(raw)) return
        const named = new Map<string, string>()
        for (const row of raw) {
          if (!isRecord(row)) continue
          const id = typeof row.agentSessionId === 'string' ? row.agentSessionId : ''
          const title = typeof row.title === 'string' ? row.title : ''
          if (id !== '' && title !== '') named.set(id, title)
        }
        setSessionNames(named)
      },
      () => {},
    )
    return () => {
      live = false
    }
  }, [host])

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

    /*
     * What this page found last time, before anything is asked for.
     *
     * Walking every transcript in the project is the most expensive read in
     * this app, and the shell unmounts the page every time a session takes the
     * window — so a trip to a terminal and back used to cost the whole scan
     * again. See `SCAN_FRESH_MS`.
     */
    const held = listAttempt === 0 ? recall<ArtifactList>(listKey(projectPath, scope), SCAN_FRESH_MS) : null
    if (held) {
      setList({ status: 'ready', list: held.value, message: null })
    } else {
      setList({ status: 'loading', list: null, message: null })
      setSelected(null)
      setSession(null)
      setHistory(null)
    }
    if (held?.fresh) return

    void (async () => {
      try {
        const response = await withDeadline(
          host.listArtifacts({ cwd: projectPath, scope }),
          'Reading this project’s history',
          SCAN_DEADLINE_MS,
        )
        if (listRun.current !== id) return
        const outcome = scanOutcome(response)
        if ('done' in outcome) {
          remember(listKey(projectPath, scope), outcome.done)
          setList({ status: 'ready', list: outcome.done, message: null })
          return
        }
        // A silent re-read behind a list that is already drawn leaves it alone.
        if (held) return
        setList({ status: 'error', list: null, message: outcome.failed })
      } catch (error) {
        if (listRun.current !== id || held) return
        setList({ status: 'error', list: null, message: readFailure(error) })
      }
    })()
  }, [host, projectPath, scope, listAttempt])

  const visible = useMemo(() => {
    const artifacts = list.list?.artifacts ?? []
    const needle = filter.trim().toLowerCase()
    return artifacts.filter((artifact) => {
      // The split that makes this page Artifacts and not Files.
      if (wasMade(artifact) !== (made === 'made')) return false
      if (session && !artifact.sessionIds.includes(session)) return false
      if (needle === '') return true
      return artifact.relPath.toLowerCase().includes(needle)
    })
  }, [list.list, filter, session, made])

  /** How many are on the other chip, so it can say so rather than hide them. */
  const changedCount = useMemo(
    () => (list.list?.artifacts ?? []).filter((artifact) => !wasMade(artifact)).length,
    [list.list],
  )
  const madeCount = useMemo(
    () => (list.list?.artifacts ?? []).filter(wasMade).length,
    [list.list],
  )

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

  /** Same idea as `listAttempt`, for the change list beside it. */
  const [historyAttempt, setHistoryAttempt] = useState(0)

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
        const response = await withDeadline(
          host.artifactChanges({ cwd: projectPath, relPath: selected, scope }),
          'Reading the changes',
          SCAN_DEADLINE_MS,
        )
        if (historyRun.current !== id) return
        const outcome = scanOutcome(response)
        if ('done' in outcome) {
          setHistory({ status: 'ready', relPath: selected, history: outcome.done, message: null })
          return
        }
        setHistory({ status: 'error', relPath: selected, history: null, message: outcome.failed })
      } catch (error) {
        if (historyRun.current !== id) return
        setHistory({
          status: 'error',
          relPath: selected,
          history: null,
          message: readFailure(error),
        })
      }
    })()
  }, [host, projectPath, scope, selected, historyAttempt])

  const current = useMemo(
    () => visible.find((artifact) => artifact.relPath === selected) ?? null,
    [visible, selected],
  )

  const onSelect = useCallback((relPath: string) => {
    setSelected(relPath)
    // A refusal belongs to the press that caused it, not to the pane.
    setOpenFailed(null)
  }, [])

  /**
   * Hand the artifact to the machine.
   *
   * `file:` and not this app's browser, and the reason is in the header: the
   * app's browser allow-lists http(s) and refuses `file:` on three navigation
   * hooks so a guest page cannot walk it onto the disk. The real browser is also
   * simply the better place for a prototype — devtools, the signed-in profile,
   * and an origin its relative URLs resolve from.
   */
  const openOnMachine = useCallback(
    (relPath: string) => {
      if (!opener) return
      setOpenFailed(null)
      void opener(fileUrl(projectPath, relPath)).then(
        (taken) => {
          if (!taken) setOpenFailed('This machine would not open that file.')
        },
        (error: unknown) => setOpenFailed(readFailure(error)),
      )
    },
    [opener, projectPath],
  )

  /*
   * Every session, not the first five.
   *
   * Asad, looking at this row: *"on the sessions here, would be better if you
   * show the other ones also, not the local only."* The cap was arbitrary — a
   * project with nine sessions drew five chips and silently dropped four, with
   * nothing on screen saying that a session was missing, so the row read as the
   * whole list while being a fifth of it. `main/artifacts.ts` already caps what
   * it scans; capping the *display* of what it found a second time is how a
   * filter ends up hiding the row somebody went looking for.
   *
   * The row scrolls sideways instead — see `.artifacts-sessions` — which costs
   * nothing on a project with two sessions and keeps every one of them
   * reachable on a project with forty.
   */
  const sessions = list.list?.sessions ?? []

  return (
    <section className="artifacts" aria-label="Artifacts">
      <header className="artifacts-head">
        <input
          className="artifacts-filter"
          type="search"
          value={filter}
          placeholder="Filter by name…"
          aria-label="Filter artifacts by name"
          spellCheck={false}
          autoComplete="off"
          onChange={(event) => setFilter(event.target.value)}
        />
        {/*
          The split this page exists on. See the header comment: "Made here" is
          the default and is what the word Artifacts means; "Changed" is the
          rest of the record, one chip away rather than deleted, so nothing this
          page knows is hidden and the two are told apart by two honest words.

          Both carry their count, which is what stops "Changed" from reading as
          a place things might be — if it is empty it says 0 and you do not
          press it.
        */}
        <div className="artifacts-scope" role="group" aria-label="What to show">
          <Pill
            on={made === 'made'}
            title="Files an agent wrote whole — the things it produced"
            onClick={() => setMade('made')}
          >
            Made here {madeCount}
          </Pill>
          <Pill
            on={made === 'changed'}
            title="Files that already existed and an agent edited"
            onClick={() => setMade('changed')}
          >
            Changed {changedCount}
          </Pill>
        </div>
      </header>

      {/*
        The second row is *which work to look at*; the first is *what to show*.

        All four chip groups used to sit on one line beside the filter box —
        Made/Changed and the two scope chips, in identical pills, so nothing on
        screen said they answered two different questions. Splitting them by row
        is the "separate with space" rule doing the work a label would otherwise
        have to.
      */}
      <div className="artifacts-sessions" role="group" aria-label="Which sessions to read">
        {/* Words, not glyphs, and the widened one says what it costs. The
            default is this project's own sessions; an agent launched from a
            parent workspace records its writes under *that* folder, which is
            the whole reason the second chip exists. */}
        <Pill on={scope === 'project'} onClick={() => setScope('project')}>
          This project’s sessions
        </Pill>
        <Pill
          on={scope === 'all'}
          title="Also read sessions started elsewhere that wrote into this folder"
          onClick={() => setScope('all')}
        >
          Every session
        </Pill>

        {sessions.length > 1 && (
          <>
            <span className="artifacts-chip-gap" aria-hidden="true" />
            <Pill on={session === null} onClick={() => setSession(null)}>
              All sessions
            </Pill>
            {sessions.map((entry) => (
              <Pill
                key={entry.sessionId}
                on={session === entry.sessionId}
                title={entry.sessionId}
                onClick={() => setSession(session === entry.sessionId ? null : entry.sessionId)}
              >
                {/* The session's name where this window knows it, and the time
                    where it does not — see `sessionNames`. The file count stays
                    either way, because it is what makes one chip worth pressing
                    over another. */}
                {sessionNames.get(entry.sessionId) ?? relativeTime(entry.at, clock)} ·{' '}
                {entry.files} file{entry.files === 1 ? '' : 's'}
              </Pill>
            ))}
          </>
        )}
      </div>

      <p className="artifacts-status" role="status" aria-live="polite">
        {list.status === 'loading'
          ? 'Reading this project’s history…'
          : list.status === 'error'
            ? ''
            : list.list
              ? summarize(list.list, visible.length, made)
              : ''}
      </p>

      {/*
        A failed scan is a page with a reason and a way out, not a sentence in
        the status line above an empty list. Before this, a scan that was
        cancelled produced no state change at all and the status line simply
        never stopped saying "Reading this project’s history…".
      */}
      {list.status === 'error' ? (
        <PageEmpty
          icon={ARTIFACTS_ICON}
          title="Could not read this project’s history"
          action={{ label: 'Try again', onClick: () => setListAttempt((n) => n + 1), primary: true }}
        >
          {list.message}
        </PageEmpty>
      ) : list.status === 'ready' && list.list && list.list.artifacts.length === 0 ? (
        <PageEmpty
          icon={ARTIFACTS_ICON}
          title="Nothing produced here yet"
          action={
            scope === 'project'
              ? { label: 'Read every session', onClick: () => setScope('all') }
              : undefined
          }
        >
          {/* What was read, on the page rather than behind a dot.
              *"No artifacts are still. I don't know."* — a zero with no
              evidence is a page a reader cannot check, and this is the same
              sentence the status line carries when there is a list to head, so
              the two cannot come to say different things. The `i` still holds
              what a scope *is*, which is the part that is a definition rather
              than a finding. */}
          {nothingFound(list.list)}{' '}
          <HoverNote label="What was read">
            {scope === 'project'
              ? 'Only the sessions started in this folder were read. Read every session to include agents launched from a parent folder.'
              : 'No session on this machine has written or edited a file inside this folder.'}
          </HoverNote>
        </PageEmpty>
      ) : (
        <div className="artifacts-body">
          <ul className="artifacts-list" aria-label={made === 'made' ? 'Things this project’s agents made' : 'Files this project’s agents changed'}>
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
                {/*
                  Two different absences, and they used to say the same thing.
                  "Nothing matches that filter" under an empty Changed chip is
                  false — nothing was filtered, there is nothing of that kind.
                */}
                <PageNote>
                  {filter.trim() !== '' || session !== null
                    ? 'Nothing matches that filter.'
                    : made === 'made'
                      ? 'No agent has written a whole file here yet. What it edited is under Changed.'
                      : 'Every file here was made by an agent rather than edited into.'}
                </PageNote>
              </li>
            )}
          </ul>

          <div className="artifacts-detail">
            {current && (
              <header className="artifacts-detail-head">
                {/*
                  The name in the title voice, the folder underneath in the
                  meta line. It was the whole relative path in monospace, which
                  is a heading that says "this is a file at a path" before
                  anything else on the page has spoken.
                */}
                <h3 className="artifacts-detail-name" title={current.relPath}>
                  {current.name}
                </h3>
                <p className="artifacts-detail-meta">
                  {[
                    kindOf(current.relPath),
                    directoryOf(current.relPath) || 'in the project root',
                    `last ${relativeTime(current.lastAt, clock)}`,
                    current.onDisk
                      ? formatBytes(current.onDisk.bytes)
                      : 'no longer on disk',
                  ]
                    .filter(Boolean)
                    .join(' · ')}
                </p>
                <div className="artifacts-detail-actions">
                  {/*
                    The artifact, or how it came to be. Two words rather than
                    two panes: the change record is real evidence and worth
                    keeping, but it is the answer to a second question and it
                    used to be the only thing this pane ever showed.
                  */}
                  <Pill on={showHistory} onClick={() => setShowHistory((on) => !on)}>
                    {showHistory ? 'Show the file' : `History ${changeSummary(current)}`}
                  </Pill>
                  {onOpenFile && current.onDisk && (
                    <button
                      type="button"
                      className="artifacts-open"
                      onClick={() => onOpenFile(current.relPath)}
                    >
                      Open in Files
                    </button>
                  )}
                  {/*
                    Drawn only when there is something to open and something to
                    open it with. A file an agent made and deleted has neither,
                    and a build with no link channel would get a button whose
                    press does nothing — which is the defect this whole change is
                    about, and it must not be reintroduced by the fix.
                  */}
                  {opener && current.onDisk && (
                    <button
                      type="button"
                      className="artifacts-open artifacts-run"
                      data-kind={previewKindOf(current.relPath)}
                      onClick={() => openOnMachine(current.relPath)}
                    >
                      {openLabel(previewKindOf(current.relPath))}
                    </button>
                  )}
                </div>
                {openFailed && <PageNote>{openFailed}</PageNote>}
              </header>
            )}

            {/* The thing itself, first. */}
            {current && !showHistory && (
              current.onDisk ? (
                <ArtifactPreview
                  // Remounted per artifact so a slow read can never land under
                  // the wrong heading — the effect's own guard covers the
                  // common case, and the key covers the rest.
                  key={current.relPath}
                  root={projectPath}
                  artifact={current}
                  bridge={fsHost}
                  renderDocument={renderDocument}
                />
              ) : (
                <PageNote>
                  An agent made this and it is not on disk any more. Its history is still here.
                </PageNote>
              )
            )}

            {showHistory && history?.status === 'loading' && <PageNote busy>Reading the changes…</PageNote>}
            {/*
              And a reason with a way out here too. This is the pane the
              recording caught stuck on "Reading the changes…": the main
              process had cancelled the scan and the reply's shape was one this
              component quietly ignored, so the sentence stayed put.
            */}
            {showHistory && history?.status === 'error' && (
              <div className="artifacts-failed">
                <PageNote>{history.message}</PageNote>
                <button
                  type="button"
                  className="page-pill"
                  onClick={() => setHistoryAttempt((n) => n + 1)}
                >
                  Try again
                </button>
              </div>
            )}
            {showHistory &&
              history?.status === 'ready' &&
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

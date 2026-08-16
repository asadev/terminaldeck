import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { panelSpec } from '../shell/panels'
import { PageEmpty } from './PageEmpty'
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
  return dot > 0 ? name.slice(dot + 1) : ''
}

/* -------------------------------------------------------------------------- */
/* Highlighting                                                                */
/* -------------------------------------------------------------------------- */

/**
 * Colour, without a syntax-highlighting library.
 *
 * `package.json` has no highlighter in it and adding one for a read-only pane
 * would be the heaviest dependency in the renderer — Shiki ships a WASM regex
 * engine and megabytes of grammars, highlight.js a few hundred kilobytes of
 * language definitions — for a page that shows one file at a time.
 *
 * So this is a scanner rather than a parser, and it is deliberately shallow: it
 * finds comments, strings, numbers and reserved words, and calls everything
 * else plain. It knows only the languages this repository is actually made of,
 * and an unknown extension gets **no colour at all** rather than a guess, which
 * is the one failure mode that would matter — a `.py` file painted with
 * JavaScript's reserved words is worse than a `.py` file painted black.
 *
 * The invariant that makes it safe is that the tokens concatenate back to the
 * exact source, byte for byte. `FileViewer.test.tsx` asserts that on every
 * language, because a highlighter that silently eats a character turns a
 * reading surface into a lie.
 */
export type TokenKind = 'plain' | 'comment' | 'string' | 'number' | 'keyword' | 'meta'

export interface Token {
  kind: TokenKind
  text: string
}

export type Language = 'js' | 'json' | 'css' | 'shell' | 'yaml' | 'markdown'

const EXTENSIONS: Readonly<Record<string, Language>> = {
  ts: 'js',
  tsx: 'js',
  mts: 'js',
  cts: 'js',
  js: 'js',
  jsx: 'js',
  mjs: 'js',
  cjs: 'js',
  json: 'json',
  jsonc: 'json',
  css: 'css',
  sh: 'shell',
  bash: 'shell',
  zsh: 'shell',
  yml: 'yaml',
  yaml: 'yaml',
  md: 'markdown',
  markdown: 'markdown',
}

/** The language to colour a path as, or null to leave it uncoloured. */
export function languageOf(relPath: string): Language | null {
  return EXTENSIONS[extensionOf(relPath).toLowerCase()] ?? null
}

const JS_KEYWORDS = new Set(
  ('await break case catch class const continue debugger default delete do else enum export ' +
    'extends false finally for from function if implements import in instanceof interface let ' +
    'new null of private protected public readonly return satisfies static super switch this ' +
    'throw true try type typeof undefined var void while with yield as async declare abstract ' +
    'keyof infer namespace override')
    .split(' '),
)

const JSON_KEYWORDS = new Set(['true', 'false', 'null'])

const SHELL_KEYWORDS = new Set(
  ('if then elif else fi for while until do done case esac function return export local readonly ' +
    'set unset shift source exit trap in select time')
    .split(' '),
)

interface Grammar {
  keywords: ReadonlySet<string>
  /** `//` for the C family, `#` for shells and YAML. */
  lineComment: readonly string[]
  /** Slash-star comments, which run across lines until they are closed. */
  blockComment: boolean
  quotes: readonly string[]
  /**
   * A `#` only opens a comment at the start of a word. Without this, `#fff` in
   * a stylesheet and `$x#y` in a shell script swallow the rest of the line.
   */
  hashNeedsBoundary?: boolean
  /** Single quotes take no escapes at all, which is how a shell reads them. */
  rawSingleQuote?: boolean
  /** `@media`, `@import` — CSS's own reserved words, which start with a sigil. */
  atRules?: boolean
  /** `key:` at the head of a line, which is what YAML is made of. */
  yamlKeys?: boolean
}

const GRAMMARS: Readonly<Record<Exclude<Language, 'markdown'>, Grammar>> = {
  js: {
    keywords: JS_KEYWORDS,
    lineComment: ['//'],
    blockComment: true,
    quotes: ["'", '"', '`'],
  },
  json: {
    // JSONC allows `//`, and plain JSON never contains one outside a string,
    // so accepting it costs nothing and colours a tsconfig correctly.
    keywords: JSON_KEYWORDS,
    lineComment: ['//'],
    blockComment: true,
    quotes: ['"'],
  },
  css: {
    keywords: new Set<string>(),
    lineComment: [],
    blockComment: true,
    quotes: ["'", '"'],
    atRules: true,
  },
  shell: {
    keywords: SHELL_KEYWORDS,
    lineComment: ['#'],
    blockComment: false,
    quotes: ["'", '"'],
    hashNeedsBoundary: true,
    rawSingleQuote: true,
  },
  yaml: {
    keywords: new Set(['true', 'false', 'null', 'yes', 'no']),
    lineComment: ['#'],
    blockComment: false,
    quotes: ["'", '"'],
    hashNeedsBoundary: true,
    yamlKeys: true,
  },
}

const WORD = /[A-Za-z0-9_$-]/
const IDENT_START = /[A-Za-z_$]/
const IDENT = /[A-Za-z0-9_$]/

/** Index just past a string opened at `start`, never running past a newline
 *  for a quote that cannot legally span one. */
function endOfString(source: string, start: number, grammar: Grammar): number {
  const quote = source[start]
  const multiline = quote === '`'
  const escapes = !(grammar.rawSingleQuote && quote === "'")
  let i = start + 1
  while (i < source.length) {
    const ch = source[i]
    if (escapes && ch === '\\') {
      i += 2
      continue
    }
    if (ch === quote) return i + 1
    // An unterminated quote must not swallow the rest of the file — an
    // apostrophe in a stray line of prose would colour a thousand lines green.
    if (ch === '\n' && !multiline) return i
    i += 1
  }
  return source.length
}

function tokenizeCode(source: string, grammar: Grammar): Token[] {
  const out: Token[] = []
  let plainFrom = 0
  let i = 0
  /** True at the start of a line, ignoring indentation. Only YAML needs it. */
  let lineHead = true

  const flush = (end: number): void => {
    if (end > plainFrom) out.push({ kind: 'plain', text: source.slice(plainFrom, end) })
  }
  const emit = (kind: TokenKind, end: number): void => {
    flush(i)
    out.push({ kind, text: source.slice(i, end) })
    i = end
    plainFrom = end
  }

  while (i < source.length) {
    const ch = source[i]

    if (ch === '\n') {
      lineHead = true
      i += 1
      continue
    }

    if (grammar.blockComment && ch === '/' && source[i + 1] === '*') {
      const close = source.indexOf('*/', i + 2)
      emit('comment', close === -1 ? source.length : close + 2)
      continue
    }

    const marker = grammar.lineComment.find((candidate) => source.startsWith(candidate, i))
    const boundary =
      marker !== '#' ||
      !grammar.hashNeedsBoundary ||
      i === 0 ||
      source[i - 1] === '\n' ||
      /\s/.test(source[i - 1])
    if (marker && boundary) {
      const nl = source.indexOf('\n', i)
      emit('comment', nl === -1 ? source.length : nl)
      continue
    }

    if (grammar.quotes.includes(ch)) {
      emit('string', endOfString(source, i, grammar))
      lineHead = false
      continue
    }

    if (grammar.atRules && ch === '@' && IDENT_START.test(source[i + 1] ?? '')) {
      let end = i + 1
      while (end < source.length && IDENT.test(source[end])) end += 1
      emit('keyword', end)
      continue
    }

    if (ch >= '0' && ch <= '9' && !(i > 0 && IDENT.test(source[i - 1]))) {
      let end = i
      while (end < source.length && /[0-9A-Za-z_.]/.test(source[end])) end += 1
      emit('number', end)
      lineHead = false
      continue
    }

    if (IDENT_START.test(ch)) {
      let end = i
      while (end < source.length && WORD.test(source[end])) end += 1
      const word = source.slice(i, end)

      // `key:` at the head of a YAML line. Checked before the keyword set so
      // `true: something` reads as a key rather than as a literal.
      if (grammar.yamlKeys && lineHead && source[end] === ':') {
        emit('meta', end)
        lineHead = false
        continue
      }
      if (grammar.keywords.has(word)) {
        emit('keyword', end)
      } else {
        // Left inside the surrounding plain run rather than emitted, so a file
        // of ordinary identifiers stays a handful of text nodes.
        i = end
      }
      lineHead = false
      continue
    }

    // A YAML sequence dash keeps the line at its head, so `- name: x` still
    // reads `name` as a key rather than as a bare word.
    if (grammar.yamlKeys && ch === '-') {
      i += 1
      continue
    }

    if (!/\s/.test(ch)) lineHead = false
    i += 1
  }

  flush(source.length)
  return out
}

const MD_FENCE = /^\s{0,3}(```|~~~)/
const MD_HEADING = /^\s{0,3}#{1,6}\s/
const MD_QUOTE = /^\s{0,3}>/

/**
 * Markdown, line by line.
 *
 * Line-based on purpose: the inline grammar (emphasis, links, entities) is
 * genuinely ambiguous without a parser, and half-colouring it produces the
 * worst outcome — a `*` that opens emphasis in one paragraph and does not in
 * the next. Headings, fenced code and quotes are unambiguous at the line level
 * and are the structure somebody skims a README for, which is the whole job
 * here: the default file this page opens is usually a README.
 */
function tokenizeMarkdown(source: string): Token[] {
  const out: Token[] = []
  let fenced = false
  let index = 0

  while (index < source.length) {
    const nl = source.indexOf('\n', index)
    const end = nl === -1 ? source.length : nl + 1
    const line = source.slice(index, end)
    const body = nl === -1 ? line : line.slice(0, line.length - 1)

    if (MD_FENCE.test(body)) {
      fenced = !fenced
      out.push({ kind: 'comment', text: line })
    } else if (fenced) {
      out.push({ kind: 'string', text: line })
    } else if (MD_HEADING.test(body)) {
      out.push({ kind: 'meta', text: line })
    } else if (MD_QUOTE.test(body)) {
      out.push({ kind: 'comment', text: line })
    } else {
      out.push({ kind: 'plain', text: line })
    }

    index = end
  }

  return out
}

export function tokenize(source: string, language: Language): Token[] {
  return language === 'markdown' ? tokenizeMarkdown(source) : tokenizeCode(source, GRAMMARS[language])
}

/**
 * Above this the file is shown without colour.
 *
 * Not a limit on the scanner, which is linear and fast — a limit on the DOM.
 * Colour means one element per non-plain run, and a 2 MB minified bundle is
 * hundreds of thousands of them; the pane would take seconds to paint and
 * scroll like treacle. Plain text above the line is a whole file, readable,
 * instantly, which is what the pane is for.
 */
export const HIGHLIGHT_MAX_CHARS = 200_000

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

/**
 * Coloured source as React nodes.
 *
 * Plain runs come back as bare strings rather than as `<span>`s. React renders
 * a string in a child array as a text node, so a file of ordinary code costs
 * one element per keyword and comment instead of one per token — on this
 * repository's largest source file that is the difference between about 6,000
 * elements and about 30,000.
 */
export function renderTokens(tokens: readonly Token[]): ReactNode[] {
  return tokens.map((token, index) =>
    token.kind === 'plain' ? (
      token.text
    ) : (
      <span key={index} className={`tok-${token.kind}`}>
        {token.text}
      </span>
    ),
  )
}

type ViewState =
  | { status: 'empty' }
  | { status: 'loading'; path: string }
  | { status: 'error'; path: string; message: string }
  | { status: 'ready'; path: string; read: FileRead }

/**
 * How long the pane stays blank before admitting it has nothing.
 *
 * The tree opens a file by itself now, and its root listing comes back in a few
 * milliseconds — but "a few" is not "none", and without this the page flashes
 * "No file open" and then replaces it with a README, which reads as a bug.
 */
const EMPTY_GRACE_MS = 300

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
  const [showEmpty, setShowEmpty] = useState(false)
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

  useEffect(() => {
    if (path) {
      setShowEmpty(false)
      return
    }
    const timer = setTimeout(() => setShowEmpty(true), EMPTY_GRACE_MS)
    return () => clearTimeout(timer)
  }, [path])

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

  const language = path ? languageOf(path) : null

  const coloured = useMemo(() => {
    if (!doc || !language) return null
    if (doc.source.length > HIGHLIGHT_MAX_CHARS) return null
    return renderTokens(tokenize(doc.source, language))
  }, [doc, language])

  const name = path ? path.slice(path.lastIndexOf('/') + 1) : ''
  const extension = path ? extensionOf(path).toUpperCase() : ''

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
        {view.status === 'empty' && showEmpty && (
          <PageEmpty icon={panelSpec('files').icon} title="Nothing to open">
            This project has no file at its top level to show.
          </PageEmpty>
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
                <code>{coloured ?? doc.source}</code>
              </pre>
            </div>
          </>
        )}
      </div>
    </section>
  )
}

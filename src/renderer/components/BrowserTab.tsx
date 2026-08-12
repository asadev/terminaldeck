import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from 'react'
import './BrowserTab.css'

/* ------------------------------------------------------------------ types -- */

/**
 * Mirrors of the types in `src/main/browser-tab.ts`, duplicated rather than
 * imported because the renderer tsconfig does not include `src/main`. When the
 * orchestrator lifts them into `src/shared/types.ts` this block goes away and
 * the imports point there instead.
 */
export interface BrowserTabState {
  id: string
  url: string
  label: string
  title: string
  loading: boolean
  canGoBack: boolean
  canGoForward: boolean
  inspecting: boolean
  error: string | null
}

export type LabelSource = 'text' | 'value' | 'aria-label' | 'alt' | 'placeholder' | 'title' | 'none'

export interface BrowserCapture {
  selector: string
  tag: string
  label: string
  labelSource: LabelSource
  url: string
  attributes: Record<string, string>
  /** The composed single-line context, already sanitised by the main process. */
  context: string
}

export interface BrowserTabBounds {
  x: number
  y: number
  width: number
  height: number
}

/** The slice of the preload bridge this panel needs. */
export interface BrowserBridge {
  createBrowserTab(options: {
    url?: string
    bounds?: BrowserTabBounds
    visible?: boolean
  }): Promise<BrowserTabState>
  navigateBrowserTab(id: string, url: string): Promise<BrowserTabState>
  reloadBrowserTab(id: string): Promise<BrowserTabState>
  stopBrowserTab(id: string): Promise<BrowserTabState>
  browserTabBack(id: string): Promise<BrowserTabState>
  browserTabForward(id: string): Promise<BrowserTabState>
  setBrowserInspect(id: string, enabled: boolean): Promise<BrowserTabState>
  closeBrowserTab(id: string): Promise<void>
  setBrowserTabBounds(id: string, bounds: BrowserTabBounds): void
  setBrowserTabVisible(id: string, visible: boolean): void
  onBrowserTabState(cb: (state: BrowserTabState) => void): () => void
  onBrowserElement(cb: (id: string, capture: BrowserCapture) => void): () => void
}

export interface BrowserTabProps {
  /** The page to open on mount. */
  initialUrl?: string
  /** False parks the native view offscreen without tearing the page down. */
  visible?: boolean
  /** Receives the one-line context to hand the agent. Wire this to the session. */
  onSendToAgent?: (text: string) => void
  /** Injectable for tests; defaults to the preload bridge on `window.pawl`. */
  bridge?: BrowserBridge
}

/* ---------------------------------------------------------------- helpers -- */

/**
 * Every method this panel calls, so a half-wired bridge is caught at mount
 * instead of at the first click.
 *
 * `satisfies` keeps the names honest, and `BrowserTab.test.tsx` checks the list
 * against the interface so a method added to {@link BrowserBridge} cannot be
 * left out of it. A short list here is not a small bug: it is the difference
 * between the explanation below and a TypeError under a button.
 */
export const BRIDGE_METHODS = [
  'createBrowserTab',
  'navigateBrowserTab',
  'reloadBrowserTab',
  'stopBrowserTab',
  'browserTabBack',
  'browserTabForward',
  'setBrowserInspect',
  'closeBrowserTab',
  'setBrowserTabBounds',
  'setBrowserTabVisible',
  'onBrowserTabState',
  'onBrowserElement',
] as const satisfies readonly (keyof BrowserBridge)[]

/**
 * Read defensively: the browser tab is wired into the preload separately, so it
 * has to render an explanation rather than crash if it mounts first.
 *
 * Exported for its test — a bridge that is present but incomplete is the case
 * that actually happens, and the case that used to slip through.
 */
export function resolveBridge(): BrowserBridge | null {
  // Tests render this to static markup, where there is no window at all.
  if (typeof window === 'undefined') return null
  const host = (window as unknown as { pawl?: Record<string, unknown> }).pawl
  if (!host) return null
  for (const method of BRIDGE_METHODS) {
    if (typeof host[method] !== 'function') return null
  }
  return host as unknown as BrowserBridge
}

/**
 * Flatten anything on its way to the agent.
 *
 * Pawl types this into a PTY running a coding CLI, where a newline submits the
 * prompt — a two-line message would send the first line as the whole
 * instruction. The main process already guarantees this for the context half;
 * this covers what the user pasted into the instruction field.
 */
export function oneLine(value: string): string {
  return value
    .replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
}

/** The exact string the agent receives. Exported because it is worth testing. */
export function composeSend(context: string, instruction: string): string {
  const lead = oneLine(instruction)
  const tail = oneLine(context)
  return lead ? `${lead} ${tail}` : tail
}

/** How the capture panel names where the label came from. */
export function describeLabelSource(source: LabelSource): string {
  return source === 'text' ? 'text' : source === 'none' ? '' : source
}

/**
 * Closing is best-effort by nature: it runs from cleanup, after unmount, and
 * races the main process tearing the same tab down. An unhandled rejection
 * there is a console error in every StrictMode dev session for no information.
 */
function closeQuietly(api: BrowserBridge, id: string): void {
  void api.closeBrowserTab(id).catch(() => undefined)
}

const EMPTY_STATE: BrowserTabState = {
  id: '',
  url: '',
  label: 'New tab',
  title: '',
  loading: false,
  canGoBack: false,
  canGoForward: false,
  inspecting: false,
  error: null,
}

function boundsOf(node: HTMLElement | null): BrowserTabBounds {
  if (!node) return { x: 0, y: 0, width: 0, height: 0 }
  const rect = node.getBoundingClientRect()
  // CSS pixels, which is the unit setBounds() wants.
  return {
    x: Math.round(rect.left),
    y: Math.round(rect.top),
    width: Math.round(rect.width),
    height: Math.round(rect.height),
  }
}

/* -------------------------------------------------------------- component -- */

/**
 * A live page beside the agent: open a dev server, click an element, hand the
 * agent the selector.
 *
 * The page itself is a native view owned by the main process, floating over
 * this component's viewport rectangle rather than inside it. Two consequences
 * are visible in the code below: the viewport div is deliberately empty and
 * only exists to be measured, and the capture panel sits *outside* it, because
 * nothing in the React tree can paint on top of a native view.
 */
export function BrowserTab({
  initialUrl = 'http://localhost:3000',
  visible = true,
  onSendToAgent,
  bridge,
}: BrowserTabProps) {
  const [state, setState] = useState<BrowserTabState>(EMPTY_STATE)
  const [capture, setCapture] = useState<BrowserCapture | null>(null)
  const [draft, setDraft] = useState(initialUrl)
  const [editingUrl, setEditingUrl] = useState(false)
  const [instruction, setInstruction] = useState('')
  const [sent, setSent] = useState(false)
  const [unwired, setUnwired] = useState(false)

  const viewportRef = useRef<HTMLDivElement | null>(null)
  const idRef = useRef<string | null>(null)
  const visibleRef = useRef(visible)
  visibleRef.current = visible

  const api = useMemo(() => bridge ?? resolveBridge(), [bridge])

  /* -- lifecycle. One native view per mount, closed on the way out. */
  useEffect(() => {
    if (!api) {
      setUnwired(true)
      return
    }
    let cancelled = false
    let created: string | null = null

    void api
      .createBrowserTab({
        url: initialUrl,
        bounds: boundsOf(viewportRef.current),
        visible: visibleRef.current,
      })
      .then((next) => {
        created = next.id
        // StrictMode mounts twice in development; without this the first view
        // would be orphaned above the window with nothing left pointing at it.
        if (cancelled) {
          closeQuietly(api, next.id)
          return
        }
        idRef.current = next.id
        setState(next)
      })
      .catch(() => setUnwired(true))

    return () => {
      cancelled = true
      idRef.current = null
      if (created) closeQuietly(api, created)
    }
  }, [api, initialUrl])

  /* -- state and capture events, filtered to this tab. */
  useEffect(() => {
    if (!api) return
    const offState = api.onBrowserTabState((next) => {
      if (next.id !== idRef.current) return
      setState(next)
    })
    const offElement = api.onBrowserElement((id, next) => {
      if (id !== idRef.current) return
      setCapture(next)
      setSent(false)
    })
    return () => {
      offState()
      offElement()
    }
  }, [api])

  /* -- keep the native view over the viewport rectangle. */
  useEffect(() => {
    if (!api || typeof window === 'undefined') return
    const node = viewportRef.current
    if (!node) return

    const report = () => {
      const id = idRef.current
      if (id) api.setBrowserTabBounds(id, boundsOf(node))
    }
    report()

    const observer = new ResizeObserver(report)
    observer.observe(node)
    // A resize moves the rectangle without resizing the element it sits in
    // (the sidebar, the tab bar), so the window needs watching too.
    window.addEventListener('resize', report)
    return () => {
      observer.disconnect()
      window.removeEventListener('resize', report)
    }
  }, [api, state.id, capture])

  useEffect(() => {
    if (!api) return
    const id = idRef.current
    if (id) api.setBrowserTabVisible(id, visible)
  }, [api, visible, state.id])

  /* -- actions. */
  const withTab = useCallback(
    (run: (api: BrowserBridge, id: string) => Promise<BrowserTabState>) => {
      const id = idRef.current
      if (!api || !id) return
      // The main process throws for an id it no longer knows, and a tab closing
      // underneath an in-flight call is the ordinary case, not the exceptional
      // one. Without the rejection handler that is an unhandled rejection in
      // the renderer every time the panel unmounts mid-navigation.
      void run(api, id).then(
        (next) => setState(next),
        () => undefined,
      )
    },
    [api],
  )

  const submitUrl = useCallback(
    (event: FormEvent) => {
      event.preventDefault()
      setEditingUrl(false)
      withTab((a, id) => a.navigateBrowserTab(id, draft))
    },
    [draft, withTab],
  )

  const toggleInspect = useCallback(() => {
    withTab((a, id) => a.setBrowserInspect(id, !state.inspecting))
  }, [state.inspecting, withTab])

  const send = useCallback(() => {
    if (!capture || !onSendToAgent) return
    onSendToAgent(composeSend(capture.context, instruction))
    setInstruction('')
    setSent(true)
  }, [capture, instruction, onSendToAgent])

  // While the user is typing, the URL bar is theirs; otherwise it follows the page.
  const urlValue = editingUrl ? draft : state.url || draft

  if (unwired) {
    return (
      <div className="browser-tab browser-tab-unwired">
        <p className="browser-unwired-title">Browser tab not connected</p>
        <p className="browser-unwired-body">
          The preload bridge has no browser methods yet, so there is nothing to open a page with.
        </p>
      </div>
    )
  }

  return (
    <div className="browser-tab">
      <div className="browser-bar">
        <div className="browser-nav">
          <button
            type="button"
            className="browser-icon-button"
            aria-label="Back"
            disabled={!state.canGoBack}
            onClick={() => withTab((a, id) => a.browserTabBack(id))}
          >
            <NavArrow direction="back" />
          </button>
          <button
            type="button"
            className="browser-icon-button"
            aria-label="Forward"
            disabled={!state.canGoForward}
            onClick={() => withTab((a, id) => a.browserTabForward(id))}
          >
            <NavArrow direction="forward" />
          </button>
          <button
            type="button"
            className="browser-icon-button"
            aria-label={state.loading ? 'Stop loading' : 'Reload'}
            onClick={() =>
              withTab((a, id) => (state.loading ? a.stopBrowserTab(id) : a.reloadBrowserTab(id)))
            }
          >
            {state.loading ? <StopGlyph /> : <ReloadGlyph />}
          </button>
        </div>

        <form className="browser-url-form" onSubmit={submitUrl}>
          <input
            className="browser-url"
            type="text"
            value={urlValue}
            spellCheck={false}
            autoCorrect="off"
            autoCapitalize="off"
            aria-label="Address"
            placeholder="localhost:3000"
            onChange={(e) => {
              setDraft(e.target.value)
              setEditingUrl(true)
            }}
            onFocus={(e) => {
              setDraft(e.target.value)
              setEditingUrl(true)
              e.target.select()
            }}
            onBlur={() => setEditingUrl(false)}
          />
          {state.loading && <span className="browser-spinner" aria-hidden="true" />}
        </form>

        <button
          type="button"
          className="browser-inspect"
          aria-pressed={state.inspecting}
          data-on={state.inspecting || undefined}
          onClick={toggleInspect}
        >
          <CursorGlyph />
          Inspect
        </button>
      </div>

      {state.error && (
        <p className="browser-error" role="status">
          {state.error}
        </p>
      )}

      {state.inspecting && !state.error && (
        <p className="browser-hint" role="status">
          Click any element in the page. Escape stops.
        </p>
      )}

      {/* Deliberately empty: the native view is painted over this rectangle. */}
      <div className="browser-viewport" ref={viewportRef} />

      {capture && (
        <div className="browser-capture">
          <div className="browser-capture-head">
            <span className="browser-capture-tag">{capture.tag ? `<${capture.tag}>` : 'element'}</span>
            <code className="browser-capture-selector" title={capture.selector}>
              {capture.selector}
            </code>
            <span className="browser-capture-spacer" />
            <button
              type="button"
              className="browser-text-button"
              onClick={() => {
                setCapture(null)
                setInstruction('')
              }}
            >
              Clear
            </button>
          </div>

          {capture.label && (
            <p className="browser-capture-label">
              <span className="browser-capture-key">{describeLabelSource(capture.labelSource)}</span>
              {capture.label}
            </p>
          )}
          <p className="browser-capture-url">{capture.url}</p>

          <div className="browser-send">
            <input
              className="browser-instruction"
              type="text"
              value={instruction}
              placeholder="What should the agent do with it?"
              aria-label="Instruction for the agent"
              onChange={(e) => setInstruction(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') {
                  e.preventDefault()
                  send()
                }
              }}
            />
            <button
              type="button"
              className="browser-send-button"
              disabled={!onSendToAgent}
              onClick={send}
            >
              {sent ? 'Sent' : 'Send to agent'}
            </button>
          </div>
        </div>
      )}
    </div>
  )
}

/* ----------------------------------------------------------------- glyphs -- */

function NavArrow({ direction }: { direction: 'back' | 'forward' }) {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d={direction === 'back' ? 'M15 5 8 12l7 7' : 'M9 5l7 7-7 7'} />
    </svg>
  )
}

function ReloadGlyph() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M20 12a8 8 0 1 1-2.6-5.9" />
      <path d="M20 4v4h-4" />
    </svg>
  )
}

function StopGlyph() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true">
      <path d="M7 7l10 10M17 7L7 17" />
    </svg>
  )
}

function CursorGlyph() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinejoin="round" aria-hidden="true">
      <path d="M5 3l6.5 17 2.4-6.9 7-2.4z" />
    </svg>
  )
}

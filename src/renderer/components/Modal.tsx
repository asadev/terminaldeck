import { useEffect, useId, useRef, type KeyboardEvent, type MouseEvent, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { chromeDim } from '../shell/chrome-dim'
import './Modal.css'

/**
 * Everything that can hold focus inside a panel. Queried live on each Tab so
 * controls rendered after open (a loaded form, a revealed section) are caught.
 *
 * type="hidden" is excluded explicitly: it matches `input:not([disabled])` but
 * cannot take focus, so landing on it as the wrap target would silently drop
 * focus to <body> — outside the panel, where the trap no longer sees Tab.
 */
const FOCUSABLE =
  'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'

interface Props {
  open: boolean
  /** Names the dialog for assistive tech, and heads the panel. */
  title: string
  /** Optional supporting line, wired up as the dialog's description. */
  description?: string
  onClose(): void
  children: ReactNode
  /** Right-aligned action row. Omit for a dialog with no actions. */
  footer?: ReactNode
  /**
   * All three are dialogs; they differ only in how much room they take.
   *
   * `xl` is the large sheet Settings sits in. It replaced a `page` size that
   * filled the window edge to edge with no scrim and no corners — which looked
   * like navigating away rather than opening something, so pressing ⌘, felt
   * like leaving your work rather than glancing at a panel over it. Closing it
   * has to put you back exactly where you were, and the surest way to promise
   * that is to never take the window away in the first place: the workspace
   * stays visible around the sheet the whole time.
   *
   * An `xl` body is handed over with no padding — what goes in it is expected
   * to be a layout of its own, with its own scrolling regions.
   */
  size?: 'md' | 'lg' | 'xl'
  /**
   * Take the whole dialog off the screen without closing it.
   *
   * There is exactly one thing that can appear over an HTML dialog and cannot be
   * re-stacked under it: a native window. `dialog.showOpenDialog` opens an
   * `NSOpenPanel` as a sheet on the *window*, so it is a separate `NSWindow`
   * above every pixel the renderer draws — and a sheet is only 880×448, anchored
   * to the top of the window, so a `lg` dialog underneath it still shows through
   * on all four sides. In the recorded walkthrough that read as two dialogs
   * interleaved: the New-session panel's agent cards sitting in the middle of
   * the folder picker, with the picker's own Cancel and Open buttons drawn
   * across them.
   *
   * No z-index can fix that, because one of the two surfaces is not in the page.
   * So the dialog steps aside for as long as the system panel is up, and comes
   * back with the answer. Hidden rather than closed: closing it would throw away
   * the agent, login and first message somebody had already chosen, which is a
   * worse trade than a moment of the workspace showing through.
   */
  hidden?: boolean
}

/**
 * Accessible modal shell: dialog roles, Escape to close, focus trapped inside
 * while open and handed back to whatever opened it on close.
 *
 * Rendered through a portal into <body> so it escapes the app's flex layout
 * and any stacking context the workspace panes create.
 */
export function Modal({
  open,
  title,
  description,
  onClose,
  children,
  footer,
  size = 'md',
  hidden = false,
}: Props) {
  const panelRef = useRef<HTMLDivElement>(null)
  const restoreRef = useRef<HTMLElement | null>(null)
  const titleId = useId()
  const descriptionId = useId()

  // Remember what had focus, and hand it back on close.
  useEffect(() => {
    if (!open) return

    restoreRef.current = document.activeElement instanceof HTMLElement ? document.activeElement : null

    return () => {
      const previous = restoreRef.current
      restoreRef.current = null
      // The trigger can be gone — a tab closed while its dialog was open.
      if (previous?.isConnected) previous.focus()
    }
  }, [open])

  /*
   * Put focus in the panel — on open, and again every time it comes back from
   * being hidden.
   *
   * The panel itself rather than its first control: screen readers then
   * announce the dialog and its title before any individual field.
   *
   * The second half of that is what `hidden` needs. A `display: none` subtree
   * cannot hold focus, so the moment the dialog steps aside for a system panel
   * the browser drops the caret onto <body> — and it does not put it back when
   * the subtree reappears. Without this, coming back from Browse left a dialog
   * on screen with nothing focused in it: Tab started from the top of the
   * *document*, and the ⌘⏎ its own footer advertises went to whatever the
   * workspace had bound that chord to.
   */
  useEffect(() => {
    if (!open || hidden) return
    panelRef.current?.focus()
  }, [open, hidden])

  /*
   * Take the window's own buttons down with the rest of the chrome.
   *
   * The scrim below dims every pixel the renderer draws. On Windows it does not
   * dim the three the OS draws — minimise, maximise and close are painted into
   * the strip above the page, outside anything a stylesheet can reach — so
   * opening Settings left them at full brightness in the corner of a dimmed
   * window. `shell/chrome-dim.ts` counts the surfaces and the main process
   * repaints the strip; this is every dialog in the app, so it is one effect
   * here rather than one per caller.
   *
   * `open && !hidden`, not `open`. `hidden` is the dialog stepping aside for a
   * native panel, and it steps aside by `display: none` — there is no scrim on
   * the window while a system file picker owns it, so there is nothing for the
   * buttons to be dim with. They come back down when the dialog does.
   */
  useEffect(() => {
    if (!open || hidden) return
    return chromeDim.dim()
  }, [open, hidden])

  // Escape is bound on the window, not the panel, so it still fires if focus
  // has drifted to <body> (a click on the scrim, an iframe stealing it).
  useEffect(() => {
    if (!open) return
    const onKey = (event: globalThis.KeyboardEvent) => {
      if (event.key !== 'Escape') return
      event.stopPropagation()
      onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open, onClose])

  if (!open) return null

  const trapTab = (event: KeyboardEvent<HTMLDivElement>): void => {
    if (event.key !== 'Tab') return
    const panel = panelRef.current
    if (!panel) return

    const focusable = Array.from(panel.querySelectorAll<HTMLElement>(FOCUSABLE)).filter(
      (el) => !el.closest('[aria-hidden="true"], [inert]'),
    )
    if (focusable.length === 0) {
      event.preventDefault()
      return
    }

    const active = document.activeElement as HTMLElement | null
    const index = active ? focusable.indexOf(active) : -1
    const first = focusable[0]
    const last = focusable[focusable.length - 1]

    if (event.shiftKey) {
      // -1 covers focus sitting on the panel itself, where a bare Shift+Tab
      // would otherwise walk straight out of the dialog.
      if (index <= 0) {
        event.preventDefault()
        last.focus()
      }
      return
    }
    if (index === -1 || index === focusable.length - 1) {
      event.preventDefault()
      first.focus()
    }
  }

  // mousedown, not click: a drag that starts on a control and ends on the
  // scrim should not be read as dismissing the dialog.
  const onScrimMouseDown = (event: MouseEvent<HTMLDivElement>): void => {
    if (event.target === event.currentTarget) onClose()
  }

  return createPortal(
    <div
      className="modal-overlay"
      // An attribute rather than a second class name, so the stylesheet reads
      // as one rule about one state. `display: none` is what it resolves to —
      // which also takes the whole subtree out of the tab order and out of the
      // accessibility tree, both of which are correct while a system panel owns
      // the screen.
      data-hidden={hidden ? 'true' : undefined}
      onMouseDown={onScrimMouseDown}
      onKeyDown={trapTab}
    >
      <div
        ref={panelRef}
        className="modal-panel"
        data-size={size}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        aria-describedby={description ? descriptionId : undefined}
        tabIndex={-1}
      >
        <header className="modal-header">
          <div className="modal-heading">
            <h2 className="modal-title" id={titleId}>
              {title}
            </h2>
            {description && (
              <p className="modal-description" id={descriptionId}>
                {description}
              </p>
            )}
          </div>
          <button type="button" className="modal-close" onClick={onClose} aria-label="Close dialog">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor">
              <path d="M6 6l12 12M18 6L6 18" strokeWidth="2.2" strokeLinecap="round" />
            </svg>
          </button>
        </header>

        <div className="modal-body">{children}</div>

        {footer && <footer className="modal-footer">{footer}</footer>}
      </div>
    </div>,
    document.body,
  )
}

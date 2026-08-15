import { useEffect, useId, useRef, type KeyboardEvent, type MouseEvent, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
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
}

/**
 * Accessible modal shell: dialog roles, Escape to close, focus trapped inside
 * while open and handed back to whatever opened it on close.
 *
 * Rendered through a portal into <body> so it escapes the app's flex layout
 * and any stacking context the workspace panes create.
 */
export function Modal({ open, title, description, onClose, children, footer, size = 'md' }: Props) {
  const panelRef = useRef<HTMLDivElement>(null)
  const restoreRef = useRef<HTMLElement | null>(null)
  const titleId = useId()
  const descriptionId = useId()

  // Move focus in on open, hand it back on close.
  useEffect(() => {
    if (!open) return

    restoreRef.current = document.activeElement instanceof HTMLElement ? document.activeElement : null
    // The panel itself rather than its first control: screen readers then
    // announce the dialog and its title before any individual field.
    panelRef.current?.focus()

    return () => {
      const previous = restoreRef.current
      restoreRef.current = null
      // The trigger can be gone — a tab closed while its dialog was open.
      if (previous?.isConnected) previous.focus()
    }
  }, [open])

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
    <div className="modal-overlay" onMouseDown={onScrimMouseDown} onKeyDown={trapTab}>
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

import { useEffect, type ReactNode } from 'react'
import { tip } from '../keymap'
import { browserWindowControls, installWindowControls } from './window-controls'

interface Props {
  title: string
  /** A quiet second line: what the view is for, when there is nothing better. */
  subtitle?: string | null
  /**
   * Rendered instead of the subtitle when the heading has something the user
   * can act on — the folder a session is running in, which is a control rather
   * than a caption.
   */
  meta?: ReactNode
  /** Whether the rail is off screen entirely: pinned away and not being peeked. */
  sidebarHidden: boolean
  /**
   * The sidebar view filling the window, or null while a session is.
   *
   * Only the stylesheet reads it, and only to indent the heading onto the
   * page's own left edge — see `.toolbar[data-page]` in shell.css. The title
   * used to stand at the window's margin while every page centred itself in a
   * measure 280 pixels to the right of it, so each page had a heading floating
   * out over its own gutter.
   */
  page?: string | null
  onRevealSidebar(): void
  /** The pointer reaching the window's left edge, which peeks the rail out. */
  onEdgeEnter(): void
  /** Right-aligned: the mode switch, and nothing else. */
  children?: ReactNode
}

/** Points the way the content's left edge moves — see `Sidebar.tsx`. */
const CHEVRON_RIGHT = 'M9.5 6.5 15 12l-5.5 5.5'

/**
 * The unified toolbar: one row over the content, and the only chrome above it.
 *
 * Apple puts the view's name on the left of a toolbar and its actions on the
 * right, and the empty space between them drags the window — which is the whole
 * reason the old title bar existed.
 *
 * Two things have moved out of here since. The control that opens and closes
 * the sidebar now lives in the sidebar's own gutter, beside the traffic lights,
 * and only reappears here when the rail is completely hidden — at which point
 * the toolbar's left pad *is* where the traffic lights are, so it is still
 * beside them. And the right-hand side holds one segmented mode switch rather
 * than the four unrelated buttons it had collected: a toolbar with a palette
 * button, a details button, a swarm button and a segmented control on it is not
 * a toolbar, it is a shelf.
 *
 * On Windows this bar has the OS's own window buttons drawn into its top-right
 * corner, over the page rather than in it — so the one thing this component has
 * to do beyond rendering is publish how much room they are taking, which is the
 * effect below. Everything that moves out of their way moves in `shell.css`.
 */
export function WindowToolbar({
  title,
  subtitle,
  meta,
  sidebarHidden,
  page = null,
  onRevealSidebar,
  onEdgeEnter,
  children,
}: Props) {
  /*
   * The window buttons' geometry, published for the stylesheet.
   *
   * Empty deps: this is a property of the window, not of any prop, and the
   * measurement keeps itself current from Chromium's own `geometrychange`
   * event — which fires on maximise, on a DPI change and on entering full
   * screen, none of which re-render this component. On every platform without
   * an overlay `browserWindowControls` hands back a host with none and the
   * whole thing is one comparison against null.
   */
  useEffect(() => {
    const host = browserWindowControls()
    return host ? installWindowControls(host) : undefined
  }, [])

  return (
    <header
      className="toolbar"
      data-sidebar-collapsed={sidebarHidden || undefined}
      data-page={page ?? undefined}
    >
      <div className="toolbar-lead">
        {sidebarHidden && (
          <button
            type="button"
            // `toolbar-reveal` takes it out of the flow and parks it beside the
            // traffic lights — see shell.css. It has to stay put whatever the
            // heading beside it does, because it is the same control the rail's
            // own gutter draws in that same spot, and a button that jumps 350px
            // when you press it is a button people stop trusting.
            className="toolbar-btn toolbar-reveal"
            onClick={onRevealSidebar}
            // The same hover that peeks the rail out from the window edge, so
            // reaching for this button reveals the thing it opens before the
            // click lands — the button is the commitment, the approach is the
            // preview.
            onPointerEnter={onEdgeEnter}
            aria-label="Show sidebar"
            aria-expanded={false}
            title={tip('Show the sidebar', 'view.sidebar')}
          >
            <svg
              width="18"
              height="18"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.5"
              strokeLinecap="round"
              strokeLinejoin="round"
              aria-hidden="true"
            >
              <path d={CHEVRON_RIGHT} />
            </svg>
          </button>
        )}
        <div className="toolbar-heading">
          <h1 className="toolbar-title">{title}</h1>
          {meta ?? (subtitle && <p className="toolbar-subtitle">{subtitle}</p>)}
        </div>
      </div>

      {/* The draggable middle. Everything either side of it is a control. */}
      <div className="toolbar-drag" />

      <div className="toolbar-actions">{children}</div>
    </header>
  )
}

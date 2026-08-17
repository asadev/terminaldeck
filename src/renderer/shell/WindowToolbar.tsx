import { useEffect, type ReactNode } from 'react'
import { tip } from '../keymap'
import { SessionTitle } from './SessionTitle'
import { browserWindowControls, installWindowControls } from './window-controls'

interface Props {
  /**
   * What the window is looking at — and while it is split, that is the *host*
   * pane, always.
   *
   * Not the focused one. The whole reason a reader can tell whose account is
   * whose is that this heading belongs to one nameable pane and never moves;
   * following focus would make it belong to whichever pane was clicked last,
   * which is the ambiguity in a costume. `App.tsx` reads it off `primaryPane`,
   * the same traversal `SplitView` boxes the guests by, so the pane with no box
   * is always the pane this names.
   *
   * Null only when there is nothing to name: a launch with nothing open, or a
   * split whose host pane has not been filled yet. A guest never appears here —
   * it states its own name, folder and account in its own bar, over its own
   * terminal. See `PaneBar`.
   */
  title: string | null
  /**
   * The session `title` is the name of, when the heading is a session's.
   *
   * Present only so the heading can be renamed in place — see
   * {@link SessionTitle}. Null for a sidebar view and for the launch screen,
   * whose headings are the app's words rather than anybody's session, and where
   * a rename would have nothing to write to.
   */
  sessionId?: string | null
  /** A quiet second line: what the view is for, when there is nothing better. */
  subtitle?: string | null
  /**
   * Rendered instead of the subtitle when the heading has something the user
   * can act on — the folder a session is running in, which is a control rather
   * than a caption.
   */
  meta?: ReactNode
  /**
   * Whether the pane this heading is about has the keyboard.
   *
   * True whenever the window is showing one thing, because then there is
   * nowhere else for focus to be. It is only a question inside a split, where
   * this heading is the *host* pane's and the keyboard may well be in a guest —
   * and there the heading draws back to exactly the weight an unfocused guest
   * bar draws back to.
   *
   * That is not decoration, it is the argument. "The top bar names the pane
   * with no box around it" is a convention a first-time user has to infer, and
   * the fastest way to teach it is to let them watch: click the guest and the
   * top bar fades while the guest's bar comes up; click back and they swap. Two
   * things that dim together are one thing. Without it the host pane has no
   * focus mark at all, because it deliberately has no border to put a ring on.
   */
  headingFocused?: boolean
  /** Whether the rail is off screen entirely: pinned away and not being peeked. */
  sidebarHidden: boolean
  /**
   * There is a tab strip above this bar, so this bar is no longer the window's
   * top band.
   *
   * Everything that follows from being the top band moves with it: the macOS
   * traffic lights are up there, the reserve that keeps clear of them belongs
   * up there, the control that brings a pinned-away rail back is drawn up there,
   * and the one hairline across the window is drawn up there too. Left here as
   * well, each of those would be a second copy — two reveal buttons, an 82-pixel
   * hole under the strip, and two rules 48px apart reading as two stacked apps.
   *
   * The state without a strip is not hypothetical and is not a corner: it is the
   * whole of a launch with nothing open, which is the first thing anybody sees.
   */
  underStrip?: boolean
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
 * The session's bar: one row over the content, naming what the window is
 * looking at and holding the one control that changes how it is shown.
 *
 * Apple puts the view's name on the left of a toolbar and its actions on the
 * right, and the empty space between them drags the window — which is the whole
 * reason the old title bar existed.
 *
 * ## It is no longer the top of the window
 *
 * Asad, 2026-08-16: *"this tabs should be upside, and this session and all this
 * whole bar including chat, split, terminal should be under this, not above —
 * because if I am inside the browser, this whole bar header is useless."* He is
 * right, and the reason is that this bar and the strip answer different
 * questions. The strip is the *window's*: what you have open, true whatever is
 * on screen. This is the *session's*: its name, its folder, its login and
 * whether it is drawn as a terminal, a conversation or a split — and not one of
 * those is a fact about a web page. So when a browser tab fills the pane this
 * bar is not dimmed or emptied, it is not rendered, and the strip above carries
 * the traffic lights and the window drag in its place. See `underStrip`.
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
 * ## Once there are two, this bar is still one session's — the host's
 *
 * The account chip states which login a session's agent was spawned under.
 * Drawn once across a window holding two sessions from two projects it was
 * wrong for at least one of them, with nothing on screen to say which, and that
 * is a correctness bug rather than a preference. The fix is that a *guest* pane
 * states its own name, folder and account over its own terminal — `PaneBar`.
 *
 * The fix that was tried first, and reverted, was to do that for every pane
 * including the host and empty this bar out. Asad, on seeing it:
 *
 *   > *"The reason why we kept the main section in its place, like on surface,
 *   > is because we did not want to move its drop-downs, its name and
 *   > everything — we wanted to keep it in the top bar, under the pills of
 *   > windows, so it feels like a main session and the other ones like
 *   > secondary sessions. If we make both exactly the same placement — if the
 *   > name and the account come down — then there is no reason to keep one of
 *   > them in a box, because all the sizes, everything, is the same."*
 *
 * That is the sharper reading and it is right. The per-pane reasoning was
 * argued on correctness — a pty has one cwd and one config directory, fixed at
 * spawn — and all of that stays true of the guests. What it got wrong was
 * applying it to the host, where this bar is not ambiguous at all: the host is
 * the pane the window is *about*, it is the one drawn flush with the window
 * with no box, and this bar sits directly on top of it. Move its identity down
 * and the two panes become the same shape stating the same things in the same
 * place, at which point the box around one of them means nothing.
 *
 * So what stays here is what is true of the window however it is arranged, plus
 * the host's own identity:
 *
 *  - **the mode switch**, because "Split" is a statement about the window and
 *    because the one thing it must be able to do while a window is split is get
 *    you out of the split. Per pane it would be the same window-level segment
 *    offered three times;
 *  - **the drag region and, without a strip above, the traffic-light reserve and
 *    the reveal button** — the duties of whichever band is the top one;
 *  - **the heading, the folder and the account — of the host pane.** Unsplit
 *    that is simply the session, and nothing about this bar has changed from
 *    what it always was. Split, it is the first pane in visual order and it
 *    does not follow focus; what follows focus is the *weight* it is drawn at,
 *    so that the top bar and the pane it belongs to dim and brighten together.
 *    See `headingFocused`.
 *
 * On Windows this bar has the OS's own window buttons drawn into its top-right
 * corner, over the page rather than in it — so the one thing this component has
 * to do beyond rendering is publish how much room they are taking, which is the
 * effect below. Everything that moves out of their way moves in `shell.css`.
 */
export function WindowToolbar({
  title = null,
  sessionId = null,
  subtitle,
  meta,
  headingFocused = true,
  sidebarHidden,
  underStrip = false,
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
      data-under-strip={underStrip || undefined}
      data-page={page ?? undefined}
    >
      <div className="toolbar-lead">
        {sidebarHidden && !underStrip && (
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
        {title !== null && (
          <div
            className="toolbar-heading"
            /*
             * Whether the pane this names has the keyboard — the host pane, in
             * a split. Stamped in both states rather than only when false, so
             * the sheet can address either one and so the attribute reads the
             * same way `PaneBar` and `.pane-leaf` stamp theirs; three places
             * spelling the same idea three ways is how one of them drifts.
             */
            data-focused={headingFocused}
          >
            {/* The heading is a control now, for a session: double-clicking it
                renames the session. `SessionTitle` renders the plain `<h1>` this
                was whenever there is no session behind it or nowhere to write a
                name to — see the note there. */}
            <SessionTitle title={title} sessionId={sessionId} />
            {meta ?? (subtitle && <p className="toolbar-subtitle">{subtitle}</p>)}
          </div>
        )}
      </div>

      {/* The draggable middle. Everything either side of it is a control. */}
      <div className="toolbar-drag" />

      <div className="toolbar-actions">{children}</div>
    </header>
  )
}

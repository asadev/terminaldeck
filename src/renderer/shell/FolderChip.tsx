import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'

/**
 * The folder a session is running in, as a control rather than a caption.
 *
 * Starting a session takes no dialog any more — the button starts one in the
 * folder you were last in and gets out of the way — and the price of that is
 * that the folder is now a decision the app made on your behalf. So it has to
 * be visible, and it has to be changeable without hunting: this is the line
 * under the session's name in the toolbar, and one click on it lists every
 * folder you have open plus a way to reach one you do not.
 *
 * ## What it does *not* do, and why
 *
 * It does not move the running session. A pty has one working directory for its
 * whole life, so "change the folder of this session" can only mean killing it
 * and starting another — and the app cannot tell whether that is safe, because
 * it cannot see what you have typed. Keystrokes go from xterm straight to the
 * pty; the renderer never sees them, so "nothing has been typed yet" is not a
 * fact this process has. Rather than guess and occasionally throw away work,
 * the menu says what it really does: it starts a session in the folder you
 * pick, and leaves the one you have alone.
 *
 * The path is set in mono because it is data — the characters are exact and
 * countable — while the menu around it is ordinary UI text. That line runs
 * through the whole window.
 */

export interface FolderOption {
  path: string
  name: string
}

interface Props {
  /** The folder the session on screen is running in. */
  path: string
  /** Every project currently open, in sidebar order. */
  options: readonly FolderOption[]
  /** Start a session in a folder that is already open. */
  onPick(path: string): void
  /** Reach a folder that is not open yet. Opens the system's folder chooser. */
  onBrowse(): void
}

const CHEVRON = 'M6.5 9.5 10 13l3.5-3.5'

/** Between the chip and the menu, and between the menu and the window's edges. */
const MENU_GAP = 8

/**
 * Where the portalled menu goes, in viewport coordinates.
 *
 * It is computed rather than inherited because the menu no longer lives inside
 * the chip: it is rendered under <body> so its glass has the whole window to
 * frost and so no ancestor's stacking context can bury it. The price of that is
 * that it has to be told where its button is, and clamped so a chip near the
 * right-hand edge does not push a 420px menu off the window.
 */
function placeMenu(anchor: DOMRect, menu: { width: number; height: number }) {
  const maxLeft = window.innerWidth - menu.width - MENU_GAP
  // -4px so the menu's first item aligns with the chip's label rather than with
  // the chip's rounded hit area, which is inset by that much.
  const left = Math.max(MENU_GAP, Math.min(anchor.left - 4, Math.max(MENU_GAP, maxLeft)))

  const below = anchor.bottom + MENU_GAP
  // Flip above the chip only when there is genuinely no room below *and* more
  // room above — a menu that flips on a window one pixel too short is worse
  // than one that is a little tight at the bottom.
  const roomBelow = window.innerHeight - below
  const flip = roomBelow < menu.height && anchor.top - MENU_GAP > roomBelow
  const top = flip ? Math.max(MENU_GAP, anchor.top - MENU_GAP - menu.height) : below

  return { left, top }
}

/** Last segment of a path — what a person calls the folder. */
export function folderLabel(path: string): string {
  const parts = path.split(/[/\\]/).filter(Boolean)
  return parts[parts.length - 1] ?? path
}

export function FolderChip({ path, options, onPick, onBrowse }: Props) {
  const [open, setOpen] = useState(false)
  const [at, setAt] = useState({ left: 0, top: 0 })
  const hostRef = useRef<HTMLDivElement>(null)
  const menuRef = useRef<HTMLDivElement>(null)

  /**
   * Measure the button, then the menu, then place it. Run in a layout effect so
   * the move happens before paint — placing it in a plain effect renders the
   * menu at 0,0 for one frame, which on a dark window is a visible flash in the
   * top-left corner.
   */
  const place = useCallback(() => {
    const button = hostRef.current?.querySelector('button')
    const menu = menuRef.current
    if (!button || !menu) return
    setAt(placeMenu(button.getBoundingClientRect(), {
      width: menu.offsetWidth,
      height: menu.offsetHeight,
    }))
  }, [])

  useLayoutEffect(() => {
    if (!open) return
    place()
  }, [open, place, options])

  // A fixed element does not follow its anchor, and the toolbar's anchor moves
  // whenever the window is resized or the sidebar is pinned or peeked away.
  useEffect(() => {
    if (!open) return
    window.addEventListener('resize', place)
    return () => window.removeEventListener('resize', place)
  }, [open, place])

  /*
   * Dismissal is bound on the document rather than on a backdrop element.
   *
   * A transparent full-window backdrop is the usual trick and it is wrong here:
   * the browser panel's pages are native views layered *above* the HTML, so a
   * backdrop would be under them and the first click on a web page would not
   * close this. Listening on the document in the capture phase catches the
   * click wherever in the HTML it lands, and pointerdown rather than click so
   * the menu is gone before whatever was clicked reacts.
   *
   * The menu is checked separately from the chip: it is portalled under <body>,
   * so it is no longer inside `hostRef` and a click on one of its own rows
   * would otherwise be read as a click outside and dismiss it before the row's
   * handler ran.
   */
  useEffect(() => {
    if (!open) return
    const onDown = (event: PointerEvent) => {
      const target = event.target
      if (target instanceof Node) {
        if (hostRef.current?.contains(target)) return
        if (menuRef.current?.contains(target)) return
      }
      setOpen(false)
    }
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return
      // Stopped here so Escape does not also travel on to whatever else in the
      // window treats it as "close" — the menu is the innermost thing open.
      event.stopPropagation()
      setOpen(false)
    }
    document.addEventListener('pointerdown', onDown, true)
    document.addEventListener('keydown', onKey, true)
    return () => {
      document.removeEventListener('pointerdown', onDown, true)
      document.removeEventListener('keydown', onKey, true)
    }
  }, [open])

  const choose = (next: () => void) => {
    setOpen(false)
    next()
  }

  return (
    <div className="folder-chip" ref={hostRef}>
      <button
        type="button"
        className="folder-chip-button"
        aria-haspopup="menu"
        aria-expanded={open}
        // The full path, because the button only has room for the last segment
        // and two projects called `web` are not an unusual thing to have open.
        title={`${path} — start a session somewhere else`}
        onClick={() => setOpen((value) => !value)}
      >
        <span className="folder-chip-path">{folderLabel(path)}</span>
        <svg
          width="14"
          height="14"
          viewBox="0 0 20 20"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.6"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden="true"
        >
          <path d={CHEVRON} />
        </svg>
      </button>

      {open &&
        createPortal(
          <div
            ref={menuRef}
            className="folder-menu"
            role="menu"
            aria-label="Start a session in"
            style={{ left: at.left, top: at.top }}
          >
            <p className="folder-menu-head">Start a session in</p>
            {options.map((option) => (
              <button
                key={option.path}
                type="button"
                role="menuitem"
                className="folder-menu-item"
                data-current={option.path === path || undefined}
                title={option.path}
                onClick={() => choose(() => onPick(option.path))}
              >
                <span className="folder-menu-name">{option.name}</span>
                <span className="folder-menu-path">{option.path}</span>
              </button>
            ))}
            <button
              type="button"
              role="menuitem"
              className="folder-menu-item folder-menu-browse"
              onClick={() => choose(onBrowse)}
            >
              Another folder…
            </button>
          </div>,
          document.body,
        )}
    </div>
  )
}

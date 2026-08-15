import { createPortal } from 'react-dom'
import { useChipMenu } from './chip-menu'

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
 * Its neighbour is `AccountChip`, which answers the other half of the same
 * question — *which login* — in the same shape, from the same menu mechanics
 * (`chip-menu.ts`), one click away from the same spot.
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

/** Last segment of a path — what a person calls the folder. */
export function folderLabel(path: string): string {
  const parts = path.split(/[/\\]/).filter(Boolean)
  return parts[parts.length - 1] ?? path
}

export function FolderChip({ path, options, onPick, onBrowse }: Props) {
  const menu = useChipMenu(options)

  return (
    <div className="folder-chip" ref={menu.hostRef}>
      <button
        type="button"
        className="folder-chip-button"
        aria-haspopup="menu"
        aria-expanded={menu.open}
        // The full path, because the button only has room for the last segment
        // and two projects called `web` are not an unusual thing to have open.
        title={`${path} — start a session somewhere else`}
        onClick={menu.toggle}
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

      {menu.open &&
        createPortal(
          <div
            ref={menu.menuRef}
            className="folder-menu"
            role="menu"
            aria-label="Start a session in"
            style={{ left: menu.at.left, top: menu.at.top }}
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
                onClick={() => menu.choose(() => onPick(option.path))}
              >
                <span className="folder-menu-name">{option.name}</span>
                <span className="folder-menu-path">{option.path}</span>
              </button>
            ))}
            <button
              type="button"
              role="menuitem"
              className="folder-menu-item folder-menu-browse"
              onClick={() => menu.choose(onBrowse)}
            >
              Another folder…
            </button>
          </div>,
          document.body,
        )}
    </div>
  )
}

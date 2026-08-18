import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react'
import { useOneMenu } from '../../shell/one-menu'
import type { AttachScope } from './mentions'
import { browseForAttachment, resolveOutsideBridge, type AttachOutsideBridge } from './outside'
import './AttachMenu.css'

/**
 * The plus button and the three rows behind it.
 *
 * Each row opens the operating system's own file panel, on the click that
 * chooses it. There is no second screen, no search field and no list of the
 * project drawn by this app:
 *
 *   > *"If I click on add files, it is opening like this. It should open our
 *   > file manager instead of staying inside. It should be directly browse —
 *   > not even click. We should not even have this search bar and this button to
 *   > click at all. Add folder → directly open the file manager. Add file →
 *   > directly. Add an image → directly. That's it. Simple."*
 *
 * ## Why a menu survives at all, when "not even click" was the ask
 *
 * Because the three are not one thing. A folder panel and a file panel are
 * different panels on both platforms, and an image panel is a file panel with a
 * filter on it — so *something* has to say which of the three is wanted before
 * the panel can open, and the only alternatives to these three rows are asking
 * afterwards or opening a panel that offers everything and filters nothing.
 * What went was the app's own browser sitting between the row and the panel,
 * which is what he was actually looking at. Pressing `Add` and then `Add files`
 * now costs two clicks and the second one *is* the file manager opening.
 *
 * ## Two modes, because there are two things on the other end of the box
 *
 * `mention` is for an agent CLI: a pick becomes an `@"path"` mention the CLI
 * expands on submit.
 *
 * `path` is for a plain shell, and it exists because this menu was once deleted
 * outright on a shell session. The reasoning was sound as far as it went — a
 * shell would type `@"…"` verbatim at its prompt and get `command not found` —
 * but the conclusion was not: it left the shell composer with a microphone and
 * a send button and nothing else, which is the "you removed everything" this
 * mode repairs. Picking a path out of the file manager is not an agent feature.
 * Only the form was, so in `path` mode the pick lands in the command line as a
 * shell-quoted path (see `shellQuote`).
 *
 * ## What used to be here and is not
 *
 * **Connectors.** The MCP server list was a fourth row. It went for the reason
 * the whole controls row under the box went — it is in the window's own bar,
 * one click away, on every session including the ones drawn as a terminal:
 *
 *   > *"Options is showing the same options that we already have here… since we
 *   > have it on top we actually don't need them here."*
 *
 * `McpServers.tsx` stays where it is: `shell/use-connectors.ts` reads it for
 * that chip, so the list has a home and the code has one owner.
 */

/** Which panel a row opens. There is no fourth kind. */
export type AttachSurface = 'file' | 'folder' | 'image'

/** What the box on the other end of this menu understands. */
export type AttachMode = 'mention' | 'path'

interface Props {
  /** The project. Only used to decide where the panel opens. */
  root: string
  /**
   * The **absolute** paths chosen in the operating system's panel. The composer
   * decides what to do with them — mentions in `mention` mode, quoted paths in
   * `path` mode — and validates them either way.
   *
   * A list rather than one at a time, and that is a bug fix rather than a
   * generalisation: a multi-selection used to be added in a loop, and every call
   * in that loop read the same state, so only the last file survived.
   * `addAttachments` folds a batch; see it for the whole account.
   *
   * `scope` is how the composer knows these are allowed to be outside the
   * project. Every route here now reaches outside, so every call says
   * `'anywhere'` — but the parameter stays, because `addAttachment` refuses an
   * outside path unless it is told, and a silent default is how that gate would
   * come to be bypassed by the next caller.
   */
  onAdd: (picks: ReadonlyArray<{ path: string; isDirectory: boolean }>, scope: AttachScope) => void
  /**
   * Something to say that is not an attachment — a browse that failed, a build
   * with no file browser in it. It lands in the composer's own notice line,
   * beside the chips, rather than in a toast this popover would outlive.
   */
  onNotice?: (message: string) => void
  /** Called on every close so the composer can take focus back. */
  onClose: () => void
  disabled?: boolean
  mode?: AttachMode
  /**
   * Where the panel opens, when that is not simply the project.
   *
   * A confined session may not be able to read the project at all, and a file
   * browser whose first screen is a directory every row of which will be refused
   * is worse than one that opens where the session can actually read. The
   * composer works it out (`browseStart`) because the boundary belongs to the
   * session and the composer is what knows which session this is.
   */
  startIn?: string
  /** Test seam for the panel. Absent means the real bridge. */
  outsideBridge?: AttachOutsideBridge
}

export interface MenuItem {
  surface: AttachSurface
  label: string
  hint: string
}

/**
 * One glyph per surface, held apart from the rows so the two modes cannot drift
 * into drawing the same thing two ways.
 */
const ICONS: Record<AttachSurface, ReactNode> = {
  file: (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
      <path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z" strokeWidth="1.6" strokeLinejoin="round" />
      <path d="M14 3v5h5" strokeWidth="1.6" strokeLinejoin="round" />
    </svg>
  ),
  folder: (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
      <path d="M3 7a2 2 0 0 1 2-2h3.6l1.8 2H19a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" strokeWidth="1.6" strokeLinejoin="round" />
    </svg>
  ),
  image: (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
      <rect x="3" y="5" width="18" height="14" rx="2" strokeWidth="1.6" />
      <path d="M3 16l5-4 4 3 3-2 6 4" strokeWidth="1.6" strokeLinejoin="round" />
    </svg>
  ),
}

/**
 * The hints say where the panel goes, not what the agent does with the result.
 *
 * They used to describe the mention — "Sent as a reference the agent reads" —
 * which was true and answered a question nobody was asking at the moment of
 * pressing a button. The one thing that was not obvious, and the one thing he
 * asked for, is that this opens the machine's own file browser rather than
 * another screen inside the app. So that is what they say.
 */
const MENTION_ITEMS: MenuItem[] = [
  { surface: 'file', label: 'Add files', hint: 'Opens the file browser' },
  { surface: 'folder', label: 'Add folder', hint: 'Opens the file browser' },
  { surface: 'image', label: 'Add an image', hint: 'Opens the file browser, images only' },
]

/**
 * The shell's two. No image row: an image is only a separate kind of thing
 * because an agent *sees* it, and a `/bin/zsh` prompt does not — offering it
 * there would be the window claiming something it cannot do, which is the
 * failure the wholesale deletion of this menu was trying to avoid in the first
 * place and made worse.
 */
const PATH_ITEMS: MenuItem[] = [
  { surface: 'file', label: 'Insert a file path', hint: 'Quoted, so a space cannot split the command' },
  { surface: 'folder', label: 'Insert a folder path', hint: 'Quoted, so a space cannot split the command' },
]

/**
 * The rows this menu offers, for the mode it is in.
 *
 * Exported so the two lists can be checked without a DOM — this project renders
 * components to strings in its tests, and a popover that is shut renders
 * nothing at all, so the only way to assert that a shell still has rows behind
 * its plus is to ask for them directly. That assertion is the point: the list
 * being empty is exactly the regression this mode exists to close.
 */
export function attachItems(mode: AttachMode): MenuItem[] {
  return mode === 'path' ? PATH_ITEMS : MENTION_ITEMS
}

export function AttachMenu({
  root,
  onAdd,
  onNotice,
  onClose,
  disabled = false,
  mode = 'mention',
  startIn,
  outsideBridge,
}: Props) {
  const [open, setOpen] = useState(false)
  /**
   * Which panel is being waited on, or null.
   *
   * The row it belongs to is marked while the panel is up. Opening a native
   * panel is not instant — the main process has to resolve the window and
   * AppKit has to build the sheet — and a menu that looks inert for a third of a
   * second after a click is a menu people click twice, which on the old
   * project-list route was harmless and here means two panels queued.
   */
  const [busy, setBusy] = useState<AttachSurface | null>(null)
  const hostRef = useRef<HTMLDivElement>(null)
  const items = attachItems(mode)
  /**
   * The word on the chip and the sentence it says on hover.
   *
   * Both change with the mode, because a chip reading "Add" over a menu that
   * inserts text into a command line is the row describing itself wrongly — and
   * the two most-read words in this composer are the ones on its buttons.
   */
  const word = mode === 'path' ? 'Path' : 'Add'
  const label =
    mode === 'path'
      ? 'Insert a file or folder path into the command line'
      : 'Add files, folders or images to this message'

  const close = useCallback(() => {
    setOpen(false)
    onClose()
  }, [onClose])

  /*
   * Shut, and nothing else — what the window's one-menu-at-a-time rule calls.
   *
   * Deliberately not `close`. `close` also hands focus back to the text box,
   * which is right when *this* popover is being dismissed and wrong when it is
   * being displaced: the user has just pressed a different control, and pulling
   * the caret into the composer would take focus off the thing under their
   * pointer. See `one-menu.ts`.
   */
  const shut = useCallback(() => setOpen(false), [])
  useOneMenu(open, shut)

  // Escape closes from anywhere inside, and a click outside dismisses. Both are
  // registered only while the menu is open, so the composer costs nothing when
  // it is shut.
  useEffect(() => {
    if (!open) return
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') {
        event.stopPropagation()
        close()
      }
    }
    const onDown = (event: MouseEvent): void => {
      const host = hostRef.current
      if (host && event.target instanceof Node && !host.contains(event.target)) close()
    }
    document.addEventListener('keydown', onKey, true)
    document.addEventListener('mousedown', onDown)
    return () => {
      document.removeEventListener('keydown', onKey, true)
      document.removeEventListener('mousedown', onDown)
    }
  }, [open, close])

  /**
   * The operating system's panel, and what happens to this popover while it is up.
   *
   * The menu stays mounted for the whole call. Closing it first would be tidier
   * to read and would break the feature: this popover closes on any `mousedown`
   * outside itself, the panel is a separate native window, and unmounting the
   * component that owns this promise while somebody is browsing would drop the
   * result on the floor. So it stays, the picks are added, and *then* it closes
   * — because the panel covered the screen, and coming back to a popover still
   * sitting over the chip row would hide the only confirmation there is.
   */
  const browse = useCallback(
    async (surface: AttachSurface): Promise<void> => {
      const bridge = resolveOutsideBridge(outsideBridge)
      if (bridge === null) {
        onNotice?.('The file browser is not wired into this build.')
        return
      }
      setBusy(surface)
      try {
        const outcome = await browseForAttachment(bridge, surface, startIn ?? root)
        if (outcome.kind === 'failed') {
          onNotice?.(outcome.message)
          return
        }
        // Escape in the panel. Nothing to say and nothing to close — the user is
        // back where they were, which is what they asked for, so the menu is
        // left open on the row they pressed.
        if (outcome.kind === 'cancelled') return
        onAdd(outcome.picks, 'anywhere')
        close()
      } finally {
        setBusy(null)
      }
    },
    [outsideBridge, onNotice, startIn, root, onAdd, close],
  )

  return (
    <div className="at-host" ref={hostRef}>
      {open ? (
        <div
          className="at-pop"
          role="dialog"
          aria-label={mode === 'path' ? 'Insert a path into the command line' : 'Attach to this message'}
        >
          <ul className="at-menu">
            {items.map((item) => (
              <li key={item.surface}>
                <button
                  type="button"
                  className="at-item"
                  // Every row is one click and that click opens the panel. A
                  // second click while the first panel is opening would queue a
                  // second panel behind it.
                  disabled={busy !== null}
                  data-busy={busy === item.surface || undefined}
                  onClick={() => void browse(item.surface)}
                >
                  <span className="at-item-icon">{ICONS[item.surface]}</span>
                  <span className="at-item-text">
                    <span className="at-item-label">{item.label}</span>
                    <span className="at-item-hint">
                      {busy === item.surface ? 'Opening the file browser…' : item.hint}
                    </span>
                  </span>
                </button>
              </li>
            ))}
          </ul>
        </div>
      ) : null}

      {/* Labelled, not a bare plus. It shares `cc-chip` with the send button
          beside it (ChatComposer.css), and the accessible name contains the word
          on screen so saying "Add" — or "Path", on a shell — out loud still hits
          the thing you can see. */}
      <button
        type="button"
        className="cc-chip"
        disabled={disabled}
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-label={label}
        title={label}
        onClick={() => (open ? close() : setOpen(true))}
      >
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
          <path d="M12 5v14M5 12h14" strokeWidth="2" strokeLinecap="round" />
        </svg>
        {word}
      </button>
    </div>
  )
}

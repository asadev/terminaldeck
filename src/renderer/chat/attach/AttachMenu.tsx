import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react'
import { useOneMenu } from '../../shell/one-menu'
import { AttachPicker, type PickerMode } from './AttachPicker'
import { McpServers } from './McpServers'
import { useControlOffer } from '../../features/offer'
import type { Attachment, AttachScope } from './mentions'
import { browseForAttachment, resolveOutsideBridge, type AttachOutsideBridge } from './outside'
import './AttachMenu.css'

/**
 * The plus button and everything behind it.
 *
 * One popover with three faces — a short menu, a picker, the connector list —
 * rather than three floating surfaces, because every one of these ends the same
 * way: something is added to the message and focus goes back to the box the
 * user was typing in.
 *
 * ## Two modes, because there are two things on the other end of the box
 *
 * `mention` is for an agent CLI: a pick becomes an `@"path"` mention the CLI
 * expands on submit, and connectors are its tools.
 *
 * `path` is for a plain shell, and it exists because this menu was once deleted
 * outright on a shell session. The reasoning was sound as far as it went — a
 * shell would type `@"…"` verbatim at its prompt and get `command not found` —
 * but the conclusion was not: it left the shell composer with a microphone and
 * a send button and nothing else, which is the "you removed everything" this
 * mode repairs. Picking a path out of the project is not an agent feature. Only
 * the form was, so in `path` mode the pick lands in the command line as a
 * shell-quoted path (see `shellQuote`) and the menu offers nothing an agent
 * would be needed to honour.
 */

export type AttachSurface = PickerMode | 'mcp'

/** What the box on the other end of this menu understands. */
export type AttachMode = 'mention' | 'path'

interface Props {
  root: string
  attachments: readonly Attachment[]
  /**
   * The **absolute** paths chosen somewhere behind this button. The composer
   * decides what to do with them — mentions in `mention` mode, quoted paths in
   * `path` mode — and validates them either way.
   *
   * A list rather than one at a time, and that is a bug fix rather than a
   * generalisation: a multi-selection in the open panel used to be added in a
   * loop, and every call in that loop read the same state, so only the last file
   * survived. `addAttachments` folds a batch; see it for the whole account.
   *
   * `scope` is how the composer knows whether these are allowed to be outside
   * the project. It is not advice: `addAttachment` refuses an outside path
   * unless it is told `'anywhere'`, so a route that reaches outside has to say
   * so, and the project list cannot start producing outside paths by accident.
   */
  onAdd: (picks: ReadonlyArray<{ path: string; isDirectory: boolean }>, scope: AttachScope) => void
  /** Free text to drop into the message, used by the connector list. */
  onInsert: (text: string) => void
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
   * Why browsing outside the project is refused on this session, or null.
   *
   * Passed down rather than worked out here, because the answer belongs to the
   * session and the composer is what knows which session this is. See
   * `main/session-boundary.ts`.
   */
  browseRefusal?: string | null
  /** Test seam for the three outside routes. Absent means the real bridge. */
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
  mcp: (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
      <path d="M12 3v6M12 15v6M5 12h14" strokeWidth="1.6" strokeLinecap="round" />
      <circle cx="12" cy="12" r="2.6" strokeWidth="1.6" />
    </svg>
  ),
}

const MENTION_ITEMS: MenuItem[] = [
  { surface: 'file', label: 'Add files', hint: 'Sent as a reference the agent reads' },
  { surface: 'folder', label: 'Add folder', hint: 'The agent gets its listing' },
  { surface: 'image', label: 'Add an image', hint: 'Screenshots included — the agent sees them' },
  { surface: 'mcp', label: 'Connectors', hint: 'MCP servers this session can reach' },
]

/**
 * The shell's two. No image row and no connectors: an image is only a separate
 * kind of thing because an agent *sees* it, and MCP servers are an agent's
 * tools — offering either at a `/bin/zsh` prompt would be the window claiming
 * something it cannot do, which is the failure the deletion was trying to avoid
 * in the first place.
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
  attachments,
  onAdd,
  onInsert,
  onNotice,
  onClose,
  disabled = false,
  mode = 'mention',
  browseRefusal = null,
  outsideBridge,
}: Props) {
  const [surface, setSurface] = useState<AttachSurface | 'menu' | null>(null)
  const hostRef = useRef<HTMLDivElement>(null)
  const buttonRef = useRef<HTMLButtonElement>(null)
  /*
   * Connectors belongs to the MCP servers feature, which can be uninstalled.
   *
   * The row stays either way, and what changes is what pressing it does: with
   * the feature installed it opens the connector list; without it, it installs
   * MCP servers and then opens the list. That is the store's own rule — where a
   * feature would have been, offer it — and a menu is the easiest place in an
   * app to break it, because deleting the entry costs one line and looks tidy.
   *
   * The *button's* name still only promises connectors when they are there. A
   * label is a description of what this menu can do now; the row inside it is
   * an offer, which is a different claim.
   */
  const connectorsOffer = useControlOffer('chat.connectors')
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
      : connectorsOffer === null
        ? 'Add files, folders, images or connectors to this message'
        : 'Add files, folders or images to this message'

  const close = useCallback(() => {
    setSurface(null)
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
  const shut = useCallback(() => setSurface(null), [])
  useOneMenu(surface !== null, shut)

  // Escape closes from anywhere inside, and a click outside dismisses. Both are
  // registered only while something is open, so the composer costs nothing when
  // the menu is shut.
  useEffect(() => {
    if (surface === null) return
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
  }, [surface, close])

  /**
   * The real open panel, and what happens to the popover while it is up.
   *
   * This menu stays mounted. Closing it first would be tidier to look at and
   * would break the feature: the popover closes on any `mousedown` outside
   * itself, the open panel is a separate native window, and unmounting the
   * component that owns this promise while the user is browsing would drop the
   * result on the floor. So it stays, the picks are added, and *then* it closes
   * — for the reason `pick` gives about a path, applied to a modal: the panel
   * covered the screen, and coming back to a popover still sitting over the chip
   * row would hide the only confirmation there is.
   */
  const browse = useCallback(
    async (surface: PickerMode) => {
      const bridge = resolveOutsideBridge(outsideBridge)
      if (bridge === null) {
        onNotice?.('The file browser is not wired into this build.')
        return
      }
      const outcome = await browseForAttachment(bridge, surface, root)
      if (outcome.kind === 'failed') {
        onNotice?.(outcome.message)
        return
      }
      // Escape in the panel. Nothing to say and nothing to close — the user is
      // back where they were, which is what they asked for.
      if (outcome.kind === 'cancelled') return
      onAdd(outcome.picks, 'anywhere')
      close()
    },
    [outsideBridge, onNotice, root, onAdd, close],
  )

  const pick = useCallback(
    (path: string, isDirectory: boolean) => {
      onAdd([{ path, isDirectory }], 'project')
      // Attaching deliberately stays open: three files should be three clicks,
      // not three trips through the menu. The confirmation is the "added" tag
      // the picker puts on the row — measured: this popover is 340×309 anchored
      // over the composer, so it covers the chip row while it is open, and the
      // chips only become the feedback once it closes.
      //
      // A path is the other case. It goes into the text the user is writing,
      // there is no chip and no tag, and the popover is sitting on top of the
      // very line it just changed — so staying open would look like nothing had
      // happened. Closing *is* the confirmation.
      if (mode === 'path') close()
    },
    [onAdd, mode, close],
  )

  const insert = useCallback(
    (text: string) => {
      onInsert(text)
      close()
    },
    [onInsert, close],
  )

  return (
    <div className="at-host" ref={hostRef}>
      {surface !== null ? (
        <div
          className="at-pop"
          role="dialog"
          aria-label={mode === 'path' ? 'Insert a path into the command line' : 'Attach to this message'}
        >
          {surface === 'menu' ? (
            <ul className="at-menu">
              {items.map((item) => {
                const offer = item.surface === 'mcp' ? connectorsOffer : null
                return (
                  <li key={item.surface}>
                    <button
                      type="button"
                      className="at-item"
                      data-offer={offer !== null || undefined}
                      title={offer?.title}
                      onClick={() => {
                        // Install, then open: the list behind this row is the
                        // confirmation that the install landed, which is a
                        // better "where to find it" than a sentence.
                        offer?.accept()
                        setSurface(item.surface)
                      }}
                    >
                      <span className="at-item-icon">{ICONS[item.surface]}</span>
                      <span className="at-item-text">
                        <span className="at-item-label">{item.label}</span>
                        <span className="at-item-hint">{offer ? offer.title : item.hint}</span>
                      </span>
                    </button>
                  </li>
                )
              })}
            </ul>
          ) : surface === 'mcp' ? (
            <McpServers root={root} onInsert={insert} onBack={() => setSurface('menu')} />
          ) : (
            <AttachPicker
              root={root}
              mode={surface}
              attachments={attachments}
              onPick={pick}
              onBrowse={() => void browse(surface)}
              browseRefusal={browseRefusal}
              onBack={() => setSurface('menu')}
            />
          )}
        </div>
      ) : null}

      {/* Labelled, not a bare plus. It shares `cc-chip` with the controls beside
          it (ChatComposer.css), and the accessible name contains the word on
          screen so saying "Add" — or "Path", on a shell — out loud still hits
          the thing you can see. */}
      <button
        ref={buttonRef}
        type="button"
        className="cc-chip"
        disabled={disabled}
        aria-haspopup="dialog"
        aria-expanded={surface !== null}
        aria-label={label}
        title={label}
        onClick={() => (surface === null ? setSurface('menu') : close())}
      >
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
          <path d="M12 5v14M5 12h14" strokeWidth="2" strokeLinecap="round" />
        </svg>
        {word}
      </button>
    </div>
  )
}

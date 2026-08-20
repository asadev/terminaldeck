import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type KeyboardEvent as ReactKeyboardEvent,
  type MouseEvent as ReactMouseEvent,
} from 'react'
import { createPortal } from 'react-dom'
import { readFailure, withDeadline } from '../../deadline'
import { asFolder, asRefusal, succeeded, type Folder, type ServersBridge } from './types'
import './ServerFolderPicker.css'

/**
 * Where on a server a session should start.
 *
 * Asad, 2026-08-19: *"it should give me a window to choose the path from server
 * to start a session."* Until this existed, a terminal on a server opened
 * wherever SSH happened to drop the account — its login directory — and there
 * was no way to say anything else. A local session has been asking *"choose a
 * project folder to run the session in"* since the day the New session dialog
 * was written; this is the same question asked of the far end.
 *
 * ## Why this is a window and not a panel on a page
 *
 * Because the first version was a panel on a page and he could not find it. It
 * was an inline disclosure behind a button reading *Choose a folder*, shut by
 * default, and the answer that came back was: *"I still cannot find the path, I
 * need to see the folder of this server. Server-side folders should be visible
 * when I click or if I click browse, there should be a window open where we can
 * drive the folders."*
 *
 * The local half of the same dialog has said **Browse…** since it was written,
 * and pressing it opens a window — macOS's own. So the remote half says
 * *Browse…* too, and opens one. Two controls asking one question in one dialog
 * had better look and behave alike, or the remote one reads as something else
 * entirely, which is precisely what happened.
 *
 * What stays on the page is one line: the folder a session will actually start
 * in, and the button that opens the window. That line is the whole state — it
 * is never blank, and it says which of three things it is showing: a folder
 * chosen for this session, this server's remembered default, or nothing at all.
 *
 * ## The default folder
 *
 * *"I can make one of them as default or something so you can always start
 * seamlessly a new session."* One tick inside the window, and this server
 * remembers. It is stored beside the server's name and address in
 * `servers.json` — the store this app already keeps per-server settings in —
 * and it is honoured in the main process, in `servers:shell:open`, so **every**
 * door gets it: this page's *Open a terminal*, the New session dialog, and the
 * plus on a server's group in the rail, which passes no folder at all.
 *
 * Which makes the tick the readable version of what it does: *start here every
 * time*. Untick it and the server goes back to landing wherever the sign-in
 * lands, which is what it did before anybody chose.
 *
 * ## Nothing is asked of the server until the window opens
 *
 * The line on the page reads a stored preference — a local file this process
 * already has — and connects to nothing. The first SFTP round trip happens when
 * somebody presses *Browse…*, which is the same bargain the rest of this area
 * makes: a server nobody is looking at is not dialled.
 *
 * ## Three things the browser deliberately does not do
 *
 * **It does not show files.** The question is which folder, and a server's
 * `node_modules` or `/usr/bin` would bury the six directories somebody is
 * looking for under thousands of names they cannot pick. How many were left out
 * is said under the list, so a folder that looks empty and is not says so.
 *
 * **It does not resolve links.** A link is drawn as a folder you may try to
 * enter, because finding out what each one points at is a round trip per entry
 * — sixty of them on an ordinary `/etc`. If it turns out not to be a folder,
 * the attempt says so in a sentence and the list stays where it was.
 *
 * **It does not build paths.** Every path it holds came back from the server's
 * own `realpath`, which is what makes `..` safe to offer: this side never does
 * string surgery on a path, and string surgery is how a picker ends up one
 * folder above the one it is showing. The one string it does join is a child
 * name onto the folder it is already in, and the answer to that call replaces
 * it with whatever the server says it really is.
 *
 * ## Typing a path is the fallback, never the route
 *
 * *"How can I remember how many path are there, how many folders are there."*
 * Quite. The list is the way through and the box is underneath it, for the
 * people and the servers the list cannot serve: a server with no SFTP
 * subsystem, a build whose preload predates this channel, a home directory this
 * account may not read. A path typed into it is taken as given rather than
 * checked first. It is *also* looked at, so the list moves there when it can; a
 * listing that fails leaves the typed path in hand and prints why underneath.
 */

/**
 * How long a listing may take before the picker stops waiting and says so.
 *
 * Shorter than the 45 seconds a server's page allows for its first look,
 * because this is asked *inside a window somebody is trying to get out of* —
 * and usually on a connection that is already up, where the whole round trip is
 * one packet. A picker that could sit spinning for three quarters of a minute
 * would have the person close the window rather than wait, which loses every
 * other choice they had already made behind it.
 */
export const FOLDER_DEADLINE_MS = 12_000

/**
 * How long the stored default may take to come back.
 *
 * Short, because it is a read of a file the main process already holds and
 * nothing crosses a network for it. A deadline at all, rather than none,
 * because a promise that never settles would leave the line on the page saying
 * nothing about a server that does have a default.
 */
export const DEFAULT_READ_DEADLINE_MS = 4000

/** The sentence for the folder nobody has chosen: wherever the sign-in lands. */
export const DEFAULT_FOLDER = 'Wherever this sign-in lands'

/**
 * What the one line on the page says, given the two facts behind it.
 *
 * Exported and pure because it is the entire state of this control as far as
 * anybody reading the page is concerned, and there are four cases in it — one
 * of which, *chosen for this session while a different default exists*, is the
 * one a person would otherwise have to work out by remembering what they ticked
 * last week.
 */
export function folderLine(
  path: string | null,
  fallback: string | null,
): { shown: string; note: string } {
  if (path === null) {
    return fallback === null
      ? { shown: DEFAULT_FOLDER, note: 'No folder chosen, so it lands wherever the sign-in does.' }
      : { shown: fallback, note: 'Its default folder. Every session on it starts here.' }
  }
  if (path === fallback) {
    return { shown: path, note: 'Its default folder. Every session on it starts here.' }
  }
  return {
    shown: path,
    note:
      fallback === null
        ? 'Chosen for this session.'
        : `Chosen for this session. Its default is ${fallback}.`,
  }
}

/**
 * Name order, with dot-folders last.
 *
 * A home directory is mostly `.cache`, `.config`, `.local`, `.npm` — tooling,
 * not work — and putting them first means the three folders somebody actually
 * came for are below the fold. They are not hidden, because a real project can
 * live in one and a picker that dropped it would be a picker that lies about
 * what is there.
 */
export function inNameOrder(entries: readonly { name: string }[]): { name: string }[] {
  return [...entries].sort((a, b) => {
    const dotted = Number(a.name.startsWith('.')) - Number(b.name.startsWith('.'))
    if (dotted !== 0) return dotted
    return a.name.localeCompare(b.name, undefined, { sensitivity: 'base' })
  })
}

/**
 * One folder joined onto another, the only path this side ever assembles.
 *
 * Exported so it can be pinned: the root is the case that gets written wrong,
 * where `'/' + '/' + 'etc'` produces `//etc`. That path works on Linux and is
 * defined by POSIX to mean something implementation-specific with two leading
 * slashes, which is not a thing to find out about on somebody's production box.
 */
export function childOf(folder: string, name: string): string {
  return folder.endsWith('/') ? `${folder}${name}` : `${folder}/${name}`
}

/** The stored default, narrowed. Anything unreadable is no default at all. */
function asStoredFolder(value: unknown): string | null {
  if (typeof value !== 'object' || value === null) return null
  const path = (value as { path?: unknown }).path
  return typeof path === 'string' && path !== '' ? path : null
}

interface Props {
  serverId: string
  /** Heads the window, so it names the machine whose folders are in it. */
  serverName: string
  bridge: ServersBridge | null
  /** The chosen folder, or null for this server's default. */
  path: string | null
  onChoose(path: string | null): void
}

export function ServerFolderPicker({ serverId, serverName, bridge, path, onChoose }: Props) {
  const [browsing, setBrowsing] = useState(false)

  /*
   * This server's remembered default, as far as this control knows.
   *
   * Held here rather than read inside the window, because the line on the page
   * prints it while the window is shut — which is the point of remembering one
   * at all. Null covers both *no default* and *not read yet*: they draw the same
   * line, and a control that flickered through a third state on the way to a
   * stored preference would be worse than one that settles into it.
   */
  const [fallback, setFallback] = useState<string | null>(null)

  const alive = useRef(true)
  useEffect(() => {
    alive.current = true
    return () => {
      alive.current = false
    }
  }, [])

  useEffect(() => {
    setFallback(null)
    if (!bridge?.serverStartIn) return
    withDeadline(
      bridge.serverStartIn(serverId),
      'reading that server’s default folder',
      DEFAULT_READ_DEADLINE_MS,
    ).then(
      (raw) => {
        if (alive.current) setFallback(asStoredFolder(raw))
      },
      // A default that could not be read is drawn as no default rather than as a
      // problem: the folder browser and the typed box both still work, and there
      // is nothing here for a person to do about it.
      () => undefined,
    )
  }, [bridge, serverId])

  /**
   * Remember a folder for this server, or clear it.
   *
   * Written the moment the tick changes rather than when the window closes,
   * because it is a setting rather than part of the answer — the line on the
   * page has to be able to say *Its default folder* while somebody is still
   * looking at the window that says it. Which also means *Cancel* below is only
   * about where **this** session starts; a default that was ticked stays ticked.
   */
  const remember = useCallback(
    (chosen: string | null) => {
      if (!bridge?.setServerStartIn) return
      setFallback(chosen)
      void bridge.setServerStartIn(serverId, chosen).catch(() => {
        // The store refused, so the line must stop claiming a default this
        // server does not have. Nothing else to say: a preference that did not
        // save is a tick that comes back unticked, which is the report.
        if (alive.current) setFallback(null)
      })
    },
    [bridge, serverId],
  )

  const line = folderLine(path, fallback)
  return (
    <div className="srvpick">
      <div className="srvpick-chosen">
        <span className="srvpick-path" title={line.shown}>
          {line.shown}
        </span>
        {/* The same word the local half of this dialog uses, because it is the
            same question about a different machine. Anything else here — and
            *Choose a folder* was the anything else — reads as a different kind
            of control and gets left alone. */}
        <button type="button" className="srvpick-browse" onClick={() => setBrowsing(true)}>
          Browse…
        </button>
      </div>
      <p className="srvpick-note">{line.note}</p>

      {browsing && (
        <FolderWindow
          serverId={serverId}
          serverName={serverName}
          bridge={bridge}
          /* Where it opens: the folder in hand, then the default, then home.
             Landing somewhere other than where the page says you are would make
             the window's first screen a thing to undo. */
          start={path ?? fallback}
          fallback={fallback}
          onRemember={remember}
          onUse={(chosen) => {
            onChoose(chosen)
            setBrowsing(false)
          }}
          onClose={() => setBrowsing(false)}
        />
      )}
    </div>
  )
}

/* --------------------------------------------------------------- the window -- */

/**
 * The window itself: a scrim, a panel, and the folders on one server.
 *
 * ## Why it is not a `Modal`
 *
 * `Modal` binds Escape to `window`, so a dialog opened from a dialog dismisses
 * both — the Add-account dialog was deleted over exactly that, and
 * `NewSessionDialog.tsx` says so where it explains why its Add-an-agent form
 * replaces the dialog body instead of opening a second one. This one *is*
 * opened from inside that dialog, so it takes Escape in the **capture** phase
 * and stops it dead: the press that closes the folder window must not also
 * close the New session dialog behind it, throwing away the server and the
 * folder somebody had already picked.
 *
 * Everything else `Modal` does that matters here it does too — a portal out of
 * the page's stacking contexts, focus into the panel on open and back to the
 * *Browse…* button on close, Tab kept inside, and a scrim that dismisses on
 * mousedown rather than click so a drag that ends outside is not a dismissal.
 */
function FolderWindow({
  serverId,
  serverName,
  bridge,
  start,
  fallback,
  onRemember,
  onUse,
  onClose,
}: {
  serverId: string
  serverName: string
  bridge: ServersBridge | null
  start: string | null
  fallback: string | null
  onRemember(path: string | null): void
  onUse(path: string | null): void
  onClose(): void
}) {
  const [at, setAt] = useState<Folder | null>(null)
  const [busy, setBusy] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)
  const [typed, setTyped] = useState('')

  /*
   * The path in hand, which is not always a listed folder.
   *
   * It is the folder the list is showing, until somebody types one — and a
   * typed path is taken as given, because somebody who knows their own server
   * must not be blocked by a browser that could not list it. Held apart from
   * `at` for exactly that case: they agree whenever the listing worked, and
   * when it did not, this is the answer and `at` is still the last folder that
   * was really read.
   */
  const [held, setHeld] = useState<string | null>(start)

  const panelRef = useRef<HTMLDivElement>(null)
  const restoreRef = useRef<HTMLElement | null>(null)

  /*
   * Retires answers from a folder nobody is looking at any more.
   *
   * Two presses into a slow server race, and without this the older reply wins
   * whenever it is the slower one — so the list shows a folder the person
   * navigated out of, with the path line above it naming the one they asked
   * for. Counted rather than a boolean, because the cleanup below has to be
   * able to say *which* request it is retiring.
   */
  const ticket = useRef(0)

  const look = useCallback(
    (where: string) => {
      if (!bridge?.listServerFolder) {
        setProblem(
          'This copy of the app cannot list folders on a server. Type the path you want instead.',
        )
        return
      }
      ticket.current += 1
      const mine = ticket.current
      setBusy(true)
      withDeadline(
        bridge.listServerFolder(serverId, where),
        'listing that folder',
        FOLDER_DEADLINE_MS,
      ).then(
        (raw) => {
          if (mine !== ticket.current) return
          setBusy(false)
          if (!succeeded(raw)) {
            // A refusal is an ordinary answer here — half of a Linux root is
            // unreadable by an ordinary account — so the list stays exactly
            // where it was and the sentence goes underneath it. Clearing it
            // would take away the only thing left to press.
            setProblem(asRefusal(raw).sentence)
            return
          }
          const folder = asFolder(raw)
          if (folder === null) {
            setProblem('That server answered with something we could not read.')
            return
          }
          setProblem(null)
          setAt(folder)
          setHeld(folder.path)
        },
        (error: unknown) => {
          if (mine !== ticket.current) return
          setBusy(false)
          setProblem(readFailure(error))
        },
      )
    },
    [bridge, serverId],
  )

  /*
   * The first listing, and the only one nobody pressed for.
   *
   * On mount and on nothing else. `start` is where the window *opens* rather
   * than something it follows, and both it and `look` go through a ref so this
   * effect can honestly declare no dependencies: written the obvious way, with
   * `[look, start]`, a re-run would fire its own cleanup first and retire the
   * listing already in flight — a window that empties itself for no reason
   * anybody could reproduce.
   *
   * An empty string is the account's own login directory, which is where SSH
   * would have put them and never `/`: a stranger started at the root of their
   * own machine is a picker opening on the one folder nobody keeps work in.
   */
  const opening = useRef({ look, start })
  opening.current = { look, start }
  useEffect(() => {
    const { look: first, start: from } = opening.current
    first(from ?? '')
    return () => {
      ticket.current += 1
    }
  }, [])

  // Remember what had focus and hand it back, so closing the window puts the
  // caret on the Browse… button that opened it rather than on <body>.
  useEffect(() => {
    restoreRef.current = document.activeElement instanceof HTMLElement ? document.activeElement : null
    panelRef.current?.focus()
    return () => {
      const previous = restoreRef.current
      restoreRef.current = null
      if (previous?.isConnected) previous.focus()
    }
  }, [])

  /*
   * Escape closes this window and **only** this window.
   *
   * Capture on `window`, and `stopImmediatePropagation`, because `Modal`'s own
   * Escape listener is also on `window`: bubbling would reach it, and
   * `stopPropagation` would not help — listeners on the same node still run.
   * Without this, one press closes the folder window and the New session dialog
   * behind it, taking the server, the folder and everything else with it.
   */
  useEffect(() => {
    const onKey = (event: globalThis.KeyboardEvent) => {
      if (event.key !== 'Escape') return
      event.stopImmediatePropagation()
      event.preventDefault()
      onClose()
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  }, [onClose])

  // Read into locals so the rows below can use them without a cast: `at` is
  // state, and TypeScript cannot carry a narrowing into a click handler.
  const here = at
  const folders = here === null ? [] : here.entries.filter((entry) => entry.kind !== 'file')
  const files = here === null ? 0 : here.entries.length - folders.length
  const shown = inNameOrder(folders)
  const isDefault = held !== null && held === fallback

  const trapTab = (event: ReactKeyboardEvent<HTMLDivElement>): void => {
    if (event.key !== 'Tab') return
    /*
     * Stopped here, and this line is not optional.
     *
     * A portal escapes the *DOM* tree and not React's: a keydown in this window
     * still bubbles to whatever rendered it, which — when this is opened from
     * the New session dialog — is a `Modal` with a focus trap of its own on its
     * overlay. That trap would find `document.activeElement` nowhere in its own
     * panel, conclude focus had escaped, and pull it into the dialog behind
     * this one on every Tab.
     */
    event.stopPropagation()
    const panel = panelRef.current
    if (panel === null) return
    const focusable = Array.from(
      panel.querySelectorAll<HTMLElement>(
        'button:not([disabled]), input:not([disabled]), [tabindex]:not([tabindex="-1"])',
      ),
    )
    if (focusable.length === 0) {
      event.preventDefault()
      return
    }
    const active = document.activeElement as HTMLElement | null
    const index = active === null ? -1 : focusable.indexOf(active)
    const first = focusable[0]
    const last = focusable[focusable.length - 1]
    if (event.shiftKey) {
      // -1 covers focus sitting on the panel itself, where a bare Shift+Tab
      // would otherwise walk straight out of the window.
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

  // mousedown, not click: a drag that starts on a row and ends on the scrim
  // should not be read as dismissing the window.
  const onScrim = (event: ReactMouseEvent<HTMLDivElement>): void => {
    if (event.target === event.currentTarget) onClose()
  }

  return createPortal(
    <div className="srvpick-scrim" onMouseDown={onScrim} onKeyDown={trapTab}>
      <div
        ref={panelRef}
        className="srvpick-window"
        role="dialog"
        aria-modal="true"
        aria-label={`Folders on ${serverName}`}
        tabIndex={-1}
      >
        <header className="srvpick-window-head">
          <h2 className="srvpick-window-title">Folders on {serverName}</h2>
          {/* Home, because he asked for it by name: *"so home folder should be
              there, so I can choose one of them."* An empty path is what the
              server resolves to this account's own login directory, so this is
              one call rather than a path assembled over here. */}
          <button type="button" className="srvpick-up" disabled={busy} onClick={() => look('')}>
            Home
          </button>
          {here !== null && here.path !== '/' && (
            <button
              type="button"
              className="srvpick-up"
              disabled={busy}
              // `..` rather than a truncated string. The server resolves it, so
              // this holds for a symlinked path where cutting at the last slash
              // would land somewhere else entirely.
              onClick={() => look(childOf(here.path, '..'))}
            >
              Up
            </button>
          )}
        </header>

        {/* The folder you are in, above the folders inside it. It is the answer
            *Use this folder* will give, which is why it is printed rather than
            left to be inferred from a highlighted row. */}
        <p className="srvpick-window-path" title={held ?? DEFAULT_FOLDER}>
          {held ?? DEFAULT_FOLDER}
        </p>

        <div className="srvpick-list">
          {/* Said while it is reading, and above the rows rather than instead of
              them: a window that empties itself on every step looks like one
              that lost the listing, and this one keeps the last folder on screen
              until the next one arrives. */}
          {busy && <p className="srvpick-note">Reading {serverName}…</p>}
          {!busy && shown.length === 0 && (
            <p className="srvpick-note">
              {here === null ? 'No folder list. Type the path below.' : 'No folders in here.'}
            </p>
          )}
          {shown.map((entry) => (
            <button
              key={entry.name}
              type="button"
              className="srvpick-row"
              disabled={busy}
              onClick={() => look(childOf(here === null ? '' : here.path, entry.name))}
            >
              {entry.name}
            </button>
          ))}
        </div>

        {/* Said out loud, because a folder holding forty files and no
            subdirectories draws an empty list, and an empty list with nothing
            under it reads as a server that answered nothing. */}
        {files > 0 && (
          <p className="srvpick-note">
            {files === 1 ? '1 file here is not shown' : `${files} files here are not shown`} — a
            session starts in a folder.
          </p>
        )}

        {problem !== null && (
          <p className="srvpick-problem" role="alert">
            {problem}
          </p>
        )}

        <div className="srvpick-typed">
          <input
            type="text"
            className="srvpick-input"
            value={typed}
            placeholder="Or type a path, like /srv/app"
            aria-label="Path on this server"
            spellCheck={false}
            onChange={(event) => setTyped(event.target.value)}
            onKeyDown={(event) => {
              // Enter means Go. It is caught rather than left alone because
              // this window is opened from inside a `<form>` that starts the
              // session — the portal keeps it out of that form in the DOM, but
              // a stray submit is not the sort of thing to leave resting on
              // where a node happens to be mounted.
              if (event.key !== 'Enter') return
              event.preventDefault()
              goTo(typed, setHeld, look)
            }}
          />
          <button
            type="button"
            className="srvpick-go"
            disabled={typed.trim() === ''}
            onClick={() => goTo(typed, setHeld, look)}
          >
            Go
          </button>
        </div>

        <footer className="srvpick-window-foot">
          {/* Named for what it does to somebody's mornings rather than for the
              field it writes. Absent when this build's preload cannot store one,
              because a tick that cannot be remembered is the dead control this
              product is removing everywhere. */}
          {bridge?.setServerStartIn !== undefined && (
            <label className="srvpick-default">
              <input
                type="checkbox"
                checked={isDefault}
                disabled={held === null}
                onChange={(event) => onRemember(event.target.checked ? held : null)}
              />
              Start here every time
            </label>
          )}
          <button type="button" className="srvpick-btn" onClick={onClose}>
            Cancel
          </button>
          <button
            type="button"
            className="srvpick-btn srvpick-btn-primary"
            disabled={held === null}
            onClick={() => onUse(held)}
          >
            Use this folder
          </button>
        </footer>
      </div>
    </div>,
    document.body,
  )
}

/**
 * Take a typed path, and only then try to list it.
 *
 * The order is the point. Somebody who knows their own server is never blocked
 * by a browser that cannot see it: the path is in hand the moment it is
 * entered, and the listing that follows is an attempt to move the list there
 * rather than a check the path has to pass. A listing that fails leaves the
 * typed path in hand — so *Use this folder* still gives it — and prints why
 * underneath.
 */
function goTo(
  typed: string,
  hold: (path: string) => void,
  look: (where: string) => void,
): void {
  const wanted = typed.trim()
  if (wanted === '') return
  hold(wanted)
  look(wanted)
}

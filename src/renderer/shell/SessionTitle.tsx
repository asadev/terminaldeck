import { MAX_TITLE_LENGTH } from '../session-title'
import { useRenameField, useSessionRename, type SessionRename } from '../state/session-rename'
import './SessionTitle.css'

/**
 * The session's name, over its terminal, renameable where it is written.
 *
 * Asad, walking the app: *"And session name also inside the terminal, if we
 * want to change we should be able to change."*
 *
 * It could be changed — from the sidebar, on the row. That is one place, and it
 * is not the place you are looking at while you are working: the rail is often
 * pinned away entirely, and the name over the terminal is the only copy of it
 * on screen. So the heading opens a field too.
 *
 * ## The same gesture, not a second one
 *
 * There is a decision on record about how a session is renamed, from the last
 * walk-through: *"I don't want this edit button here. Just double click should
 * make it editable. That's it. Over the text, when I double click, it should
 * become like editable and I can change the text."* So this is a double-click
 * on the heading, and there is no pencil beside it — a second idiom for one
 * action is worse than either idiom on its own, because then neither is the
 * answer to "how do I rename this".
 *
 * A gesture costs two things a button gives away, and both are paid for here
 * exactly as the rail pays for them. It leaves nothing on screen to say it
 * exists, so the heading carries a tooltip naming both ways in. And it cannot
 * be performed from a keyboard, so F2 does it — F2 rather than Return, which on
 * a focused element means "press it", and `aria-keyshortcuts` so the shortcut is
 * discoverable rather than folklore.
 *
 * ## And the same rename underneath
 *
 * `useSessionRename` is the single write path: it owns the cleaning, the
 * `MAX_TITLE_LENGTH` budget, the "a blank field is a cancel" rule, and the
 * `fromUser` flag that stops the auto-titler taking the name away again at the
 * session's next pause in output. `useRenameField` owns the mechanics that are
 * easy to get subtly different between two copies — chiefly the focus steal
 * documented there, which the terminal underneath this heading is the very
 * thing that causes.
 *
 * ## What happens when there is nowhere to write
 *
 * The heading renders as a plain heading. Outside a store — the static-render
 * tests here, and `.harness/` — there is no session list to write a name into,
 * and a gesture that opens a field whose value goes nowhere is the same fault
 * as a button that highlights and does nothing. Absent beats inert.
 */
interface Props {
  /** What the heading says. A name, a derived title, or a view's label. */
  title: string
  /**
   * The session this is the name of, or null when the heading is not a
   * session's — a sidebar view, or the launch screen with nothing open. Null
   * renders a plain heading, because there is nothing to rename.
   */
  sessionId?: string | null
  /**
   * How large the heading is set, which is a question about what it is the
   * heading *of*.
   *
   * `window` is the window's own title, at the toolbar's title scale. `pane` is
   * the same heading inside one pane of a split, where the window is showing
   * two of them and a pair of title-scale headings side by side would be two
   * windows' worth of chrome in one window — see `PaneBar`.
   *
   * It is one control at two sizes rather than two controls, because the rename
   * is the expensive half: the gesture, the F2 fallback, the blur rule and the
   * single write path through `useSessionRename` are all things that go subtly
   * wrong when they are written twice. The attribute is emitted only for the
   * pane, so the window's markup is byte-for-byte what it was.
   */
  scale?: 'window' | 'pane'
  /**
   * Where the typed name goes, when it does not go into this app's own session
   * store.
   *
   * Absent for every session running on this computer, and absent is the
   * ordinary case: the name is one field of one record `useSessionRename`
   * already owns, and a callback threaded in for those would be a second answer
   * to a question the store has already answered.
   *
   * Present for a session on a **paired machine**, where the name belongs to a
   * different computer and has to leave here as a frame. That was impossible
   * until tonight and the heading said so by staying a plain `<h1>`; the wire
   * has a `rename` verb now, and *"the things that are aligned they can work
   * seamlessly together when they are connected with remote also."*
   *
   * The text arrives exactly as it was typed. `userSessionTitle`'s cleaning and
   * its "a blank field is a cancel" rule belong to the store's path and are
   * deliberately not applied here: the machine that stores the name is what
   * bounds and strips it, and over there a blank name is not a cancel but *use
   * the folder's name again* — the only way back from a rename, which this would
   * swallow.
   */
  onRename?: (name: string) => void
}

export function SessionTitle({ title, sessionId = null, scale = 'window', onRename }: Props) {
  const paneScale = scale === 'pane' ? 'pane' : undefined
  const store = useSessionRename()
  /*
   * One rename, two places it can land.
   *
   * `useRenameField` owns the mechanics that must not be written twice — the
   * focus steal, the double-`end` guard, Escape versus blur — so the remote path
   * is expressed as a different *destination* handed to the same field rather
   * than as a second field beside it. `available: true` because the caller only
   * passes this when the far machine has said it will take a name; the question
   * is asked once, up where the link's capabilities are read, and not again
   * here.
   */
  const rename: SessionRename = onRename
    ? {
        available: true,
        rename: (_sessionId, typed) => {
          onRename(typed)
          return true
        },
      }
    : store
  const field = useRenameField(rename)
  const renameable = sessionId !== null && rename.available

  if (field.editing !== null && field.editing.id === sessionId) {
    return (
      <form
        className="toolbar-title-form"
        onSubmit={(event) => {
          event.preventDefault()
          field.end(true)
        }}
      >
        <input
          className="toolbar-title-input"
          data-scale={paneScale}
          value={field.editing.draft}
          // The same budget every other title in this app is cut to. Held at
          // the field as well as in `userSessionTitle`, so the limit is visible
          // while typing rather than applied silently on save.
          maxLength={MAX_TITLE_LENGTH}
          autoFocus
          aria-label={`New name for ${title}`}
          onChange={(event) => field.type(event.target.value)}
          onKeyDown={(event) => {
            if (event.key !== 'Escape') return
            event.preventDefault()
            // Stopped so Escape does not travel on to anything else in the
            // window that treats it as "close" — the field is the innermost
            // thing open. The same rule `useChipMenu` follows.
            event.stopPropagation()
            field.end(false)
          }}
          // Clicking away keeps the name, the way Finder and every editor
          // sidebar do — unless nothing the user did caused the blur, which
          // over a terminal is the common case rather than the corner one. See
          // `useRenameField`.
          onBlur={(event) => {
            if (field.blurred()) return
            const input = event.currentTarget
            requestAnimationFrame(() => input.focus())
          }}
        />
      </form>
    )
  }

  if (!renameable) {
    return (
      <h1 className="toolbar-title" data-scale={paneScale}>
        {title}
      </h1>
    )
  }

  return (
    <h1
      className="toolbar-title"
      data-scale={paneScale}
      data-renameable="true"
      // The only advertisement a hidden gesture gets, and it names both ways in
      // — the same sentence the rail's rows carry, because it is the same
      // gesture and a second wording would read as a second feature.
      title={`${title} — double-click or F2 to rename`}
      // Focusable so the keyboard can reach the gesture at all. Not given a
      // button's role: it is a heading, it does nothing on a single click, and
      // claiming otherwise would be the dead control the brief forbids.
      tabIndex={0}
      aria-keyshortcuts="F2"
      onDoubleClick={() => field.begin(sessionId, title)}
      onKeyDown={(event) => {
        // F2 rather than Return, because Return on a focused element means
        // "activate it" everywhere else in this window.
        if (event.key !== 'F2') return
        event.preventDefault()
        field.begin(sessionId, title)
      }}
    >
      {title}
    </h1>
  )
}

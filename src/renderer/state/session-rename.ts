import { useCallback, useEffect, useRef, useState } from 'react'
import { userSessionTitle } from '../session-title'
import { useOptionalStore } from './store'

/**
 * Renaming a session, from wherever its name is on screen.
 *
 * Reported while walking the app: **"a session's name cannot be edited."** It
 * could not: the label came from the folder, or from `session-title.ts` reading
 * the agent's own output, and there was no field anywhere in the window that
 * wrote to it.
 *
 * ## Why the sidebar reaches the store instead of taking a prop
 *
 * Every other thing the sidebar can do arrives as a callback from `App.tsx`,
 * and that is right for them: what views exist, what is open, what a click on a
 * row means are all decisions made above the rail. A session's *name* is not
 * one of those. It is a single field of one record in this store, three
 * surfaces read it from here already (the rail, the toolbar heading and the
 * close confirmation), and a callback threaded down would only add a place for
 * `App.tsx` to hand back a different answer than the one the store holds.
 *
 * `dashboard/useBoard.ts` reaches the store the same way and for the same
 * reason. Both use {@link useOptionalStore} rather than `useStore` because
 * these components are also rendered on their own — in `renderToStaticMarkup`
 * tests and in `.harness/` — where a throwing hook is a page that will not
 * render at all rather than a page with one control fewer.
 *
 * ## What "available" is for
 *
 * A rename with nowhere to write is a control that highlights on hover and does
 * nothing, which is the one thing this window is not allowed to have. Outside a
 * provider there is no session list, so the affordance is not drawn — rather
 * than drawn and inert.
 */
export interface SessionRename {
  /** Whether there is a session list to write a name into. */
  available: boolean
  /**
   * Give this session the name somebody typed.
   *
   * Returns whether the name was taken. `false` is a blank field, which is a
   * cancel and not a request to be called nothing — see `userSessionTitle`, and
   * callers should close the field rather than report a failure.
   */
  rename(sessionId: string, typed: string): boolean
}

export function useSessionRename(): SessionRename {
  const store = useOptionalStore()
  const setSessionTitle = store?.setSessionTitle

  const rename = useCallback(
    (sessionId: string, typed: string): boolean => {
      if (!setSessionTitle) return false
      const name = userSessionTitle(typed)
      if (name === null) return false
      // `fromUser` is what stops the auto-titler taking it away again on the
      // session's next pause in output — see `withSessionTitle`.
      setSessionTitle(sessionId, name, { fromUser: true })
      return true
    },
    [setSessionTitle],
  )

  return { available: setSessionTitle !== undefined, rename }
}

/**
 * The field itself: opening it, keeping it open, and closing it.
 *
 * ## Why this is a hook and not a copy
 *
 *   > "And session name also inside the terminal, if we want to change we
 *   > should be able to change."
 *
 * A session's name is now editable from two places — the rail's row and the
 * heading over the terminal — and there is a decision on record about how:
 * *"I don't want this edit button here. Just double click should make it
 * editable."* So both are the same gesture on the same name, and the parts that
 * are easy to get subtly different between two hand-written copies live here.
 *
 * The one that matters is `userActed`. Timed in the running app: the field
 * appears at t+73ms, `xterm-helper-textarea` takes focus at t+75ms, and a blur
 * handler that treats every blur as "clicked away" closes the field at t+76ms —
 * before a single key can be typed. `relatedTarget` cannot separate the two
 * cases, because a real click into the terminal names the same element. What
 * can is that a click or a keypress is something the *user* did and arrives
 * before the focus moves; a blur with no user action behind it is a steal, and
 * the field takes its focus back instead of closing.
 *
 * The listeners are on the document and in the capture phase, because the
 * dismissing click by definition happens somewhere other than the field.
 */
export interface RenameField {
  /** The id being renamed and the draft so far, or null when no field is open. */
  editing: { id: string; draft: string } | null
  begin(id: string, name: string): void
  type(draft: string): void
  /** Close, keeping what was typed or throwing it away. */
  end(save: boolean): void
  /**
   * What a field's `onBlur` should do.
   *
   * Returns true when the blur was the user leaving — the caller has nothing
   * more to do, the name is saved. Returns false when the focus was stolen, and
   * the caller must put it back; on the *next frame* rather than inside the
   * handler, because a `focus()` in the middle of a `blur` is a fight the
   * browser arbitrates and Chromium does not always give to the caller.
   */
  blurred(): boolean
}

export function useRenameField(rename: SessionRename): RenameField {
  const [editing, setEditing] = useState<{ id: string; draft: string } | null>(null)
  /** Guards against a second `end` — a submit followed by the resulting blur. */
  const open = useRef(false)
  const userActed = useRef(false)

  const begin = useCallback((id: string, name: string) => {
    open.current = true
    // Reset here, so the double-click that *opened* the field does not itself
    // count as an action taken since it opened.
    userActed.current = false
    setEditing({ id, draft: name })
  }, [])

  const type = useCallback((draft: string) => {
    setEditing((current) => (current === null ? null : { ...current, draft }))
  }, [])

  const end = useCallback(
    (save: boolean) => {
      if (!open.current) return
      open.current = false
      setEditing((current) => {
        // A blank field is a cancel — `userSessionTitle` refuses it, and a
        // session called nothing is a row with nothing written on it.
        if (save && current) rename.rename(current.id, current.draft)
        return null
      })
    },
    [rename],
  )

  const blurred = useCallback((): boolean => {
    if (!userActed.current) return false
    end(true)
    return true
  }, [end])

  useEffect(() => {
    if (!editing) return
    const mark = (): void => {
      userActed.current = true
    }
    document.addEventListener('pointerdown', mark, true)
    document.addEventListener('keydown', mark, true)
    return () => {
      document.removeEventListener('pointerdown', mark, true)
      document.removeEventListener('keydown', mark, true)
    }
  }, [editing])

  return { editing, begin, type, end, blurred }
}

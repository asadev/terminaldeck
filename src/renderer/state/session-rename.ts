import { useCallback } from 'react'
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

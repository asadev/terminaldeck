/**
 * "A dialog is open in the page", for the native macOS window.
 *
 * The native window can draw a screen of its own over the page (Artifacts, a
 * terminal, the browser — `native-screens.ts`). A dialog the page opens — New
 * session, a confirmation, adding an agent — is drawn *in* the page, so while a
 * native screen covers it the dialog is there and nobody can see it. So the
 * page says when its first dialog opens and its last one closes, and the native
 * window shows the page for as long as one is up:
 *
 *     post { type: 'page-modal', open: true | false }
 *
 * Counted here, once, and held by the app's dialog primitives rather than by
 * each dialog: `Modal` (every sheet in the app), `CommandPalette`, the task
 * pages' overlays through their one scroll lock (`crm-task/lib/use-scroll-lock.ts`),
 * and Accounts' add-account popup. Inside Electron nothing is posted.
 */

import { useEffect } from 'react'
import { isNativeShell, postToNative } from '../../shared/native-shell'

export interface PageModal {
  /** One dialog is open; call what this returns when it closes. Safe to call twice. */
  hold(): () => void
  held(): number
}

export function createPageModal(tell: (open: boolean) => void): PageModal {
  let count = 0
  return {
    hold() {
      let holding = true
      count += 1
      if (count === 1) tell(true)
      return () => {
        if (!holding) return
        holding = false
        count -= 1
        if (count === 0) tell(false)
      }
    },
    held: () => count,
  }
}

export const pageModal: PageModal = createPageModal((open) => {
  if (isNativeShell()) postToNative({ type: 'page-modal', open })
})

/** Hold the page's "a dialog is open" for as long as `open` is true. */
export function usePageModal(open: boolean): void {
  useEffect(() => (open ? pageModal.hold() : undefined), [open])
}

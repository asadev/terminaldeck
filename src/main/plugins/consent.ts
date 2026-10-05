/**
 * The question that allows a plugin, put the way `deck-control/consent.ts`
 * puts every question: to a real person, defaulting to no.
 *
 * ## Why a native dialog and not the in-window one
 *
 * The window's confirmation sheet is the assistant's: its headline is "Hoot is
 * asking to do this", or an AI app's name, and an answer there can also come
 * from one of the owner's phones. Neither is true of this question. The person
 * pressed Allow on a plugin themselves, at this keyboard, and the thing being
 * decided is whether a stranger's program may run here at all — which no phone,
 * no access key and no tool should be able to answer. A dialog drawn by the
 * operating system over the app's own window is the one surface none of those
 * can reach: the assistant's screen-driving tools work inside the page, and
 * this is not in the page.
 *
 * ## The four ways it says no
 *
 * The dialog's default button and its Escape key are both "Don't allow". It
 * closes itself after {@link PLUGIN_CONSENT_TIMEOUT_MS} — the same two minutes
 * the broker gives — and that is `timeout`. With no window there is nobody to
 * ask: `no-approver`. And if anything throws on the way, the host treats it the
 * same as no window. There is no "allow always", because the grant it creates
 * already is one, keyed to these exact files.
 */

import { DEFAULT_CONSENT_TIMEOUT_MS } from '../deck-control/consent'
import type { PluginConsent, PluginConsentOutcome } from './host'

export const PLUGIN_CONSENT_TIMEOUT_MS = DEFAULT_CONSENT_TIMEOUT_MS

/** `approver` is the app's own window's contents — the one `isApprover` names — or null. */
export function nativePluginConsent(approver: () => Electron.WebContents | null): PluginConsent {
  return async (request) => {
    const at = (): number => Date.now()
    const contents = approver()
    if (contents === null || contents.isDestroyed()) return { granted: false, reason: 'no-approver', at: at() }
    // Loaded on first use, so nothing that imports this module loads Electron.
    const { BrowserWindow, dialog } = await import('electron')
    const parent = BrowserWindow.fromWebContents(contents)
    if (parent === null || parent.isDestroyed()) return { granted: false, reason: 'no-approver', at: at() }
    const abort = new AbortController()
    let timedOut = false
    const timer = setTimeout(() => {
      timedOut = true
      abort.abort()
    }, PLUGIN_CONSENT_TIMEOUT_MS)
    try {
      const answer = await dialog.showMessageBox(parent, {
        type: 'warning',
        buttons: ['Don’t allow', 'Allow'],
        defaultId: 0,
        cancelId: 0,
        noLink: true,
        message: request.message,
        detail: request.detail,
        signal: abort.signal,
      })
      const outcome: PluginConsentOutcome =
        answer.response === 1 && !timedOut
          ? { granted: true, at: at() }
          : { granted: false, reason: timedOut ? 'timeout' : 'declined', at: at() }
      return outcome
    } finally {
      clearTimeout(timer)
    }
  }
}

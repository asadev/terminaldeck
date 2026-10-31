/**
 * The page's dialogs, drawn by the native macOS window (lane S).
 *
 * Same shape as `native-new-session.ts`: when the native window says it draws a
 * dialog (its name is in the `native-screens` list), the page stops mounting
 * that dialog and hands the native window the question instead; the answer comes
 * back here and runs the *same* code the page dialog's buttons run. One act, one
 * implementation, whichever window drew the question.
 *
 *     page → native   { type: 'dialog', name, open, seq, data }
 *     native → page   window.tdDialog.run(name, action, arg)
 *
 * Inside Electron nothing lists the dialogs and nothing installs `tdDialog`, so
 * nothing changes there.
 */

import { isNativeShell, postToNative, type NativeHost } from '../shared/native-shell'

/** The dialogs the native window can draw, by the name both sides use. */
export const NATIVE_DIALOGS = {
  closeConfirm: 'close-confirm',
  switchAccount: 'switch-account',
  alerts: 'alerts-sheet',
  palette: 'palette',
  shortcuts: 'shortcuts',
  help: 'help',
  onboarding: 'onboarding',
  sessionInspector: 'session-inspector',
  featureOffer: 'feature-offer',
  joinRemote: 'join-remote',
  copilotSetup: 'copilot-setup', // lane B
  copilotConsent: 'copilot-consent', // lane B
} as const

export type NativeDialogName = (typeof NATIVE_DIALOGS)[keyof typeof NATIVE_DIALOGS]

export interface NativeDialogMessage {
  type: 'dialog'
  name: string
  open: boolean
  /** Every message's own number: the native side drops anything older. */
  seq: number
  /** Which opening of this dialog: the same while it is up and only updated (busy, a
   *  problem), new when it opens again — so the native sheet is not shown twice. */
  opening: number
  data?: Record<string, unknown>
}

let seq = 0
let openings = 0
const showing = new Map<string, number>()

/** Show `name`, or update it if it is already up. */
export function showNativeDialog(name: string, data: Record<string, unknown>, host: NativeHost = globalThis as NativeHost): void {
  if (!isNativeShell(host)) return
  seq += 1
  let opening = showing.get(name)
  if (opening === undefined) {
    openings += 1
    opening = openings
    showing.set(name, opening)
  }
  const message: NativeDialogMessage = { type: 'dialog', name, open: true, seq, opening, data }
  postToNative(message, host)
}

/** The dialog is answered or no longer wanted: close the native one. */
export function hideNativeDialog(name: string, host: NativeHost = globalThis as NativeHost): void {
  if (!isNativeShell(host)) return
  const opening = showing.get(name)
  if (opening === undefined) return // nothing up: nothing to close
  showing.delete(name)
  seq += 1
  const message: NativeDialogMessage = { type: 'dialog', name, open: false, seq, opening }
  postToNative(message, host)
}

/** One dialog's answers: `confirm`, `cancel`, … with the native side's argument. */
export type DialogHandler = (action: string, arg: unknown) => boolean | void

interface TdDialogHost extends NativeHost {
  tdDialog?: unknown
}

/**
 * Leave `window.tdDialog` on the page for the native window's answers. Returns the
 * cleanup, so `useEffect(() => publishDialogCommands(get), [])` is the whole wiring.
 */
export function publishDialogCommands(
  current: () => Partial<Record<string, DialogHandler>> | null,
  host: TdDialogHost = globalThis as TdDialogHost,
): () => void {
  if (!isNativeShell(host)) return () => {}
  const previous = host.tdDialog
  const commands = {
    run(name: unknown, action: unknown, arg?: unknown): boolean {
      if (typeof name !== 'string' || typeof action !== 'string') return false
      const handler = current()?.[name]
      if (!handler) return false
      return handler(action, arg) !== false
    },
  }
  host.tdDialog = commands
  return () => {
    if (host.tdDialog === commands) host.tdDialog = previous
  }
}

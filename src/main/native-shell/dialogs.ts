/**
 * Electron's dialogs, made usable from a process with no window of its own.
 *
 * In the native shell every dialog is free-standing — there is no Electron
 * window to hang a sheet from — and the engine is not the app in front: the
 * native window belongs to another process. A free-standing panel opened by a
 * background app lands *behind* the window the person is looking at, which
 * reads as a button that did nothing. So each dialog brings this process
 * forward first. Every one of them is opened by somebody pressing something
 * (a picker, a consent question), so coming forward is what they asked for.
 *
 * A caller that passes `null` for the window — the native window's stand-in has
 * no `BrowserWindow` — is handed to Electron as the window-less form.
 */

type DialogMethod = (...args: unknown[]) => unknown

export const FRONTED_DIALOGS = ['showOpenDialog', 'showSaveDialog', 'showMessageBox', 'showCertificateTrustDialog'] as const

export function frontDialogs(dialog: object, front: () => void): string[] {
  const target = dialog as Record<string, unknown>
  const wrapped: string[] = []
  for (const name of FRONTED_DIALOGS) {
    const original = target[name]
    if (typeof original !== 'function') continue
    const call = (original as DialogMethod).bind(dialog)
    try {
      target[name] = (...args: unknown[]): unknown => {
        try {
          front()
        } catch {
          /* coming forward is a courtesy; the dialog still opens */
        }
        const rest = args.length >= 2 && (args[0] === null || args[0] === undefined) ? args.slice(1) : args
        return call(...rest)
      }
      wrapped.push(name)
    } catch {
      /* a frozen module: the dialogs still work, they just open behind */
    }
  }
  return wrapped
}

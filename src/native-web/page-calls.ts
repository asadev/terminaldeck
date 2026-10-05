/**
 * Hoot's window readers, answered by the page.
 *
 * In the Electron window the main process runs three known script strings in
 * the page — `ui.do`, `ui.list`, `where` — to read and drive what is on screen.
 * The native page is not a window it can run script in, so the engine sends
 * each as a named call instead (`main/native-shell/page-call.ts`):
 *
 *     push  native-shell:page-call   { id, fn: 'ui.do' | 'ui.list' | 'where', arg? }
 *     send  native-shell:page-result  id, value
 *
 * and this answers it from the same two globals those script strings read —
 * `__terminaldeckUi` (`driving/ui-bridge.ts`) and `__terminaldeckWhere`
 * (`driving/where.ts`). Every page hears every push, so only a page that has
 * those globals answers: the main window. Settings, the island and a screen in
 * a window of its own stay quiet, rather than answering first with nothing.
 */

export const PAGE_CALL_CHANNEL = 'native-shell:page-call'
export const PAGE_RESULT_CHANNEL = 'native-shell:page-result'

/** The globals the page publishes — `UI_GLOBAL` and `WHERE_GLOBAL` in the renderer. */
export const UI_GLOBAL = '__terminaldeckUi'
export const WHERE_GLOBAL = '__terminaldeckWhere'

interface UiGlobal {
  do?(request: unknown): unknown
  list?(): unknown
}

/** The answer to one call, or null when this page is not the one to give it. */
export function answerPageCall(call: unknown, host: Record<string, unknown>): { id: string; value: unknown } | null {
  if (typeof call !== 'object' || call === null) return null
  const { id, fn, arg } = call as { id?: unknown; fn?: unknown; arg?: unknown }
  if (typeof id !== 'string' || id === '') return null
  const ui = host[UI_GLOBAL] as UiGlobal | undefined
  if (fn === 'ui.do') return typeof ui?.do === 'function' ? { id, value: ui.do(arg) ?? null } : null
  if (fn === 'ui.list') return typeof ui?.list === 'function' ? { id, value: ui.list() ?? null } : null
  if (fn === 'where') {
    const where = host[WHERE_GLOBAL]
    return typeof where === 'function' ? { id, value: (where as () => unknown)() ?? null } : null
  }
  return null
}

export function installPageCalls(
  ipc: {
    on(channel: string, listener: (event: unknown, ...args: unknown[]) => void): unknown
    send(channel: string, ...args: unknown[]): void
  },
  host: Record<string, unknown>,
): void {
  ipc.on(PAGE_CALL_CHANNEL, (_event, call) => {
    let answer: { id: string; value: unknown } | null
    try {
      answer = answerPageCall(call, host)
    } catch (error) {
      // A reader that throws is answered with nothing rather than left to time out.
      const id = (call as { id?: unknown } | null)?.id
      answer = typeof id === 'string' ? { id, value: null } : null
      console.error('[native-web] a page call failed:', error)
    }
    if (answer !== null) ipc.send(PAGE_RESULT_CHANNEL, answer.id, answer.value)
  })
}

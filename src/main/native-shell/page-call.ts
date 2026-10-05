import { randomUUID } from 'node:crypto'
import { UI_GLOBAL, UI_LIST_CALL } from '../deck-control/ui-tools'
import { WHERE_CALL } from '../deck-control/where-tool'

/**
 * The page's three readers, reached without running script in it.
 *
 * Hoot's tools read and drive the window through three calls into the page:
 * `ui.do` (open a panel, focus a session), `ui.list` (what can be opened) and
 * `where` (what is on screen). In a window they are `executeJavaScript` strings.
 * The native page is not a Chromium window, and running arbitrary script in it
 * from here is exactly the power the bridge does not hand out — so the three
 * known strings are recognised and sent as a *named* call over the event stream,
 * and the page answers on a channel of its own. Anything else is refused.
 *
 * The page side (the shim) does, for `native-shell:page-call {id, fn, arg}`:
 *
 *     fn 'ui.do'   → globalThis.__terminaldeckUi?.do(arg) ?? null
 *     fn 'ui.list' → globalThis.__terminaldeckUi?.list() ?? null
 *     fn 'where'   → globalThis.__terminaldeckWhere?.() ?? null
 *
 * and answers with `send('native-shell:page-result', id, value)`.
 */

export const PAGE_CALL_CHANNEL = 'native-shell:page-call'
export const PAGE_RESULT_CHANNEL = 'native-shell:page-result'

export type PageCall = { fn: 'ui.do'; arg: unknown } | { fn: 'ui.list' } | { fn: 'where' }

const DO_PREFIX = `globalThis.${UI_GLOBAL}?.do(`
const DO_SUFFIX = ') ?? null'

/** The call a known script string stands for, or null for any other script. */
export function pageCallFor(code: string): PageCall | null {
  if (code === WHERE_CALL) return { fn: 'where' }
  if (code === UI_LIST_CALL) return { fn: 'ui.list' }
  if (code.startsWith(DO_PREFIX) && code.endsWith(DO_SUFFIX)) {
    try {
      return { fn: 'ui.do', arg: JSON.parse(code.slice(DO_PREFIX.length, code.length - DO_SUFFIX.length)) as unknown }
    } catch {
      return null
    }
  }
  return null
}

export interface PageCalls {
  /** What `executeJavaScript(code)` answers in the native page. Null when no page is there to ask. */
  evaluate(code: string): Promise<unknown>
  /** The page's answer to one call. */
  settle(id: unknown, value: unknown): void
}

export function createPageCalls(deps: {
  /** Push to the page. False when no page is listening. */
  push(channel: string, args: readonly unknown[]): boolean
  timeoutMs?: number
}): PageCalls {
  const waiting = new Map<string, (value: unknown) => void>()
  const timeoutMs = deps.timeoutMs ?? 5_000
  return {
    evaluate(code) {
      const call = pageCallFor(code)
      if (call === null) {
        return Promise.reject(new Error('The native shell runs only its own named page calls, not arbitrary script.'))
      }
      const id = randomUUID()
      return new Promise((resolve) => {
        const timer = setTimeout(() => {
          waiting.delete(id)
          // The answer a window that has not booted gives: nothing to look at yet.
          resolve(null)
        }, timeoutMs)
        timer.unref?.()
        waiting.set(id, (value) => {
          clearTimeout(timer)
          waiting.delete(id)
          resolve(value)
        })
        if (!deps.push(PAGE_CALL_CHANNEL, [{ id, ...call }])) {
          clearTimeout(timer)
          waiting.delete(id)
          resolve(null)
        }
      })
    },
    settle(id, value) {
      if (typeof id !== 'string') return
      waiting.get(id)?.(value)
    },
  }
}

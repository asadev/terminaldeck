import { randomUUID } from 'node:crypto'
import { isPrivateOrigin, mayDrive, refuseAPathOnTheWrongComputer } from '../deck-control/browser-tools'
import type { ToolContext, ToolOutput, ToolSpec } from '../deck-control/catalogue'
import { Refused, type Tier } from '../deck-control/surface'

/**
 * The agents' six browser tools, in the native shell, driving the native
 * window's own browser.
 *
 * In the Electron app those tools drive a Chromium page this process owns. The
 * native shell's browser is the native window's (Safari's engine), in another
 * process, so each call becomes a command pushed to it and an answer awaited:
 *
 *     push   native-browser:command  { id, verb, args, session }
 *     invoke native-browser:result   [id, result]
 *
 * `verb` is the tool's wire name — `browser_open`, `browser_read`,
 * `browser_step`, `browser_screenshot`, `browser_handover`, `browser_close` —
 * and `args` is exactly what the agent passed. `session` is who is calling:
 * `{ sessionId, machineId }` for a session (which may only drive its own
 * windows), null for Hoot or an AI app acting as the owner. `result` is
 * `{ value, summary? }`, or `{ error }` for a refusal said in plain words; a
 * `value.url` is remembered for the public-website rule below.
 *
 * What does not change is everything in front of the call: the same schemas,
 * descriptions and tiers, the same `mayDrive` (no paired device drives, no
 * unattended run drives), and the same rule that the first change on a public
 * website is put to the person — tracked here from the addresses the native
 * browser reports, because the page is not in this process to ask.
 *
 * With no native window connected, or no answer in time, the call is refused
 * in one sentence rather than hanging the agent.
 */

export const NATIVE_BROWSER_COMMAND = 'native-browser:command'
export const NATIVE_BROWSER_RESULT = 'native-browser:result'

export const NATIVE_BROWSER_VERBS = [
  'browser_open',
  'browser_read',
  'browser_step',
  'browser_screenshot',
  'browser_handover',
  'browser_close',
] as const

/** The handover returns after about 45 seconds by design; everything else is quicker. */
const DEFAULT_TIMEOUTS: Readonly<Record<string, number>> = { browser_handover: 75_000 }
const DEFAULT_TIMEOUT_MS = 40_000

export const NO_NATIVE_BROWSER =
  'The native window’s browser is not open, so there is no page to drive. Ask the person to open the app’s window, then try again.'

export interface NativeBrowserDriver {
  /** Push one command and wait for its answer. */
  send(verb: string, args: Record<string, unknown>, session: { sessionId: string; machineId: string } | null): Promise<ToolOutput>
  /** The native browser's answer. False when nothing was waiting for that id. */
  settle(id: unknown, result: unknown): boolean
  /** Calls still waiting, for a test or a status line. */
  waiting(): number
}

export function createNativeBrowserDriver(deps: {
  /** Push to the native window. False when nothing is listening. */
  push(channel: string, args: unknown[]): boolean
  timeoutMs?(verb: string): number
}): NativeBrowserDriver {
  const pending = new Map<string, (result: unknown) => void>()
  const timeoutFor = deps.timeoutMs ?? ((verb: string) => DEFAULT_TIMEOUTS[verb] ?? DEFAULT_TIMEOUT_MS)

  return {
    send(verb, args, session) {
      const id = randomUUID()
      return new Promise<ToolOutput>((resolve, reject) => {
        const ms = timeoutFor(verb)
        const timer = setTimeout(() => {
          pending.delete(id)
          reject(
            new Refused(
              'not-permitted',
              `The native window’s browser did not answer ${verb} within ${Math.round(ms / 1000)} seconds. ` +
                'It may be busy loading; try once more, or ask the person to look at the browser.',
            ),
          )
        }, ms)
        timer.unref?.()
        pending.set(id, (raw) => {
          clearTimeout(timer)
          pending.delete(id)
          const result = typeof raw === 'object' && raw !== null ? (raw as Record<string, unknown>) : { value: raw }
          if (typeof result.error === 'string' && result.error !== '') {
            reject(new Refused('not-permitted', result.error))
            return
          }
          const summary =
            typeof result.summary === 'object' && result.summary !== null ? (result.summary as Record<string, unknown>) : {}
          resolve({ value: 'value' in result ? result.value : null, summary })
        })
        if (!deps.push(NATIVE_BROWSER_COMMAND, [{ id, verb, args, session }])) {
          clearTimeout(timer)
          pending.delete(id)
          reject(new Refused('not-permitted', NO_NATIVE_BROWSER))
        }
      })
    },
    settle(id, result) {
      if (typeof id !== 'string') return false
      const waiter = pending.get(id)
      if (waiter === undefined) return false
      waiter(result)
      return true
    },
    waiting: () => pending.size,
  }
}

function callingSession(context: ToolContext): { sessionId: string; machineId: string } | null {
  const caller = context.caller
  if (caller.kind !== 'session' || caller.sessionId === undefined) return null
  return { sessionId: caller.sessionId, machineId: caller.machineId ?? '' }
}

function originOf(url: unknown): string | null {
  if (typeof url !== 'string' || url === '') return null
  try {
    const parsed = new URL(url)
    return parsed.protocol === 'http:' || parsed.protocol === 'https:' ? parsed.origin : null
  } catch {
    return null
  }
}

/**
 * The six tools, re-pointed at the native browser.
 *
 * Built from the Electron app's own specs so the catalogue an agent reads —
 * names, schemas, descriptions, tiers — is the same one. Only `precheck`,
 * `escalate` and `run` change: the window-name checks in the original precheck
 * read this process's binding map, which does not hold the native browser's
 * windows, so the native side resolves names and refuses in its own words.
 */
export function nativeBrowserTools(specs: readonly ToolSpec[], driver: NativeBrowserDriver): ToolSpec[] {
  /** The page each caller last saw, per window it named — for the public-website rule. */
  const lastUrl = new Map<string, string>()
  /** Origins the person has already let a caller change, per window. */
  const granted = new Set<string>()
  const keyOf = (args: Record<string, unknown>, context: ToolContext): string => {
    const session = callingSession(context)
    const window = typeof args.window === 'string' ? args.window : ''
    return `${session?.sessionId ?? ''}\u0000${session?.machineId ?? ''}\u0000${window}`
  }
  const known = new Set<string>(NATIVE_BROWSER_VERBS)

  return specs
    .filter((spec) => known.has(spec.wire))
    .map((spec): ToolSpec => {
      const step = spec.wire === 'browser_step'
      const shot = spec.wire === 'browser_screenshot'
      return {
        ...spec,
        precheck: (_args, context) => {
          mayDrive(context, spec.id)
          if (shot) refuseAPathOnTheWrongComputer(context, spec.id)
        },
        ...(step
          ? {
              /*
               * The first change on a public website goes to the person, as it
               * does in the Electron app. Unknown is treated as public: a page
               * this side has not been told about is not one it may assume is
               * private.
               */
              escalate: (args: Record<string, unknown>, context: ToolContext): Tier => {
                const key = keyOf(args, context)
                const origin = originOf(lastUrl.get(key))
                if (origin !== null && isPrivateOrigin(origin)) return 'act'
                return origin !== null && granted.has(`${key}\u0000${origin}`) ? 'act' : 'alter'
              },
            }
          : {}),
        run: async (args, context): Promise<ToolOutput> => {
          const key = keyOf(args, context)
          if (step) {
            // Reaching `run` means any question was answered yes: this origin is now allowed for this window.
            const origin = originOf(lastUrl.get(key))
            if (origin !== null) granted.add(`${key}\u0000${origin}`)
          }
          const output = await driver.send(spec.wire, args, callingSession(context))
          const value = output.value as { url?: unknown } | null
          if (value !== null && typeof value === 'object' && typeof value.url === 'string') lastUrl.set(key, value.url)
          if (spec.wire === 'browser_close') lastUrl.delete(key)
          return output
        },
      }
    })
}

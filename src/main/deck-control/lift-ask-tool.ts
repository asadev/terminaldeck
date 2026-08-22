/**
 * `browser.lift_request` — the ask, and only the ask.
 *
 * ## What this is beside the tool that must not exist
 *
 * `worker-tools.ts` and `session-tools.ts` both record, at length, that there
 * is no `browser.lift` and there must not be: a tool that copies a signed-in
 * session between profiles is a tool that exfiltrates a login. Nothing here
 * weakens a word of that. This tool moves no cookie, reads no jar, and cannot
 * be retried into doing either — it files a **request** with the desk in
 * `browser-lift-requests.ts`, and the request surfaces in the browser's
 * Scraping panel as a row with two answers. The lift itself still runs only in
 * the main process, behind the same `ipcMain` channel as ever, when a person
 * arms and presses Approve on that row.
 *
 * ## Why the ask exists at all
 *
 * The old answer to "what does an agent that needs a login do" was
 * `browser.handover` — raise a banner over the page and hand the person the
 * baton. That covers *one page the agent is on*. It does not cover the fleet
 * case this feature is for: eight workers that need the session a profile
 * already holds, where there is no page of the agent's to banner and the
 * person may be nowhere near the browser. The panel's inbox was built for
 * exactly that ask (`ScrapingPanel.tsx` has drawn it since the panel landed)
 * and until 2026-08-22 no channel stood behind it — a control that rendered
 * and could never fire. This tool is the sender's end of that channel.
 *
 * ## The retry loop, priced at zero
 *
 * The named objection to a request tool is that an agent can ask in a loop.
 * The desk answers an identical open ask with the existing request rather than
 * a second row, caps the inbox at eight, and lets nothing an agent reaches
 * answer a request — see `browser-lift-requests.ts`, where each of those is a
 * tested rule rather than a sentence. What a loop buys is the same row it
 * already had, and a result that says so.
 */

import { fileLiftRequest } from '../browser-lift-requests'
import { slotName, windowsOf } from '../browser-binding'
import type { JsonSchema, ToolContext, ToolOutput, ToolSpec } from './catalogue'
import { withEmptiness } from './empty-result'
import { Refused } from './surface'

const SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    from: {
      type: 'string',
      description:
        'The profile whose signed-in session you are asking to have copied — its name as the person and the panel say it.',
    },
    into: {
      type: 'array',
      items: { type: 'string' },
      description:
        'Worker names to copy it into, from browser.workers. Omit to ask for every worker.',
    },
    reason: {
      type: 'string',
      description:
        'One line the person reads beside the ask: why you need these workers signed in. They decide on it, so say the real reason.',
    },
  },
  required: ['from'],
  additionalProperties: false,
}

/**
 * The same two refusals `worker-tools.ts` writes out per tool, written out
 * again here rather than shared, on that file's own argument: a shared helper
 * one tool forgot to call would be a gate with a hole in it.
 */
function mayAsk(context: ToolContext): void {
  const caller = context.caller
  const isSession = caller.kind === 'session' && caller.sessionId !== undefined
  if (!isSession && caller.kind !== 'local') {
    throw new Refused(
      'not-granted',
      'browser.lift_request only works for sessions at this machine. Asking for a person’s logins from a ' +
        'paired device is not something this app does. Say what you would have done and let them do it.',
    )
  }
  if (context.attended === false) {
    throw new Refused(
      'not-permitted-unattended',
      'browser.lift_request puts a question about the person’s logins in front of them, and there is ' +
        'nobody at the machine to answer it. Do not retry and do not look for another way. Say in your ' +
        'report what you would have asked.',
    )
  }
}

/**
 * Who asked, in words the inbox can print and a person can recognise.
 *
 * A session's *name* does not travel into a tool context, so the honest
 * handles are the ones this process really holds: the slot of a window the
 * person attached to the calling session — `B1` is vocabulary he already uses
 * — or the plain fact that it is a session or the copilot. Never a session id:
 * ids appear on no screen, and a row naming one would be the panel speaking a
 * language nobody at the keyboard reads.
 */
export function askerName(context: ToolContext): string {
  const caller = context.caller
  if (caller.kind === 'session' && caller.sessionId !== undefined) {
    const slots = windowsOf(caller.sessionId, caller.machineId ?? '')
      .map((window) => slotName(window.n))
    if (slots.length > 0) return `The session driving ${slots[0]}`
    return 'A session in this app'
  }
  return 'The copilot'
}

function str(args: Record<string, unknown>, key: string): string {
  const value = args[key]
  return typeof value === 'string' ? value : ''
}

function strings(args: Record<string, unknown>, key: string): string[] {
  const value = args[key]
  if (value === undefined || value === null) return []
  if (!Array.isArray(value) || value.some((entry) => typeof entry !== 'string')) {
    throw new Refused('not-permitted', `${key} must be an array of worker names`)
  }
  return value as string[]
}

export function liftAskTool(): ToolSpec {
  return {
    id: 'browser.lift_request',
    wire: 'browser_lift_request',
    /*
     * `act`, the same reading `browser.worker` gives its own tier: this call
     * changes what another surface shows — a row lands in the person's inbox —
     * and a call whose effect somebody else can observe is not a read.
     */
    tier: 'act',
    title: 'Ask the person to copy a signed-in session into workers',
    description:
      'Files a request, and only a request: it appears in the browser’s Scraping panel with Approve and ' +
      'Decline beside it, and copying the session is something only the person can do, there. Asking ' +
      'again for the same thing returns the same waiting request rather than filing another. The person ' +
      'may approve, decline, or do nothing — do not retry; report that you asked and move on. ' +
      'browser.workers shows afterwards which sites each worker is signed into.',
    index:
      'Ask the person — never do — to copy a profile’s signed-in session into worker profiles; the ask lands in their Scraping panel with two answers.',
    inputSchema: SCHEMA,
    precheck: (args, context) => {
      mayAsk(context)
      if (str(args, 'from').trim() === '') {
        throw new Refused('not-permitted', 'from names the profile whose session you are asking about')
      }
    },
    summary: (args) => `Ask for a session lift from ${str(args, 'from') || '?'}`,
    run: async (args, context): Promise<ToolOutput> => {
      mayAsk(context)
      const answer = fileLiftRequest({
        askedBy: askerName(context),
        from: str(args, 'from'),
        into: strings(args, 'into'),
        reason: args.reason,
      })
      if (!answer.ok) throw new Refused('not-permitted', answer.reason)
      const note = answer.repeated
        ? 'You already asked this. The same request is still waiting in the person’s Scraping panel — do not ask again; report that it is pending.'
        : 'The ask is in the person’s Scraping panel now, with Approve and Decline beside it. They may also do nothing. Do not retry; report that you asked.'
      return {
        value: withEmptiness(
          {
            asked: true,
            repeated: answer.repeated,
            requestId: answer.request.id,
            from: answer.fromName,
            into: answer.intoNames,
            note,
          },
          {
            // A filed (or re-found) request is one real thing; this tool has
            // no empty case, and says so on every result anyway — the same
            // spelled-out `empty: false` browser.worker carries, for the same
            // reason.
            produced: 1,
            whenNone: 'unreachable: a refused ask throws with its reason instead of answering empty.',
          },
        ),
        summary: { asked: 1, repeated: answer.repeated, empty: false },
      }
    },
  }
}
